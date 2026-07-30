defmodule SamenCore.TestRepo.Migrations.ActionFixture do
  @moduledoc """
  T40 E2 action-library fixture table (ADR-039 §5): `sat_target`, a second
  trigger source (`test/support/automation_fixture.ex`) alongside T39's
  `asj_subject` — adds `owner_id`/`tags` surfaces the record-mutation family
  needs (`assign_owner`/`add_tag`) that `Subject` doesn't have, plus its own
  🔒 vault-routed `pii_sat_email` (the webhook snapshot assert's negative
  control).
  """
  use Samen.Migration

  @resources [SamenCore.Support.AutomationFixture.Target]

  def up do
    create table(:sat_target, primary_key: false) do
      add(:sat_title, :text, null: false)
      add(:sat_priority, :text, default: "normal")
      add(:sat_owner_id, :uuid)
      add(:sat_tags, {:array, :text}, default: [])
      add(:pii_sat_email, :text)
      add(:sat_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:sat_org_id, :uuid, null: false)
      add(:sat_inserted_at, :utc_datetime, null: false)
      add(:sat_updated_at, :utc_datetime, null: false)
    end

    create(index(:sat_target, [:sat_org_id], name: "sat_target_org_idx"))

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(index(:sat_target, [:sat_org_id], name: "sat_target_org_idx"))
    drop(table(:sat_target))
  end
end
