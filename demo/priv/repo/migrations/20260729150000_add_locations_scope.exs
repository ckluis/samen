defmodule Demo.Repo.Migrations.AddLocationsScope do
  @moduledoc """
  Mounts the Locations universal scope (F5, T47) into the demo host's one
  Postgres, and catalogs the resource in the SAME migration transaction
  (ADR-004 catalog-in-tx). Mirrors `20260729100000_add_docs_scope.exs`.

    * `dll_location` — Location: `name`, `address` (🔒 vaulted, `vault:
      :pii_address`, ADR-036 H4/c17 composite). No geometry column
      (ADR-037 §5.10). Archivable (ADR-040 §5.9).
  """
  use Samen.Migration

  @resources [
    Demo.LocationsScope.Location
  ]

  def up do
    create table(:dll_location, primary_key: false) do
      add(:dll_name, :text, null: false)
      add(:dll_address, :text)
      add(:dll_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:dll_org_id, :uuid, null: false)
      add(:dll_inserted_at, :utc_datetime, null: false)
      add(:dll_updated_at, :utc_datetime, null: false)
      add(:dll_archived_at, :utc_datetime_usec)
    end

    create(index(:dll_location, [:dll_org_id]))

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)
    drop(table(:dll_location))
  end
end
