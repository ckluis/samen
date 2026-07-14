# GATE — WS-B "Operator Cockpit v1" (workstream gate, phase B9)

**Decision: GO**

Date: 2026-07-14
Scope gated: the ENTIRE WS-B workstream — eight gated phases, each already phase-gated GO,
plus the B9 inheritance-proof + carry-resolution work, now adversarially re-gated as a whole
(round 3):

| Phase | Commit | Scope |
|---|---|---|
| B1 | `2fc5ca9` | Subscription-movement ledger (`mov`) + pure `MovementClassifier` + backfill (G7 core) |
| B2 | `9643e66` | `:source :domain` rollup generalization (`mrr`) + pure revenue metrics + reconciliation/erasure red-paths (G7 compute) |
| B3 | `ddb77bc` | Revenue operator surface + k-anon cross-tenant MRR-by-plan (G7 UI) |
| B4 | `fe4d9b3` | Explainable per-tenant health score + accounts drill-down (G17) |
| B5 | `dfa04d0` | Kernel feature-flag evaluation engine: `evaluate/2`, ETS cache, 4 red-paths (G6 kernel) |
| B6 | `6a8e331` | Two-plane flag admin + experiment seam (G6 UI) |
| B7/B8 | `c5235c2` | Token-blind product-event primitive (`pae`) + PII-refusing `track/1` + funnel/retention seed (`paf`) (G12) |
| B9 | *uncommitted* | Vertical inheritance proof (driftwood + pawchart mounts) + all 6 carry resolutions + this gate |

Inputs: `docs/ws-b/design.md` (all 32 ACs), `docs/ws-b/build-plan.md` (Phase B9 + the
carries list), ADR-017/018/019/020/021, the seven phase commits, and the live tree.

---

## Verdict in one line

WS-B workstream-wide adversarial re-gate (round 3): **GO**. All suites green with exact
counts; every one of the design's 32 ACs maps to a named covering test; 3 cross-phase hunts
VERIFIED BY RUNNING (not by reading alone); 4 load-bearing red-paths re-probed
non-tautologically with LIVE sabotage→flip→byte-exact SHA-verified restore and zero git
residue; operator-surface LOC = 0 in both verticals confirmed by spot-count; all 6 carries
confirmed resolved as real working-tree changes, each with a red-path. Zero P0/P1; three
P2 findings (§Findings), none blocking.

**Tree state:** the repo is mid-WS-B by design — HEAD = `c5235c2` (B7+B8); ALL B9 work +
the 6 carry resolutions are uncommitted working-tree changes (a 38-entry set: 25 modified +
13 new files) awaiting the commit that follows this gate.

---

## Green — suite counts (exact, all green)

| Suite | Result |
|---|---|
| samen_core | **1001 passed** (13 properties, 988 tests) |
| samen_web `ci.sh` | **481 passed** (1 property, 480 tests) |
| demo default | **454 passed** (17 properties, 437 tests), 52 excluded |
| demo `ci.sh` adversarial | **52 passed** + full `mix samen.verify.*` chain OK (`api_contract` / `same_org_fk` / `no_pii_columns` / `aggregate_privacy` all OK) |
| driftwood `ci.sh` | **ALL PASSED** (full verifier gate + crypto-shred + 2 PITR game-days, red-paths fail-closed) |
| pawchart `ci.sh` | **ALL PASSED** (46 + microchip anti-tautology probe) |
| destruction oracle | **12 passed** |
| driftwood cockpit inheritance | **7 passed** (`driftwood/test/cockpit_inheritance_test.exs`) |
| pawchart cockpit inheritance | **5 passed** (`pawchart/test/cockpit_inheritance_test.exs`) |

---

## AC coverage

The design (`docs/ws-b/design.md §6`) defines **exactly 32 ACs** — AC-G7-1..9,
AC-G17-1..7, AC-G6-1..8, AC-G12-1..6, AC-X1..2 (the gate directive's "36" is a miscount;
see finding WSB-GATE3-P2-03). Every AC maps to a **named covering test in the tree** —
verified by mapping each AC to its test file this gate, not trusted from the phase reports.
AC-X2 mapping to 0 dedicated files is NOT a gap: AC-X2 is the gate-meta-AC ("all suites +
every ci.sh + verify chain green") and is covered by `ci.sh` itself.

---

## Cross-phase hunt (the round-3 focus — all verified BY RUNNING)

1. **Mid-funnel flag ramp × B8 retention cohorts — SAFE.** A flag ramp does NOT corrupt
   retention cohorts: `flag.assignment` via `assignment_payload` carries no `subject_id` →
   nil `pae_actor_ref` → excluded from BOTH the retention subquery
   (`WHERE pae_actor_ref IS NOT NULL`) and the funnel (event-name filter). Probed live,
   INCLUDING the load-bearing inverse: a subject-bearing flag event WOULD contaminate —
   so the exclusion is the mechanism, not an accident.
2. **Crypto-shred stays coherent across mov/mrr/pae/paf — SAFE.** Post-shred: `mov` rows→0,
   `mrr` delta→0, the `pae` pseudonym is unreconstructable, Invariant R1 + the `paf`
   reconciliation HOLD post-shred, and a content-scan (not report-attestation) catches a
   sabotaged domain arm.
3. **Health/B7 coherence is honest.** The activity factor degrades to `:unknown` and
   adoption uses a seat proxy — both within AC-G17-7's graceful-degradation contract, with
   honest explanation strings (see finding WSB-GATE3-P2-02 for the follow-on).

---

## 4 tautology probes (all non-vacuous, all restored byte-exact, SHA-verified, zero git residue)

| Probe | Sabotage | Result |
|---|---|---|
| R1 reconciliation (B2) | classifier misattribution | reconciliation diverges → FAILS; restore → green |
| Flag monotonic ramp (B5) | `phash2` → `:rand` | 2 properties FAIL (determinism + monotonic org-stable ramp) |
| `track/1` PII refusal (B7) | classifier gate bypass | 6 tests FAIL |
| Health dunning coherence (B4) | dunning branch | 4 tests FAIL |

All four sabotages performed LIVE this gate (not replayed from phase reports), each flipped
the guarded tests, each restored byte-exact with SHA verification and zero residue.

---

## Inheritance measure (AC-X1, from the B9 prove unit — spot-count confirmed this gate)

Both verticals adopt ALL of WS-B with **operator-surface LOC = 0** — the four cockpit
surfaces (revenue, `AccountDetailLive`, `FlagAdminLive`, `AnalyticsLive`) appear via the
ONE pre-existing `samen_operator_routes/2` call in each router; zero vertical LiveView
modules authored. The only new vertical files are the Analytics domain mount (driftwood
`analytics.ex` **84** lines, pawchart **83** — fresh abbrevs `fae`/`vae` per ADR-006) + 3
migrations each. LOC = non-comment, non-blank code lines, measured the WS-A-gate way from
the live tree.

| WS-B capability | Driftwood LOC | PawChart LOC | What the lines are |
|---|---|---|---|
| B3/B4/B6/B8 operator surfaces (revenue, account detail, flag admin, analytics) | 0 | 0 | inherited via the existing `samen_operator_routes/2` macro call |
| B5/B7 flag-engine + `track/1` emission from framework choke points | 0 | 0 | kernel; verticals inherit emission with zero call-site changes |
| B6 flag-admin namespace seam (router) | 1 (`driftwood_web/router.ex`: `flags_namespace: Driftwood.Primitives`) | 0 (default resolution) | one macro option |
| B7 Analytics domain mount (`analytics.ex`, incl. `NonPiiSetup` clearances) | 84 | 83 | `use Ash.Domain` + `use Samen.Scopes.Analytics` with fresh abbrev (`fae`/`vae`) |
| Config wiring — domain-list entries + `track/1` emitter + flag `emit` | 4 | 4 | 2 domain-list appends + 2 emitter config lines |
| Config data — `mrr`/`paf` domain-sourced rollup registry (host-table SQL, ADR-018) | 85 | 87 | two `Rollup.Spec` registry entries |
| **Total adoption delta** | **174** | **174** | zero vertical LiveView modules; zero samen_core CODE changes (abbrev registry gained append-only data rows) |

(Migrations — 3 each, 204/206 lines — and the inheritance-proof tests themselves —
217/175 lines — are excluded from the adoption measure, as in the WS-A gate.)

---

## Carry dispositions (the "carries into B9" list — ALL RESOLVED, B9 unit 2, 2026-07-14)

The gate directive said "7 carries"; the build-plan lists exactly **6** (part of finding
WSB-GATE3-P2-03). All 6 confirmed this gate as real working-tree changes vs HEAD, each
with a red-path:

| Carry | Disposition |
|---|---|
| B4-P2-1 (two-clock past-due desync) | **RESOLVED** — `account_detail/4` captures ONE `DateTime.utc_now()` and threads it through `account_joins/4` → `past_due_by_account/3` AND onto each invoice as `__past_due__`; the LiveView renders that verbatim (`past_due_now?/1` deleted — no second clock). Red-path: `operator_account_detail_render_test.exs` parks a due date 1s ahead, loads, lets it cross "now", renders — no flag/score desync; fresh-read positive control flips both together. |
| B4-P2-2 (`:unpaid` not dunning-flagged) | **RESOLVED** — `:unpaid` folded into `HealthScore.dunning?/1` (`in [:past_due, :unpaid]`) with a `dunning_explanation/2` that names the dunning status; `:paused`-style states keep the honest "unrecognized state" catch-all. Red-path + positive control in `operator_health_score_test.exs`; `:unpaid` added to the property generator. |
| B6-N1 (foreign-id probes → permanent regression) | **RESOLVED** — permanent foreign-id regression test in `operator_flag_admin_test.exs`: Reads mutators (toggle/set_rollout/put_rules) AND UI events (kill/enable/edit) driven with a foreign org's flag id all answer "Flag not found." with ZERO mutation; own-flag positive control proves the refusal is the org boundary, not a broken path. |
| B6-N2 (non-idempotent re-enable) | **RESOLVED** — `enable_flag` now routes through an idempotent `enable/3` (the `kill/3` twin — an enabled flag stays enabled); the raw toggle is no longer exposed as a UI event. Red-path: double-click enable after a kill stays ENABLED; double-kill pinned idempotent too. |
| B7-P2-1 (silent entity_ref scrub) | **RESOLVED as REFUSAL** (fail-closed per the design ethos) — the silent scrub-to-nil is replaced by Gate 4 in `Samen.Analytics.track/1`: a PII-shaped / vault-token / structured `entity_ref` refuses the WHOLE event (`{:error, :pii_rejected}`, logged); non-binary scalars stringify through the same gate. ADR-021 §5 records the decision (RP-A1 addendum). Red-paths in `analytics_track_test.exs` (+ opaque-ref over-block twin) and `demo/test/analytics_capture_test.exs` (zero rows persisted — no partial row). |
| B8-P2-2 (env-vacuous `never_read_current` lint) | **RESOLVED** — env-independent SOURCE-level AST scan in `samen_web/test/samen/web/operator_analytics_zero_ash_read_test.exs`: AnalyticsReads contains ZERO Ash calls / `Mount.resource` resolutions, only the two `paf` rollup SQL reads (non-vacuity floor), `use Samen.Cdc.Analytics` marker pinned; anti-tautology fixture (a sneaked live `pae` `Ash.read!` scan) is FLAGGED. Complements — does not replace — `never_read_current` where the CDC tier is on. |

---

## Findings

### WSB-GATE3-P2-01 — samen_core pool-timeout flake (P2)

samen_core full suite has a ~1-in-8 flake: over 8 full runs (seeds 0-5 + 2 more), 7 passed
clean (1001/1001) and 1 failed with `DBConnection.ConnectionError ... connection not
available and request was dropped from queue after 4000ms`. Root cause (verified):
`test/verify_vault_declared_parity_test.exs` `with_direct_connection/1` (lines 219-239)
opens direct Postgrex connections OUTSIDE the sandbox pool for DDL (ALTER TABLE), which
under a random seed that schedules it concurrently with other sync DB-heavy tests
transiently exhausts connection slots against `pool_size: 10` — the 4000ms queue timeout
then lands on WHICHEVER test is waiting for a pool checkout at that instant (a property
once, the parity test another time), which is why it masqueraded as a "property failure"
in the initial run. NOT a correctness defect: every property passes deterministically in
isolation and across all fixed seeds (0-31337); the reveal_grant clock property is provably
deterministic (clock computed relative to `grant.expires_at`, passed as `now:`); no WS-B
guarantee is weakened. Fix suggestion: raise the test pool_size, add
`queue_target`/`queue_interval` slack in `config/test.exs`, or gate
verify_vault_declared_parity's direct connections behind a mutex so they don't compete
with the pool. Non-blocking for GO.

### WSB-GATE3-P2-02 — health activity factor permanently `:unknown` (P2)

Latent under-wiring (within AC, honestly labeled):
`samen_web/lib/samen/web/operator/reads.ex:155` hardcodes `__activity_days__: nil`, so
HealthScore's activity factor is ALWAYS `:unknown` (renormalizes out) even though B7's
`pae` ledger is now live and emitting from framework choke points. Likewise
`adoption_factor` uses only the seat proxy; flag-adoption breadth (G6) is "pending". This
is CONSISTENT with AC-G17-7 (graceful `:unknown` when the signal is absent) and the
design's explicit "ships independent of G12, gains fidelity when G12 lands" stance — none
of AC-G17-1..7 require the activity/adoption factors to be LIVE. But now that `pae` emits,
wiring a pae-recency read into `__activity_days__` is a follow-on the design anticipated;
until then the health score's activity dimension is permanently inert. No AC violation, no
coherence lie (the explanation string honestly says "G12 pae not emitting / pending").
Flag for a future fidelity item, not a gate blocker.

### WSB-GATE3-P2-03 — directive miscounts confirmed (P2, documentation/accounting, not code)

Two directive miscounts confirmed: (a) the directive says "36 WS-B ACs" but design.md
defines exactly **32** (G7×9 + G17×7 + G6×8 + G12×6 + X×2); (b) the directive says "7
carries" but the build-plan's carries-into-B9 list has exactly **6** (B4-P2-1, B4-P2-2,
B6-N1, B6-N2, B7-P2-1, B8-P2-2). Every real AC and every real carry is accounted for —
the miscounts are in the directive's tallies, not in coverage. This gate report records
the correct counts as ground truth.

No P0/P1.

---

## Carries forward (pre-existing standing items + this gate's P2s)

1. **WS-C carry (A1 gate INFO-1, standing, recorded in `docs/saas-gap-roadmap.md` §WS-C):**
   a host custom TYPE self-classifying `samen_pii_class/0 => :non_pii` bypasses the
   two-reviewer `non_pii!` clearance discipline (single-party escape hatch,
   `classification.ex:90`). No kernel type or vertical uses it today; close or
   reviewer-gate it in WS-C.
2. **Upstream Ash `to_page` raw-limit-split bug (standing):** `Ash.Actions.Read.to_page/7`
   (3.x) splits fetched rows at the RAW requested limit; `Samen.Web.Api.PageLimitClamp` is
   the mitigation (clamps `page[size]` at the plug). Remove when upstream fixes.
3. **SMTP/ESP dispatch (standing operator TODO, disclosed out-of-scope since WS-A):**
   email delivery remains fail-honest (`:pending` / `{:error, :not_configured}`, never
   fake-delivered) until the operator configures a real adapter.
4. **WSB-GATE3-P2-01** — samen_core test-pool flake hardening (pool_size / queue slack /
   direct-connection mutex).
5. **WSB-GATE3-P2-02** — wire a pae-recency read into `__activity_days__` (and flag-adoption
   breadth into `adoption_factor`) now that the G12 signal exists — the fidelity follow-on
   the design anticipated.

---

## Fix tasks

**Mandatory: none.** The gate is GO; all three P2s are non-blocking and carried forward
above. The immediate next step is the B9 commit banking the 38-entry uncommitted set this
gate verified.
