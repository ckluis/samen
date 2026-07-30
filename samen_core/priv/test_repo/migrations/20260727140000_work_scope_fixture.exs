defmodule SamenCore.TestRepo.Migrations.WorkScopeFixture do
  @moduledoc """
  Tables for the Work scope (F1, ADR-041 §3, T43): `spw_project` + `stw_task`, mounted
  in `samen_core` tests via `test/support/work_fixture.ex`.

  `stw_task` is self-referential (`stw_parent_id → stw_task.stw_id`, the Subtask tree,
  cycle-refused at the Ash change level — ADR-041 §3.4) and links to `spw_project`
  (`stw_project_id`). Both tables carry `<abbrev>_archived_at` (ADR-040 §5.9 — Project
  and Task are both `archivable: true`).

  `stw_priority` stores `Samen.Type.Priority`'s integer RANK (`low=10, normal=20,
  high=30, urgent=40`), not the atom — the type's storage_type is `:integer`
  (ADR-036 D2).

  Catalog rows are written by `catalog_sync/1` in the SAME transaction (ADR-004).
  """
  use Samen.Migration

  @resources [
    SamenCore.Support.WorkFixture.Project,
    SamenCore.Support.WorkFixture.Task
  ]

  def up do
    create table(:spw_project, primary_key: false) do
      add(:spw_name, :text, null: false)
      add(:spw_status, :text, default: "active")
      add(:spw_owner_id, :uuid)
      add(:spw_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:spw_org_id, :uuid, null: false)
      add(:spw_inserted_at, :utc_datetime, null: false)
      add(:spw_updated_at, :utc_datetime, null: false)
      add(:spw_archived_at, :utc_datetime_usec)
    end

    create(index(:spw_project, [:spw_org_id]))

    create table(:stw_task, primary_key: false) do
      add(:stw_kind, :text, default: "task")
      add(:stw_title, :text)
      add(:stw_body, :text)
      add(:stw_status, :text, default: "pending")
      add(:stw_priority, :integer, default: 20)
      add(:stw_due_at, :utc_datetime)
      add(:stw_completed_at, :utc_datetime)
      add(:stw_subject_key, :text)
      add(:stw_subject_id, :uuid)
      add(:stw_custom, :map)
      add(:stw_owner_id, :uuid)
      add(:stw_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:stw_org_id, :uuid, null: false)
      add(:stw_inserted_at, :utc_datetime, null: false)
      add(:stw_updated_at, :utc_datetime, null: false)
      add(:stw_archived_at, :utc_datetime_usec)

      add(
        :stw_parent_id,
        references(:stw_task, column: :stw_id, name: "stw_task_stw_parent_id_fkey", type: :uuid)
      )

      add(
        :stw_project_id,
        references(:spw_project,
          column: :spw_id,
          name: "stw_task_stw_project_id_fkey",
          type: :uuid
        )
      )
    end

    create(index(:stw_task, [:stw_org_id]))
    create(index(:stw_task, [:stw_parent_id]))
    create(index(:stw_task, [:stw_project_id]))
    create(index(:stw_task, [:stw_subject_key, :stw_subject_id]))

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)
    drop(table(:stw_task))
    drop(table(:spw_project))
  end
end
