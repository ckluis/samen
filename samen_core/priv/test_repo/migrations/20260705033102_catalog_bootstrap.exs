defmodule SamenCore.TestRepo.Migrations.CatalogBootstrap do
  @moduledoc """
  Bootstrap migration for the Samen machine catalog (T1.2).

  Creates the `tam_table` and `fld_field` catalog tables and seeds catalog rows
  for all existing Samen resources (those created by the prior initial_core
  migration). Because this migration runs in a DDL transaction (the default),
  both the catalog table creation and the row inserts are atomic.

  ## Bootstrap note (spike F5)

  The catalog tables are plain Ecto DDL — NOT Ash resources — to avoid the
  chicken-and-egg where you need the catalog to write catalog rows for itself.
  This is the documented bootstrap exception: document it here, not a workaround.
  """

  use Samen.Migration

  @resources [
    SamenCore.Support.Crm.Contact,
    SamenCore.Support.Crm.Company,
    SamenCore.Support.Clinical.Patient,
    SamenCore.Support.Clinical.Staff,
    SamenCore.Support.PropFixture
  ]

  def up do
    create_catalog_tables()
    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)
    drop(table(:fld_field))
    drop(table(:tam_table))
  end
end
