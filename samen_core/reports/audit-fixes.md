# Audit fixes

## Fix round — vault-stack audit (verdict=partial)

Date: 2026-07-05. All five mandated fixes landed in `samen_core/`, each with a
red-path test and an anti-tautology probe. Whole suite green: **238 passed**
(9 properties, 229 tests), `mix test --warnings-as-errors` clean, `mix ash.codegen
--check` clean.

### Fix 1 (P0, integration) — resource↔vault integration (`Samen.Vault.Change`)

Built `Samen.Vault.Change` (`lib/samen/vault/change.ex`), a global
`Ash.Resource.Change` injected into every resource with a `pii do` block by
`Samen.Transformers.MaterializePii`. On the real Ash `:create`/`:update` actions
(in `before_action`), for each set `pii_attribute` it: resolves the subject_id
(the resource PK), calls `Samen.Vault.store_fields/4` (ciphertext + token in
`pii_vault`), and `force_change_attribute`s the domain column to the opaque `vt_*`
token. On read the field's normal value is `%Masked{}` — presented by
`Samen.Type.VaultField.cast_stored/2` (`lib/samen/type/vault_field.ex`), no
per-resource read hook.

- Red path: `test/vault_change_integration_test.exs` creates a `Clinical.Patient`
  via its real `:create` action and asserts (a) `pii_pat_mrn`/`pat_full_name`/
  `pii_pat_dob` hold `vt_*` tokens NOT plaintext; (b) `pii_vault` has a ciphertext
  row per field (dob/full_name/mrn) with no plaintext in the ciphertext; (c)
  `Ash.read` returns `%Masked{}`; (d) JSON of the record shows `••••`, never the
  plaintext. Plus update re-vaults, untouched-field token intact, reveal round-trip,
  post-shred `:shredded`.
- Anti-tautology probe: neutered the token-replacement in `do_vault` (leave
  plaintext on the changeset). Result: all 8 integration tests FAILED — the create
  raises because `Samen.Type.VaultField.dump_to_native/2` refuses to write a
  non-token (fail closed). Reverted, green.

### Fix 2 (P0, correctness) — no plaintext column for a vault-routed field

`Samen.Transformers.MaterializePii` now materializes the logical PII attribute as
a `Samen.Type.VaultField` (`:string`/`:text` storage holding the token) — there is
NO separate plaintext column and NO `<field>_token` side column; the ONE domain
column IS the token column. Reconciled the migrations: `20260705140508_vault_
token_columns.exs` (codegen) converts `pat_full_name`/`pat_emails`/`pat_phones`/
`pii_pat_dob` (and staff equivalents) from `:map`/`:date` plaintext to `:text`
token columns; `20260705040000_vault_tables.exs` no longer adds redundant
`*_token` columns. `VaultField.dump_to_native/2` fails closed on any non-token.

- Red path: the `(a)`/`(d)` assertions in `vault_change_integration_test.exs` and
  the updated `resource_test.exs` "create + FK + read round-trips" test assert the
  raw SQL column is a `vt_*` token and contains none of `MRN-9`/`Grace`/`Hopper`.
- Anti-tautology probe: same probe as Fix 1 (the guard is the same VaultField
  dump). Confirmed non-vacuous.

### Fix 3 (P1, authz) — reveal capability binds to the requestor, not the approver

`Samen.Reveal.Grants.active?/2` now keys the reveal capability on
`requestor_id == actor` (gated on `granted_by != requestor_id`), not `granted_by
== actor`. The distinct approver AUTHORIZES; the requestor REVEALS — closing the
self-serve-via-throwaway-requestor collusion (an operator could previously be the
approver for a burner requestor and hold the reveal capability). Updated the seam
and property tests to reveal as the requestor.

- Red path: `test/reveal_grants_test.exs` "the APPROVER does NOT hold the reveal
  capability", "throwaway-requestor collusion is closed", and "self-approved grant
  can never authorize a reveal".
- Anti-tautology probe: reverted `active?` to `granted_by == ^requestor_id`.
  Result: 8 tests + 1 property FAILED (incl. the approver-denied and collusion red
  paths). Reverted, green.

### Fix 4 (P1, doc-vs-code drift) — `Samen.Vault` moduledoc corrected

Rewrote the "Vault routing" moduledoc section of `Samen.Vault` to describe what is
ACTUALLY wired: the built `Samen.Vault.Change` write path, the `Samen.Type.Vault
Field.cast_stored` read masking (not a per-resource hook), and the fail-closed
`dump_to_native` last-line guard. No longer claims an unbuilt integration.

### Fix 5 (P2, shred defence-in-depth) — deny depends on ACTUAL key destruction

Added `key_material_present?/1` to the `Samen.Kms` behaviour and all three adapters
(FileBacked checks the `.dek` file; InMemory checks the `:SHREDDED` sentinel;
AwsKmsDynamo delegates in stub mode + documents the enabled-mode `GetItem`
contract). FileBacked `shred/1` now verifies the DEK file is gone BEFORE writing
the tombstone (fail closed on `:key_material_not_destroyed`). `Samen.Erasure.
erased?/1` now requires `key_material_present?/1 == false` in addition to the
positive tombstone and sealed vault rows; the erasure report surfaces
`key_material_present` for the oracle (check-2b).

- Red path: `test/shred_key_material_test.exs` "a tombstone-written-but-DEK-left
  shred does NOT count as erased" (a `LeakyShredAdapter` writes a positive tombstone
  but leaves the key; `erased?` must be false), plus conformance
  `key_material_present?` pre/post-shred assertions across all three adapters.
- Anti-tautology probes: (1) removed the `key_material_present?` clause from
  `erased?/1` → the leaky-shred red path FAILED (erased? wrongly true). (2)
  sabotaged FileBacked `key_material_present?` to always return `false` → the
  conformance pre-shred `== true` assertion FAILED. Both reverted, green.
