# Vault-stack re-audit (post fix-round)

**Date:** 2026-07-05
**Scope:** Re-audit of the `samen_core` vault stack after the bounded fix round for
the 5 prior mandatory issues. Confirm each fix genuinely landed (re-run its red
path), sabotage-probe (anti-tautology) at least one, re-run the full suite, re-check
the original attack list.
**Verdict:** **CONFIRMED** — all 5 mandatory fixes are genuinely landed, load-bearing,
and non-vacuous. No remaining mandatory issues.

## Environment / gate results

- Full suite: **238 passed** (9 properties, 229 tests), `mix test --warnings-as-errors`
  PASS (seed 0).
- `mix ash.codegen --check` → **exit 0** (no migration drift).
- No leftover `SABOTAGE PROBE` markers in `lib/`; probe files byte-identical to
  pre-probe backups (diff verified for vault_field / change / grants / erasure).

## Per-fix confirmation

### Fix 1/2 (P0) — resource↔vault integration + no plaintext column — CONFIRMED
- `Samen.Vault.Change` (global Ash change injected by `MaterializePii`) routes each
  set `pii_attribute` plaintext → `pii_vault` ciphertext + `vt_*` token, and
  `force_change_attribute`s the domain column to the token. `Samen.Type.VaultField`
  is the storage type: `cast_stored` → `%Masked{}` on read; `dump_to_native` FAILS
  CLOSED (`:error`) on any non-token — the last-line guard.
- **DB schema proof (end-to-end):** all 5 patient PII columns are `text` token
  columns — `pat_emails`, `pat_full_name`, `pat_phones`, `pii_pat_dob`, `pii_pat_mrn`.
  NO `map`/`date` plaintext columns remain; NO `<field>_token` side columns.
- Red path `test/vault_change_integration_test.exs` (a–d) green: raw SQL shows
  `vt_*` tokens not plaintext; `pii_vault` ciphertext contains no plaintext; `Ash.read`
  → `%Masked{}`; JSON shows `••••`.
- **Anti-tautology probe (RUN):** neutered `Samen.Vault.Change.do_vault` to leave
  plaintext on the changeset (no token replacement). Result: **all 8 integration
  tests FAILED** — `create` raises because `VaultField.dump_to_native` refuses to
  persist plaintext (fail closed). Reverted → 8 passed.

### Fix 3 (P1 authz) — reveal capability binds to REQUESTOR, not approver — CONFIRMED
- `Samen.Reveal.Grants.active?/2` filters on `requestor_id == actor` AND
  `granted_by != requestor_id` (distinct-approver gate re-checked on read). DB CHECK
  `rvg_distinct_party` present in the reveal-grants migration (confirmed in
  `pg_constraint`).
- Red paths in `test/reveal_grants_test.exs` green: "approver does NOT hold the
  capability", "throwaway-requestor collusion is closed", "self-approved grant can
  never authorize a reveal".
- **Anti-tautology probe (RUN):** reverted the `active?` filter to the pre-fix
  approver-is-revealer model (`granted_by == actor`). Result: **8 tests + 1 property
  FAILED** (approver-denied + collusion red paths). Reverted → 23 passed.

### Fix 4 (P1 doc drift) — `Samen.Vault` moduledoc corrected — CONFIRMED
- Moduledoc describes what is ACTUALLY wired: the `Samen.Vault.Change` write path,
  `VaultField.cast_stored` read masking (not a per-resource hook), and the
  fail-closed `dump_to_native` last-line guard. `Samen.Vault.Change` moduledoc and
  `MaterializePii` moduledoc agree with the code. No residual claim of an unbuilt
  integration. (Doc-only fix; no red path applicable.)

### Fix 5 (P2 shred DiD) — deny depends on ACTUAL key destruction — CONFIRMED
- `key_material_present?/1` added to the `Samen.Kms` behaviour + all 3 adapters
  (FileBacked checks `.dek` file; InMemory checks `:SHREDDED` sentinel; AwsKmsDynamo
  delegates in stub mode, documents the enabled-mode `GetItem` contract and raises
  loudly if enabled-but-unwired). FileBacked `shred/1` verifies the DEK is gone
  BEFORE writing the tombstone (`:key_material_not_destroyed` otherwise).
  `Erasure.erased?/1` requires `key_material_present?/1 == false`.
- Red path `test/shred_key_material_test.exs` green: a `LeakyShredAdapter` that
  tombstones but leaves the DEK is NOT `erased?`.
- **Anti-tautology probe (RUN):** removed the `key_material_present?` clause from
  `erased?/1` (trust tombstone alone). Result: the leaky-shred RED PATH **FAILED**
  (`erased?` wrongly true). Reverted → 2 passed.

## Original attack-list re-check (all closed)

- **Plaintext in domain column** — closed. Physical columns are `text` tokens; the
  write path + `dump_to_native` guard make plaintext un-persistable.
- **Leak by omission on read** (CSV/JSON/log/HEEx) — closed. `%Masked{}` implements
  `String.Chars`/`Inspect`/`Jason.Encoder`/`Phoenix.HTML.Safe`/`to_iodata`, carries
  no plaintext (only token+label). Gate-0 fix task #1 (LiveView masking) closed.
- **Self-serve reveal via throwaway requestor** — closed. Capability binds to the
  requestor gated on a distinct approver; approver cannot reveal.
- **Self-approval** — closed at BOTH layers (policy `:self_approval` + DB CHECK
  `rvg_distinct_party`); a self-approved grant can never authorize on read.
- **Tombstone-only "shred" (key recoverable)** — closed. `erased?`/oracle key on
  actual key-material destruction.
- **PITR resurrects the key** — closed (unchanged from S0.5): key store external to
  Postgres; `vault_pitr_test` proves restored ciphertext cannot decrypt.

## Residues (honest — none mandatory)

1. Composite reveal returns the JSON-encoded binary, not a typed `%FullName{}`
   (a typed-reveal decode helper is future polish). NOT a leak — plaintext still
   exits only via the single `reveal/3` chokepoint.
2. `AwsKmsDynamo` `key_material_present?`/`backups_disabled?` production contracts
   (`GetItem`/`DescribeContinuousBackups`) are documented + stub-delegated, NOT
   exercised against live AWS in CI (ADR-001 §8.1). Fail-loud when enabled-but-unwired.
   T2.9 oracle check-2b + a prod game-day are the durable backstop.
3. Read-path `%Masked{}` carries label `:vault` (no field-name context); the
   field-specific label is only set on the write path. Cosmetic (labels never carry
   plaintext).
