defmodule SamenCore.TestRepo.Migrations.RichTypesAddressDob do
  @moduledoc """
  T14 (ADR-036 H4/H5): extends the T13 rich-types fixture (`srp_personal_fixture` /
  `sro_org_fixture`) with the new `pii_address`/`pii_dob` vault classes and the
  `Samen.Type.Address` catalog-dump proof.

    * `srp_personal_fixture` gains `srp_address` — a VAULTED `Samen.Type.Address`
      `pii_attribute` (composite routing convention: abbrev prefix, NO `pii_`
      prefix) — and `pii_srp_dob` — a VAULTED scalar `:date` `pii_attribute` (the
      `pii_` prefix convention). Both materialize to `Samen.Type.VaultField`
      (`:text`, holding an opaque `vt_*` token — Gate-0 vault-stack shape), same as
      the T13 `pii_srp_email`/`pii_srp_phone`/`pii_srp_profile_url` columns.
    * `sro_org_fixture` gains `sro_billing_address` — a PLAIN (non-vaulted) `:map`
      column of `Samen.Type.Address`, the catalog-dump proof (mirrors
      `sro_support_email`/`sro_support_phone`/`sro_website`).

  Per ADR-036 D4/D5 there is no central vault-class registry/table to touch —
  `pii_address`/`pii_dob` are zero-migration DECLARATIONS (`vault :name` +
  `pii_attribute`); this migration is entirely about the fixture RESOURCE'S own
  columns, exactly like the T13 migration it extends.

  Additive columns on ALREADY-catalogued resources → `catalog_sync/2`'s `only:`
  scoping (spike note F2), one call per resource/column-set, so `down` removes
  exactly these new `fld_field` rows without touching the T13 columns' rows —
  `change/0` so both the DDL (`alter … add`, Ecto auto-reverses to `remove`) and
  the catalog `execute/2` reversible pairing flip on `down` for free.
  """
  use Samen.Migration

  def change do
    alter table(:srp_personal_fixture) do
      add(:srp_address, :text)
      add(:pii_srp_dob, :text)
    end

    alter table(:sro_org_fixture) do
      add(:sro_billing_address, :map)
    end

    catalog_sync([SamenCore.Support.RichTypes.PersonalFixture], only: [:address, :dob])
    catalog_sync([SamenCore.Support.RichTypes.OrgFixture], only: [:billing_address])
  end
end
