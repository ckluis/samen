# Task PRE (Gate-4 carry into Phase 5) — F4.2 + F4.3

**Date:** 2026-07-07
**Status:** green. samen_core 768 passed (was 758; +10 new), demo 399, adversarial 48,
all spikes green. `mix test --warnings-as-errors` green. Root `bash ci.sh` green before
and after.

> Note: a separate pre-existing `reports/PRE.md` (Phase-2 carry-forward, 2026-07-05) is
> unrelated and left untouched. This report is the Gate-4-into-P5 carry-over.

---

## F4.2 — terminate live impersonation on suspension

**Change:** `Samen.Impersonation.Scope.for_session/3`
(`lib/samen/impersonation/scope.ex`) now consults
`Samen.OperatorPlane.Suspension.suspended?/2` for the session's operator BEFORE the
session lookup, on every scope rebuild. A suspended operator gets
`{:error, :operator_suspended}` — the same access-denied shape every other
reveal/operator path returns for a suspended operator — even when the underlying
`imp_impersonation_session` row is still unexpired and open. This is the per-request
operator-plane analogue of the existing per-request expiry gate: `open/1` already refused
to START a session while suspended; `for_session/3` now refuses to CONTINUE one, so
suspending an operator mid-session ends the open session on its NEXT request.

Fail-closed: `suspended?/2` defaults to "treat as suspended" when the suspension table is
unreachable, so a rebuild that cannot confirm the operator is un-suspended denies. Repo
plumbing: `for_session` forwards `:repo` only when present (so `suspended?/2` falls back to
the configured repo rather than being handed a `nil`).

**Red path + positive control** (`test/impersonation_test.exs`, describe "suspending an
operator ends a live session on its next request (F4.2)"):
- open a live 30-min session -> scope rebuilds `{:ok, scope}`; suspend the operator
  mid-session -> next `Scope.for_session/3` returns `{:error, :operator_suspended}` while
  `Sessions.active?/2` still reports the session unexpired (proves it is the suspension
  gate, not expiry); clear the suspension -> the SAME session rebuilds to `{:ok, scope}`
  again (positive control).
- a DIFFERENT operator's live session over the same org is unaffected by the first
  operator's suspension.

**Anti-tautology probe:** neutered the gate (`if false and Suspension.suspended?...`) via a
project-local scratch backup, reran both F4.2 tests -> BOTH FLIPPED to failing (deny became
`{:ok, %Samen.Scope{}}`). Reverted; scratch dir removed. Result: the tests are genuinely
bound to the suspension gate.

---

## F4.3 — reason/detail free-text shred honesty

The operator-authored `reason` (impersonation sessions, reveal requests) and the
audit-chain/-event `detail` are **plaintext metadata**, NOT crypto-shreddable: a subject
DEK destruction cannot reach a plaintext column, and the audit chain deliberately preserves
the `detail` token (its hash commits to it). So "who it was about becomes unrecoverable"
holds for the vaulted PII + per-subject ciphertext but NOT for operator free text.

**Doc (preferred cheap fix — named the residue explicitly):**
- `docs/adr/002-worm-anchor.md` — new **§2.5** "The `detail`/`reason` free-text is a
  NON-shreddable plaintext channel", qualifying the prior unqualified "who it was about
  becomes unrecoverable" wording; §4 consequences updated.
- moduledocs updated: `Samen.Impersonation.Sessions`, `Samen.Reveal.Grants`,
  `Samen.AuditChain`, `Samen.AuditChain.Writer` — each names the residue and the mitigation.

**Fail-closed value-shape scan (reject chosen as default, documented):** new
`Samen.PiiReasonScan` (`lib/samen/pii_reason_scan.ex`) wraps
`Samen.PiiValueShape.classify_value/1` (email / SSN / phone value shapes only — the
space-separated-name shape is **excluded**, because ordinary reasons like "customer #1234
reported a billing error" have internal spaces and would false-reject). `check/2` REJECTS a
bare PII-shaped reason/detail with `{:error, {:pii_shaped_reason, shape}}` and logs a
`Logger.warning`. Wired at three write boundaries, all BEFORE any DB write:
- `Samen.Impersonation.Sessions.open/1` (impersonation reason)
- `Samen.Reveal.Grants.request/1` (reveal-request reason)
- `Samen.AuditChain.Writer.write/2` (audit detail — last-line belt at the shared chain
  boundary; composed details `event=... reason=...` are not bare value shapes and pass).

Reject-not-warn is the fail-closed choice: a stored plaintext PII value in a non-shreddable
channel is exactly the leak a later shred cannot erase, so it is refused up front. This is a
heuristic (not a taint proof) and does not gate on names — the load-bearing control is the
human convention "reasons name the ticket, not the person," now stated in all four
moduledocs + the ADR.

**Red paths + positive controls** (`test/pii_reason_scan_test.exs`, 22 assertions across 8
tests): PII-shaped reason rejected at each of the three call sites (no row lands); a normal
reason (with the same internal spaces) passes at each; unit coverage of `scan/1`+`check/2`
including that a space-separated name is NOT rejected.

**Anti-tautology probe:** neutered the scan (`scan/1` -> always `:ok`) via a scratch backup,
reran the suite -> 5 tests FLIPPED to failing (the three call-site rejections + the unit
scan/check), PII values flowed through unrejected. Reverted; scratch removed. Result: the
tests are genuinely bound to the scan.

---

## Repo convention note (for Phase 5 proper)

The repo has NO `apps/` dir; top level is flat (`samen_core/`, `demo/`, `spikes/`). The new
Driftwood app therefore belongs at top-level
`/Users/clank/Desktop/projects/samen/driftwood/` (matching the `demo/` sibling convention),
with its own `ci.sh`, mounting `samen_core` scopes + `Samen.Context` exactly as `demo/`
does. The Driftwood build itself is out of scope for PRE; this task delivered only the
Gate-4 carry-over hardening in samen_core + docs.

## Files touched
- `lib/samen/impersonation/scope.ex` (F4.2 gate + moduledoc)
- `lib/samen/impersonation/sessions.ex` (F4.3 reason scan + moduledoc)
- `lib/samen/reveal/grants.ex` (F4.3 reason scan + moduledoc)
- `lib/samen/audit_chain.ex` (moduledoc residue note)
- `lib/samen/audit_chain/writer.ex` (F4.3 detail scan + moduledoc)
- `lib/samen/pii_reason_scan.ex` (NEW)
- `docs/adr/002-worm-anchor.md` (§2.5 + §4)
- `test/impersonation_test.exs` (F4.2 tests)
- `test/pii_reason_scan_test.exs` (NEW — F4.3 tests)
