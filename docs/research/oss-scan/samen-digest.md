# Samen — Capability Digest

Source repo: `/Users/clank/Desktop/projects/samen` (branch `saas-readiness-phase-1`; public at github.com/ckluis/samen, MIT). Snapshot date: 2026-08-18.

## 1. What Samen is

Samen is an **Elixir · Ash · Phoenix "SaaS foundry"** — a substrate for one builder (or a small studio) to launch *many* SaaS products fast without re-solving the hard parts each time. It is explicitly **not** a hosted product or a Hex package: it is an internal monorepo published so the architecture and verification discipline are legible. Every commit is AI-authored (Claude, `Co-Authored-By`), reviewed and adversarially gated by a human operator.

Its hero claim (the "honest" version, deliberately weakened from an earlier false-by-construction claim):

> **PII is masked by default. Reveal is grant-gated, second-party-approved, logged in a hash-chained log the tenant can read, and time-boxed. Cross-tenant views are aggregate-only and token-blind.**

Core value propositions:
1. **PII vaulting + masking by default** on every surface, plane, adapter, job, and AI call.
2. **Two-plane architecture**: every app runs a tenant product plane and an operator control plane (with masked impersonation); both masked by default.
3. **Crypto-shred erasure**: deleting a subject's key material (per-subject keys in an external KMS, outside Postgres/WAL) makes their vaulted PII unrecoverable across every tier — erasure = key destruction, not row scrubbing.
4. **Machine-readable catalog**: a schema dictionary for grounding LLMs and tooling.
5. **Generative proof**: `mix samen.gen.app` emits a *running* product (web UI, JSON:API, seeds, observability, tests, full 19-step verifier gate) that passes its own gate with zero hand-edits.
6. **An AI plane that structurally cannot leak PII** — token-blind by construction (chokepoint-minted masked payloads), not by policy.

## 2. Repo layout

| Path | Role |
|---|---|
| `samen_core/` | The kernel (web-dependency-free): vault + crypto-shred, masking, policies/RBAC/org-scoping, catalog, hash-chained audit, `samen.verify.*` verifier tiers, generators, scope blueprints, AI kernel, automation engine |
| `samen_web/` | Framework web layer: tenant + operator plane router mount macros, UI kit, masked rendering, identity spine, mountable product surfaces |
| `samen_stripe/`, `samen_postmark/`, `samen_ses/`, `samen_resend/`, `samen_anthropic/` | First-party-but-separate vendor adapter packages (path-dep on `samen_core` only; all vendor/HTTP deps live here, never in core — INV-4) |
| `demo/` | API-only dogfood host; canonical Identity policy-matrix and red-path reference |
| `driftwood/` | Freight vertical — deepest reference, includes crypto-shred game-day |
| `pawchart/` | Veterinary vertical — proves mount leverage (~188 authored lines of scope mounts + ~3,900-line hand-built clinic UI) |
| `spikes/` | Mechanism spikes s00–s07 that de-risked the kernel (still run by root CI) |
| `docs/` | 49 ADRs (`docs/adr/`), guides, gate reports (`gate-ws-*.md`, `gate-burndown.md`), `saas-gap-roadmap.md`, compliance docs |
| `scripts/` | `sabotage.sh` + 285 committed sabotage patches |
| `spec/` | `full-saas-readiness.md` master spec (workstreams WS-A..WS-L) |
| `_orch/` | Autonomous-run orchestration state (backlog.yaml, task handoffs T01–T10x, verify verdicts, jido-eval-report) |
| `ci.sh` / `ci-fast.sh` | Root fail-fast gate: spikes + kernel + generative probes + framework + all verticals; must end `ROOT CI: ALL PASSED` |

## 3. Kernel (`samen_core`) — module inventory

`samen_core/lib/samen/` (each a subsystem, most with a dir of resources + a facade module): abbrev/abbrev_registry, aggregate, **ai**, analytics, anchor (WORM), api/api_contract, approvals, archival, audit/audit_chain/audit_event, auth, **automation**, backup, billing, break_glass, **catalog**, cdc, **chokepoint**, clone, context, crm, custom_fields, custom_objects, delivery, dsar, enrichment, erasure, factory, feature_flags, files, fleet, impersonation, jobs, kms, mailbox, marketing, **masked** (`%Masked{}` renders `••••`, implements Phoenix.HTML.Safe), metrics, migration, no_plaintext_pii, non_pii, notifications, observability, operator_plane, **pii** (pii_classify, pii_reads, pii_reason_scan, pii_value_shape), **policy** (OrgScope FilterCheck, fail-closed on org-less actors), red_path, **resource** (`use Samen.Resource, archivable:/versioned:` sugar), retention, reveal, revenue/rollup, **scope/scopes**, search, sequences, support, tracer, transformers, **type**, **vault**, verifier(s), versioning, webhook, wide_event.

**Universal scope blueprints** (`Samen.Scopes.*`, ADR-004: library-authored Ash blueprint macros a host materializes into its own namespace/repo): analytics, automation, billing, calendar, cms, crm, docs, identity, locations, mailbox, marketing, outreach, primitives, sales_ops, support, tags, views, work (Project + self-referential Task w/ subtree cascade). Plus `samen_web`-side: chat.

**Rich declared types** (ADR-036): Money (wraps ash_money/ex_money), Percent, Score, Duration (ISO-8601 export), Priority, URL, Email, Phone, Address, plus `pii_address`/`pii_dob` vault classes. The vault write path re-runs each type's `cast_input` so vaulted values are validated + normalized. Tier-1 custom fields support 11 bounded types; a non-`pii_declared` custom field of type email/phone/address is refused BY TYPE (vault-bypass prevention).

**Mix tasks** (`samen_core/lib/mix/tasks/`): generators `samen.gen.app` / `gen.scope` / `gen.resource` (with `--field-type` rich-type menu) / `gen.agent`; `samen.abbrev.reserve` (deterministic allocator, host-namespaced registry); `samen.catalog.dump`; `samen.ai.smoke`; `samen.audit.freeform_projection`; and ~20 **verifier tiers**: `samen.verify.{agent_coverage, aggregate_privacy, ai_prompt_masking, api_contract, catalog_parity, erasure_completeness, fleet_wire, metric_labels, migrations, never_read_current, no_pan_columns, no_pii_columns, no_plaintext_pii, oban_queues, pii_classify, pii_reads, prefixes, same_org_fk, sink_schema, tnt_boundary, tnt_catalog, vault_declared_parity}`.

## 4. Web framework layer (`samen_web`)

`samen_web/lib/samen/web/` surfaces: **auth** (the self-serve identity spine), api (JSON:API, deny-by-default `/api/v1`, `PageLimitClamp`), authz, **operator** (control-plane workspace), tenant, settings, onboarding, notifications (inbox + prefs), billing, crm, support, marketing, automation, ai, chat (cross-plane realtime, catalog-driven masking-aware object unfurl), csv (RFC-4180 round-trip + formula-injection neutralization at the export chokepoint), files (LiveView upload chokepoint, quarantine-by-default), search (⌘K command palette over non-PII tsvector), saved_views, reads (keyset pagination contract), rate_limit (Hammer-backed auth+webhook ingress only), fleet (portfolio cockpit), flags, geo, ics, object_ref, webhook, work. Plus `ui/` (function-component kit + token CSS, kit-level responsive pass) and `Samen.Web.Mount` / `Samen.Web.Plane` (two-plane mountable-module pattern, ADR-009).

**Identity spine** (ADR-035, generator-emitted with zero hand-edits): registration (Org+User+Membership atomic, credential PII vaulted) → email verification → password reset (sessions invalidated, audited) → session management (remember-me, listing, revocation, deterministic org-cap eviction) → team invites (role selection, lifecycle) → OIDC via `assent` (Google reference IdP, honors TOTP step-up) → TOTP 2FA (`nimble_totp`, vaulted recovery codes) → onboarding wizard → login-family auth events into notifications/audit. End-user auth is deliberately **host-owned at launch** (ADR-029/031 BYO-auth on-ramp; `:auth_required?` armed fail-secure in `:prod` per ADR-045).

## 5. Architecture patterns (the load-bearing ideas)

- **Vault chokepoint**: every 🔒 field writes a `vt_*` token through one chokepoint (`Samen.Pii.WriteGuard` / `Samen.Vault.Change`; `Samen.Type.VaultField` has a last-line `dump_to_native` refusal). Plaintext PII is nowhere at rest. Custom thin vault on OTP `:crypto` AES-256-GCM driven by a `Samen.Kms` behaviour (ADR-003 rejected AshCloak/Cloak); per-subject keys in an external KMS (ADR-001; file-backed KMS sim locally).
- **Reveal grants**: second-party approval enforced in policy AND by DB `CHECK (granted_by <> requestor_id)`; `expires_at`, no in-place renewal; Oban auto-revoke enqueued in the same transaction as the approval.
- **Hash-chained audit** (ADR-002): append-only, tenant-readable; DB trigger refuses UPDATE/DELETE; periodically anchored to a WORM store; carries tokens only, so it stays crypto-shreddable.
- **Token-blind aggregate plane**: cross-tenant views (MRR, queues, cohorts) run on a separate token-blind actor over resources with no `pii_*` columns at all; the reveal path structurally refuses that actor — the two paths are mutually exclusive by construction. Default-deny CDC classifier for freeform columns (ADR-015): opt-in allowlist (vault-routed or two-reviewer `non_pii!`), not name/type heuristics.
- **Fail-honest adapters** (ADR-014/024/026/038): an unconfigured/unimplemented adapter returns `{:error, :not_configured | :not_implemented}` — never fake success. Applies to email delivery, Stripe sync, files storage (Local real, S3 skeleton), deploy artifacts (missing secret raises and names itself), AI providers, backup restore.
- **Two-plane + three-identity model** (ADR-010): the SaaS is itself an org (operator org) mounting the same universal scopes over tenant orgs as accounts; tenant-admin PII clear vs tenant end-customer PII masked drawn purely by composing `OrgScope` + `PiiResolution`. Masked impersonation included.
- **Catalog as data**: machine-readable schema dictionary drives CSV mapping, LLM grounding, object unfurls, verifier parity checks (`catalog_parity`, `vault_declared_parity`).
- **Chokepoint-everything**: single decrypt scanner (`Samen.Chokepoint`), single send path (`Samen.Delivery.Chokepoint`), single upload path (`Samen.Files.ChokepointGuard`), single AI egress path (`Samen.AI` chokepoint minting `%Samen.AI.MaskedPayload{}` — providers refuse raw strings by `FunctionClauseError`).
- **Abbrev registry**: every host app gets a short prefix/abbrev (e.g. `hb`/`hrb`) namespacing tables; global registry with host-namespaced ownership + `mix samen.abbrev.reserve` allocator + fail-closed flatten-conflict tripwire (ADR-006/023/025).
- **Approvals engine** (ADR-040 E3): generalized `Samen.Approvals` + Gate face, requester ≠ approver at policy and DB-CHECK layers — how any mutating AI/automation tool executes.
- **Automation engine** (ADR-039): `Samen.Automation.Action` 8-kind registry → `Automation.Compile` → `Reactor.Builder` with per-step compensation; `Automation.Run` on AshStateMachine; RunRecord bounded-outcome allowlist; Health/Breaker; EventCapture same-transaction Oban enqueue.
- **Lifecycle substrate** (ADR-040): soft-delete via ash_archival (`archived_at`, preparation-variant read filter, restore-capable, `archive_related` cascade) with terminal hard-delete/crypto-shred preserved; `versioned:` audit-on-write via ash_paper_trail.
- **Ash ecosystem posture** (ADR-037, deep adopt/reject gate over 12 packages): ADOPT ash_money, ash_archival, ash_oban, ash_paper_trail, Reactor, AshStateMachine, ash_rate_limiter (pinned 1.0.0, narrow); REJECT ash_ai (vendor deps into core, no chokepoint concept), ash_admin (first-party operator plane), ash_authentication rewrites; Jido agent framework also evaluated and rejected (`_orch/jido-eval-report.md`).

## 6. The AI plane (ADR-043) and agent loop (ADR-047)

- **AI kernel is hand-built** (ash_ai rejected). Keyless by default: deterministic fake provider in CI; `SAMEN_AI_LIVE=1` live lane; claim-evidence records which lane ran.
- **No-PII-egress chokepoint**: all prompt assembly passes the masking chokepoint; `mix samen.verify.ai_prompt_masking` + AST anti-bypass probe + permanent red-team eval tier (≥90% context-assembly bar).
- **`samen_anthropic`**: Anthropic Messages API adapter (`Samen.AI.Provider` behaviour); accepts ONLY chokepoint-minted `%MaskedPayload{}`; `embed/2` honestly `{:error, :not_implemented}`; fixture-transport cassettes in CI.
- **Embeddings + pgvector** (required, not optional-by-detection); Prompt resource with six verbs; runtime catalog grounding; **MCP server** (HTTP + SSE in samen_web, per-operator tokens, no stdio in prod; protocol 2025-03-26); support-operator and CRM/analytics AI surfaces.
- **Agent loop (ADR-047, BUILT, accepted 2026-08-17)**: first-party durable multi-step tool use governed by the EG2 egress class (tool defs/args/results are governed egress; per-turn history grant re-scrub). Zero new dependencies. **AI writes do not exist**: AI outputs are drafts/proposals; anything with side effects goes through the E3 approvals engine. Budgets/cost caps, transcript retention w/ erasure-envelope compliance (ADR-046), `mix samen.gen.agent` + `mix samen.verify.agent_coverage` (raw-spawn AST lock + coverage floor). Streaming deferred.

## 7. Fleet cockpit (ADR-044, "SaaS holding company in a box")

Dual-mode fleet registry (manual registration + opt-in self-registration/heartbeat with secured credentials), token-blind report wire, cross-product operator identity, fleet directives with honest degradation (unreachable app = observability without fleet flags, never a fake "applied"), tenant identity masked by default and unmasked per-viewer by role/account scoping (dedicated per-product operator×app→account assignment model; absent row ⇒ `:none`).

## 8. Key dependencies (pinned where load-bearing)

- **samen_core**: ash ==3.31.2, ash_postgres ==2.10.0, spark ==2.7.2, ecto_sql ==3.14.0, postgrex, oban ==2.23.0, ash_oban, ash_money + ex_money(+_sql), ash_archival, ash_paper_trail, ash_state_machine, simple_sat (pure-Elixir policy SAT solver, no NIF), telemetry_metrics, opentelemetry(_api/_ecto — db_statement disabled so no `pii_` token serializes into spans), phoenix_html (for `%Masked{}` Safe impl), jason, stream_data. **Zero vendor/HTTP deps in core (INV-4).**
- **samen_web**: phoenix ~>1.8.9, phoenix_live_view ~>1.2.9, ash_phoenix (forms), assent (OIDC protocol lib), nimble_totp, ash_rate_limiter ==1.0.0 + hammer ~>7.0, samen_core (path).
- **Adapter packages**: `req` (HTTP) lives only in samen_stripe/samen_anthropic/ESP packages.
- Toolchain: Elixir 1.20 / OTP 29, local PostgreSQL.

## 9. The verification story (the point of the repo)

Every guarantee ships with a green proof, a red-path proof, and a **sabotage** proving the test can fail ("a test that cannot fail is a bug"):
- **Sabotage harness**: `scripts/sabotage.sh` replays 285 committed patches (`SAMEN_SABOTAGE=1 ./ci.sh`): SHA-256 touched files → apply → *named* tests must fail → revert → byte-exact restore verified.
- **Destruction oracle**: `mix samen.verify.no_plaintext_pii` runs as a separate OS process across every tier (domain rows, vault, audit, rollups, Oban args, KMS store) attesting a shredded subject is unrecoverable; driftwood's crypto-shred game-day regenerates and re-verifies per CI run.
- **Generative proof**: root `ci.sh` generates a fresh app, runs its entire gate, seeds/boots/HTTP-probes it, and sabotages the generated gate to prove non-vacuity (`gen_app_flagship_probe.exs`, `gen_post_probe.exs`, `gen_agent_probe.exs`; collision-proof abbrev derivation via `Samen.Gen.ProbeAbbrev`).
- **AC-mapped gate reports** in `docs/gate-*.md`; every workstream ends in an adversarial gate (GO/NO-GO). Newest: F1–F7 burn-down gate (`docs/gate-burndown.md`, GO).
- **Docs verified as code**: every fenced command in README + getting-started is checked against the CI probes' executed set by `doc_commands_test.exs`.
- Suite counts (directional, 2026-08): samen_core 2606, samen_web 1711, demo 465, driftwood 123, pawchart 49; 285/285 sabotages flip.
- Compliance docs: `docs/compliance-story.md` (GDPR/SOC2 control-posture, explicitly NOT certification), `docs/claim-evidence.md`, `docs/claim-sweep.md` (claim→evidence audits).

## 10. Development process / meta-conventions

- **Autonomous agent loop**: `_orch/` holds a ~105+-task planned DAG (backlog.yaml, per-task handoffs, verify verdicts) executed in 7 phases with phase gates that run full `./ci.sh` (INV-3). Cross-cutting 50+-file changes decompose into ADR + phased items ("decompose-cross-cutting-changes rule"); ADRs are docs-only, batches build.
- **Invariants INV-1..7**: mask-by-default survives everything; two-plane discipline; full gate at every phase boundary; fail-honest + vendor-free core; substrate-first (capabilities land in core/web/generators, verticals only prove); docs/claims sync in the same phase; masked AI egress.
- **Determinism discipline**: loop-until-dry flake sweeps (dry-twice stop condition), flake ledger + RED-on-revert regression tests; gate tasks run foreground/synchronous.
- Numbered workstreams from two roadmaps: `docs/saas-gap-roadmap.md` (G1–G28 gap register, WS-A/B/C/D/E/F1–F7 — A/B/D/E + F1–F7 burn-down all shipped/GO) and `spec/full-saas-readiness.md` (WS-A identity … WS-L ops hardening — the current, mostly-shipped commercial-readiness run).

## 11. Open gaps, caveats, and roadmap themes (as of 2026-08-18)

**Honestly-simulated / operator-TODO (human-gated, NOT claimed done):**
- Real Neon PITR drill, real AWS KMS + DynamoDB + S3 Object-Lock (WORM), ClickHouse ClickPipes activation, live Stripe keys, Fly production deploys. Local sims (file-backed KMS, local PITR harness, LocalPgDump backup verification, two-BEAM-node Oban :peer proof) exercise the same invariants; their numbers are labeled sims/proxies.
- Live lanes documented-but-not-CI: `STRIPE_TEST_KEY`, `SAMEN_POSTMARK_SMOKE`, `SAMEN_ESP_LIVE`, `SAMEN_AI_LIVE`.

**Known product-depth gaps (from the gap register, still open):**
- G8 tenant lifecycle: dunning surface shipped; provision/suspend/offboard operator actions still open.
- G11: `/readyz` + metrics-egress/alert runbook shipped; **public status page still open**.
- G13 billing depth: plan/entitlement editor shipped; **Stripe sync is a stub** (`SyncAdapter.Stub`), usage rating/proration/tax = op-todo (live keys). Samen "governs the Stripe-mirror you bring" — it does not move money today.
- G19 DSAR self-serve export + retention admin (P2); G21 support-desk depth (CSAT/macros/KB/routing, P2); G22 agent-grounding packaging for builders (P2); G23 product feedback→roadmap (absent); G24 i18n/timezone/currency (USD+UTC hardcoded, no gettext); G25 a11y kit pass; G28 operator RBAC granularity (P3).
- WS-E follow-ons: real `Storage.S3` + virus `Scanner` impls (fail-honest skeletons shipped); per-abbrev tsvector trigger/GIN index for search-at-scale; fleet-wide `assign_async`/`stream` perf rewrite (skeleton primitive only); pawchart Identity scope; operator-plane search-box wiring.
- ADR-025 full abbrev/verifier host-partition: deferred (bounded tripwire shipped instead). ADR-007 rollup cron wiring: deferred. Oban multi-node in production: proven locally only.
- Carried P2s from the burn-down gate: G8 dunning `metrics/3` is an in-memory fold not a DB aggregate; G17b flag-adoption fold into the health score.
- Non-PII self-classify escape hatch (`samen_pii_class/0 => :non_pii` bypassing two-reviewer clearance) — carried, unused today.
- AI streaming deferred (ADR-047). SAML documented as extension seam, not built. Data residency US-only (ADR-032). Distribution stays in-monorepo (ADR-033) — no Hex packages.

**Current run state:** branch `saas-readiness-phase-1` is the near-complete full-saas-readiness burn-down; latest commits are Phase-7 compliance docs (K1/K2/K3), infra proofs (L4 multi-node Oban, L6 backup verification), and authz read-scope lint hardening. Remainder is credential-gated cloud infra (T88/T89/T91) + the final gate (T93), operator-pending. The work rides an open PR (BATON run) rather than main.

**Roadmap themes to expect next:** operator cockpit v2 depth (tenant lifecycle actions, status page, real Stripe sync), WS-C remnants/P2 sweep (DSAR, desk depth, i18n, a11y), real-infrastructure drills (WS-L: Neon/KMS/S3/Fly), and packaging the agent-grounding differentiator (MCP/eval harness) for external builders.

## 12. One-line positioning for evaluators

Samen = a verification-obsessed, AI-authored Elixir/Ash monorepo framework whose moat is *governance by construction* (vault chokepoints, two-plane masking, token-blind aggregates, crypto-shred, fail-honest adapters, generative CI proof, 285-patch sabotage harness) — world-class deep on the trust kernel, honestly demo-to-first-cut on some commercial product surfaces, with live-vendor integration and cloud infra drills deliberately left as labeled operator TODOs.
