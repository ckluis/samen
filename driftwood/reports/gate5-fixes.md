# GATE-5 FIX ROUND — bounded, one pass

- **Date:** 2026-07-07
- **Scope:** land the single mandatory-in-phase fix from `docs/gate-5-report.md` exactly as
  diagnosed — **F3** — each with a red-path (must-fail) test + an anti-tautology probe, keeping
  all suites + `driftwood/ci.sh` + root `ci.sh` green.
- **Directive item:** `F3 — guard the session-less /operator/impersonate path
  (nil operator_id/org_id + :operator_suspended) so it renders access-denied not a 500;
  regression test RP5b added; verified live HTTP 200; driftwood/ci.sh + root ci.sh green.`

---

## F3 — session-less `/operator/impersonate` renders access-denied, not a 500

### The defect (as diagnosed by gate-5)

`DriftwoodWeb.OperatorImpersonationLive`'s moduledoc claims the absent-session path "renders
the access-denied state, no data." The running app **500'd** instead: `mount/3` → `load/3`
with `operator_id = nil` → `Samen.Impersonation.scope(nil, …)` →
`Samen.Impersonation.operator_id/1` raised `FunctionClauseError` (no nil clause). No PII leak
(500 body is `Internal Server Error`), so this is availability/robustness, not disclosure — but
it contradicts a stated fail-closed contract on the operator-plane entry page.

### The fix (landed, exactly as diagnosed)

`lib/driftwood_web/operator_impersonation_live.ex`:

- A guarded `load/3` head — `when not is_binary(operator_id) or not is_binary(org_id)` — routes
  a nil/partial-param mount to a shared `denied/3` access-denied assign (no data, no reveal, no
  session info).
- The success `case` now also handles `{:error, :operator_suspended}` (which
  `Impersonation.for_session/3` can return for a suspended operator mid-session and the old code
  would have crashed on) alongside `:session_inactive` — both fail-closed to `denied/3`.

The guard is deny-on-read: any non-binary `operator_id`/`org_id` renders `session_inactive:
true` → the `access denied` template branch, `drivers: []`, `loads: []`.

### Red-path (must-fail) test — regression RP5b

`test/web_red_paths_test.exs`, RED PATH 5b:

```elixir
test "a session-less mount (nil operator_id/org_id) renders access-denied, does NOT crash" do
  for {op_id, org_id} <- [{nil, nil}, {nil, "some-org"}, {"op-x", nil}] do
    socket = DriftwoodWeb.OperatorImpersonationLive.load(empty_socket(), op_id, org_id)
    html = render(DriftwoodWeb.OperatorImpersonationLive, socket.assigns)
    assert html =~ "access denied", ...
    refute html =~ "driver-row"
    refute html =~ "CDL-OK-"
    assert socket.assigns.drivers == []
    assert socket.assigns.session_inactive == true
  end
end
```

Drives all three nil/partial permutations that `mount/3` can pass when params/session are
absent — the exact path that used to 500. Passes with the fix (6/6 in `web_red_paths_test.exs`).

### Anti-tautology probe (sabotage → confirm flip → revert)

- **Scratch:** project-local `driftwood/.gate5_scratch/` (backup of the live file), removed at end.
- **Sabotage:** removed the guarded `load/3` clause so the nil path falls through to
  `Impersonation.scope(nil, …)` — the pre-fix behavior.
- **Result:** RP5b **FLIPPED to failing** with exactly the diagnosed crash —
  `FunctionClauseError` at `Samen.Impersonation.operator_id/1`
  (`lib/samen/impersonation.ex:130` ← `scope/3:87` ← `operator_impersonation_live.ex:57`).
  Suite went 6/6 → **5/6, 1 failed**. This proves the red path exercises the real guard, not a
  tautology.
- **Revert:** restored from backup; file is **byte-identical** to the original
  (`md5 = 9d08cb6211418176cea2e63cd577a3a0` before and after). Scratch dir removed. RP5b green
  again.

### Live HTTP verification

Booted the app (`MIX_ENV=dev PORT=4010 mix phx.server`) and curled the session-less path:

```
GET http://127.0.0.1:4010/operator/impersonate
→ HTTP 200
body contains "access denied"; grep for CDL-OK-/vt_ → nothing; grep for driver-row → nothing
```

HTTP **200** + fail-closed access-denied, no PII, no data rows — matches the diagnosis
(500 → 200) exactly.

---

## Green-before / green-after

- **Green-before:** root `bash ci.sh` exit 0 — the F3 fix + RP5b were already present in the tree
  from the gate-5 session; this round re-verified the guarantee is real (anti-tautology + live
  HTTP) and re-confirmed all gates.
- **Green-after (deterministic, non-piped runs):**
  - `samen_core` standalone: **768 passed** (9 properties, 759 tests).
  - `driftwood` `mix test --warnings-as-errors`: **47 passed** (1 property, 46 tests), 4
    adversarial excluded (run in `ci.sh` step 18).
  - `driftwood/ci.sh`: **ALL PASSED** (20 steps — 16 verifiers + default + adversarial + T5.4
    crypto-shred game-day + T5.5 PITR game-day, both arms + red-path probe).
  - root `bash ci.sh`: **exit 0 — ROOT CI: ALL PASSED** (spikes + samen_core 768 + demo 399+48 +
    demo CI gate + full driftwood gate).
- **Note on a transient grep-piped observation:** one `bash ci.sh 2>&1 | grep …` run showed a
  momentary `766/768` for samen_core (a property/DB-transaction retry surfacing under the piped,
  concurrent run). Every clean deterministic run — standalone `mix test` and the un-piped
  `ci.sh` (exit 0) — shows **768 passed**. No real failure; the gate exit code is authoritative.

## Files touched this round

- None. The F3 fix (`lib/driftwood_web/operator_impersonation_live.ex`) and its regression test
  (`test/web_red_paths_test.exs` RP5b) were already landed by the gate-5 session and are
  byte-identical after this round's anti-tautology probe. This round is a bounded
  verify-and-attest pass: it independently proved the guarantee non-vacuous (sabotage flip +
  revert), confirmed live HTTP 200, and re-ran both CI gates green.

## Residues (unchanged — carry-to-P6, as gate-5 labeled)

- **F1** — the reference vertical mounts no public AshJsonApi/webhook surface; external-surface
  guarantees proven in `demo`, unproven on freight PII. Carry-to-P6.
- **F2** — the tenant-owner-sees-own-PII-in-clear rule is inverted in Driftwood's tenant UI
  (fail-SAFE over-masking). Carry-to-P6 or ratify the stricter posture.

Neither is a breach; both are out of scope for this bounded fix round.
