---
project: Lightning
url: https://github.com/OpenFn/lightning
category: Automation and Data
relevance: high
verdict: Mature production Elixir/Phoenix workflow-automation platform on samen's exact stack; mine its run/snapshot execution model, retention/zero-persistence-worker discipline, and several libraries (libcluster_postgres, packmatic, sobelow) — but LGPL means patterns only, no code.
---

# 050 — Lightning (OpenFn)

## What the project is

Lightning is the v2 OpenFn platform: an open-source workflow-automation and data-integration platform used by governments and NGOs in 40+ countries (a certified Digital Public Good). Users build DAG workflows (jobs + triggers + edges) in a visual LiveView editor or via CLI, trigger them by webhook, cron, or Kafka, and monitor every execution in a unified history dashboard with per-project RBAC. Single edition (no open-core split), dual-licensed **LGPL-3.0/GPL-3.0**, ~5,100 commits, active CI (CircleCI, Dialyzer, Credo, Sobelow, ExCoveralls), Docker/Kubernetes deploys, live hosted instance at app.openfn.org.

Stack: Elixir ~>1.18, Phoenix ~>1.7, LiveView ~>1.0, Ecto/Postgres (no Ash — plain contexts), Oban ~>2.19, warnings-as-errors, a `mix verify` alias chaining coverage + format + Dialyzer + Credo + Sobelow.

Execution architecture (the distinctive part): Lightning itself never executes user job code. It maintains a queue of **runs**; a separate NodeJS **ws-worker** checks out an entire run over a websocket (JWT-signed run tokens), executes all steps in a sandboxed runtime engine, streams logs/status back, and requests credentials/dataclips on demand. The worker is deliberately **zero-persistence** — no database, no filesystem. Domain model: `WorkOrder` (one triggering event) → `Run`(s, incl. retries) → steps, with **workflow snapshots** pinning every run to the exact workflow version it started on (jobs/triggers can be freely edited or deleted without corrupting in-flight or historical runs), and **dataclips** (input/output state) governed by per-project retention policies. Other subsystems visible in `lib/lightning/`: `workflow_versions` + `version_control/` (GitHub project sync, project-as-code YAML via provisioning API/CLI), `auditing/`, `ai_assistant/` (chat assistant for job code), `kafka_triggers/` (broadway_kafka), `usage_tracking/` (anonymized daily usage reports to a central tracker), `webhook_auth_methods`, `collaboration.ex` backed by `y_ex` (Yjs CRDT bindings) for real-time collaborative editing, MFA via nimble_totp + eqrcode, credentials encrypted with cloak_ecto and described by ex_json_schema forms.

## What samen could adopt

1. **Snapshot-per-run workflow versioning.** *What:* every Automation run pins to an immutable snapshot of the workflow definition at enqueue time; editing/deleting actions never corrupts in-flight or historical runs, and history renders against the snapshot. *Why it fits:* samen's Automation engine (ADR-039: Action registry → Compile → Reactor, Run on AshStateMachine) already has RunRecord, but Lightning proves the operator-grade contract — "edit freely, history stays true" — that a multi-tenant automation surface needs; it also composes with ash_paper_trail (`versioned:`) already in the lifecycle substrate. *Effort:* **M**.

2. **WorkOrder ⊃ Run(s) retry model.** *What:* separate the triggering event (work order) from execution attempts (runs), so retry-from-start / retry-from-step is a new Run under the same WorkOrder, and the history UI groups attempts with a rolled-up status. *Why it fits:* samen's Health/Breaker + bounded RunRecord outcomes would gain a clean, auditable retry story without mutating past run records — same append-only spirit as the hash-chained audit. *Effort:* **M**.

3. **Zero-persistence executor + short-lived scoped run tokens.** *What:* the ws-worker pattern — executor holds no DB/filesystem, fetches credentials/state per-run via JWT-scoped claims, returns results through one channel. *Why it fits:* this is samen's token-blind/chokepoint philosophy applied to job execution; if samen ever executes tenant-authored code (or isolates AI agent tool execution), the "checkout-the-whole-run, stateless executor, per-run token" design is the proven Elixir-side reference. *Effort:* **L** (pattern to record in an ADR now, build later).

4. **Dataclip retention policies at the automation layer.** *What:* per-project data-storage settings — retention period for run input/output payloads, option to store nothing ("zero-persistence projects"), scrubbing of stored state. *Why it fits:* samen has a `retention` subsystem and vaulted PII, but automation run payloads/transcripts are exactly where residual PII accumulates (ADR-046 erasure envelopes for AI transcripts already gestures at this); a per-org automation-payload retention knob closes the loop. *Effort:* **M**.

5. **`libcluster_postgres` for node discovery.** *What:* libcluster strategy that clusters BEAM nodes through Postgres — no k8s API, no gossip infra. *Why it fits:* samen is Postgres-only by conviction and just proved multi-node Oban locally (L4); this makes production clustering config-free on any host while keeping the "nothing but Postgres" purity. *Effort:* **S**.

6. **`packmatic` for DSAR export.** *What:* streaming on-the-fly zip generation. *Why it fits:* G19 (DSAR self-serve export) is an open P2; streaming zip of a subject's data avoids buffering PII to disk/memory — matches the no-plaintext-at-rest posture. *Effort:* **S**.

7. **`sobelow` + `mix_audit` in the root gate.** *What:* Phoenix-specific static security scanning and Hex advisory audit inside a single `verify`-style alias, with warnings-as-errors. *Why it fits:* samen's ci.sh is deep on invariant verifiers but has no third-party security lint tier; Sobelow is cheap, Phoenix-aware, and would run in ci-fast. *Effort:* **S**.

8. **Project-as-code provisioning (export/import YAML + GitHub sync).** *What:* a provisioning API + CLI that round-trips an entire project (workflows, triggers, credentials refs) as YAML, plus optional GitHub repo sync for change review. *Why it fits:* samen's catalog-as-data and fleet directives want a declarative "app/automation spec" artifact for backup, review, and fleet rollout; Lightning shows the shape (and the auth pitfalls) of that API. *Effort:* **M**.

9. **Webhook auth methods as a first-class model.** *What:* named, reusable auth methods (API key / basic) attachable to webhook triggers, managed in UI and audited. *Why it fits:* samen has webhook ingress + Hammer rate limiting; promoting inbound-webhook auth to a catalogued, per-trigger resource is a small step that hardens the automation EventCapture path. *Effort:* **S**.

10. **Kafka trigger pattern (note only).** *What:* broadway_kafka-backed triggers with failure alerting. *Why it fits:* if samen ever needs high-volume ingestion beyond webhooks, Broadway-into-automation-EventCapture is the idiomatic route; Lightning's `kafka_triggers/` is a working reference. *Effort:* **L** — defer until a vertical demands it.

## What to ignore and why

- **The code itself.** LGPL-3.0/GPL-3.0 is incompatible with copying into MIT samen. Adopt patterns and independently reimplement; never vendor source.
- **NodeJS runtime + npm adaptor ecosystem.** Lightning's value is executing arbitrary JS jobs against ~100 npm adaptors. Samen's automation is deliberately a bounded 8-kind Action registry with compensation — importing an arbitrary-code runtime would break the approvals/masking guarantees that are samen's moat.
- **cloak_ecto for encryption.** Samen explicitly rejected Cloak-style column encryption (ADR-003) in favor of the per-subject-key vault + crypto-shred; Lightning's approach can't do erasure-by-key-destruction.
- **Bodyguard/plain-Ecto authorization.** Samen's Ash policy layer (OrgScope + PiiResolution, SAT-solved) is categorically stronger; nothing to take.
- **y_ex/Yjs collaborative editing.** Impressive, but real-time co-editing of definitions is far outside samen's operator-first needs; heavy Rust-NIF dependency for no current requirement.
- **AI assistant design.** Lightning ships job code+context to a hosted Apollo service with none of samen's masking chokepoint/token-blindness — samen's ADR-043/047 plane is strictly ahead; do not regress toward it.
- **Sentry/PromEx/scrivener/petal_components.** Samen already has OpenTelemetry with PII-safe spans, metrics egress, keyset pagination contract, and a first-party UI kit; swapping introduces vendor deps into surfaces INV-4 keeps clean.
- **Multi-tenancy model.** Lightning's project-scoped RBAC is shallower than samen's two-plane, three-identity org model; nothing to learn there beyond confirmation.
