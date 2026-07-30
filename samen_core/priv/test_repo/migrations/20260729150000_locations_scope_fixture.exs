defmodule SamenCore.TestRepo.Migrations.LocationsScopeFixture do
  @moduledoc """
  Table for the Locations scope (F5, T47): `sll_location`, mounted in
  `samen_core` tests via `test/support/locations_fixture.ex`.

  `sll_address` is the vaulted composite column (composite routing convention:
  abbrev prefix, no `pii_` prefix — mirrors `srp_address` from T14's
  `rich_types_address_dob` migration), a `Samen.Type.VaultField` `:text` column
  holding an opaque `vt_*` token, never plaintext.

  Catalog rows are written by `catalog_sync/1` in the SAME transaction (ADR-004).
  """
  use Samen.Migration

  @resources [
    SamenCore.Support.LocationsFixture.Location
  ]

  def up do
    create table(:sll_location, primary_key: false) do
      add(:sll_name, :text, null: false)
      add(:sll_address, :text)
      add(:sll_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:sll_org_id, :uuid, null: false)
      add(:sll_inserted_at, :utc_datetime, null: false)
      add(:sll_updated_at, :utc_datetime, null: false)
      add(:sll_archived_at, :utc_datetime_usec)
    end

    create(index(:sll_location, [:sll_org_id]))

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)
    drop(table(:sll_location))
  end
end
