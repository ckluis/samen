# Gate-4 Fix Round

## F4.1 (MANDATORY-IN-PHASE, MED) — bind the reveal chokepoint to the token's real subject

**Status: LANDED (green).**

### The finding (from docs/gate-4-report.md)

The single plaintext chokepoint `Samen.Vault.reveal/3` accepted a caller-supplied
`:subject_id` opt but **ignored it** (`_opts`). So break-glass (and the routine
reveal API) could decrypt subject **A**'s plaintext while the tamper-evident local
audit + breadth budget recorded subject **B** — an accountability-evasion. The
report's empirical probe:
`BreakGlass.reveal(%{masked: <A's token>, subject_id: "B"})` returned
`{:ok, %{plaintext: "alice-SECRET@a.test", local_entry: %{subject_id: "B…"}}}`.

The threading of `subject_id` into the vault call already existed at both callers
(`BreakGlass.reveal/1` → `vault.reveal(req.masked, repo, subject_id: req.subject_id)`;
`Reveal.reveal/5` → `vault_mod.reveal(masked, repo, Keyword.take(opts, [:subject_id]))`).
The gap was solely that the chokepoint dropped the opt on the floor.

### The fix (single chokepoint, not re-architecture)

`samen_core/lib/samen/vault.ex` — `reveal/3` now reads the `:subject_id` opt and
threads it to `reveal_token/3`, which, after loading the `VaultRow`, applies:

```elixir
defp bind_subject(nil, _real), do: :ok            # no assertion (raw internal callers)
defp bind_subject(same, same), do: :ok            # asserted == real → allow
defp bind_subject(_asserted, _real), do: {:error, :subject_mismatch}  # mismatch → DENY
```

The bind runs **before** `Kms.adapter().unwrap/1` — the DEK is never touched on a
mismatch, so no PII for the real subject is produced under a wrong subject's audit.
`nil` (no assertion) is preserved for the internal oracle scans
(`scan_no_plaintext/2`, `scan_pitr_key_absent/2`) which call `reveal_token/2` with no
subject; their behaviour is unchanged (the 3rd param defaults to `nil`). No caller
signatures changed; no PII leaks to an unauthorized party.

### Red paths added (must-fail without the fix)

1. `test/vault_test.exs` — "F4.1 subject-bind at the reveal chokepoint":
   - **RED**: mismatched `:subject_id` DENIES `:subject_mismatch`, no `{:ok, _}`.
   - positive control: matching `:subject_id` reveals.
   - absent `:subject_id` (raw caller) still reveals — no bind applied.
2. `test/break_glass_test.exs` — "(F4.1) break-glass subject bind":
   - **RED**: `BreakGlass.reveal` with a request `subject_id` = B but A's masked
     token DENIES `:subject_mismatch` — A's plaintext never surfaces under B's
     local audit / breadth budget (the exact report scenario).
   - positive control: matching subject_id still reveals.
3. `test/reveal_grant_seam_test.exs` — routine path, REAL `Samen.Vault`:
   - **RED**: an APPROVED grant for subject X + a masked token that is really Y's
     DENIES `:subject_mismatch` at the vault (grant satisfied, vault still denies).
   - positive control: with Y's real subject_id the same real-vault reveal succeeds.

### Anti-tautology probe (sabotage → confirm flip → revert → state)

Backed up `lib/samen/vault.ex` to `.gate4_scratch/` (project-local), sabotaged
`bind_subject/2`'s mismatch clause to `do: :ok` (defeating the bind), and re-ran the
three affected test files.

**Result: 3 tests FAILED (49/52 passed).** The break-glass RED path returned
`{:ok, %{plaintext: "alice-SECRET@a.test", local_entry: %{subject_id: "subj-11586"}}}`
— A's plaintext under B's audit, reproducing the F4.1 finding exactly. This proves
the bind is a non-vacuous discriminator, not an always-deny.

Reverted from the backup, deleted `.gate4_scratch/`, confirmed `grep -c SABOTAGED
lib/samen/vault.ex == 0`. With the fix restored all 52 pass.

### Gate results (run before AND after)

| Check | Before | After |
|---|---|---|
| `samen_core` `mix test --warnings-as-errors` | 752 passed | **758 passed** (9 properties, 749 tests) — +6 new tests |
| `demo` `mix test --warnings-as-errors` | 399 passed | **399 passed** (17 properties, 382 tests), 48 excluded — no regression |
| root `bash ci.sh` | exit 0 | **exit 0 — ROOT CI: ALL PASSED** |

### Files changed

- `samen_core/lib/samen/vault.ex` — chokepoint subject-bind (`bind_subject/2`; `reveal/3`/`reveal_token/3` thread the opt; doc updated).
- `samen_core/test/vault_test.exs` — F4.1 chokepoint red paths + controls.
- `samen_core/test/break_glass_test.exs` — F4.1 break-glass red path + control.
- `samen_core/test/reveal_grant_seam_test.exs` — F4.1 routine-path red path (real vault) + control.

F4.2 and F4.3 are carry-to-P5 per the report and are OUT of this bounded round.
