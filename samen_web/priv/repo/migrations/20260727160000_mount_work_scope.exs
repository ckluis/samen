defmodule Samen.WebTest.Repo.Migrations.MountWorkScope do
  @moduledoc """
  Mounts the Work universal scope (F1, ADR-041 §3, T43) into the samen_web test
  host's one Postgres, and catalogs every resource in the SAME migration
  transaction (ADR-004 catalog-in-tx). Mirrors
  `20260708130000_mount_billing_support_scopes.exs`.

  Fresh `ww*` abbrevs (the global registry already owns the scope-default `wpj`/
  `wtk` via demo — see `Samen.WebTest.Work` moduledoc).

    * `wwp_project` — a container noun (name/status/owner). No PII.
    * `wwt_task`    — the canonical Task (ADR-041 §3.2). No PII.

  Both tables carry `<abbrev>_archived_at` (ADR-040 §5.9 — archivable true).
  """
  use Samen.Migration

  @resources [
    Samen.WebTest.Work.Project,
    Samen.WebTest.Work.Task
  ]

  def up do
    create table(:wwp_project, primary_key: false) do
      add(:wwp_name, :text, null: false)
      add(:wwp_status, :text, default: "active")
      add(:wwp_owner_id, :uuid)
      add(:wwp_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wwp_org_id, :uuid, null: false)
      add(:wwp_inserted_at, :utc_datetime, null: false)
      add(:wwp_updated_at, :utc_datetime, null: false)
      add(:wwp_archived_at, :utc_datetime_usec)
    end

    create(index(:wwp_project, [:wwp_org_id]))

    create table(:wwt_task, primary_key: false) do
      add(:wwt_kind, :text, default: "task")
      add(:wwt_title, :text)
      add(:wwt_body, :text)
      add(:wwt_status, :text, default: "pending")
      add(:wwt_priority, :integer, default: 20)
      add(:wwt_due_at, :utc_datetime)
      add(:wwt_completed_at, :utc_datetime)
      add(:wwt_subject_key, :text)
      add(:wwt_subject_id, :uuid)
      add(:wwt_custom, :map, default: fragment("'{}'::jsonb"))
      add(:wwt_owner_id, :uuid)
      add(:wwt_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wwt_org_id, :uuid, null: false)
      add(:wwt_inserted_at, :utc_datetime, null: false)
      add(:wwt_updated_at, :utc_datetime, null: false)
      add(:wwt_archived_at, :utc_datetime_usec)

      add(
        :wwt_parent_id,
        references(:wwt_task,
          column: :wwt_id,
          name: "wwt_task_wwt_parent_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :wwt_project_id,
        references(:wwp_project,
          column: :wwp_id,
          name: "wwt_task_wwt_project_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )
    end

    create(index(:wwt_task, [:wwt_org_id]))
    create(index(:wwt_task, [:wwt_parent_id]))
    create(index(:wwt_task, [:wwt_project_id]))
    create(index(:wwt_task, [:wwt_subject_key, :wwt_subject_id]))

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(constraint(:wwt_task, "wwt_task_wwt_project_id_fkey"))
    drop(constraint(:wwt_task, "wwt_task_wwt_parent_id_fkey"))
    drop(table(:wwt_task))
    drop(table(:wwp_project))
  end
end
