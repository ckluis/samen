defmodule SamenCore.TestRepo.Migrations.CustomFieldsFixture do
  @moduledoc """
  T3.8 test fixture: the `tcf_widget` table (a resource with a Tier-1 `tcf_custom`
  jsonb bag) plus its catalog rows. Runs after the catalog bootstrap and the
  `tnt_field` table exist, so `catalog_sync/1` writes `tam_table`/`fld_field`
  rows in the same transaction (catalog parity holds).
  """
  use Samen.Migration

  @resources [SamenCore.Support.CustomFields.Widget]

  def up do
    create table(:tcf_widget, primary_key: false) do
      add(:tcf_name, :text, null: false)
      add(:tcf_custom, :map)
      add(:tcf_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:tcf_org_id, :uuid, null: false)
      add(:tcf_inserted_at, :utc_datetime, null: false)
      add(:tcf_updated_at, :utc_datetime, null: false)
    end

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)
    drop(table(:tcf_widget))
  end
end
