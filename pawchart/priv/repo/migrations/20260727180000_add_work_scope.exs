defmodule PawChart.Repo.Migrations.AddWorkScope do
  @moduledoc """
  Mounts the Work universal scope (F1, ADR-041 §3, T43) into PawChart's one
  Postgres, and catalogs every resource in the SAME migration transaction
  (ADR-004 catalog-in-tx). Mirrors the demo/driftwood analogs with PawChart's
  fresh `pw*` abbrevs.

  This is the **destination-creating** migration (T43's side of the ADR-041 §7
  file-touch partition) — zero references to any CRM table.

    * `pwp_project` — a container noun (name/status/owner). No PII.
    * `pwt_task`    — the canonical Task (ADR-041 §3.2, field-for-field). No PII.

  Both tables carry `<abbrev>_archived_at` (ADR-040 §5.9 — archivable true).
  """
  use Samen.Migration

  @resources [
    PawChart.Work.Project,
    PawChart.Work.Task
  ]

  def up do
    create table(:pwp_project, primary_key: false) do
      add(:pwp_name, :text, null: false)
      add(:pwp_status, :text, default: "active")
      add(:pwp_owner_id, :uuid)
      add(:pwp_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:pwp_org_id, :uuid, null: false)
      add(:pwp_inserted_at, :utc_datetime, null: false)
      add(:pwp_updated_at, :utc_datetime, null: false)
      add(:pwp_archived_at, :utc_datetime_usec)
    end

    create(index(:pwp_project, [:pwp_org_id]))

    create table(:pwt_task, primary_key: false) do
      add(:pwt_kind, :text, default: "task")
      add(:pwt_title, :text)
      add(:pwt_body, :text)
      add(:pwt_status, :text, default: "pending")
      add(:pwt_priority, :integer, default: 20)
      add(:pwt_due_at, :utc_datetime)
      add(:pwt_completed_at, :utc_datetime)
      add(:pwt_subject_key, :text)
      add(:pwt_subject_id, :uuid)
      add(:pwt_custom, :map, default: fragment("'{}'::jsonb"))
      add(:pwt_owner_id, :uuid)
      add(:pwt_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:pwt_org_id, :uuid, null: false)
      add(:pwt_inserted_at, :utc_datetime, null: false)
      add(:pwt_updated_at, :utc_datetime, null: false)
      add(:pwt_archived_at, :utc_datetime_usec)

      add(
        :pwt_parent_id,
        references(:pwt_task,
          column: :pwt_id,
          name: "pwt_task_pwt_parent_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :pwt_project_id,
        references(:pwp_project,
          column: :pwp_id,
          name: "pwt_task_pwt_project_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )
    end

    create(index(:pwt_task, [:pwt_org_id]))
    create(index(:pwt_task, [:pwt_parent_id]))
    create(index(:pwt_task, [:pwt_project_id]))
    create(index(:pwt_task, [:pwt_subject_key, :pwt_subject_id]))

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(constraint(:pwt_task, "pwt_task_pwt_project_id_fkey"))
    drop(constraint(:pwt_task, "pwt_task_pwt_parent_id_fkey"))
    drop(table(:pwt_task))
    drop(table(:pwp_project))
  end
end
