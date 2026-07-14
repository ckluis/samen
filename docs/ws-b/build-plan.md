# WS-B — "Operator Cockpit v1" · Build Plan

- **Status:** Buildable. Follows `docs/ws-b/design.md` + ADR-017..021.
- **Date:** 2026-07-13
- **Sizing principle:** SMALL serialized workflow units — session limits interrupt runs, so each unit must bank in ~10-20 min and each PHASE must be independently committable + gate-able. Default concurrency 1 on agent fan-outs (memory: serialize workflow fan-outs; a session-limit hit then strands ≤1 agent, resume re-runs only the straggler).
- **Model routing:** **opus** for kernel resources/engines, red-path/reconciliation/erasure design, verify, and gates; **default** for bulk (web reads, LiveViews, registry rows, wiring, docs). Stated per phase.
- **Gate cadence:** an adversarial phase-gate after each phase (findings fixed in-phase); a workstream-wide adversarial re-gate at the end (round-2), matching the WS-A gate shape (`docs/gate-ws-a.md`).

---

## Dependency graph (phases)

```
B1 (mov ledger + classifier) ──> B2 (:source rollup + revenue metrics) ──> B3 (revenue operator surface)
                                                                              │
B4 (health score + drill-down) ───────────────────────────────────────────── depends on B1 (mov timeline)
B5 (flag engine kernel) ──> B6 (flag admin two-plane UI + experiment seam)
B7 (pae capture + PII refusal) ──> B8 (thin funnel/retention read)
B5,B7 feed B4's activity+adoption factors (graceful; B4 ships without them)
B9 (vertical inheritance proof + workstream gate)  ── depends on ALL
```

B1→B2→B3 is the G7 chain (must serialize). B4 (G17) needs B1's `mov` for the timeline but ships its score without B5/B7 (graceful degradation). B5→B6 (G6) and B7→B8 (G12) are independent chains. B9 gates the whole.

---

## Phase B1 — Subscription-movement ledger + classifier (G7 core)  · opus

**Scope:** the `mov` capture substrate — everything downstream reconciles to it.
**AC IDs:** AC-G7-1, AC-G7-2, AC-G7-3. **ADR:** 017.
**Deps:** none (WS-A shipped the StatusChange seam).
**Tasks:**
1. New kernel resource `Billing.SubscriptionEvent` (abbrev `mov`) in the billing scope blueprint — append-only, `OrgScope`d, bounded/non-PII columns per design §1.2. Registry row `"mov": "Demo.BillingScope.SubscriptionEvent"`.
2. Pure `Samen.Billing.MovementClassifier.classify(before, after) -> mov_kind` + unit tests (AC-G7-1, all state pairs).
3. `Samen.Billing.SubscriptionMovement` Ash change, attach to `Billing.Subscription`'s `changes do` (modeled on `StatusChange`); appends one `mov` row per create/update with signed delta + before/after (AC-G7-2).
4. `MovementBackfill.from_snapshot/1` — one synthetic `:new` per active sub (day-one reconciliation honesty).
5. Verifier green on `mov`: `no_pii_columns`, `sink_schema`, `prefixes`, `catalog_parity`, abbrev-registry append (AC-G7-3).
**Gate:** phase-gate; confirm `mov` is token-blind and the change fires exactly once per mutation.

## Phase B2 — `:source :domain` rollup + revenue metrics (G7 compute)  · opus

**Scope:** the ADR-018 rollup generalization + the pure metric functions.
**AC IDs:** AC-G7-4, AC-G7-5 (reconciliation red-path), AC-G7-6, AC-G7-7 (erasure red-path), AC-G7-8. **ADR:** 018.
**Deps:** B1.
**Tasks:**
1. Add `:source` (`:aud_event | :domain`) to `Samen.Rollup.Spec`; existing specs default `:aud_event` (behavior unchanged). Domain-sourced erasure REBUILD arm (recompute subject-free, no `raw_retained?` dependence).
2. Register `RevenueRollup` (abbrev `mrr`, `mrr_revenue_rollup`, grain `(org_id, period_month, mov_kind)`) as a `:domain` spec; wire into `RollupRefreshWorker` (AC-G7-6).
3. `Samen.Web.Operator.RevenueMetrics` — pure waterfall / NRR / gross+logo churn / cohort-retention over the rollup (AC-G7-8).
4. **Reconciliation red-path (AC-G7-4/5):** seed a lifecycle (new→upgrade→downgrade→cancel→reactivate); assert `opening + Σmov_delta == closing` to the cent; sabotage the classifier → diverges → FAILS → restore (anti-tautology).
5. **Erasure red-path (AC-G7-7):** post-shred subject-free recompute; sabotaged recompute still counting the subject FAILS the oracle.
**Gate:** phase-gate; both red-paths proven non-tautological (sabotage→fail→restore byte-exact).

## Phase B3 — Revenue operator surface (G7 UI)  · default (opus reviews masking)

**Scope:** the inherited operator revenue page.
**AC IDs:** AC-G7-9 (cross-tenant aggregate floor), contributes AC-X1.
**Deps:** B2.
**Tasks:**
1. Revenue view (a `RevenueLive` or a section on `PlatformBillingLive`) rendering the waterfall + churn + NRR + cohort grid from `RevenueMetrics`; declare in `samen_operator_routes/2` (inherited at 0 LOC).
2. Cross-tenant MRR-by-plan via `operator_aggregate` + a `CohortSpec` (reuse the `Demo.Aggregate.MrrByTier` pattern); k-anon min-5 suppression (AC-G7-9, M/RP: 4 tenants→`%Suppressed{}`, 5th→count).
**Gate:** phase-gate; confirm cross-tenant read never bypasses the floor.

## Phase B4 — Health score + drill-down (G17)  · opus (score) + default (UI)

**Scope:** the composite score + the account detail surface.
**AC IDs:** AC-G17-1..7. **ADR:** 019.
**Deps:** B1 (mov timeline); B5/B7 optional (graceful `:unknown`).
**Tasks:**
1. `Samen.Web.Operator.HealthScore.score/1` → `%HealthBreakdown{}` with four weighted factors; explainable `%Factor{}` (AC-G17-1/3); past-due lowers score (AC-G17-2, the incoherence fix); graceful `:unknown` activity (AC-G17-7).
2. `AccountDetailLive` at `/operator/accounts/:id` (declared in `samen_operator_routes/2`, inherited); renders breakdown + `mov` timeline + tickets; `AccountsLive` row link (AC-G17-4).
3. **Masking (AC-G17-5):** breakdown on any plane has zero plaintext PII / no `vt_` leak.
4. **Aggregate floor (AC-G17-6):** cross-tenant band distribution via `operator_aggregate`; <5 band suppresses (probe 4→suppressed, 5th→count).
**Gate:** phase-gate.

## Phase B5 — Feature-flag evaluation engine (G6 kernel)  · opus

**Scope:** the pure engine + cache — the load-bearing determinism/fail-safe.
**AC IDs:** AC-G6-1..6, AC-G6-8 (assignment event, but pae emit lands in B7). **ADR:** 020.
**Deps:** none (pae emit for AC-G6-8 wires when B7 lands; the assignment path is designed here).
**Tasks:**
1. New `pff` fields `target_rules` + `variants` (bounded jsonb, structurally validated); write-time non-PII targeting-key validation via `Pii.Classification` (AC-G6-4 refusal).
2. `Samen.FeatureFlags.evaluate/2` → `%Decision{}` — kill-switch→targeting→`phash2` bucketing→default (AC-G6-1).
3. `Samen.FeatureFlags.Cache` (ETS + GenServer, PubSub invalidation on write); fail-safe `{off}` on cache error (AC-G6-5); no per-render DB read (AC-G6-6).
4. **Red-paths:** RP-F1 determinism+stability property (AC-G6-2, sabotage phash2→:rand FAILS), RP-F2 distribution (AC-G6-3), RP-F3 non-PII key (AC-G6-4), RP-F4 fail-safe (AC-G6-5).
5. Variant assignment path (weighted bucketing) emits the `flag.assignment` payload — the emit call sites to `track/1` land in B7; assert the assignment DECISION here.
**Gate:** phase-gate; all four flag red-paths proven non-tautological.

## Phase B6 — Flag admin, two-plane UI + experiment seam (G6 UI)  · default

**Scope:** the malleability-convention two-plane admin.
**AC IDs:** AC-G6-7, AC-G6-8 (with B7 landed). **ADR:** 020.
**Deps:** B5; AC-G6-8 needs B7's `track/1`.
**Tasks:**
1. Tenant `Samen.Web.Flags.SettingsLive` (new `samen_flags_routes/2` macro or module-route fold) — write-gated `admin`+`writable?/1`.
2. Operator `Samen.Web.Operator.FlagAdminLive` at `/operator/flags` (in `samen_operator_routes/2`, inherited) — kill switch, rollout ramp, per-org evaluated state; operator-plane impersonation read-only (posture) + kernel enforcement (AC-G6-7).
3. Wire the `flag.assignment` emit to `track/1` (AC-G6-8, once B7 exists).
**Gate:** phase-gate; confirm operator-plane write refusal is kernel-enforced, not UI-only.

## Phase B7 — Product-event capture + PII refusal (G12 primitive)  · opus

**Scope:** the token-blind `pae` ledger + capture boundary — the moat foundation.
**AC IDs:** AC-G12-1, AC-G12-2 (PII refusal red-path), AC-G12-3, AC-G12-4, AC-G12-5. **ADR:** 021.
**Deps:** none (CDC projection + Pii.Classification + WideEvent.for_subject exist).
**Tasks:**
1. New kernel resource `Analytics.ProductEvent` (abbrev `pae`), token-blind columns per design §4.2; `pae_actor_ref` via `WideEvent.for_subject/2`; registry row.
2. `Samen.Analytics.track/1` — best-effort, bounded catalog + `Pii.Classification` validation; refuses `:plaintext_pii` props (AC-G12-2 red-path, sabotage→fail→restore).
3. Emit the seed set from framework choke points: `session.signed_in`, `first_run.completed`, `record.created` (kit create path), `search.used` (AC-G12-4; verticals inherit at 0 LOC).
4. **CDC (AC-G12-3):** `project(ProductEvent)` returns all columns; cdc_mirror oracle tier + `no_pii_columns` + `sink_schema` green; a non-projected column is a violation.
5. **Erasure (AC-G12-5):** post-shred `pae_actor_ref` unrecoverable across live+mirror.
**Gate:** phase-gate; PII-refusal + CDC token-blind red-paths proven.

## Phase B8 — Thin funnel/retention read (G12 seed read)  · default

**Scope:** ONE inherited operator analytics page — seed, not the product.
**AC IDs:** AC-G12-6, contributes AC-X1. **ADR:** 021.
**Deps:** B7.
**Tasks:**
1. `paf` rollup over `pae` (signup→first-run→first-record funnel + 4-week retention); a `:domain` `Rollup.Spec` (reuses B2's `:source`).
2. `Samen.Web.Operator.AnalyticsReads` + a minimal `AnalyticsLive` (in `samen_operator_routes/2`, inherited); cross-tenant via aggregate floors, k-anon min 5 (AC-G12-6).
**Gate:** phase-gate; confirm seed scope (no paths/DAU/MAU/ClickHouse).

## Phase B9 — Vertical inheritance proof + workstream gate  · opus

**Scope:** prove 0-LOC inheritance + the round-2 adversarial re-gate.
**AC IDs:** AC-X1 (inheritance), AC-X2 (gate green). **Deps:** ALL.
**Tasks:**
1. Mount the new kernel scopes (`mov`, `mrr`, `pae`, `paf`, flag fields) in driftwood + pawchart domains with FRESH abbrevs (registry appends); verify operator-surface LOC = 0 (the inherited pages appear via the macro). Measure LOC the WS-A-gate way (AC-X1).
2. Full workstream adversarial re-gate: all suites + every ci.sh + full `mix samen.verify.*` chain + `--only adversarial` green; re-probe the 3-5 load-bearing cross-phase red-paths (reconciliation, flag stability, PII refusal, health masking, erasure) non-tautological with byte-exact restore + zero git residue (AC-X2). Write `docs/gate-ws-b.md`.
**Gate:** workstream GO/NO-GO.

**Carries into B9 (P2s deferred from phase gates) — ALL RESOLVED (B9 unit 2, 2026-07-14):**
- ~~B4-P2-1~~ **RESOLVED**: `account_detail/4` captures ONE `DateTime.utc_now()` and threads
  it through `account_joins/4` → `past_due_by_account/3` AND onto each invoice as
  `__past_due__`; the LiveView renders that verbatim (`past_due_now?/1` deleted — no
  second clock). Red-path: `operator_account_detail_render_test.exs` parks a due date 1s
  ahead, loads, lets it cross "now", renders — no flag/score desync; fresh-read positive
  control flips both together.
- ~~B4-P2-2~~ **RESOLVED**: `:unpaid` folded into `HealthScore.dunning?/1`
  (`in [:past_due, :unpaid]`) with a `dunning_explanation/2` that names the dunning
  status; `:paused`-style states keep the honest "unrecognized state" catch-all.
  Red-path + positive control in `operator_health_score_test.exs`; `:unpaid` added to the
  property generator.
- ~~B6-N1~~ **RESOLVED**: permanent foreign-id regression test in
  `operator_flag_admin_test.exs` — Reads mutators (toggle/set_rollout/put_rules) AND UI
  events (kill/enable/edit) driven with a foreign org's flag id all answer "Flag not
  found." with ZERO mutation; own-flag positive control proves the refusal is the org
  boundary, not a broken path.
- ~~B6-N2~~ **RESOLVED**: `enable_flag` now routes through an idempotent `enable/3`
  (the `kill/3` twin — an enabled flag stays enabled); the raw toggle is no longer
  exposed as a UI event. Red-path: double-click enable after a kill stays ENABLED;
  double-kill pinned idempotent too.
- ~~B7-P2-1~~ **RESOLVED as REFUSAL (fail-closed per the design ethos)**: the silent
  entity_ref scrub-to-nil is replaced by Gate 4 in `Samen.Analytics.track/1` — a
  PII-shaped / vault-token / structured entity_ref refuses the WHOLE event
  (`{:error, :pii_rejected}`, logged); non-binary scalars stringify through the same
  gate. ADR-021 §5 records the decision (RP-A1 addendum). Red-paths in
  `analytics_track_test.exs` (+ opaque-ref over-block twin) and
  `demo/test/analytics_capture_test.exs` (zero rows persisted — no partial row).
- ~~B8-P2-2~~ **RESOLVED**: env-independent SOURCE-level AST scan in
  `samen_web/test/samen/web/operator_analytics_zero_ash_read_test.exs` — AnalyticsReads
  contains ZERO Ash calls / `Mount.resource` resolutions, only the two `paf` rollup SQL
  reads (non-vacuity floor), `use Samen.Cdc.Analytics` marker pinned; anti-tautology
  fixture (a sneaked live pae `Ash.read!` scan) is FLAGGED. Complements — does not
  replace — `never_read_current` where the CDC tier is on.

---

## Estimated workflow-agent count

| Phase | Units | Model | Est. agents |
|---|---|---|---|
| B1 | classifier / resource+change / backfill+verify | opus | 3 |
| B2 | :source+erasure / rollup+worker / metrics / reconciliation-RP / erasure-RP | opus | 4-5 |
| B3 | revenue UI / cross-tenant aggregate-RP | default (+opus review) | 2 |
| B4 | score / drill-down UI / masking-RP / aggregate-RP | opus+default | 3-4 |
| B5 | fields+validation / engine / cache / 4 red-paths | opus | 4-5 |
| B6 | tenant admin / operator admin / assignment wire | default | 3 |
| B7 | resource / track+PII-RP / emit seed set / CDC+erasure RP | opus | 4 |
| B8 | paf rollup / analytics read+UI | default | 2 |
| B9 | inheritance proof / workstream gate | opus | 2 |
| **Total** | | | **≈ 27-30 workflow agents** |

Serialized at concurrency 1 on fan-outs; a session-limit interruption strands ≤1 agent and resume re-runs only the straggler (memory convention). Each phase banks an independent commit + phase-gate report.
