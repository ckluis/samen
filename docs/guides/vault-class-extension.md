# Vault-class extension guide — adding a new `pii_*` class

**Audience:** whoever needs a new PII field that doesn't fit an existing vault class —
a vertical adding a `pii_ssn`-grade field (an SSN/national ID/passport number, a new
scalar-shaped secret), or a new PII **composite** shape (an address, a bank account, a
government ID with multiple parts). Read [ADR-036](../adr/ADR-036-rich-types.md) first
(§2 D4/D5, §3 H4/H5, §10) for *why* the vault-class model is shaped this way; this guide
is *how*.

Reference implementation (copy from these):

- `samen_core/lib/samen/type/address.ex` — the newest composite PII type (H4)
- `samen_core/test/support/rich_types_fixture.ex` — `PersonalFixture`'s `pii do` block
  declares `pii_address`/`pii_dob` (this guide's worked example)
- `samen_core/priv/test_repo/migrations/20260721180000_rich_types_address_dob.exs` —
  the additive-column migration pattern (`catalog_sync/2` with `only:`)
- `samen_core/test/type/address_test.exs` — the full test shape (contract + catalog +
  vault-registry probe + garbage-input red/positive-control + `Samen.MaskingCase` 3-proof)
- `samen_core/lib/samen/vault/change.ex` — the vaulted write-path cast gate
  (`cast_declared_types/1`), for the composite-validation decision in §3 below
- `samen_core/test/support/clinical.ex` (`Core.Person`) — the original `pii_dob`
  scalar-reuse example this guide formalizes (H5)

---

## 0 · The one thing to unlearn: **there is no central registry**

A "vault class" (`pii_email`, `pii_dob`, `pii_address`, your new `pii_ssn`, …) is **not**
a row in a table, an enum, or a config list anywhere. It is exactly two declarations
inside a resource's (or shared fragment's) `pii do … end` block:

```elixir
pii do
  vault :pii_ssn
  pii_attribute :ssn, :string, vault: :pii_ssn
end
```

That's it. Every vault-routed field of every class shares ONE physical table
(`Samen.Vault.VaultRow` / `pii_vault`, keyed by `(subject_id, vault_name, field_name)`,
`vault_name` stored as the class-atom string) — so declaring a new class costs **zero**
schema/table changes to the vault itself. Do not go looking for a place to "register"
`pii_ssn` beyond the `vault :pii_ssn` line above; there isn't one. If you skip the
`vault :name` declaration and only add `pii_attribute … vault: :pii_ssn`, compilation
FAILS closed (`Samen.Pii.Verifiers.VaultDeclared` / the `MaterializePii` transformer's
own check) — this is the closed-world guarantee that makes the recipe below safe to
follow without a checklist of "don't forget to also update X."

## 1 · The files a vertical touches — enumerated

For the common case (§2, a new field of a type samen already ships, e.g. `:string`,
`:date`, `Samen.Type.EmailAddress`) there are exactly **two** files:

| # | File | What changes |
|---|---|---|
| 1 | The resource or shared fragment (e.g. `lib/my_app/scopes/hr/blueprint.ex`, or a `Spark.Dsl.Fragment` like `Core.Person`) | Add `vault :pii_ssn` + `pii_attribute :ssn, :string, vault: :pii_ssn` inside its existing (or a new) `pii do … end` block |
| 2 | A new migration for that resource's own table | `alter table(...) do add(:pii_<abbrev>_ssn, :text) end` + `catalog_sync([Resource], only: [:ssn])` |

Nothing else. No vault schema change, no registry file, no verifier config, no
`Samen.Pii.Classification` edit (a `:string`/`:date`/… scalar is not "the type" being
classified here — `pii_attribute` already routes it to the vault regardless of the
type's own classification). If you also want operator-side reveal (a granted
break-glass read of the plaintext), add a THIRD line to the same `pii do` block:
`reveal :some_action`, naming an existing action on the resource — `Samen.Pii.Verifiers.RevealActionExists`
fails compile if the action doesn't exist.

If you're introducing a genuinely NEW **composite shape** (§3) — not just a new scalar
field — add up to three more files (the type module, its tests, and, if the type needs
its own write-boundary validation, a narrow edit to the vault kernel).

## 2 · The `pii_ssn`-grade recipe (scalar reuse — H5, the common case)

Worked example: a vertical needs a national-ID field on `Hr.Employee`.

```elixir
# lib/my_app/scopes/hr/blueprint.ex (or wherever Employee's pii block lives)
pii do
  vault :pii_national_id
  pii_attribute :national_id, :string, vault: :pii_national_id
end
```

```elixir
# priv/repo/migrations/<ts>_employee_national_id.exs
defmodule MyApp.Repo.Migrations.EmployeeNationalId do
  use Samen.Migration

  def change do
    alter table(:emp_employee) do
      add(:pii_emp_national_id, :text)
    end

    catalog_sync([MyApp.Hr.Employee], only: [:national_id])
  end
end
```

That's the whole recipe. What you get for free, by construction, with **zero** extra
code:

- **Validation on write.** `Samen.Vault.Change` re-runs the declared type's
  `Ash.Type.cast_input/2` on every SCALAR `pii_attribute` before it reaches the vault
  (ADR-036 §10, T99) — a garbage value is refused as a normal changeset error, the DB
  stays unchanged. This is automatic for ANY scalar type (`:string`, `:date`,
  `Samen.Type.EmailAddress`, …); you do not opt in.
- **Masking on read.** The materialized column is `Samen.Type.VaultField`
  (`MaterializePii`), so `Ash.read` returns `%Samen.Masked{}` — `••••` by construction,
  with no per-resource read hook.
- **Reveal / crypto-shred / erasure.** All inherited from the shared `Samen.Vault`
  runtime — the class name is just a partition key, not a separate code path.
- **Verifier coverage.** `Samen.NoPlaintextPii.Tiers.VaultDeclarations` (checks the
  physical column is VaultField/text), `pii_reads` (C3), `no_plaintext_pii` (C5) all
  key on the `pii do` DECLARATION via `Samen.Pii.Info`, not a hardcoded class list —
  a new class needs no verifier changes.

Ship a `Samen.MaskingCase` 3-proof test (`use Samen.MaskingCase`; see
`samen_core/lib/samen/masking_case.ex` for the pattern: GREEN tenant-clear, RED
operator-masked, SABOTAGE-twin leak-detection) on whatever surface first renders the
field. A garbage-input probe test is optional busywork for a scalar — it is already
proven generically by `Samen.Vault.CastValidationTest`; add one only if your scalar
type has its own format rule worth a dedicated regression (as `EmailAddress`/
`PhoneNumber`/`URL` do).

## 3 · New COMPOSITE PII shape (harder case — the `Address`/H4 precedent)

Reuse §2 whenever the field is a single scalar. Reach for a new composite `Ash.Type`
only when the PII shape genuinely has multiple parts that must travel together (an
address, `FullName`, a labelled `Emails`/`Phones` list). Composite PII types route by
**vault name**, not the `pii_` column prefix — `<abbrev>_<name>`, e.g. `srp_address`.

### 3.1 · The type module

`samen_core/lib/samen/type/<name>.ex` (or the host app's own `lib/` if it's
vertical-specific, not foundry-shipped — self-classification works the same either way):

```elixir
defmodule MyApp.Type.BankAccount do
  use Ash.Type

  defstruct [:routing_number, :account_number]

  def storage_type(_constraints), do: :map
  def samen_pii_class, do: :pii   # composite PII types self-classify UNCONDITIONALLY

  def cast_input(nil, _), do: {:ok, nil}
  def cast_input(%__MODULE__{} = v, _), do: {:ok, v}
  def cast_input(%{} = map, _), do: build(map)
  def cast_input(_, _), do: :error

  # cast_stored/2, dump_to_native/2 — mirror Samen.Type.FullName/Address exactly.
end
```

`samen_pii_class => :pii` is **always honored, no gate** (`Samen.Pii.Classification`
precedence #1) — unlike a self-classified `:non_pii` type, there is no reviewer
clearance to fight through, and none can accidentally override it later either.

### 3.2 · Decide: does the write path need to validate this composite?

**Default: no extra work needed** — a bare `field.composite?` PII type is stored
byte-for-byte on the vaulted write path with no cast gate (ADR-036 §10). This is safe
and correct for a type with no real format rule to enforce, or for a type that will
compose fine with loosely-shaped legacy writers.

**If your composite has a genuine format rule worth enforcing at write time** (the way
`Address.country` must be a real ISO-3166-1 alpha-2 code) AND it is a **brand-new**
type with no shipped loose-shape writers to break, follow the `Address` precedent: a
narrow, TYPE-SPECIFIC carve-out in `samen_core/lib/samen/vault/change.ex`'s
`cast_declared_types/1`, by module identity — NOT a blanket flip of `field.composite?`
(that requires first auditing and cleaning up every existing writer of every existing
composite type, a cross-cutting task, tracked separately — see the ADR-036 §10
addendum and its T14 follow-up note):

```elixir
field.composite? and field.type not in [Samen.Type.Address, MyApp.Type.BankAccount] ->
  {:cont, {:ok, {[{field, plaintext} | casted], clears}}}

true ->
  case Ash.Type.cast_input(field.type, plaintext) do
    ...
  end
```

This is a kernel-file edit — it is the ONE exception to "two files" in §1's table.
Keep the carve-out to types you are certain have no existing loose writers (grep for
every `pii_attribute :x, YourType` in the codebase first); if any exist and write a
shape your OWN `cast_input` would reject, land that cleanup first or you will break a
shipped write path.

### 3.3 · The `pii do` declaration + migration

Identical to §2, except the physical column carries **no `pii_` prefix** (composite
convention): `pii_attribute :bank_account, MyApp.Type.BankAccount, vault: :pii_bank`
on a resource abbreviated `emp` materializes to column `emp_bank_account`, type `:text`
(still a `vt_*` token column — `MaterializePii` treats composite and scalar PII
identically once materialized, the ONLY difference is the storage name).

### 3.4 · Tests

- Type-contract tests (`use ExUnit.Case`): cast/dump round trip, partial values (every
  field SHOULD be optional unless you have a real reason not to), and — if §3.2 applied
  — the garbage-input REJECT vectors your format rule defines.
- Catalog-dump proof: if useful, a PLAIN (non-vaulted) attribute of the type on a
  fixture resource proves `Samen.Catalog.fields/1` reports the type's own module name
  (mirrors `Samen.Type.AddressTest`'s `OrgFixture.billing_address`) — a composite PII
  type still classifies `:pii` even used plainly, so this is safe, just not a
  sanctioned production pattern.
- Vault-class registry probe: `Samen.Pii.Info.vaults/1` includes your new class name;
  `Samen.Pii.Info.fields/1` shows the field routed to it with the right `composite?`
  flag and storage name.
- If §3.2 applied: the garbage-input vault-write-path RED test + POSITIVE CONTROL,
  permanently homed in (or added alongside) `samen_core/test/vault/vault_cast_validation_test.exs`
  — the pattern `Samen.Type.AddressTest` and this file's `ADDRESS NORMALIZATION PARITY`
  describe block both follow.
- The `Samen.MaskingCase` 3-proof (same as §2).

## 4 · Checklist

- [ ] `vault :name` + `pii_attribute` declared in a `pii do` block (§1/§2/§3.3)
- [ ] Migration adds the new column + `catalog_sync(..., only: [...])` (§1/§2/§3.3)
- [ ] (composite only) type module with `samen_pii_class => :pii` (§3.1)
- [ ] (composite only, format rule + brand-new type) the narrow `cast_declared_types/1`
      carve-out in `vault/change.ex` (§3.2)
- [ ] `Samen.MaskingCase` 3-proof test on the first rendering surface (§2/§3.4)
- [ ] `mix test --warnings-as-errors` green; `./ci-fast.sh` ends `CI-FAST: ALL PASSED`
