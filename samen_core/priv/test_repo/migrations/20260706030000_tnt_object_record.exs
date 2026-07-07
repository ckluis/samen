defmodule SamenCore.TestRepo.Migrations.TntObjectRecord do
  @moduledoc """
  Bootstrap the Tier-2 tables (T3.9):

    * `tnt_object` — the org-scoped custom-object catalog (plain DDL, like
      `tnt_field`).
    * `tnt_record` — the physical backing table for the `Samen.CustomObjects.Record`
      Ash resource (abbrev-prefixed `tnr_*`, org-scoped, validated-at-write). Its
      catalog rows are written by `catalog_sync/1` in the same transaction so
      catalog parity holds.

  No FK from any system table into either table (the one-way boundary); the record
  references OUT to system rows as opaque IDs in `tnr_refs`, never as a Postgres
  FK. Runs after the catalog bootstrap and `tnt_field` exist.
  """
  use Samen.Migration

  @resources [Samen.CustomObjects.Record]

  def up do
    create_tnt_object_table()
    create_tnt_record_table()
    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)
    drop(table(:tnt_record))
    drop(table(:tnt_object))
  end
end
