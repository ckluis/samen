defmodule PawChart.Repo.Migrations.CatalogTables do
  @moduledoc """
  Bootstraps the catalog tables (`tam_table` / `fld_field`) BEFORE any migration
  that calls `catalog_sync/1` (aud_event, driftwood_resources). In demo these are
  created inside the T1.9 CRM-dogfood migration; Driftwood has no such dogfood, so it
  creates them in a dedicated bootstrap migration that runs first.
  """
  use Samen.Migration

  def up do
    create_catalog_tables()
  end

  def down do
    drop(table(:fld_field))
    drop(table(:tam_table))
  end
end
