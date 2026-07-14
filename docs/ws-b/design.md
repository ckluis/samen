# WS-B — "Operator Cockpit v1" · Design Spec

- **Status:** Design (buildable). Build phases follow this spec + ADR-017..021; each phase is independently committable + gate-able.
- **Date:** 2026-07-13
- **Scope owner:** WS-B design sub-orchestrator (opus). Design only — no code touched.
- **Reads:** `docs/saas-gap-roadmap.md` (WS-B = G7 + G17 + G6 + G12 seed), `docs/gap-discovery/operator.md` (evidence base), `docs/gate-ws-a.md` (WS-A shipped: CRUD/kit/notifications/bounded-reads exist), `docs/cdc-analytics-tier.md`, `docs/adr/007-rollup-cron-worker.md`, existing ADR-001..016, live tree.
- **Mission:** turn Samen's world-class governed substrate (billing scope, token-blind aggregate + k-anon floors, CDC projection, notifications engine, rollup framework) into the operator **cockpit** it is missing — revenue movements, per-tenant health, a flag evaluation engine, and the first product-analytics events — **entirely as read/compute/capture layers over already-governed data**, framework-first, privacy-correct by construction.

**North star (measured):** every capability lands in `samen_web` (operator plane) or `samen_core` (kernel, only where sanctioned — flag evaluation + event capture); `driftwood` + `pawchart` PROVE inheritance at ≈0 vertical LiveView lines via the existing `samen_operator_routes/2` macro + one domain-mount.

---

## 0 · Grounding — what exists today (cited, from this pass)

**Operator plane (WS-A + ADR-010).** `samen_web/lib/samen/web/operator/reads.ex` assembles accounts (tenant-orgs CRM), platform billing, and desk over the operator org's OWN book on the TENANT plane (PII clear — the SaaS owns it). MRR = `Enum.reduce` over active subscriptions × monthly price (`platform_billing/2:161`); `account_metrics/3` sums MRR live. Health today is a single pill from subscription status (`reads.ex:555-560`: active→healthy, past_due→at_risk, cancelled→churned). Operator LiveViews (`AccountsLive`, `PlatformBillingLive`, `DeskLive`, optional `AggregateLive`) are declared **inside** `samen_operator_routes/2` (`router.ex:139-147`) — adding a new operator page there means every vertical that calls the macro inherits it at 0 LOC.

**Billing scope.** `samen_core/lib/samen/scopes/billing/blueprint.ex`: `Subscription` has `status ∈ {active, inactive, trialing, past_due, cancelled, unpaid}`, `customer_id`, `plan_id`, `current_period_end`, `trial_end`/`cancel_at`/`cancelled_at`; `Invoice`, `Plan`, `Price` (monthly/annual). **Subscription has NO status-change event / audit trail today** — its `changes do` block carries only `SameOrgFk`. This is the load-bearing G7 gap (movement attribution needs the events).

**Notifications engine (A4).** `Samen.Notifications.Engine.notify/1` (record→vault-route body→broadcast id-only envelope→prefs-gated dispatch) + `Samen.Notifications.StatusChange` — an Ash change already attached to `Invoice` as `change({StatusChange, event_prefix: "invoice", statuses: [...]})`. **This is the reusable event-emission seam.** `Notification` abbrev `pnt`; `NotificationPreference` abbrev `npr`.

**Token-blind aggregate + floors (LOAD-BEARING).** `Samen.Aggregate.read_all/2` routes every cohort row through: query-budget accounting → `budget_suppress` → `Samen.Aggregate.Privacy.apply/3` (k-anon `min_cohort = 5`, l-diversity `min_distinct = 2`) → optional DP noise. A cohort under floor is replaced by `%Samen.Aggregate.Suppressed{reason:, k:/l:/limit:, observed:}`. The actor is the fixed singleton `%Samen.Aggregate.Actor{id: "operator_aggregate", kind: :operator_aggregate}`. Resources declare `aggregate_cohort_spec/0` (`%CohortSpec{cohort_key_columns, cohort_count_column, distinct_sensitive_column, value_columns, sensitive_attribute}`); a resource with none returns `{:error, :no_cohort_spec}` (fail-closed). `mix samen.verify.aggregate_privacy` fails closed on any aggregate resource lacking a spec. **These floors CONSTRAIN cross-tenant cockpit analytics — WS-B designs within them, never around them.**

**Rollup framework (ADR-007).** `Samen.Rollup.Spec{name, table, subject_column, suppressed_column, rebuild_sql: {delete_sql, insert_sql}, bounded_columns}` registered via `config :samen_core, :rollups`; `Samen.Jobs.RollupRefreshWorker` (queue `:rollups`, cron `*/10 * * * *`, concurrency 2, calls `rebuild_all/1`). Erasure `erase_subject/3` picks REBUILD (raw retained → recompute subject-free) vs SUPPRESS (flip `suppressed_column = TRUE`) arm. **ADR-007 carry:** the `Spec` is implicitly `source: :aud_event`; domain-sourced rollups (our revenue rollup) need the `:source` generalization ADR-007 deferred to a 3rd vertical. WS-B decides this explicitly (ADR-018).

**CDC projection (A1, default-deny).** `Samen.Cdc.Projection.project/1` returns only token-blind columns (vault `vt_*` tokens, bounded ids, enums, timestamps, numbers, metadata); freeform strings default-deny to `:plaintext_pii` and are EXCLUDED. `Samen.Cdc.LocalPostgres` is the faithful local sim (`cdc_mirror` schema); ClickHouse is a not-connected skeleton. `read_current/3` ALWAYS raises (never-read-current); analytics reads mark their module `use Samen.Cdc.Analytics`. **This is the vault-excluded projection path G12 events flow into.**

**Wide-event telemetry.** `Samen.WideEvent` — an enforced-key STRUCT (not persisted, 7-day TTL), bounded-type-only (`opaque_id | token | enum | number`), `mix samen.verify.sink_schema` fails on any free-string field. Good for OBSERVABILITY, wrong shape for a persisted product-event ledger. G12 builds a NEW governed resource, not a wide-event reuse (§4.1 argues this).

**Abbrev registry.** `samen_core/priv/abbrev_registry.json` — `"abbrev": "Module"` rows, 3-letter lowercase, never recycled, verifier-enforced (`Samen.Verifiers.AbbrevRegistry`). Free prefixes confirmed this pass: `mrr`, `mov`, `hsc`, `hsf`, `ffa`, `fex`, `pae`, `paf`, `pas` (all unclaimed).

**Gate substrate to keep green.** ci.sh: `mix compile --warnings-as-errors`, the `mix samen.verify.*` suite (`pii_classify --baseline`, `no_plaintext_pii`, `no_pii_columns`, `aggregate_privacy`, `api_contract`, `catalog_parity`, `prefixes`, `sink_schema`, `never_read_current`), `mix test --warnings-as-errors`, `mix test --only adversarial`, driftwood crypto-shred + PITR game-days.

---

## 1 · G7 — Revenue analytics (MRR movements / churn / cohorts / NRR)

### 1.1 The core problem: attribution needs events, and they don't exist

Snapshot MRR is a live sum (`platform_billing/2`). Movements (new / expansion / contraction / churn / reactivation) are a **diff over subscription state through time** — they cannot be computed from current rows alone. Two subscriptions both `active` at $99 tell you nothing about whether one is a new sale and the other a downgrade-from-$199. **We must capture subscription-change events first.**

### 1.2 Decision — a subscription-change ledger via the existing StatusChange seam (ADR-017)

Attach a new kernel change `Samen.Billing.SubscriptionMovement` to `Billing.Subscription`'s `changes do` block (the exact seam `StatusChange` already proves on `Invoice`). On every create/update it appends ONE row to a new append-only kernel resource **`Billing.SubscriptionEvent`** (abbrev `mov`), capturing the movement as a bounded, non-PII, token-blind record:

- `mov_org_id` (bounded id — the tenant), `mov_subscription_id` (bounded id), `mov_customer_id` (bounded id)
- `mov_kind` (enum: `:new | :expansion | :contraction | :churn | :reactivation | :noop`) — computed from `(old_status, old_mrr_cents) → (new_status, new_mrr_cents)` by a pure classifier `Samen.Billing.MovementClassifier.classify/2`
- `mov_mrr_delta_cents` (integer, signed — the reconciliation quantity), `mov_mrr_before_cents`, `mov_mrr_after_cents`
- `mov_plan_id`, `mov_from_plan_id` (bounded ids), `mov_occurred_at` (timestamp), `mov_reason` (enum, bounded)

**No PII by construction:** every column is a bounded id, enum, integer, or timestamp — the same discipline as `WideEvent`. The classifier is pure and unit-testable in isolation. The MRR-before/after ride the row so the ledger is self-contained (no re-join to price history to reconcile). `mov` rows are org-scoped (`OrgScope`) and erasure-covered: a subject's `mov` rows are subject-keyed by `mov_customer_id` and shred via the standard rollup erasure arm.

**Backfill honesty:** movements only exist from the change hook forward. The design ships an explicit `Samen.Billing.MovementBackfill.from_snapshot/1` that seeds a single synthetic `:new` movement per currently-active subscription at install time, so day-one MRR reconciles; pre-install history is DISCLOSED as absent (design out-of-scope §7), never fabricated.

### 1.3 Decision — rollup rows, not live scan, for the waterfall (ADR-018)

Movements over months = a rollup. Register a revenue rollup (table `mrr_revenue_rollup` — as shipped in B2, a RAW table on the `rol` precedent: `mrr` is its column prefix, not a registry abbrev; no Ash resource fronts it) as a **domain-sourced** `Samen.Rollup.Spec` — which forces the ADR-007 `:source` generalization decision. **ADR-018 decides: implement the `:source` dimension now** (WS-B is the "3rd vertical-shaped" trigger ADR-007 waited for — a movement-sum rollup differently shaped from settlement/subscription sums). The rollup recomputes per-period `{new, expansion, contraction, churn, reactivation}` sums from the `mov` ledger (a domain table), and the erasure arm recomputes subject-free after a subject's `mov` rows are shredded (post-shred the period sums simply lose that subject's deltas — subject-free by construction).

- Rollup grain: `(org_id, period_month, mov_kind)` → `sum(mov_mrr_delta_cents)`, `count`.
- Read path: `Samen.Web.Operator.RevenueReads` marks itself `use Samen.Cdc.Analytics`-equivalent for the rollup table (a report module, never-read-current-clean since the rollup is Postgres-primary, not the CDC mirror — the analytics marker convention applies to the report, the rollup lives in the primary repo).
- The `RollupRefreshWorker` cron drives refresh; the operator dashboard reads `mrr_revenue_rollup`, never a live movement scan.

### 1.4 Derived metrics (pure functions over the rollup)

`Samen.Web.Operator.RevenueMetrics`: **MRR waterfall** (opening + new + expansion − contraction − churn + reactivation = closing), **gross/net churn %**, **NRR** (`(opening + expansion − contraction − churn) / opening`), **logo churn** (count of `:churn` movements / opening active count), **cohort retention grid** (customers grouped by signup-month `:new` row, retained % per subsequent month from their `mov` timeline). Forecast is OUT OF SCOPE (§7).

### 1.5 The reconciliation red-path (fail-closed proof)

**Invariant R1 (movement ledger sums to the MRR delta):** for any period, `opening_mrr + Σ(mov_mrr_delta_cents) == closing_mrr`, where opening/closing are the independently-computed live snapshot MRRs at period boundaries. A test seeds a subscription lifecycle (new → upgrade → downgrade → cancel → reactivate), asserts each emits the correctly-classified `mov` row, and asserts the waterfall reconciles to the snapshot delta to the cent. **Red-path:** sabotage the classifier to misattribute an expansion as `:noop` → the sum diverges from the snapshot delta → the reconciliation test FAILS. This is the anti-tautology: the ledger is only trustworthy if it reconciles, and the test proves the reconciliation is load-bearing.

### 1.6 Cross-tenant revenue (portfolio) rides the aggregate floors

Per-tenant revenue (the operator's OWN book) is clear (tenant plane, the SaaS owns it). Any CROSS-tenant portfolio revenue tier (MRR-by-plan across all tenants, benchmarking) MUST route through the `operator_aggregate` actor + `aggregate_cohort_spec/0` → k-anon `min_cohort = 5` suppression. `RevenueRollup` used cross-tenant declares a `CohortSpec` keyed on `plan`/`tier` with `cohort_count_column = tenant_count`; a plan with <5 tenants renders `%Suppressed{}`. **This is the existing `Demo.Aggregate.MrrByTier` pattern extended to movements** — no new floor mechanism, reuse.

---

## 2 · G17 — Per-tenant health scores + drill-down

### 2.1 Decision — a scored, explainable health model over already-computed inputs (ADR-019)

Replace the single subscription-status pill with a composite score. **All inputs already exist in `Operator.Reads`** — this is a compute layer, not new plumbing. `Samen.Web.Operator.HealthScore.score/1` takes the assembled account row and returns `%HealthBreakdown{score: 0..100, band: :healthy | :watch | :at_risk | :critical, factors: [%Factor{name, weight, value, contribution, explanation}]}`.

Four weighted factors (weights are config, defaulted):
- **Billing state** (weight 40) — active/trialing = full, past_due = penalty scaled by days-overdue + past-due invoice count/amount (fixes the gate-noted health/dunning incoherence: today's pill ignores past-due invoices Billing shows), cancelled = 0.
- **Activity** (weight 25) — recency of last product-analytics event (from G12 `pae`; degrades gracefully to `:unknown` when G12 not yet emitting, so G17 ships independently and gains fidelity when G12 lands).
- **Support load** (weight 20) — open-ticket count + breach count from `desk_metrics` (inverse — more open/breaching = lower).
- **Adoption** (weight 15) — seat utilization (active memberships / entitled seats) + feature-flag adoption breadth (distinct flags evaluated true for the org, from G6).

The breakdown is **explainable by construction**: each `%Factor{}` carries its raw value, weight, contribution, and a human `explanation` string — the drill-down renders "why this score" without a second computation.

### 2.2 Drill-down surface

A new operator LiveView `Samen.Web.Operator.AccountDetailLive` at `/operator/accounts/:id` (declared in `samen_operator_routes/2` so verticals inherit it). Renders: the health score + factor breakdown, the account's subscription/MRR movement timeline (from `mov`), open tickets, seat/adoption, and the "Open account" impersonation link. Reuses the WS-A `timeline/1` kit component + `object_card/1`. `AccountsLive` gains a row link to it (the drill).

### 2.3 Token-blind constraints (LOAD-BEARING)

Per-tenant health of the operator's OWN book is a TENANT-plane read — clear, no floors needed (the SaaS owns this data; same as today's accounts CRM). **Health is NOT a new PII surface**: every factor input is a bounded count/enum/amount/timestamp — no name, email, or freeform string enters the score or the breakdown. **Cross-tenant health** (portfolio health distribution, "how many accounts are at-risk across the fleet") is aggregate-only: it routes through `operator_aggregate` + a `CohortSpec` on `band` with k-anon `min_cohort = 5` — a band with <5 accounts renders `%Suppressed{}`. **Red-path (MC-H1):** a masking test asserts the health breakdown, rendered on any plane, contains zero plaintext PII and no `vt_` token leak; and the cross-tenant band distribution suppresses a <5 cohort (probed by seeding 4 at-risk accounts → `%Suppressed{}`, then a 5th → count appears).

---

## 3 · G6 — Feature-flag evaluation engine

### 3.1 Kernel placement argument (ADR-020)

`evaluate/2` is a pure, deterministic function over governed config + a non-PII subject key — no web dependency, needed by every plane and by API/worker code paths, not just LiveViews. **It belongs in the kernel** (`samen_core`), exactly like the notifications engine's record/dispatch core. The ADMIN UI (both planes) belongs in `samen_web`. The `FeatureFlag` resource already lives in the kernel primitives scope (abbrev `pff`).

### 3.2 The engine — `Samen.FeatureFlags.evaluate/2`

`evaluate(flag_name, subject)` → `%Decision{on: boolean, variant: atom | nil, reason: :kill_switch | :disabled | :targeted | :rollout_in | :rollout_out | :default}`. Deterministic pipeline:

1. **Kill switch** — `enabled == false` → `{off, reason: :kill_switch}` (short-circuits everything; the incident lever).
2. **Targeting** — rules key ONLY off governed, NON-PII attributes by construction (org_id, plan, tier, stage — NEVER name/email). A `%TargetRule{attribute, op, values, then: on/off/variant}` list; first match wins. Targeting attributes are validated at flag-write time against a non-PII allowlist (see §3.5 red-path).
3. **Deterministic bucketing** — `bucket = :erlang.phash2({flag_name, subject_key}, 10_000) / 100.0` (0.0..100.0); `on = bucket < rollout_pct`. **Org-stable + flag-independent:** the same `(flag, org)` always buckets identically (stable rollout ramp — raising `rollout_pct` only ever ADDS orgs, never reshuffles), and different flags bucket independently (no correlated exposure). `subject_key` is a non-PII bounded id (org_id or a per-org stable token), NEVER a PII field.
4. **Default** — `stage`-derived default when no rule/rollout applies.

New kernel resource fields on `FeatureFlag` (or a sibling `pff` extension): `target_rules` (bounded jsonb — attribute/op/values, structurally validated), `variants` (bounded map name→weight for multivariate). `rollout_pct`/`enabled`/`stage` already exist.

### 3.3 Cached evaluation (no per-render DB read)

An ETS-backed `Samen.FeatureFlags.Cache` (GenServer owner, `:read_concurrency`) holds the flag config per org, invalidated on flag write via a PubSub broadcast (the same id-only envelope pattern as notifications). `evaluate/2` reads the cache; a cache miss loads once and populates. Kill-switch flips propagate via the invalidation broadcast (bounded staleness = one broadcast hop, acceptable for a rollout lever; the kill switch is fail-safe — on cache/lookup error, `evaluate` returns `{off}` for a flag it cannot confirm ON). Assignment (for experiments) emits an event — see §3.4.

### 3.4 Experiment seam (design the seam; full analysis out-of-scope)

When a flag has `variants`, `evaluate/2` assigns a variant deterministically (weighted bucketing on the same stable hash) and emits ONE **assignment event** into the G12 product-analytics path: a `pae` event `flag.assignment` with `{flag_name, variant, org_id}` (all bounded/non-PII). This is the SEAM: assignment events + G12 event capture + G7-style rollup = A/B analysis is *possible*. **Full A/B statistical analysis (metric lift, significance) is OUT OF SCOPE** (§7) — it composes G12 funnels + a stats layer that is its own workstream. WS-B ships the assignment event and asserts it flows to `pae`; it does not compute lift.

### 3.5 Admin UI (both planes, malleability convention)

Follows the proven two-plane posture (no abstracted module exists yet; the pattern is `writable?/1` posture + kernel enforcement, per `Operator.Live` and the chat `ThreadsLive`):
- **Tenant plane** — `Samen.Web.Flags.SettingsLive` (mounted via a new `samen_flags_routes/2` macro or folded into module routes): a tenant admin sees flags applicable to their org and their evaluated state; write affordances (toggle, rollout %) gated `admin` + `writable?/1` (tenant plane true).
- **Operator plane** — `Samen.Web.Operator.FlagAdminLive` at `/operator/flags` (declared in `samen_operator_routes/2`): the SaaS sees all flags, the kill switch, rollout ramp, and per-org evaluated state for debugging. Kill switch is an operator-plane write on the operator org's OWN flag rows (tenant plane of the operator org — writable). Enforcement is the kernel Ash policy (`OrgScope` + `RoleAtLeast(:admin)`), never the UI.

### 3.6 Red-paths (fail-closed proof)

- **RP-F1 determinism + stability:** a property test asserts `evaluate/2` is deterministic (same input → same output across 1000 calls) and org-stable (raising `rollout_pct` from N to N+k only ever flips orgs off→on, never on→off — the monotonic-ramp invariant). Sabotage: replace `phash2` with `:rand` → the stability property FAILS.
- **RP-F2 distribution:** over 10k synthetic org keys at `rollout_pct = 30`, the on-fraction is 30% ± tolerance (bucketing is uniform). Sabotage: bias the hash → distribution test FAILS.
- **RP-F3 non-PII targeting key (by construction):** flag-write validation REFUSES a target rule keyed on a PII-classified attribute (name/email); a test asserts a rule on `email` is rejected at write and `evaluate` never receives a PII subject key. Sabotage: allow the PII attribute → the refusal test FAILS.
- **RP-F4 kill-switch fail-safe:** with the cache poisoned/unavailable, `evaluate` returns `{off}` (never fails ON). Sabotage: default-ON on error → the fail-safe test FAILS.

---

## 4 · G12 seed — product-analytics events (governed capture primitive)

### 4.1 Placement + why a new resource, not WideEvent (ADR-021)

Product events need PERSISTENCE, per-tenant scoping, erasure coverage, and the CDC projection path — none of which `WideEvent` (7-day TTL struct, observability-shaped) provides. **G12 builds a new kernel resource** `Analytics.ProductEvent` (abbrev `pae`) in the primitives scope, token-blind by construction (the same discipline that lets it mirror through the vault-excluded CDC projection). Event CAPTURE is a kernel candidate (framework-emitted, needed by every plane/worker) — placement in kernel argued and accepted (ADR-021). Funnel/retention READS are a thin `samen_web` operator surface.

### 4.2 The capture primitive

`Samen.Analytics.track/1` (kernel): given `{org_id, actor_ref, event_name, entity_ref, occurred_at, props}` → validate → write a `pae` row → best-effort, never fail-closed against the primary write (rides alongside, like `Engine.emit/2`). `pae` columns (ALL bounded/non-PII):
- `pae_org_id` (bounded id), `pae_actor_ref` (a per-subject-keyed HMAC pseudonym via the existing `Samen.WideEvent.for_subject/2` mechanism — NOT a raw user id, NOT PII), `pae_event_name` (enum from a registered catalog — NOT freeform), `pae_entity_ref` (bounded id/token), `pae_occurred_at` (timestamp), `pae_props` (bounded map — **structurally validated against a per-event schema; no freeform strings**).

**Framework-emitted events (the seed set):** `session.signed_in`, `first_run.completed`, `record.created`, `search.used`, `flag.assignment` (from §3.4). Emitted from the framework choke points that already exist (session controller, first-run, kit create path, search) — verticals inherit emission at 0 LOC.

### 4.3 The PII refusal red-path (fail-closed proof)

**RP-A1 (event capture refuses a PII-bearing payload):** `track/1` validates `pae_props` and `pae_event_name` against the bounded catalog + the shared `Samen.Pii.Classification` oracle (the SAME default-deny mechanism A1 shipped for CDC). A payload carrying a freeform string that classifies `:plaintext_pii` (e.g. `%{"email" => "a@b.com"}`) is REFUSED at capture — the event is dropped with a logged `:pii_rejected`, never persisted. Sabotage: bypass the classifier → the refusal test FAILS (a PII prop reaches `pae`). This is the exact H-2/A1 discipline applied to the capture boundary.

### 4.4 The CDC projection path

`pae` is token-blind by construction, so `Samen.Cdc.Projection.project(ProductEvent)` returns all its columns (no plaintext to exclude) and it mirrors cleanly through the vault-excluded projection — the destruction oracle's `cdc_mirror` schema-assertion tier covers it for free (a non-projected physical column on `pae` would be an oracle violation). Erasure-for-free: `pae_actor_ref` is a per-subject HMAC pseudonym; on shred the subject's vault key destruction renders re-identification impossible across live + mirror simultaneously.

### 4.5 Thin operator read (seed scope — decided honestly)

WS-B ships ONE thin funnel/retention read as a Postgres rollup (`Samen.Web.Operator.AnalyticsReads` over a `pae` rollup), surfaced on a minimal operator `AnalyticsLive` page: a signup→first-run→first-record funnel + a 4-week retention curve, cross-tenant → aggregate floors (k-anon min 5 on cohort). **This is a SEED, not the analytics product** — no paths, no arbitrary event exploration, no DAU/MAU dashboards, no ClickHouse (Postgres rollup only). The full product-analytics discipline (G2 in the operator lens) is a later workstream once ClickHouse is warranted. Stated out-of-scope §7.

---

## 5 · Framework-first inheritance (the acceptance measure)

Every WS-B operator surface is declared inside `samen_operator_routes/2` (`AccountDetailLive`, `FlagAdminLive`, `AnalyticsLive`, a revenue page on `PlatformBillingLive` or a new `RevenueLive`). A vertical that already calls `samen_operator_routes Driftwood.Operator, repo: ...` inherits ALL of them at **0 new LiveView lines** — the only vertical delta is mounting the new kernel resources (`mov`, `mrr` rollup, `pae`, flag fields) in its domain (`use Ash.Domain` mount lines with fresh abbrevs, ≈8-15 LOC per resource-bearing scope, the ADR-016-measured pattern). The flag engine + `track/1` are kernel — verticals inherit emission from the framework choke points at 0 LOC. **AC-X1 (inheritance):** driftwood + pawchart adopt all of WS-B in domain-mount + registry rows only; the operator-surface LOC is genuinely 0 (proven the same way the WS-A gate proved it).

---

## 6 · Acceptance criteria (numbered, testable, mapped to test type)

Test types: **U** unit · **P** property · **I** integration · **M** masking (per-plane) · **RP** red-path (must-fail under sabotage, anti-tautology probed) · **V** verifier/gate · **X** cross-phase.

### G7 — Revenue analytics
- **AC-G7-1** `MovementClassifier.classify/2` maps each `(old,new)` state pair to the correct `mov_kind` (new/expansion/contraction/churn/reactivation/noop). — **U**
- **AC-G7-2** A subscription create/update appends exactly one `mov` row via the `SubscriptionMovement` change, with correct `mov_mrr_delta_cents` and before/after. — **I**
- **AC-G7-3** `mov` carries zero PII: every column is bounded id/enum/int/timestamp; `Cdc.Projection.project` returns all columns; `no_pii_columns` + `sink_schema` green. — **V**
- **AC-G7-4** The MRR waterfall (opening+new+expansion−contraction−churn+reactivation) reconciles to the independent snapshot MRR delta to the cent (Invariant R1). — **I**
- **AC-G7-5 (RECONCILIATION RED-PATH)** Sabotaging the classifier to misattribute a movement makes AC-G7-4 diverge → the reconciliation test FAILS; restore → green. — **RP**
- **AC-G7-6** `RevenueRollup` registers as a `:source :domain` `Samen.Rollup.Spec`; `RollupRefreshWorker` refreshes it; the dashboard reads the rollup table, never a live movement scan. — **I**
- **AC-G7-7** After a subject's `mov` rows are shredded, the domain-sourced rollup recomputes subject-free (post-shred the erased subject contributes 0 to period sums); a sabotaged recompute that still counts the subject FAILS the oracle. — **RP**
- **AC-G7-8** NRR / gross churn / logo churn / cohort-retention grid compute correctly from a seeded lifecycle fixture. — **U**
- **AC-G7-9** Cross-tenant MRR-by-plan routes through `operator_aggregate` + `CohortSpec`; a plan with <5 tenants renders `%Suppressed{}` (k-anon floor honored). — **M/RP**

### G17 — Health scores + drill-down
- **AC-G17-1** `HealthScore.score/1` returns a `%HealthBreakdown{}` with the four weighted factors summing to the composite; band thresholds correct. — **U**
- **AC-G17-2** Past-due invoices lower the score (fixes the gate-noted health/dunning incoherence) — an account active-but-past-due scores below active-current. — **U**
- **AC-G17-3** The breakdown is explainable: each factor carries value/weight/contribution/explanation with no second computation needed. — **U**
- **AC-G17-4** `AccountDetailLive` at `/operator/accounts/:id` renders score + factor breakdown + MRR-movement timeline + tickets; `AccountsLive` links to it. — **I**
- **AC-G17-5 (MASKING)** The health breakdown rendered on any plane contains zero plaintext PII and no `vt_` token leak (health is not a new PII surface). — **M**
- **AC-G17-6** Cross-tenant health-band distribution routes through `operator_aggregate`; a band with <5 accounts suppresses (probe: 4→`%Suppressed{}`, 5th→count). — **M/RP**
- **AC-G17-7** Health degrades gracefully when G12 activity signal absent (`:unknown` activity factor, score still computes) — G17 ships independent of G12. — **U**

### G6 — Feature-flag evaluation engine
- **AC-G6-1** `evaluate/2` returns `%Decision{on, variant, reason}` through the kill-switch→targeting→rollout→default pipeline. — **U**
- **AC-G6-2 (DETERMINISM + STABILITY RED-PATH)** Determinism (same input→same output) + monotonic org-stable ramp (raising rollout_pct only flips off→on) as a property; sabotaging `phash2`→`:rand` FAILS the stability property. — **P/RP**
- **AC-G6-3 (DISTRIBUTION RED-PATH)** At rollout_pct=30 over 10k org keys the on-fraction is 30%±tol; biasing the hash FAILS the distribution test. — **P/RP**
- **AC-G6-4 (NON-PII TARGETING RED-PATH)** Flag-write refuses a target rule keyed on a PII-classified attribute; sabotaging the allowlist FAILS the refusal test. — **RP**
- **AC-G6-5 (KILL-SWITCH FAIL-SAFE)** With the cache unavailable, `evaluate` returns `{off}`; defaulting-ON-on-error FAILS the fail-safe test. — **RP**
- **AC-G6-6** Cached evaluation does no per-render DB read; a flag write broadcasts an invalidation and the next `evaluate` reflects it. — **I**
- **AC-G6-7** Two-plane flag admin: tenant `SettingsLive` write-gated `admin`+`writable?`; operator `FlagAdminLive` kill switch + per-org state; operator-plane impersonation is read-only (posture) with kernel enforcement. — **I/M**
- **AC-G6-8** Assigning a variant emits one `flag.assignment` `pae` event (the experiment seam). — **I**

### G12 — Product-analytics events (seed)
- **AC-G12-1** `Analytics.track/1` writes one bounded `pae` row for a valid event; best-effort (a track failure never fails the primary write). — **U/I**
- **AC-G12-2 (PII REFUSAL RED-PATH)** `track/1` refuses a payload whose prop classifies `:plaintext_pii` (dropped, logged, never persisted); bypassing the classifier FAILS the refusal test. — **RP**
- **AC-G12-3** `pae` is token-blind: `Cdc.Projection.project(ProductEvent)` returns all columns; the cdc_mirror oracle tier + `no_pii_columns` + `sink_schema` green; a non-projected column would violate the oracle. — **V/RP**
- **AC-G12-4** Framework choke points emit the seed events (`session.signed_in`, `first_run.completed`, `record.created`, `search.used`) — verticals inherit emission at 0 LOC. — **I/X**
- **AC-G12-5** `pae_actor_ref` is a per-subject HMAC pseudonym (not a raw id); post-shred the subject is unrecoverable across live+mirror. — **RP**
- **AC-G12-6** The seed funnel + retention read computes over a `pae` rollup, cross-tenant via aggregate floors (k-anon min 5). — **I/M**

### Cross-cutting
- **AC-X1 (INHERITANCE)** driftwood + pawchart adopt ALL WS-B surfaces in domain-mount + registry rows only; operator-surface LOC = 0 (measured). — **X**
- **AC-X2 (GATE GREEN)** All suites + every ci.sh + the full `mix samen.verify.*` chain + adversarial gate green before/after each phase; abbrev registry appends verifier-clean. — **V**

---

## 7 · Explicit out-of-scope

- **Revenue forecasting / LTV projection** — the waterfall/churn/NRR/cohorts ship; predictive forecast does not.
- **Pre-install movement history** — movements exist from the change-hook forward + one synthetic `:new` backfill per active sub; deeper history is disclosed absent, never fabricated.
- **Full A/B experiment analysis (metric lift, significance)** — WS-B ships the assignment-event SEAM (§3.4) only; lift/significance compose G12 funnels + a stats layer = a later workstream.
- **The full product-analytics product** (arbitrary event exploration, paths, DAU/MAU dashboards, ClickHouse activation) — G12 ships a SEED (capture primitive + one thin funnel/retention read on a Postgres rollup). Operator-lens G2's full discipline is deferred.
- **Usage-based billing / rating / proration / Stripe live sync (G13)** — not in WS-B; revenue analytics reads the existing subscription×price MRR, not a usage-rating engine.
- **Status page / SLA-uptime / alerting (G11)** and **tenant lifecycle admin (G8)** — separate roadmap items, not WS-B.
- **DP noise on cockpit reads** — the k-anon/l-diversity floors + query budget are the load-bearing privacy mechanism WS-B reuses; DP noise stays the existing opt-in aggregate feature, not newly wired here.

---

## 8 · Data-model deltas → abbrev registry entries required

New kernel/aggregate resources (each an append-only `"abbrev": "Module"` row in `samen_core/priv/abbrev_registry.json`; per-host verticals add their OWN fresh abbrevs when they mount the scope, per ADR-006/016):

| Abbrev | Owner (demo reference host) | Role |
|---|---|---|
| `mov` | `Demo.BillingScope.SubscriptionEvent` | append-only subscription-change ledger (movement rows) |
| — (`mrr` = column prefix only, NOT a registry row) | raw table `mrr_revenue_rollup` (shipped B2 per the `rol_daily_event_count` precedent — no Ash resource, no abbrev-registry row) | domain-sourced revenue-movement rollup table |
| `hsc` | `Demo.Analytics.HealthScoreRollup` | (optional) materialized per-account health snapshot if score is rolled up rather than live-computed |
| `ffa` | `Demo.PrimitivesScope.FlagAssignment` | (only if variant assignments persist beyond the `pae` event; else omit — assignment lives in `pae`) |
| `pae` | `Demo.Analytics.ProductEvent` | governed product-analytics event ledger (token-blind) |
| — (`paf` = column prefix only, NOT a registry row) | raw table `paf_product_event_rollup` (shipped B8 per the `mrr_revenue_rollup`/B2 precedent — no Ash resource, no abbrev-registry row; tam_table logical name `Demo.Analytics.ProductEventRollup`) | funnel/retention rollup over `pae` |

Verticals add fresh abbrevs when mounting (e.g. driftwood `d**`, pawchart `p**`), never reusing the demo prefixes — the ADR-006 append-only, one-owner-forever discipline. `hsc`/`ffa` are conditional (see §2.1 live-vs-rollup and §3.4 event-vs-resource); the design defaults to live health compute (no `hsc`) and event-only assignment (no `ffa`) unless a phase-time performance measurement forces materialization, in which case the abbrev is reserved then.
