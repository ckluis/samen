---
project: CYFR
url: https://github.com/cyfrworks/cyfr
category: Agent Platforms With License Warnings
relevance: medium
verdict: Pattern quarry, not a dependency — an Elixir/Phoenix agent control plane whose enforcement-record, consent-pinning, and vault-reference patterns map cleanly onto samen's approvals/AI plane, but the product itself is FSL-encumbered on its policy core, single-user, and immature (0 stars).
---

# 012 — CYFR

## What the project is

CYFR ("Give your AI power, not trust") is a self-hosted control system for AI agents that sits between LLMs and external systems: the model *proposes* actions, CYFR validates them against explicitly granted permissions, and sandboxed WASM components *execute* them. Notably for samen, the backend is an **Elixir/Phoenix umbrella** (apps: `cyfr` core + Sanctum policy layer, `codex` CLI, `porta` React PWA, `mcp-bridge`, `locus`, `opus`), Phoenix ~>1.8.6 / LiveView / Bandit / Ecto (SQLite default, Postgres optional), OpenTelemetry + Prometheus telemetry, `req`/Finch HTTP, ueberauth for OIDC/GitHub/Google.

Component model: **Reagents** (pure compute, no I/O), **Catalysts** (I/O), **Formulas** (orchestrations, with SSE/PubSub execution-event streaming for agentic loops), **Tinctures** (runtime-managed HTML/JS frontends), all versioned as `type:publisher.name:version` WASM binaries, Sigstore-signed. Permission model: **Connections** (encrypted credentials) → **Profiles** (immutable consent revisions binding a component's declared needs to specific Connections; grant a whole component line or pin to a version; revocation immediate on next run) → **Enforcements** (per-execution records of what was approved vs what actually executed). MCP everywhere: components exposed as MCP tools; `mcp-bridge` wraps stdio MCP servers behind HTTP with namespaced tool prefixes (`bridge:fs__read_file`); MCP headers accept `vault:CONNECTION_NAME` references resolved at request time. Deployment is Docker Compose, **single-user by design**, 507 commits, 0 stars, active releases.

Licensing (why it is in the warnings category): core is Apache-2.0, but **Sanctum — precisely the auth/policy/audit/tenancy subsystem — is FSL-1.1-Apache-2.0** (source-available, non-compete restricted, converts to Apache-2.0 two years after each release). The part of CYFR most relevant to samen is the part you cannot freely embed in a competing product.

## What samen could adopt

1. **Enforcement records: approved-scope vs actual-egress reconciliation.**
   *What:* CYFR pairs each execution with an immutable record of what consent authorized and what the run actually did, surfaced as first-class "Enforcements" in the dashboard.
   *Why it fits:* samen's ADR-047 agent loop already has RunRecord + hash-chained audit + E3 approvals, but the join "this approval covered X; the transcript shows the run touched X and only X" is implicit. A per-run enforcement reconciliation (and a `samen.verify.*` tier asserting no tool call outside the approval's scope) is exactly samen's governance-by-construction idiom.
   *Effort:* M.

2. **Version-pinned, immutable consent revisions.**
   *What:* CYFR grants apply to a component *line* by default or pin to a specific version; consent is recorded as an immutable revision rendering exactly what was approved; a changed component means the pinned grant no longer covers it.
   *Why it fits:* samen approvals currently approve an action instance; automation actions and AI tools evolve. Recording the approved action *definition hash* in the approval and fail-closing when the definition drifts prevents "approved v1, executed v2" — a natural extension of samen's requester≠approver DB-CHECK discipline.
   *Effort:* M (hash of `Samen.Automation.Action` / tool def into the Approvals record + a policy check).

3. **`vault:<name>` credential indirection at the egress chokepoint.**
   *What:* secrets never appear in configs or headers; a `vault:` reference is resolved to the sealed credential at request time inside the trusted runtime.
   *Why it fits:* samen's fleet self-registration credentials, webhook secrets, and any future outbound-MCP or automation HTTP step headers could carry `vault:` tokens resolved through `Samen.Kms` at the delivery/AI chokepoint — keeps plaintext secrets out of automation definitions the same way `vt_*` tokens keep PII out of rows.
   *Effort:* S.

4. **Request-anchored causal chains ("Activities" feed + `log correlate`).**
   *What:* a unified MCP-log + execution feed where every audit line, tool call, and run is correlated to the originating request, with a CLI verb to pull the whole chain.
   *Why it fits:* samen has wide_event/tracer/audit but the operator-plane UX of "show me everything this one agent turn caused" is an open cockpit-v2 theme; correlation-id-anchored chains over existing audit events is mostly a read-model + UI.
   *Effort:* M.

5. **Explicit per-tenant execution concurrency caps.**
   *What:* `CYFR_MAX_CONCURRENT_EXECUTIONS` (global) and `..._PER_TENANT` caps on agent/automation runs.
   *Why it fits:* samen's AI plane has budgets/cost caps (ADR-047) but per-tenant *concurrency* fairness for agent loops and automation runs is a cheap noisy-neighbor guard expressible with existing Oban queue partitioning.
   *Effort:* S.

6. **MCP stdio→HTTP bridge pattern with namespaced tool prefixes** (future, if samen ever *consumes* external MCP tools rather than only serving them).
   *What:* wrap stdio MCP servers behind an HTTP gateway, prefix tools by backend to avoid collisions, rate-limit the `/mcp` ingress per client IP.
   *Why it fits:* samen's MCP posture is server-side, HTTP+SSE, no stdio in prod — the bridge is the client-side complement that preserves that posture, and tool namespacing prevents grounding ambiguity in the catalog.
   *Effort:* M–L; only when outbound MCP lands on the roadmap.

## What to ignore and why

- **CYFR as a dependency or embedded platform.** Sanctum (the auth/policy/audit core) is FSL-1.1 — non-OSI, non-compete-restricted until each release's 2-year conversion — which is disqualifying for MIT-licensed samen even before fit questions. And samen already rejected far more Elixir-native options (ash_ai, Jido) for less.
- **The WASM component registry/build pipeline (Rust→WIT→WASM, Sigstore signing, publisher namespaces).** It solves third-party untrusted-code distribution — a problem samen doesn't have; samen's automation actions are first-party Elixir behind a bounded 8-kind registry. Worth remembering only as the pattern (wasmex-style sandboxing) if tenant-authored code ever becomes a requirement — that would be an L-effort ADR of its own.
- **Reagent/Catalyst/Formula/Tincture nomenclature and runtime-managed frontends.** Samen's LiveView-first, mountable-plane architecture already covers this; adopting the taxonomy would add vocabulary, not capability.
- **ueberauth-based identity and the React PWA.** Samen's generator-emitted identity spine (assent OIDC, nimble_totp) and LiveView UI kit are deliberate first-party choices; nothing here beats them.
- **Single-user/SQLite deployment posture.** Opposite of samen's multi-tenant two-plane model; the ops story (Docker Compose + Caddy) offers samen nothing new.
