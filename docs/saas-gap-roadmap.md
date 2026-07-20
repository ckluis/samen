# Samen SaaS Gap Roadmap

**Mission:** Samen is a meta-harness that makes building AND running a SaaS a joy. It has the
close-the-first-contract 80%. This roadmap ranks everything a SaaS needs that Samen is missing
or under-serves, and sequences gated, framework-first workstreams to fill it.

**Method (Phase 0 Discovery, 2026-07-09):** four parallel deep-dive audits, full evidence in
`docs/gap-discovery/`:
- [builder-dx.md](gap-discovery/builder-dx.md) — the builder's journey
- [operator.md](gap-discovery/operator.md) — running the SaaS
- [end-user.md](gap-discovery/end-user.md) — the tenant's users
- [harden-existing.md](gap-discovery/harden-existing.md) — depth-vs-claim audit of what's built

**North star for every item:** does this make building or running a SaaS on Samen more of a joy,
and does it level up the framework (samen_web / kernel) so every vertical inherits it?

---

## Headline diagnosis (all four lenses converge)

1. **The security/governance kernel is as deep as the gates claim.** Crypto-shred, two-plane
   masking, token-blind aggregates, hash-chained audit, verifier gate + destruction oracle,
   the generator's correct-by-construction output — all world-class with honest evidence.
2. **The product surfaces on top are demo-deep.** Only ~6 of ~30 LiveViews handle events;
   "New contact" buttons are unwired; marketing "sent" email goes nowhere (no-op adapter that
   marks `delivered`); Stripe sync is a stub; flags/search/files are resources with no engine;
   no pagination anywhere. A real first tenant hits a wall in week one on nearly every product
   feature — each an honestly-labeled stub, not a breach, but a wall nonetheless.
3. **Builder DX is scaffolding lag, not architecture lag.** Everything the verticals do thinly
   at runtime (pawchart: full UI in ~12 router lines), the generator doesn't emit — builders
   hand-copy web/API/seeds/observability/deploy from demo/pawchart. Near-zero
   time-to-gate-green masks a large time-to-first-visible-feature.
4. **One claim-integrity item:** the "provably non-PII" CDC/aggregate classifier is a
   name+type heuristic + human allowlist — benign-named freeform strings (e.g. `drv_notes`)
   pass as `:metadata` and mirror to ClickHouse. The mechanism is out of step with the
   load-bearing claim. (harden H-2)
5. **The strategic edge:** because governance plumbing already exists, analytics, DSAR,
   status/SLA, and delivery can ship *privacy-correct by construction* — exactly where
   incumbent operator tools are weakest for regulated B2B.

Three memory-carried residues were confirmed already fixed (Workspace header, F4.2, partial
F4.3) — do not re-scope.

---

## Ranked gap register (deduped across lenses)

Tiers: **P0** = week-one wall or claim-integrity · **P1** = joy multiplier, near-term ·
**P2** = important, sequence later. Layer: kernel / web (samen_web) / gen (generators+docs) /
op-todo (human operator task).

| # | Gap (cluster) | Lens | Delta in one clause | Joy | Effort | Layer | Tier |
|---|---|---|---|---|---|---|---|
| G1 | **Real CRUD + list ergonomics** | end-user, harden | Most LiveViews read-only; no pagination/sort/filter/bulk anywhere incl. JSON:API (unbounded reads) | H | M | web+kernel | ✅ shipped (WS-A) |
| G2 | **Delivery engine + notifications inbox** | end-user, harden, operator | Marketing send is a no-op stub; `Notification` resource has no inbox/engine/prefs; SLA breach is a silent state flip; kernel `Send.:create_checked` hardcodes `msp_suppression` | H | M | kernel+web | ✅ shipped (WS-A) |
| G3 | **PII classifier: heuristic → mechanism** | harden | "Provably non-PII" is name/type heuristic + allowlist; freeform strings leak to the aggregate plane by naming | H (trust) | M | kernel | ✅ shipped (WS-A phase A1) |
| G4 | **Generator catch-up (web/API/seed scaffolds)** | builder | gen.app emits headless data layer only; no resource/scope generators; JSON:API + seeds + observability wiring all hand-copied | H | M | gen | ✅ shipped (WS-D) |
| G5 | **Onboarding + empty states + first-run** | end-user | Inconsistent empty states, no first-run, no in-app sample data | H | M | web | ✅ shipped (WS-A) |
| G6 | **Feature-flag evaluation engine** | operator, harden | Flags are config rows nothing evaluates; no bucketing/targeting/rollout; experiments absent | H | S/M | kernel+web | ✅ shipped (WS-B) |
| G7 | **Revenue analytics (MRR movements)** | operator | Snapshot MRR only; no movements/churn/cohorts/NRR | H | M | web | ✅ shipped (WS-B) |
| G8 | **Tenant lifecycle admin** | operator | No provision/suspend/offboard/export/delete actions from the operator plane | H | M | web+kernel | P1 |
| G9 | **Global search** | end-user, harden | PII-safe index registry exists; zero search action / ⌘K / UI | H | M | kernel+web | ✅ shipped (WS-E) |
| G10 | **Getting-started tutorial + cookbook + README** | builder | 3 reference guides, no zero-to-feature walkthrough, no gate-failure index | M-H | S | gen | ✅ shipped (WS-D) |
| G11 | **Status/health/SLA + alerting** | operator | Metrics defined but unwired; bare `/healthz`; no status page/alerts/health dashboard | H | M | web+gen | P1 |
| G12 | **Product analytics over CDC** | operator | No event capture/funnels/retention; vault-excluded CDC projection is an ideal unused feed — privacy-correct-by-construction moat | H | L | new (web) | ✅ seed shipped (WS-B) |
| G13 | **Billing depth: Stripe sync + usage rating** | operator, harden | Stripe-mirror schema inert; SyncAdapter stub; no rating/proration/tax | M-H | L | kernel+op-todo | P1 |
| G14 | **Files engine** | end-user, harden | Metadata resource only; no storage adapter/upload/preview | M/H | M | kernel+web | ✅ shipped (WS-E) |
| G15 | **Import/export (CSV mapper)** | end-user | None at any granularity; catalog-as-data makes a generic mapper feasible; export = highest-risk mask-by-omission vector | M/H | M | web | ✅ shipped (WS-E) |
| G16 | **Deploy story (Fly/Neon templates)** | builder | Zero deploy artifacts; all carried as operator TODOs | H | M | gen+op-todo | ✅ shipped (WS-D) |
| G17 | **Per-tenant health scores + drill-down** | operator | Health is a single subscription-status pill | M-H | S | web | ✅ shipped (WS-B) |
| G17b | Fidelity follow-on (B9 gate F2): wire a pae-recency read into `__activity_days__` (currently hardcoded nil → activity factor always :unknown) + flag-adoption breadth into the adoption factor — pae now emits, the seam is ready | operator | — | M | S | web | P2 |
| G18 | **Self-serve settings (profile/2FA/sessions/API keys)** | end-user | Models exist, no screens, no `/settings` route | M | M | web | ✅ shipped (WS-E; 2FA/sessions host-owned by design) |
| G19 | **DSAR self-serve + compliance reporting** | operator | Erasure/audit built; no DSAR export, retention admin, SOC2 evidence surface | M | M | web | P2 |
| G20 | **Responsive/mobile + perf polish** | end-user | Zero `@media`; no `assign_async`/`stream`/skeletons | M/H | M | web | ✅ shipped (WS-E; skeleton primitive, `assign_async` deferred) |
| G21 | **Support desk depth (CSAT/macros/KB/routing)** | operator, harden | Desk only reads; SLA reporting absent | M | M | web | P2 |
| G22 | **Agent-grounding packaging (MCP, json diagnostics, reusable eval)** | builder | Differentiator built but unpackaged for builders | M-H | M | gen | P2 |
| G23 | **Product feedback → roadmap** | operator | Absent entirely | M | M | new | P2 |
| G24 | **i18n / timezone / currency** | end-user | USD + UTC hardcoded, no gettext | M | M | web | P2 |
| G25 | **A11y (kit-level)** | end-user | 3 aria/role/alt occurrences total; kit fix = fleet leverage | L-M | M | web | P2 |
| G26 | **Test/red-path scaffolds for verticals** | builder | 4 mandated test files hand-copied per resource | M | M | gen | ✅ shipped (WS-D) |
| G27 | **Misc kernel residues** | harden | Webhook A6 over-strict guard; rollup cron ADR-007; abbrev-registry tax ADR-006; Oban multi-node concurrency | L-M | S-M | kernel+op-todo | P2 |
| G28 | **Operator RBAC granularity / backlog tooling** | operator | Closed role set fine for now; backlog = link out | L | M | web | P3 |

Human-operator TODOs (not agent work, tracked for completeness): real Neon PITR drill, AWS
KMS+DynamoDB+S3-ObjectLock, ClickHouse ClickPipes activation, Stripe live keys, Fly account.

---

## Workstream candidates (gated, framework-first, one at a time)

### WS-A — "Product Reality" (G1 + G2 + G5, riders G3-adjacent masking tests) ← RECOMMENDED FIRST
> **✅ SHIPPED 2026-07-13** — all 5 phases (A1–A5) gated GO; workstream-wide adversarial gate GO: `docs/gate-ws-a.md`.
Turn the read-only demonstration into a product a tenant can actually use:
real CRUD on every mounted LiveView (kit-level form/table primitives so verticals inherit),
pagination/sort/filter/bulk as kit defaults + JSON:API `default_limit`, a real outbound email
delivery adapter (fix the kernel Send no-op + `msp_suppression` hardcode), in-app notifications
inbox + prefs fed by a delivery engine (SLA breach and system events flow into it), consistent
empty states + first-run.
**Why first:** every lens hits this wall; it is the difference between "gorgeous demo" and
"SaaS you can run"; nearly all of it lands in samen_web/kit so both verticals inherit; it
unblocks WS-B (operator surfaces need real data flow to be honest).
**New PII surfaces requiring per-plane masking tests:** CRUD write forms, notifications inbox.

### WS-B — "Operator Cockpit v1" (G7 + G17 + G6 + G12 seed)
> **✅ SHIPPED 2026-07-14** — all 9 phases (B1–B9) gated GO; workstream-wide adversarial re-gate GO: `docs/gate-ws-b.md`.
Revenue movements (MRR waterfall/churn/cohorts), per-tenant health drill-down, feature-flag
evaluation engine with targeting/rollout, and the first product-analytics events over the
vault-excluded CDC projection. Pure read/compute layers over already-governed data — the
privacy-correct-by-construction moat.

### WS-C — "Truth & Trust" (G3 + G19 + G27 selections)
> Carry from A1 gate (INFO-1): a host custom TYPE self-classifying `samen_pii_class/0 => :non_pii`
> bypasses the two-reviewer `non_pii!` clearance discipline (single-party escape hatch,
> `classification.ex:90`). No kernel type or vertical uses it today; close or reviewer-gate it here.
Replace the non-PII heuristic with a real mechanism (default-deny freeform strings from the
aggregate plane; explicit provable allowlist with verifier backing), DSAR self-serve export,
retention admin. Small surface, protects the load-bearing claim.
**Note:** G3 is claim-integrity — if WS-A is chosen first, G3 ships as a rider inside WS-A's
gate (it is kernel-scoped and independent) or immediately after. It must not wait two
workstreams.

### WS-D — "Builder Joy" (G4 + G10 + G16 + G26)
> **✅ SHIPPED 2026-07-16** — all 11 phases (D1–D11) gated GO; workstream-wide adversarial gate GO: `docs/gate-ws-d.md`.
Push the proven thin-mount patterns up into generators (web/API/seed/observability scaffolds,
resource/scope gen), zero-to-feature tutorial, gate-failure index, Fly/Neon deploy templates.
Highest leverage once the surfaces being scaffolded (WS-A) are real — generating today's
read-only patterns would scaffold the wrong thing.

### WS-E — "Table Stakes UX" (G9 + G14 + G15 + G18 + G20)
> **✅ SHIPPED 2026-07-18** — all 7 phases (E1–E7) gated GO; workstream-wide adversarial gate GO: `docs/gate-ws-e.md`.
Search engine + ⌘K, files engine with storage adapter, CSV import/export mapper (mask-by-
omission red-paths mandatory), self-serve settings, responsive pass.

**Sequencing logic:** A → (C rider) → B → D → E, revisiting rank after each gate. D
deliberately follows A so generators emit the *real* patterns.

---

## State after WS-A/B/D/E (2026-07-18) — the re-rank (all planned workstreams shipped)

**Shipped: 16 gaps** (G1/G2/G3/G5 in WS-A · G6/G7/G17 + G12-seed in WS-B · G4/G10/G16/G26
in WS-D · **G9/G14/G15/G18/G20 in WS-E**). **Every planned workstream (A/B/D/E) is now
gated GO** — WS-E closed the end-user P1 table-stakes (search, files, CSV, settings,
responsive). All six flagged mask-by-omission PII surfaces are now closed with per-plane
red-paths: notifications inbox + CRUD forms (WS-A), **file preview + export + profile
self-edit + search results (WS-E)** — the four WS-E surfaces bound into the standing
`scripts/sabotage.sh` harness and re-flipped by the E7.2 flagship cross-surface probe.

**Remaining work, ranked (no planned workstream left — these are the next-workstream candidates):**
1. **"Operator Cockpit v2"** (unassigned operator P1s: G8 tenant lifecycle · G11
   status/SLA/alerting · G13 billing depth/Stripe sync · G17b health-activity fidelity) —
   deepens WS-B; G13 has an operator-TODO half (live Stripe keys). The highest-value
   remaining cluster now that end-user table-stakes are done.
2. **WS-C remnants + P2 sweep** (:non_pii self-classify escape hatch [A1 carry] · G19 DSAR
   export/retention · G21 desk depth · G22 agent-grounding packaging · G23 feedback · G24
   i18n · G25 a11y · G27 kernel residues · ADR-025 verifier host-partition).
3. **WS-E follow-ons (documented, non-blocking):** real `Storage.S3` + `Scanner` impls
   (operator-TODO, fail-honest skeletons shipped) · per-abbrev tsvector trigger/GIN index
   for demo/pawchart search-at-scale · fleet-wide `assign_async`/`stream` perf rewrite
   (skeleton primitive shipped) · pawchart Identity scope to unlock its settings mount ·
   operator-plane search-box wiring.

**Standing carries (do not lose):** SMTP/ESP adapter = operator TODO (fail-honest) ·
Samen.Web.Api.PageLimitClamp until upstream Ash fixes the to_page raw-limit split · ADR-025 ·
demo `mk_agent` → Samen.Factory optional tightening · real Neon/AWS/ClickHouse/Fly drills =
human operator.

---

## WS-F1 — Honesty & Safety Smalls (2026-07-20)

Pre-publish honesty + public-repo hygiene pass. All five units shipped:

1. **Pitch honesty.** `index.html` + `docs/archive/samen-foundry.{html,txt}` claimed retiring
   Clerk+Stripe while end-user auth is host-owned (ADR-029) and Stripe sync is a documented
   Stub (`SyncAdapter.Stub` returns `{:ok, %{stub: true}}`). Softened every such instance to
   "Samen **governs** the identity/billing you **bring**" (auth host-owned; billing a governed
   Stripe-mirror with a host-owned sync adapter). Other consolidation claims (CRM/marketing/
   CMS/support/analytics-CDC/Oban) are genuine and left intact.
2. **/readyz readiness probe.** `/healthz` stays a static-200 liveness route; new
   `Samen.Web.Readiness.check/1` (framework-first, samen_web) probes Repo `SELECT 1` + KMS
   store (read-only `attest`) + Oban liveness and returns `{:ok|:error, per-component}`. Emitted
   page-controller gained `readyz/2` (200/503); both gen router templates route `/readyz`; the
   fly.toml traffic gate now rides `/readyz` (was `/healthz`). Verticals (driftwood, pawchart)
   patched. Red-path test with per-component positive controls (`readiness_test.exs`, 4 tests).
3. **Public-repo safety/candor.** `SECURITY.md` (private disclosure), GitHub private
   vulnerability reporting **enabled via gh** (`{"enabled":true}`), repo description + 10 topics
   set, README AI-authorship disclosure (every commit `Co-Authored-By: Claude`), `CHANGELOG.md`
   prepared for v0.1.0.
4. **CSV formula injection.** `Samen.Web.Csv.escape/1` now formula-neutralizes export cells
   (`= + - @` / leading TAB/CR → single-quoted literal; plain negative numbers exempt) at the
   serialization chokepoint. Red-path tests + sabotage patch `16-f1-csv-formula-injection.patch`.
5. **Repo hygiene.** `index.html` declared canonical; the divergent long-form doc relocated to
   `docs/archive/samen-foundry.{html,txt}` with an archived banner; README updated; 4 untracked
   `erl_crash.dump` files deleted.

**Deliberately DECLINED in F1 (do NOT build):**
- **First-party Stripe/ESP adapters** — the fail-honest boundary holds (unconfigured stub
  returns `{:error, :not_configured}` / labeled no-op, never a false success). Docs on-ramp
  (implement the `SyncAdapter` behaviour / SMTP delivery adapter) instead of a shipped integration.
- **CONTRIBUTING / Code of Conduct / GitHub-Actions CI** — internal-foundry lane; the adversarial
  gate is the local `./ci.sh` + sabotage harness. Revisit only if outside contributors materialize.
- **Full `handle_event` Endpoint sweep** — thin smoke only; a complete per-LiveView event audit
  is out of F1's ≤half-day-unit scope.

**F1 carries (do not lose):**
- **v0.1.0 tag is an OPERATOR action.** F1 did NOT `git commit`/`git tag` (per brief). After the
  operator commits the F1 work, tag `v0.1.0` (CHANGELOG.md [0.1.0] entry is ready and links the
  release tag). Private-vulnerability-reporting + repo description/topics were applied live via gh
  and need no commit.

---

## WS-F2 — Launchability On-Ramp (2026-07-20)

Doc-scoped phase with ONE reference implementation: prove day-1 login exists and reframe the
operator TODOs as a walkable launch gate. All four units shipped:

1. **BYO-auth ADR + reference wiring (ADR-031).** The launch-blocking hole was
   `Samen.Web.CurrentOrg.resolve/3` trusting `params["org"]` as identity. Chose a **minimal
   session-auth verifier over phx.gen.auth** (phx.gen.auth forks a parallel password schema past
   the vaulted `Identity.User`; the framework owns the *seam*, not the IdP). Shipped: framework
   `Samen.Web.Auth` (the `"samen_current_user"` authenticated-principal seam, session-only) + a
   fail-closed prod path in `CurrentOrg.resolve/3` (opt-in per mount via `:authn` +
   `:authorized_orgs` labels; OFF by default so demo/pawchart/all existing tests are untouched).
   Driftwood is the reference: `Driftwood.Auth` (PBKDF2 verifier, `:crypto`, no new dep, no
   committed credential), `DriftwoodWeb.Auth` (runtime-gated module plug + login/logout session
   helpers), `DriftwoodWeb.AuthController` (`/login` + `/logout`), router wires `:authn` to
   `{:app_env, :driftwood, :auth_required?}`. Red-path: an unauthenticated prod request derives NO
   actor; an authenticated user cannot act on a non-member org (`auth_prodpath_test.exs`, 13 tests).
   Sabotage `17-f2-authn-actor-gate-bypass.patch` flips both prod-path RED tests.
2. **First-real-launch checklist (`docs/launch-checklist.md`).** The operator TODOs reframed as a
   top-to-bottom launch gate: auth (arm + BYO IdP), ESP, Stripe keys, KMS/secrets, deploy, drills —
   each labeled BLOCKER/HONESTY/DRILL, each pointing at the fail-honest seam it backs.
3. **BYO-ESP how-to (`docs/guides/byo-esp.md`).** How to implement `Samen.Delivery.Adapter` in the
   HOST (gen_smtp or an HTTP ESP) without samen owning an adapter — the fail-honest boundary holds.
4. **Tenant onboarding** — folded into ADR-031 §4 (provision org → user+membership → credential →
   first login), not a separate build.

**F2 carries (do not lose):**
- **Operator-plane (SaaS-staff) auth** — F2 scoped to the TENANT actor. The `/operator/*` surfaces
  still assume a trusted seat; gate them with the same `Samen.Web.Auth` principal seam before
  exposing off-localhost.
- **Membership-seam for production** — driftwood's `:authorized_orgs` sources from the credential
  store (reference); point it at real `Identity.Membership` rows for prod (the authorization SoT).
- **Actor role on the authenticated path** is still `:member` (not read from the membership row) —
  enrich from `Membership.role` when operator-plane/tenant-admin distinctions are wired.
- Auth is opt-in per mount and OFF by default; a real launch sets `:auth_required?` true in prod
  config (see the checklist). The reference verifier is PBKDF2-over-config, NOT a production IdP.

---

## WS-F3 — Trust & Lifecycle (privacy + security) (2026-07-20)

Privacy/security lifecycle depth. Units shipped this phase (each guarantee ships green/red +,
where the brief mandates, a committed sabotage patch replayed by `scripts/sabotage.sh`):

4. **Bounded API-key expiry (deny-on-read) + last_used_at (F3.4).** `key_api_key` gained
   `expires_at` (a hard ceiling — never unbounded; `Samen.Scope.ApiKey.bounded_expiry/2` clamps
   every mint into `(now, now+max_ttl]`, default 90d / max 365d) + `last_used_at`. The demo auth
   plug DENIES-ON-READ (`expires_at > now` filter → an expired key never resolves to an actor) and
   best-effort stamps `last_used_at` via a least-privilege `:mark_used` action; `Samen.Scope.ApiKey`
   gained an `expired?/2` predicate + a fail-closed expiry conjunct in `authorized?/5`; the samen_web
   settings `mint/3` bounds expiry and `list/2` surfaces expires_at/last_used_at/`expired?`. Migrations:
   demo `key_api_key`, driftwood `dok_api_key`, samen_web `wok_api_key`. Trio: `scope_api_key_expiry_test`
   (11, samen_core) + `api_key_expiry_red_path_test` (3, demo deny-on-read) + hygiene additions (3, samen_web).
   Sabotage `18-f3-apikey-expiry-gate-bypass.patch` (drops the expiry conjunct) flips the deny red-path.

5. **Break-glass reconciliation + audit-chain verify sweep on the default crontab (F3.5).**
   `Samen.Jobs.default_crontab/0` now also mounts `Samen.AuditChain.VerifyWorker` (`*/15`, re-verifies
   every org's live hash chain, emits `[:samen, :audit_chain, :verify]` + per-tamper
   `[:samen, :audit_chain, :tamper]`) and `Samen.BreakGlass.ReconcileWorker` (`*/10`, anchors
   node-local deferred break-glass entries + emits `[:samen, :break_glass, :unanchored]`). New
   `AuditChain.verify_all/1`. Test: `audit_chain_verify_sweep_test` (5, incl. RED tamper-detected +
   telemetry). (No sabotage mandated for this wiring unit.)

2. **Per-scope retention / TTL config + worker (F3.2).** New `Samen.Retention` (spec-driven, framework-first
   — a host registers `%Samen.Retention.Spec{}` via `:samen_core, :retention_specs`), `Samen.Retention.Spec`,
   `Samen.Retention.SweepWorker` (nightly `0 3 * * *`). `action: :shred` crypto-shreds each expired row's
   subject via `Samen.Erasure`; `:delete` prunes. Fail-closed cutoff: a non-positive/nil TTL is REFUSED
   (never "sweep the whole table"). Documented defaults (`default_ttl_seconds/0`: files 365d · messages 180d ·
   tickets 365d · subscribers 730d). Trio: `retention_sweep_test` (9). Sabotage
   `19-f3-retention-does-not-fire.patch` (reports rows swept but skips the destroy) flips the sweep red-path.

3. **DSAR export + breach-scope enumerator (F3.3 / F3.6).** New `Samen.Dsar.export_subject/2` — the read
   mirror of `Samen.Erasure`: walks the subject's `pii_vault` rows + audit-chain trail into a structured
   plane-correct bundle and records a `dsar_export` event on the subject's chain. TWO-PLANE split with no
   cross-plane leakage: tenant plane → plaintext; operator plane → `••••` unless `grant?: true`; the bundle
   never carries a token/ciphertext. `Samen.Dsar.affected_subjects/2` enumerates distinct subjects over the
   audit chain in a time window (the breach-notification runbook's scope tool). Trio: `dsar_export_test` (4,
   incl. operator-masked red-path + serialized-bundle no-leak assertion + with-grant positive control).
   Sabotage `20-f3-dsar-plane-bypass.patch` (masks nothing on the operator plane) flips the plane red-path.

6. **Docs + residency ADR + breach runbook (F3.6, partial).** `docs/adr/032-data-residency-us-only.md`
   (US-only, documented; no per-tenant region selection today), `docs/runbooks/breach-notification.md`
   (contain → scope via `AuditChain`/`Dsar.affected_subjects` → tokens-vs-plaintext assessment → notification
   guidance → remediation), `docs/free-text-pii-residue.md` (the non-shreddable free-text residue + controls).

**F3 CARRIES (both CLOSED in F3b, 2026-07-20):**

- **UNIT 1 — Append-only ConsentEvent ledger — CLOSED (F3b).** Shipped as a NEW append-only kernel resource on
  the Marketing scope (`Samen.Scopes.Marketing.Blueprint.define_consent_event`, modeled line-for-line on the
  `mov` ledger `define_subscription_event`): events `granted`/`withdrawn` + `source` + bounded `purpose`, no
  update/destroy action, no PII column. Consent state is DERIVED from the ledger (`Samen.Marketing.Consent.state/3`,
  latest-event-wins, `occurred_at` at microsecond precision for a deterministic tiebreak) and is now the SOURCE
  OF TRUTH; the mutable `consent_at`/`msu_consent_at` column is kept only as a documented cache (Subscriber
  blueprint moduledoc). The erasure-surviving suppression HASH is `subject_hash` — the trace-sink pseudonym
  (`Samen.WideEvent.for_subject/1`) computed at append time and stored on the immutable row, so a `:withdrawn`
  verdict + its hash outlive a subject crypto-shred (proven by the erasure-survival test). Capture seam:
  `Samen.Marketing.ConsentChange` on Subscriber (best-effort after_action, like `SubscriptionMovement`). Wired
  into `Samen.Scopes.Marketing.__using__` + blueprint; abbrevs reserved via the sanctioned allocator per host
  (`demo/mce · driftwood/fmv · pawchart/vmv · samen_web/wmv · samen_core-fixture/sxv`); migrations added in
  demo/driftwood/pawchart + samen_web test-support + the samen_core suppression fixture. `refuse_if_undeliverable`
  in `samen_web/.../marketing/reads.ex` gained a fail-closed `:consent_withdrawn` conjunct off the ledger.
  Trio: `demo/test/marketing_consent_ledger_test.exs` (green append+derive · red append-only immutability · red
  erasure-survival · no-PII). Sabotage `21-f3-consent-ledger-immutability.patch` (adds a mutable `:mutate_consent`
  update action → flips the immutability test).

- **UNIT 6 code half — pii_reason_scan over TENANT free-text at write — CLOSED (F3b).** Shipped as a reusable
  chokepoint change `Samen.Pii.FreeTextScan` (`fields:` opt) running `Samen.PiiReasonScan.check/2` fail-closed at
  the write `before_action`; a tenant freeform value that is ITSELF a bare email/SSN/phone shape is refused
  before any row lands (DB unchanged). Wired framework-first on the kernel Marketing `Suppression.notes` column,
  so every marketing mount inherits the tenant free-text chokepoint at 0 authored LOC. Same blind spot as the
  operator scan by design (prose-embedded PII + names remain a documented residue). Red-path:
  `demo/test/marketing_free_text_pii_scan_red_path_test.exs` (green ordinary note · red email/phone refusal with
  DB-unchanged control). Sabotage `22-f3-free-text-pii-scan-bypass.patch` (scan an empty string → flips the
  red-path). `docs/free-text-pii-residue.md` updated (the F3 tenant scan is now shipped, not "being extended").

---

## WS-F4 — Verification Honesty (QA) (2026-07-20)

Test-honesty pass: close the gaps between what the suites CLAIM and what they PROVE. All five units shipped.

1. **Thin mount smoke per framework LiveView (`samen_web/test/samen/web/mount_smoke_test.exs`, 1 data-driven
   test over 34 surfaces).** ONE mount assertion per framework LiveView, driven through the REAL
   `mount/3` + `handle_params/3` + `render/1` lifecycle a mounted `live_session` route runs — the signed-session
   round-trip (`Mount.to_session`/`from_session`) + `CurrentOrg.resolve/3` + the initial load + render, the class
   of a documented past production 500 that the existing isolated render/load tests skip. New
   `Samen.WebTest.DataCase.mount_smoke/4` helper. Deliberately NOT an event sweep (declined — thin smoke only).
   The host-local LiveViews (demo contact/operator-impersonation, driftwood broker/operator-impersonation) were
   already mount-covered by existing dogfood/masked tests; the samen_web endpoint is intentionally OFF in :test
   (application.ex), so `live/2`-through-a-running-endpoint is not the fleet convention — the mount-lifecycle
   harness is.
2. **Red-path twins for the 5 remaining green-only masking surfaces.** THREE render surfaces got an in-test
   `assert_leak_detected!` anti-tautology twin (`use Samen.MaskingCase`): `notifications_masking`,
   `chat_unfurl_masking`, `ui_masking` — proving the operator `refute … =~ plaintext/token` scans are refutable
   (a clear/raw render leaks and IS caught). TWO fail-closed RESOLVER gates got committed sabotage patches:
   `23-f4-operator-apikey-plane-bypass.patch` (APP pawchart — the operator API-KEY posture reveals instead of
   omitting; flips `operator_plane_masking_test` "owner PII is ABSENT") and
   `24-f4-impersonation-plane-bypass.patch` (APP samen_core — the impersonation posture reveals instead of
   masking; flips `impersonation_masking_test` "PRESENT-but-MASKED"). Sabotage harness now 24 patches.
3. **StreamData property tests.** `samen_core/test/search_tsquery_property_test.exs` (3: `Samen.Search.query/3`
   never raises on arbitrary terms salted with tsquery operator chars — proves the `websearch_to_tsquery` choice
   holds end-to-end vs raw `to_tsquery`) + `samen_web/test/samen/web/csv_property_test.exs` (6: RFC-4180
   round-trip through the neutralization fixed point + the F1.4 formula-injection invariant — a round-tripped
   cell never starts with a formula lead char unless numeric). Pattern ref: `abbrev_property_test.exs`.
4. **Pool/queue headroom** added to `samen_web/config/test.exs` + `demo/config/test.exs` (pool_size 20 +
   `queue_target: 200` / `queue_interval: 2_000`, mirroring `samen_core/config/test.exs` — kills seed-dependent
   checkout-timeout flakes).
5. **`ci-fast.sh` iteration tier** — spikes + samen_core + samen_web only (skips the 3 gen_app probes +
   demo/vertical gates); documented at the top of the script + referenced in CLAUDE.md's Suites/CI section. NOT a
   substitute for `./ci.sh` before a milestone.

**F4 dep note:** `stream_data` added to `samen_web/mix.exs` (NOT `:test`-only — samen_core, a path dep, already
brings it as a prod dep, so a `:test` restriction conflicts).

**Suite totals after F4:** samen_core 1211 · samen_web 618 · demo 465 · driftwood 123 · pawchart 49. Sabotage
harness: 24 patches.

**F4 CARRIES (do not lose):**
- **Host-local LiveView mount smoke is via existing dogfood/masked tests, not the new sweep** — if a host adds a
  NEW bespoke LiveView (its own `load/*` arity), it needs its own mount assertion; the framework sweep only
  covers `Samen.Web.Router.__routes__/2` surfaces.
- **`mount_smoke/4` drives the mount LIFECYCLE, not the websocket transport** — samen_web has no Endpoint in
  :test by design. If an Endpoint is ever booted in test (e.g. for a connected-upload or push-event assertion),
  revisit whether a true `live/2` sweep should supersede the lifecycle harness.
- **UploadLive is the one render special-case** — its `render/1` reads live-upload assigns a connected socket
  supplies; the smoke passes a `%{upload_ref: :file_upload}` render-only stub (the mount itself is unmodified).

---

## WS-F5 — Ops Reality (2026-07-20)

Turn the observability/ops story from "defined but unwired" into a real operator surface. All six units shipped
(no new fail-closed SECURITY guarantee → no new sabotage patch; the harness stays at 24).

1. **Metrics egress (framework-first, OFF by default).** `Samen.Metrics.definitions/0` was defined but unreported.
   `Samen.Observability.child_specs/2` now starts a Prometheus reporter child behind a `metrics_egress?` flag
   (resolved from opts or `config :otp_app, Samen.Observability`), reporter module + name injectable (default
   `TelemetryMetricsPrometheus.Core` / `:\#{otp_app}_prometheus`). NO new dep in samen_core/samen_web/verticals —
   the reporter is a runtime `{reporter, arg}` value, so the tree compiles without the package; FAIL-HONEST: flag
   ON + reporter not loadable RAISES (never a metrics-on app exporting nothing). The `/metrics` HTTP surface is a
   framework `Samen.Web.MetricsController` (resolves the reporter via runtime `apply` → 200 when running, 404 when
   off — never a fake empty 200), mounted by a new `samen_metrics_route/1` router macro. Gen templates wired:
   `mix_exs_web` adds `{:telemetry_metrics_prometheus_core, "~> 1.1"}` (generated apps are real deployables),
   `runtime.exs` maps `SAMEN_METRICS_ENABLED` → the config flag, both gen routers add `samen_metrics_route(...)`,
   deploy runbook documents it (scrape over the PRIVATE net, not public). Verticals adopt the macro at 1 line each
   (driftwood/pawchart routers) as the leverage proof. Tests: `metrics_egress_test.exs` (8 — flag-off byte-identical
   child list + ON via opts/config + fail-honest RED) + `metrics_controller_test.exs` (4, samen_web).
2. **WS-E surface telemetry** through the same bounded machinery, three new `Samen.Metrics.definitions/0` series:
   `samen.files.upload.byte_size` (emitted by `Samen.Files.upload/3`, tag `result`), `samen.search.query.duration`
   (emitted by `Samen.Search.query/3`, no unbounded term label), `samen.csv.export.row_count` (emitted by
   `Samen.Web.Csv.export/3`, tag `result`). All best-effort (an emit never fails the operation). Tests:
   `files_upload_test.exs` (+2, incl. a rejected-upload-emits-nothing twin), `search_telemetry_test.exs` (2),
   `csv_test.exs` (+1). Label-lint (`mix samen.verify.metric_labels`) stays green (bounded tags only).
3. **`docs/runbooks/alerts.md`** — the page-a-human catalog: Oban backlog (`samen.oban.job.queue_time` + per-queue
   backlog; erasure/reveal governance-critical), discarded jobs, seal-lag (`[:samen,:audit_chain,:verify]` recency +
   `[:samen,:break_glass,:unanchored]` age; page on any `[:samen,:audit_chain,:tamper]`), KMS error rate, plus
   `/readyz` + pool saturation. Warn/page thresholds + first-response steps; links breach/break-glass/beam-introspection.
4. **`docs/runbooks/secrets-rotation.md`** — DATABASE_URL / SECRET_KEY_BASE / KMS (`SAMEN_KMS_KEY_ID`/`REGION`, the
   careful DEK-rewrap case) / webhook HMAC (vaulted per-webhook `pii_*_signing_secret` re-mint, not an env var).
   Fail-closed rule: never unset before the replacement is set + confirmed.
5. **`docs/runbooks/rollback.md`** — bad-RELEASE (code/config) rollback, DISTINCT from data recovery: Fly release
   rollback + the migration hazard (release_command migrates before traffic → a code rollback does not undo a
   destructive migration → escalate to `pitr-gameday.md`, linked not duplicated) + post-rollback verification.
6. **`scripts/fleet-status.sh`** — per-product required-secret drift check. Required set = the fail-closed baseline
   (DATABASE_URL/SECRET_KEY_BASE/PHX_HOST/SAMEN_KMS_KEY_ID/SAMEN_KMS_REGION) ∪ each product's own
   `config/*.exs` env references. Reports SET/EMPTY/MISSING per key + optional SAMEN_METRICS_ENABLED; exit 1 on any
   required missing (`--warn-only` for advisory). **NEVER prints a secret VALUE** (values read only inside a `-z`
   test). bash 3.2-compatible (no associative arrays).

**F5 CARRIES (do not lose):**
- **`/metrics` port is NOT public.** The endpoint rides the app port and is only served when egress is ON. Scrape it
  over Fly's PRIVATE network (internal scrape config / Grafana Agent sidecar) — do NOT add it to a public
  `[[http_service]]`. The deploy runbook says so; a real prod host must honor it.
- **Metrics egress reporter dep is on the HOST, not the framework.** samen_core/samen_web/verticals carry NO
  reporter dep (runtime-resolved). A vertical or generated app that flips `metrics_egress?: true` MUST add
  `{:telemetry_metrics_prometheus_core, "~> 1.1"}` (or its own reporter) to deps — else `child_specs/2` fail-honest
  raises. Generated apps already get the dep via the gen template.
- **The `/metrics` route on the verticals is ADOPTED but egress-OFF** — driftwood/pawchart mount `samen_metrics_route`
  (proving reuse) but ship no reporter dep + flag off, so the route 404s until an operator enables it. Demo is
  API-only (no browser router) and does not mount it.
- **fleet-status.sh required set is the gen-template contract + config grep**, since the verticals have no prod
  `runtime.exs` (they are local/dogfood). A product that grows a prod runtime with new `fetch_secret!` keys is
  picked up automatically by the config grep.
- **No new sabotage patch** — F5 adds observability + docs + a script, not a fail-closed security gate. The
  fail-honest metrics-egress raise ships a green+RED test pair (not a committed sabotage). Harness stays 24.

**Suite totals after F5:** samen_core 1223 · samen_web 623 · demo 465 · driftwood 123 · pawchart 49. Sabotage
harness: 24 patches.

---

## WS-F6 — Builder Leverage (2026-07-20)

The largest F-phase: close the builder-DX scaffolding gap and pay down the two god-files. All nine
units shipped (no new fail-closed SECURITY guarantee → no new sabotage patch; the harness stays at 24 —
but sabotage #15 was REFRESHED, see Unit 7).

1. **`mix samen.gen.resource --live` (the DX red flag — done first).** The resource generator now emits
   index/show/form LiveViews on the `Samen.UI` kit (pattern extracted from `driftwood/.../broker_live.ex`),
   wired into the generated app's router alias block (idempotent, fail-closed on a missing anchor). Masking
   by construction: each screen reads through Ash under a `plane: :tenant` scope; the 🔒 field resolves via
   the resource's `prepare(Samen.Api.PiiResolution)` BEFORE the LiveView sees it (no hand-mask, no `vt_*`).
   `Samen.Gen.Post` + `post_templates.ex` gained the emitters (`resource_{index,show,form}_live` + a mount
   smoke test); `gen_post_probe.exs` now passes `--live` and asserts emission + wiring + the generated app's
   ci.sh green + smoke. Cookbook Recipe 7. Also de-flaked the probe's resource-abbrev derivation (`jwh`
   collided with the primitives Webhook abbrev ~1/10 runs → remapped).

2. **`mix samen.gen.app --modules` mount menu + surface→macro table.** New `--modules chat,files,search,…`
   selection. `files`/`search` mount over `<App>.Primitives`, `csv` over the authored `Vertical`, `settings`
   over `Operator` — all ≈0 authored LOC. `chat` is documented-with-prerequisite (needs a materialized
   `Samen.Scopes.Chat` mount + a `Chat.Presence` server the generated app doesn't author) — NOT half-mounted:
   requesting it writes a prerequisite comment + prints a notice. The menu is real: with a mountable surface
   selected, `/` becomes `<App>Web.HomeLive` (`Samen.UI` `app_shell`+`module_nav`, a "Product" nav_group of
   the mounted surfaces). Surface→macro table in `docs/guides/generators.md`. `gen_app_flagship_probe.exs`
   generates with `--modules files,search,csv,settings` + asserts routes serve + menu renders. Off-by-default
   safe (no `--modules` output byte-identical to before). En route it fixed a genuine latent bug: framework
   `Samen.Web.Files.UploadLive.render/1` read `@upload_ref` as an assign mount never set (500 on first JS-less
   paint) — one-line masking-neutral fix in mount.

3. **`.formatter.exs` in generated apps.** New emitter (headless: `import_deps: [:ash, :ash_postgres]`; web adds
   `:phoenix`; api adds `:ash_json_api`). Required making `ash`/`ash_postgres` DIRECT deps in the gen mix.exs
   templates (mix format's `import_deps` only resolves direct deps) — pinned to the exact versions the SoT
   already uses. Also single-lined a config line so `mix format --check-formatted` passes on the generated tree.

4. **Upgrade/distribution ADR — DECIDED.** `docs/adr/033-in-monorepo-distribution-constraint.md`: Samen stays an
   explicit in-monorepo path-dep framework (verticals + every generated app resolve `samen_core`/`samen_web`
   via computed relative `path:`; `--target` only chooses WHERE the app dir sits, the dep always climbs back to
   this checkout). Hex + git-subtree REJECTED for now. Named revisit trigger: first external builder needing an
   app outside the tree / a second independent consumer / the `ash`/`ash_postgres` `==` pins loosening (those
   exact pins are the Hex precondition). Pointer added in `docs/guides/generators.md`.

5. **Docs bundle.** `docs/README.md` front-door index; `docs/adr/README.md` one-line-per-ADR index (all 33);
   ExDoc live for samen_core + samen_web (`{:ex_doc, "~> 0.34", only: :dev}` + `docs:` config; `mix docs` emits
   `doc/` HTML, gitignored; created `samen_web/README.md`); `docs/concepts/two-plane-masking.md` (the reader-facing
   two-plane + `Samen.Api.PiiResolution` + `%Samen.Masked{}` explainer, extracted from ADR-009/010); cookbook
   Recipes 8–10 (run a crypto-shred · write a sabotage patch · mount surfaces in a fresh vertical); the
   doc-command extractor extended over the new docs (+ a `no_plaintext_pii` rule; Recipe 9's manual sabotage
   commands stamped `bash operator-todo`).

6. **`templates.ex` externalized: 4979 → 710 LOC.** 55 big emitters moved to `samen_core/priv/templates/*.eex`,
   read at COMPILE TIME via `@external_resource` + `File.read!` (embedded in the BEAM; the tiny non-EEx
   `render/2` substitution engine is UNTOUCHED, so literal `<%= %>` HEEx in the templates still passes through).
   Behavior-identical, PROVEN by a new byte-parity oracle (`test/templates_parity_test.exs` + 212 golden
   fixtures across headless/web/web+api/web+api+deploy/`--modules`). All 3 gen probes green.

7. **`ui.ex` split: 1599 → 156 LOC.** 36 components split into 8 `Samen.UI.*` submodules
   (`ui/{shell,nav,table,form,overlay,feedback,object,helpers}.ex`); `Samen.UI` is now a 34-`defdelegate`
   facade — ZERO call-site churn across the 48+ `import Samen.UI` sites. Safe because Phoenix applies
   `attr … default:` in the CALLEE (empirically confirmed), so a delegate renders identically; only call-site
   attr-typo validation is lost (no warning, so `--warnings-as-errors` stays green). 623 samen_web tests green;
   demo/driftwood/pawchart compile zero-warning. **Regression owned + fixed:** the split moved `list_view/1` out
   of `ui.ex`, so sabotage `15-e6-list-loading-paints-rows.patch` (authored against `ui.ex:674`) no longer
   applied → **refreshed against `samen_web/lib/samen/ui/table.ex`**; verified apply → flips `loading-contract`
   → reverts byte-exact (SHA identical). Two source-scanner guard tests that hard-coded the single-file `ui.ex`
   assumption were widened to scan the whole `ui/` tree (intent strengthened, not weakened).

8. **`ci.sh` parallelized: 366.57s → 331.78s (~9.5%, default path).** The four independent gates (samen_web ·
   demo tests+CI · driftwood · pawchart) now run CONCURRENTLY behind explicit per-gate exit-code collection
   (a backgrounded failure does NOT trip `set -e`; each PID is `wait`ed + checked, per-app logs captured, ANY
   failure aborts before `ROOT CI: ALL PASSED`). The 3 gen probes + sabotage harness stay SEQUENTIAL (they share
   + byte-exact-restore the abbrev registry / patch the same apps). Failure-path proven (scratch harness + a
   real sabotage-abort). Also fixed a demo adversarial load-order flake surfaced by the higher concurrency
   (`Code.ensure_loaded(RevealAudit)` — faithful, not weakened). The win is Amdahl-bounded by the sequential
   prefix (spikes + samen_core + 3 gen probes ≈ 250s+), which Unit 8(B) below would attack.

9. **Dep pins aligned fleet-wide.** Sole genuine drift: `stream_data` `~> 1.3` → `== 1.3.0` (samen_web, demo,
   driftwood, pawchart, + all 3 gen templates), matching the samen_core SoT; golden fixtures regenerated via
   the sanctioned `SAMEN_UPDATE_GOLDEN=1` path. NO mix.lock re-resolution anywhere (every app already locked at
   1.3.0). `ash`/`ash_postgres`/`ecto_sql`/`oban`/Phoenix-family verified already consistent.

**F6 CARRIES (do not lose):**
- **Unit 8(B) — shared deps/_build across the 3 gen probes (execution-ready).** Each probe generates a
  DIFFERENTLY-configured scratch app and recompiles ash/ash_postgres/phoenix from scratch (~the sequential
  prefix's cost). CARRIED, not forced: a shared `_build` across differently-configured apps risks a spurious
  PASS masking a failure. Spec: warm `_build/test/lib/{ash,ash_postgres,ash_json_api,phoenix,…}` ONCE into an
  absolute cache dir OUTSIDE each probe's scratch, export `MIX_DEPS_PATH`/`MIX_BUILD_ROOT` into every probe
  subprocess (`compile_and_dump!` + the generated ci.sh + the boot `mix run`), keep each probe's byte-exact
  registry restore + `File.rm_rf!` scratch cleanup untouched; ACCEPTANCE = all 3 probes green + registry
  byte-exact. This is the remaining lever on the ci.sh wall-clock.
- **Unit 2 — `chat` via `--modules` needs a materialized `Samen.Scopes.Chat` mount + a `Chat.Presence` server**
  the generated app doesn't author; it's documented-with-prerequisite in the surface→macro table. Auto-mounting
  it is a future gen unit (emit the chat scope mount + presence child).
- **ADR-033 Hex trigger** (above) — the exact `ash`/`ash_postgres` pins are the deliberate in-monorepo
  reproducibility choice AND the Hex precondition; revisit on the named trigger.

**Suite totals after F6:** samen_core 1235 · samen_web 623 · demo 465 · driftwood 123 · pawchart 49. Sabotage
harness: 24 patches (sabotage #15 refreshed for the ui.ex→ui/table.ex path move). templates.ex 4979→710 LOC ·
ui.ex 1599→156 LOC. ci.sh 366.57s→331.78s.

---

## State after WS-A/B/D (2026-07-16) — the re-rank

**Shipped: 11 gaps** (G1/G2/G3/G5 in WS-A · G6/G7/G17 + G12-seed in WS-B ·
G4/G10/G16/G26 in WS-D). Every P0 is closed. The 2026-07-09 headline diagnosis above is
now HISTORICAL: the surfaces are no longer demo-deep (gate-ws-a), the operator has a
cockpit (gate-ws-b), and the generator emits a running product with permanent generative
proof in root ci.sh (gate-ws-d). ~2,270 tests + three probes across the tree.

**Remaining work, ranked:**
1. **WS-E "Table Stakes UX"** (G9 search · G14 files · G15 import/export · G18 settings ·
   G20 responsive) — the last planned workstream; closes the end-user P1s. Export and file
   preview are two of the six flagged mask-by-omission PII surfaces — red-paths mandatory.
2. **"Operator Cockpit v2"** (unassigned operator P1s: G8 tenant lifecycle · G11
   status/SLA/alerting · G13 billing depth/Stripe sync · G17b health-activity fidelity) —
   deepens WS-B; G13 has an operator-TODO half (live Stripe keys).
3. **WS-C remnants + P2 sweep** (:non_pii self-classify escape hatch [A1 carry above] ·
   G19 DSAR export/retention · G21 desk depth · G22 agent-grounding packaging · G23
   feedback · G24 i18n · G25 a11y · G27 kernel residues · ADR-025 verifier host-partition).

**Standing carries (do not lose):** SMTP/ESP adapter = operator TODO (framework side done,
fail-honest) · Samen.Web.Api.PageLimitClamp until upstream Ash fixes the to_page raw-limit
split · ADR-025 · demo `mk_agent` → Samen.Factory optional tightening · real
Neon/AWS/ClickHouse/Fly drills = human operator.

---

## Non-negotiable riders on every workstream
- Framework-first: capability lands in samen_web (or kernel where sanctioned); verticals only prove it.
- Masking by construction: every new PII surface ships per-plane masking tests (six flagged:
  notifications inbox, CRUD forms, file preview, export, profile self-edit, search results).
- Fail-closed proof: every guarantee ships a passing test + red-path must-fail test,
  anti-tautology probed; verifier gate + destruction oracle stay green.
- Adversarial gate per phase, findings fixed in-phase; commit each gated milestone; all suites
  + every ci.sh green before/after; ADRs for design decisions.
