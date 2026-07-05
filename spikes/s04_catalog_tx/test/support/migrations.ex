defmodule S04CatalogTx.Migrations.Bootstrap do
  @moduledoc """
  Migration 1: create the catalog storage tables (`tam_table`/`fld_field`) and the
  base `com_contact` table with its two original columns. No `com_phone` yet —
  that column is added by a later migration together with its catalog row, which
  is the atomicity under test.
  """
  use Samen.Migration

  def up do
    create_catalog_tables()

    create table(:com_contact, primary_key: false) do
      add(:com_id, :uuid, primary_key: true, null: false, default: fragment("gen_random_uuid()"))
      add(:com_name, :text)
      add(:com_org_id, :uuid, null: false)
    end

    # Seed the catalog for the columns that exist at bootstrap. We pass an
    # explicit column list because the resource module already declares :phone
    # (the test adds that column in a later migration); the bootstrap catalog must
    # reflect only what the bootstrap DDL created.
    Samen.Migrations.Helpers.seed_bootstrap_catalog()
  end

  def down do
    Samen.Migrations.Helpers.unseed_bootstrap_catalog()
    drop(table(:com_contact))
    drop(table(:fld_field))
    drop(table(:tam_table))
  end
end

defmodule S04CatalogTx.Migrations.AddPhone do
  @moduledoc """
  Migration 2 — the ATOMIC case under test.

  Adds `com_phone` to `com_contact` AND writes the `fld_field` catalog row for it,
  both inside the same migration transaction (Ecto wraps `change/0`). Reversible:
  rollback drops the column and removes the catalog row.
  """
  use Samen.Migration

  def change do
    alter table(:com_contact) do
      add(:com_phone, :text)
    end

    # Same transaction as the ALTER above: write the catalog row for exactly the
    # column this migration adds (:phone), sourced from Ash.Resource.Info so the
    # stored row carries the abbrev-prefixed name com_phone. Scoped with `only:`
    # so the reversible `down` removes exactly this column's catalog row.
    catalog_sync([S04CatalogTx.Crm.Contact], only: [:phone])
  end
end

defmodule S04CatalogTx.Migrations.AddPhoneCrashAfterDDL do
  @moduledoc """
  RED PATH migration. Adds the `com_phone` column, then raises BEFORE the catalog
  insert — simulating a crash between the DDL and the catalog write.

  Because DDL + would-be catalog write share the migration transaction, the raise
  must abort the transaction and leave NEITHER the column NOR the catalog row.
  If the column survives (or a partial catalog row is written), the atomicity
  guarantee is broken and the test fails — proving the guarantee is real, not
  asserted.
  """
  use Samen.Migration

  def up do
    alter table(:com_contact) do
      add(:com_phone, :text)
    end

    # Force the schema statements to flush, then crash before the catalog insert.
    flush()
    raise "injected crash between DDL and catalog insert"

    # Never reached:
    catalog_sync([S04CatalogTx.Crm.Contact], only: [:phone])
  end

  def down do
    # Provided for completeness; never runs because up/0 aborts.
    alter table(:com_contact) do
      remove(:com_phone)
    end
  end
end
