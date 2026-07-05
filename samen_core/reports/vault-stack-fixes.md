# Vault-stack fix round

**Task:** Bounded one-pass fix round for the vault-stack audit (verdict=partial).
**Date:** 2026-07-05
**Status:** GREEN
**Baseline:** 218 tests. Final: **238 tests** (9 properties, 229 tests); +20.
**Gates:** `mix test --warnings-as-errors` PASS (seeds 42/999/default deterministic);
`mix ash.codegen --check` clean.

## Mandated fixes — all landed

See `reports/audit-fixes.md` "Fix round — vault-stack audit" for the per-fix
narrative, red paths, and anti-tautology probe results. Summary:

| # | Priority | Fix | Red path | Probe result |
|---|---|---|---|---|
| 1 | P0 integration | `Samen.Vault.Change` + `Samen.Type.VaultField`: create/update route plaintext→vault, domain column ← token, read ← `%Masked{}` | `vault_change_integration_test.exs` (a–d) | neuter token-swap → 8 tests FAIL (VaultField dump fails closed) |
| 2 | P0 correctness | No plaintext column: the ONE domain column IS the token column; migrations reconciled | raw-SQL token assertions in integration + `resource_test.exs` | same guard as Fix 1 |
| 3 | P1 authz | reveal capability binds to REQUESTOR (distinct approver), not approver | `reveal_grants_test.exs` approver-denied + collusion-closed | revert to `granted_by` → 8 tests + 1 property FAIL |
| 4 | P1 doc drift | `Samen.Vault` moduledoc rewritten to what is actually wired | n/a (doc) | n/a |
| 5 | P2 shred DiD | `key_material_present?/1` on behaviour+3 adapters; `erased?/1` requires actual DEK destruction | `shred_key_material_test.exs` leaky-shred + conformance | drop check → red path FAIL; sabotage adapter → conformance FAIL |

## Key files

- `lib/samen/type/vault_field.ex` — NEW: the vault-field storage type (token
  column; `cast_stored` → `%Masked{}`; `dump_to_native` fails closed on non-token).
- `lib/samen/vault/change.ex` — NEW: the resource↔vault Ash change (write path).
- `lib/samen/transformers/materialize_pii.ex` — materializes VaultField token
  columns (no plaintext column) + injects the global vault change.
- `lib/samen/vault.ex` — corrected moduledoc; `materialize/2` updated for raw
  structs; removed dead `token_field_name/1`.
- `lib/samen/reveal/grants.ex` — `active?/2` binds capability to the requestor.
- `lib/samen/kms.ex`, `.../kms/{file_backed,in_memory,aws_kms_dynamo}.ex` —
  `key_material_present?/1` callback + implementations; FileBacked shred verifies
  DEK gone before tombstone.
- `lib/samen/erasure.ex` — `erased?/1` depends on actual key destruction; report
  surfaces `key_material_present`.
- Migrations: `20260705035640_initial_core.exs` (unchanged plaintext form kept as
  the codegen baseline), `20260705140508_vault_token_columns.exs` (NEW codegen
  migration converting PII columns to `:text` token columns),
  `20260705040000_vault_tables.exs` (no redundant `*_token` side columns).
- Tests: `vault_change_integration_test.exs`, `shred_key_material_test.exs` (NEW);
  updated `resource_test.exs`, `reveal_grants_test.exs`, `reveal_grant_seam_test.exs`,
  `reveal_grant_property_test.exs`, `kms_conformance_test.exs`, `erasure_test.exs`.

## Anti-tautology probes (HARD RULE 2) — all confirmed non-vacuous

1. **Vault write guard (Fix 1/2):** neutered the token-replacement in
   `Samen.Vault.Change.do_vault` → all 8 `vault_change_integration_test.exs`
   FAILED (create raises: `VaultField.dump_to_native` refuses plaintext). Reverted.
2. **Requestor binding (Fix 3):** reverted `active?/2` to `granted_by ==
   ^requestor_id` → 8 tests + 1 property FAILED (approver-denied + collusion red
   paths). Reverted.
3. **Erasure key-material clause (Fix 5):** removed `false <- key_material_present?`
   from `erased?/1` → the leaky-shred red path FAILED (erased? wrongly true).
   Reverted.
4. **Adapter key-material sensor (Fix 5):** sabotaged FileBacked
   `key_material_present?` to `false` → conformance pre-shred `== true` assertion
   FAILED. Reverted.

## Honest caveats / residue

- The vault stores each field value as an opaque binary: composite PII structs are
  JSON-encoded (`Samen.Vault.Change.dump_plaintext/1`), scalars stringified.
  `reveal/3` returns that same binary; a host that needs the TYPED value decodes
  it. This is faithful to "the vault stores opaque bytes" but means composite
  reveal returns JSON, not a `%FullName{}` — a typed-reveal decode helper is
  future polish (not a leak; plaintext still only exits via the single chokepoint).
- Fix 5's `key_material_present?/1` production contract (AwsKmsDynamo `GetItem`
  after `DeleteItem`) is documented and stub-delegated but NOT exercised against
  live AWS in CI — consistent with the ADR-001 §8.1 "no live AWS in CI" rule; the
  T2.9 oracle check-2b and a prod game-day are the durable backstop.
- `%Masked{}` produced on read carries label `:vault` (the type has no field-name
  context); the field-specific label is only set on the `Samen.Vault.Change` write
  path. Cosmetic (labels are for diagnostics, never plaintext).
