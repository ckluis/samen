defmodule Demo.Repo.Migrations.AddWorkScope do
  @moduledoc """
  Mounts the Work universal scope (F1, ADR-041 §3, T43) into the demo host's one
  Postgres, and catalogs every resource in the SAME migration transaction
  (ADR-004 catalog-in-tx). Mirrors `20260706050000_add_support_scope.exs`.

  This is the **destination-creating** migration (T43's side of the ADR-041 §7
  file-touch partition) — it creates `wpj_project` + `wtk_task` ahead of any future
  data migration. **T43 touches NO CRM code**; this migration has zero references
  to `act_activity` or any CRM table.

    * `wpj_project` — a container noun (name/status/owner). No PII.
    * `wtk_task`    — the canonical Task (ADR-041 §3.2, field-for-field): kind,
      title, body, status (plain enum), priority (`Samen.Type.Priority`, stored as
      an integer RANK — low=10/normal=20/high=30/urgent=40), due_at, completed_at,
      the generic `(subject_key, subject_id)` object-ref anchor, custom, owner_id,
      self-referential parent_id (the Subtask tree, cycle-refused at the Ash change
      level), project_id. No PII.

  Both tables carry `<abbrev>_archived_at` (ADR-040 §5.9 — archivable true).
  """
  use Samen.Migration

  @resources [
    Demo.WorkScope.Project,
    Demo.WorkScope.Task
  ]

  def up do
    create table(:wpj_project, primary_key: false) do
      add(:wpj_name, :text, null: false)
      add(:wpj_status, :text, default: "active")
      add(:wpj_owner_id, :uuid)
      add(:wpj_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wpj_org_id, :uuid, null: false)
      add(:wpj_inserted_at, :utc_datetime, null: false)
      add(:wpj_updated_at, :utc_datetime, null: false)
      add(:wpj_archived_at, :utc_datetime_usec)
    end

    create(index(:wpj_project, [:wpj_org_id]))

    create table(:wtk_task, primary_key: false) do
      add(:wtk_kind, :text, default: "task")
      add(:wtk_title, :text)
      add(:wtk_body, :text)
      add(:wtk_status, :text, default: "pending")
      add(:wtk_priority, :integer, default: 20)
      add(:wtk_due_at, :utc_datetime)
      add(:wtk_completed_at, :utc_datetime)
      add(:wtk_subject_key, :text)
      add(:wtk_subject_id, :uuid)
      add(:wtk_custom, :map, default: fragment("'{}'::jsonb"))
      add(:wtk_owner_id, :uuid)
      add(:wtk_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wtk_org_id, :uuid, null: false)
      add(:wtk_inserted_at, :utc_datetime, null: false)
      add(:wtk_updated_at, :utc_datetime, null: false)
      add(:wtk_archived_at, :utc_datetime_usec)

      add(
        :wtk_parent_id,
        references(:wtk_task,
          column: :wtk_id,
          name: "wtk_task_wtk_parent_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :wtk_project_id,
        references(:wpj_project,
          column: :wpj_id,
          name: "wtk_task_wtk_project_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )
    end

    create(index(:wtk_task, [:wtk_org_id]))
    create(index(:wtk_task, [:wtk_parent_id]))
    create(index(:wtk_task, [:wtk_project_id]))
    create(index(:wtk_task, [:wtk_subject_key, :wtk_subject_id]))

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(constraint(:wtk_task, "wtk_task_wtk_project_id_fkey"))
    drop(constraint(:wtk_task, "wtk_task_wtk_parent_id_fkey"))
    drop(table(:wtk_task))
    drop(table(:wpj_project))
  end
end
