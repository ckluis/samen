defmodule Driftwood.Repo.Migrations.AddLocationsScope do
  @moduledoc """
  Mounts the Locations universal scope (F5, T47) into Driftwood's Postgres,
  and catalogs the resource in the SAME migration transaction (ADR-004
  catalog-in-tx). Mirrors `20260729100000_add_docs_scope.exs`.

    * `fll_location` — Location: `name`, `address` (🔒 vaulted, `vault:
      :pii_address`, ADR-036 H4/c17 composite). No geometry column
      (ADR-037 §5.10). Archivable (ADR-040 §5.9). `fll` is the
      collision-corrected abbrev — see `Driftwood.Locations` moduledoc for the
      incident record.
  """
  use Samen.Migration

  @resources [
    Driftwood.Locations.Location
  ]

  def up do
    create table(:fll_location, primary_key: false) do
      add(:fll_name, :text, null: false)
      add(:fll_address, :text)
      add(:fll_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fll_org_id, :uuid, null: false)
      add(:fll_inserted_at, :utc_datetime, null: false)
      add(:fll_updated_at, :utc_datetime, null: false)
      add(:fll_archived_at, :utc_datetime_usec)
    end

    create(index(:fll_location, [:fll_org_id]))

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)
    drop(table(:fll_location))
  end
end
