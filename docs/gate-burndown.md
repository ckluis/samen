# GATE — F1–F7 Burn-down (the luminary burn-down, phase F7 workstream gate)

**Decision: GO**

Date: 2026-07-20

> **Point-in-time snapshot (luminary X4).** Every count below (suite totals, sabotage-patch
> total, gate-step numbering) is the number reproduced AT THIS GATE (F7). Many phases have
> shipped since, and every one of these numbers has grown — do not cite this table as the
> repo's current state. For a live count: `ls scripts/sabotages/*.patch | wc -l` (sabotages),
> `cd samen_core && mix test` / `cd samen_web && mix test` (suite totals). `README.md`'s
> "Suite totals" section is intended to track HEAD, not this gate.

Scope gated: the ENTIRE F1–F7 burn-down — six committed phases (F1, F2, F3, F3b, F4, F5, F6),
each already phase-gated in its roadmap record, plus the F7 phase (Cockpit v2 + tail + this final
gate), now adversarially re-gated as a whole (round 1). F7 is the FINAL phase of the burn-down.

| Phase | Commit | Scope (one line) |
|---|---|---|
| F1 | `dee98f4` | Honesty & safety smalls — pitch honesty, `/readyz`, public-repo safety, CSV formula injection, hygiene |
| F2 | `0c0c08d` | Launchability on-ramp — BYO-auth reference wiring (ADR-031) + launch gate docs |
| F3 | `45cc046` | Trust & lifecycle — API-key expiry (deny-on-read), retention sweeps, DSAR export, audit-chain verify sweep |
| F3b | `f0d2b6a` | F3 carries — append-only ConsentEvent ledger + tenant free-text PII scan |
| F4 | `2fa657e` | Verification honesty — mount smokes, masking red-path twins, StreamData property tests, `ci-fast.sh` |
| F5 | `b9ed08f` | Ops reality — metrics egress (fail-honest), WS-E telemetry, runbooks, `fleet-status.sh` |
| F6 | `a178134` | Builder leverage — `gen.resource --live`, `--modules` mount menu, `templates.ex`/`ui.ex` splits, faster CI |
| F7 | *uncommitted* | Cockpit v2 (G8 dunning · G11 lifecycle emails · G13 plan/entitlement editor · G17b health fidelity) + tail (WS-C `:non_pii` type gate · ADR-025 tripwire · G27 A6 · mk_agent · ci.sh determinism) + this gate |

Inputs: `docs/saas-gap-roadmap.md` (the WS-F1..F6 phase records + the ranked gap register), the seven
committed phase commits, ADR-031/032/033/034 + the updated ADR-025, and the live tree.

---

## Verdict in one line

F1–F7 burn-down adversarial gate (round 1): **GO**. Every F7 unit ships its green/red proofs; every
new fail-closed guarantee is bound into the standing `scripts/sabotage.sh` harness (now **28**
patches, up from 24) with a NAMED must-fail test that flips on apply and reverts byte-exact; all five
suites reproduce their counts with `--warnings-as-errors` clean; `SAMEN_SABOTAGE=1 ./ci.sh` ends
`ROOT CI: ALL PASSED`. Two F7 units resolved to "already shipped / correctly deferred" and are
recorded as such (G27/A6 was closed in Gate-6; the full ADR-025 partition stays deferred, now
tripwire-enforced). No P0/P1 findings.

**Tree state:** HEAD = `a178134` (F6); the uncommitted set is the F7 delta — the four Cockpit-v2
surfaces + the five tail units + the four new sabotage patches (25–28) + ADR-034 + the ADR-025/
moduledoc corrections + this gate + the roadmap re-rank + the README/index count refresh — awaiting
the commit that follows this gate.

---

## Green — suite counts (exact, all green, reproduced this gate with `SAMEN_SABOTAGE=1 ./ci.sh`)

| Suite | After F6 | After F7 | Delta |
|---|---|---|---|
| samen_core | 1235 | **1285 passed** (15 properties, 1270 tests), `--warnings-as-errors` clean | +50 |
| samen_web | 623 | **647 passed** (3 properties, 644 tests) | +24 |
| demo | 465 | **465 passed** (17 properties, 448 tests), 52 excluded — API-only | 0 |
| driftwood | 123 | **123 passed** | 0 |
| pawchart | 49 | **49 passed** | 0 |
| root `ci.sh` spikes | green | s00/s02/s03/s04/s05/s07 — all green | — |
| gen_app flagship + post + deploy probes + verifier gates | green | all green (non-vacuous, byte-exact registry restore) | — |
| `SAMEN_SABOTAGE=1` harness | 24/24 | **28/28 sabotages flipped named tests; byte-exact restores** | +4 |
| ci.sh final line | — | `==> ROOT CI: ALL PASSED` | — |

The demo/driftwood/pawchart counts are UNCHANGED by F7 by design: Cockpit-v2 is framework-first in
`samen_web`; G11 lifecycle emails and the WS-C/ADR-025 tail land in the `samen_core` kernel; the demo
`mk_agent` tightening is a test-helper internals change (count unchanged); G27/A6 was already tested
in `demo/test/webhook_payload_allowlist_test.exs`.

---

## F7 unit coverage — every unit mapped to a named proof / disposition

### Cockpit v2 (the four operator/billing P1s)

| Unit | Delivery | Covering test(s) | Sabotage bind |
|---|---|---|---|
| **G8 — Dunning surface** | `Samen.Web.Billing.Dunning` (bounded per-customer fold over `Reads`) + `DunningLive` at `/billing/dunning` | `dunning_masking_test.exs` (5): non-vacuity + tenant-clear (green) + operator-`••••` DOM-scan (red) + both-planes anti-tautology + `assert_leak_detected!` refutability twin | reuses the `PiiResolution` seam already bound by `24-f4-impersonation-plane-bypass` + `10-e4-search-projection-plane-bypass` (no redundant patch; refutability proven in-test) |
| **G11 — Lifecycle emails, BYO-ESP-wired** | `Samen.Delivery.Lifecycle` enqueue seam + `Lifecycle.EmailWorker` (transactional sibling of the marketing `SendWorker`, through the fail-honest `Delivery.Adapter` boundary; NO first-party ESP) | `delivery_lifecycle_test.exs` (23): event enum, `decide/3` fail-honest incl. anti-tautology + test-env sink, `perform/1` GREEN (LocalSink/{:ok}) + RED-D1 (unconfigured→blocked, never sent) + RED-D2 (adapter error→failed), discard on malformed, token-only args | **`25-f7-lifecycle-delivery-fail-honest.patch`** — flips the lifecycle D1 seam (fake `:deliver` for a nil adapter in non-test env) → 4 named RED tests fail |
| **G13 — Plan / entitlement editor** | governed CRUD in `Billing.Reads` (admin-gated via `write_scope/2`) + a fail-closed feature-key allowlist + `PlansLive` editor (create/edit plan+features, grant/revoke entitlement) | `billing_plan_editor_test.exs` (13): admin create/update GREEN + member REFUSED RED (each with anti-tautology admin control); unknown feature-key refused on create+update; entitlement grant→revoke + out-of-set feature refused; mounted-surface affordance + operator-plane no-write | **`26-f7-plan-editor-admin-gate-bypass.patch`** — flips the feature-key allowlist (allow-all) → 2 named RED tests fail (the admin gate itself is pure kernel `RoleAtLeast`, governed-by-construction) |
| **G17b — pae-recency → health `:activity` factor** | wired `__activity_days__` from the pae ProductEvent recency signal via the framework `Analytics.product_event_resource/0` config seam (DISTINCT-ON, bounded, token-blind, graceful nil) | `operator_activity_recency_test.exs` (6): fresh event→known healthy factor; old event→dormant band; no-event NEGATIVE control (`:unknown`); unwired-resource degrades to `:unknown`; renormalization invariant holds; no-PII (bounded integer) | — (fidelity wire-up; no new fail-closed seam) |

### Tail (five units)

| Unit | Disposition | Covering test(s) | Sabotage bind |
|---|---|---|---|
| **WS-C remnant — `:non_pii` type self-classify gate** | CLOSED: a host type self-classifying `samen_pii_class => :non_pii` now requires a two-DISTINCT-party `Samen.NonPii.TypeClearance` clearance (mirrors the `non_pii!` column distinct-party rule); ungoverned → fail-closed to `:pii`. ADR-034. Zero behavior change (no kernel/vertical type self-classifies `:non_pii`). | `pii_type_clearance_test.exs` (8) + `pii_classification_test.exs` (+1): valid two-party clearance→`:non_pii` (green); ungoverned/self-review/wrong-type/malformed→`:pii` (red); anti-tautology same-module ±clearance | **`27-f7-nonpii-type-selfclassify-bypass.patch`** — drops the clearance guard (reopens the hole) → 2 named RED tests fail |
| **ADR-025 — verifier host-partition** | Bounded slice shipped (the FULL 50+-file partition stays DEFERRED per the decompose rule): a fail-closed **flatten-conflict tripwire** — `AbbrevRegistry.load/0` now raises (naming ADR-025) the day a real cross-host abbrev reuse or host-vs-global mismatch is committed, turning the silent latent risk into a self-enforcing trigger. ADR-025 + moduledoc stale facts corrected (the `hosts` key now carries 5 non-conflicting entries). | `abbrev_flatten_conflict_test.exs` (9): committed registry has 0 conflicts + lossless union + allocator still reserves (green); cross-host reuse + host-vs-global mismatch each RAISE fail-closed (red); same-owner reuse + distinct-per-host are NOT conflicts (positive control) | **`28-f7-abbrev-flatten-conflict-tripwire.patch`** — weakens the distinct-owner test (`>1`→`>2`) so 2-way lossy flattenings go undetected → named RED tests fail |
| **G27 — webhook A6 over-strict guard** | ALREADY DONE — closed in Gate-6 (`16d2dd5`): `Samen.Webhook.Payload.storage_name?/2` keys on the resource's DECLARED abbrev (`Samen.Info.abbrev/1`), not the blanket `~r/^[a-z]{3}_/`. | `demo/test/webhook_payload_allowlist_test.exs` "A6 (Gate-6)" describe (3 red-paths): `cdl_number` catalog name SURVIVES; a `waw_`-prefixed name is STILL stripped; the opt-in allowlist still governs | already covered (Gate-6); no F7 code |
| **demo `mk_agent` → `Samen.Factory`** | Tightened: the demo test-local `mk_agent/1` fixture now routes its vault-PII Agent create through `Samen.Factory.create!/3` + `Factory.person/2` (governed chokepoint) instead of a raw `Ash.create(authorize?: false)`. | demo suite (465) green; the 4 `mk_agent` call sites + the PII-masking test pass unchanged | — (test-hygiene) |
| **ci.sh determinism carry** | Hardened: the 3 gen probes' fragile hand-remapped abbrev derivation replaced with `Samen.Gen.ProbeAbbrev` — collision-CHECKED against the live registry + the probe's own in-flight set, advancing deterministically. Collision-proof by construction regardless of registry growth (was ~1/10-runs flake-prone). F6 carry 8(B) shared-`_build` correctly stays deferred (spurious-PASS hazard). | `gen_probe_abbrev_test.exs` (9): `next_clear_abbrev` + `app_identity` advance past a pre-reserved naive candidate/family member, asserting naive-was-taken ∧ chosen-is-clear ∧ set validates; all 3 probes run green with byte-exact registry restore | — (determinism guarantee, not a masking/security seam) |

---

## The sabotage harness (re-run this gate — 28 patches, non-vacuous, byte-exact restore)

`SAMEN_SABOTAGE=1 ./ci.sh` ran `scripts/sabotage.sh`: all **28** committed sabotages
(`scripts/sabotages/01..28`) applied → their NAMED tests FAILED → reverted byte-exact (SHA-256
verified, zero residue). F7 added four (25–28), each a genuinely NEW refutable fail-closed seam:

| Patch | App | Seam reopened | Named must-fail |
|---|---|---|---|
| `25-f7-lifecycle-delivery-fail-honest` | samen_core | lifecycle D1 (unconfigured adapter faked to `:deliver`) | 4 lifecycle RED tests (blocked-not-sent, no-deliver-branch, sink-never-fallback, integration) |
| `26-f7-plan-editor-admin-gate-bypass` | samen_web | feature-key allowlist (allow-all) | 2 RED tests (unknown feature-key refused on create / on update) |
| `27-f7-nonpii-type-selfclassify-bypass` | samen_core | type `:non_pii` clearance guard dropped | 2 RED tests (ungoverned→`:pii`; self-review→`:pii`) |
| `28-f7-abbrev-flatten-conflict-tripwire` | samen_core | flatten-conflict detection weakened (`>1`→`>2`) | 2 RED tests (cross-host reuse RAISES; conflict reported) |

The four Cockpit-v2 + tail units that did NOT add a patch each did so for a recorded reason: G8's
masked field flows through the already-bound `PiiResolution` seam (patches 24/10 + an in-test
`assert_leak_detected!` twin); G17b/mk_agent/ci.sh-determinism add no fail-closed masking/security
seam; G27/A6 was already bound at Gate-6.

---

## Cross-phase hunts (round-1 focus — all pass)

1. **Lifecycle vs marketing delivery share the fail-honest boundary — SAFE.** Both realize
   `Samen.Delivery.Adapter` with the D1 invariant (`:delivered/:sent` ⟺ a *configured* adapter
   returned `{:ok}`); the lifecycle worker is its OWN module (not shared code), so patch 25 flips the
   lifecycle D1 seam independently of the marketing send-worker's existing coverage. A nil marketing
   adapter never rescues the lifecycle path (LocalSink is never a prod fallback) — proven by the
   "nil does not rescue nil" test.
2. **Plan editor cannot bypass the admin gate — SAFE.** Every write routes through Ash with the
   caller's `write_scope/2` (same-org, plane-preserving `:member`→`:admin` elevation) — never
   `authorize?: false`, never a hand-rolled insert — so `OrgScope` + `RoleAtLeast :admin` apply; the
   feature-key allowlist (patch 26) is the one NEW web seam Ash could not enforce (a plain `:map`).
3. **The `:non_pii` type gate and the abbrev tripwire are both fail-closed-by-default — SAFE.** An
   ungoverned `:non_pii` self-classification falls through to the mask-unknown-by-default `:pii`
   result; a lossy registry flattening RAISES. Both make the SAFE outcome the AUTOMATIC one; patches
   27/28 prove each is refutable.
4. **G8 dunning cannot disagree with the health score — SAFE.** `Dunning.rows` uses the exact
   `HealthScore.dunning?/1` definition (past-due invoice OR `:past_due`/`:unpaid` status) and folds
   over the SAME `Reads`-resolved (PII plane-correct) records — no private read, no second clock.

---

## Findings

### F7-P2-1 — G8 dunning `metrics/3` is an in-memory fold, not a pure DB aggregate (P2)

`Dunning.metrics/3` derives `overdue_cents`/`invoices` from the bounded in-memory `rows` fold rather
than a raw `Ash.sum`/`count`. This is a DELIBERATE choice matching the `Operator.Reads`
platform-billing precedent (single source of truth + one clock reading so the header and table cannot
desync) and is still bounded by construction (≤ the `Reads` `limit(200)`). Recorded so it is not
mistaken for an unbounded read. Fix (optional): a second DB-aggregate headline read with
reconciliation, if a pure-DB headline is later wanted. Non-blocking.

### F7-P2-2 — G17b flag-adoption fold + G13 entitlement `expires_at` surface carried (P2)

G17b wired pae-recency into the `:activity` factor but did NOT fold flag-adoption breadth into the
`:adoption` factor: feature flags here are operator-owned rollout controls with no framework-level
bounded per-account adoption signal / cross-scope resolution seam (ties to G6). The `:adoption`
factor's "flag-adoption breadth pending (G6)" note is left honest, not faked. Separately, G13's
entitlement editor grants/revokes by feature but does not yet surface `expires_at` as a display
column. Both are recorded carries, non-blocking.

No P0/P1.

---

## Carry dispositions (F7 units that resolved to "already done / deferred")

| Unit | Disposition |
|---|---|
| G27 / A6 webhook over-strict guard | **DONE (Gate-6)** — no F7 code; the abbrev-keyed guard + 3 demo red-paths are the standing proof. The roadmap G27 row is corrected in the re-rank. |
| ADR-025 full host-partition (§2, 50+ files) | **DEFERRED (correctly) + now tripwire-enforced** — becomes load-bearing and self-announcing (fail-closed build error) the moment a real cross-host prefix reuse lands. |
| F6 carry Unit 8(B) — shared deps/`_build` across the 3 gen probes | **RE-AFFIRMED deferred** — a shared `_build` across differently-configured apps risks a spurious PASS masking a failure (a determinism HAZARD); isolation is what makes each probe's green trustworthy. |

---

## Carries forward (this gate's P2s + standing operator-TODO / human-gated items)

1. **F7-P2-1** — G8 dunning DB-aggregate headline (optional; bounded today).
2. **F7-P2-2** — G17b flag-adoption fold (needs a G6 bounded per-account flag signal) + G13
   entitlement `expires_at` surface.
3. **Standing operator-TODO / human-gated (NOT agent work):** real Neon PITR drill · AWS
   KMS+DynamoDB+S3-ObjectLock · ClickHouse ClickPipes/drills · Oban multi-node concurrency · DP
   epsilon budget enforcement (`query_budget` WARN-not-enforced today) · a real MCP server · first-party
   Stripe/ESP adapters (the fail-honest BYO boundary holds — host implements `SyncAdapter` /
   `Delivery.Adapter` per the guides) · a production IdP (the F2 PBKDF2-over-config verifier is a
   reference, not an IdP) · operator-plane (SaaS-staff) auth arming.
4. **Framework standing:** `Samen.Web.Api.PageLimitClamp` until upstream Ash fixes the `to_page`
   raw-limit split · the WS-E follow-ons (real `Storage.S3`/`Scanner` impls, per-abbrev tsvector
   trigger/GIN index, fleet-wide `assign_async`/`stream` perf rewrite, pawchart Identity scope to
   unlock its settings mount).

---

## Fix tasks

**Mandatory: none.** The gate is GO; both P2s are non-blocking and carried forward above. F7 is the
FINAL phase of the F1–F7 burn-down — with this gate, every burn-down phase is gated GO, every Cockpit-v2
P1 (G8/G11/G13/G17b) is shipped framework-first, the WS-C `:non_pii` type escape hatch and the ADR-025
silent-risk are both closed fail-closed, and the standing sabotage harness stands at 28 patches. The
immediate next step is the F7 commit banking the uncommitted set this gate verified.
