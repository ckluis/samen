defmodule Driftwood.Repo.Migrations.AddWorkScope do
  @moduledoc """
  Mounts the Work universal scope (F1, ADR-041 §3, T43) into Driftwood's one
  Postgres, and catalogs every resource in the SAME migration transaction
  (ADR-004 catalog-in-tx). Mirrors `20260708110000_mount_billing_support_scopes.exs`'s
  Support half, with Driftwood's fresh `dw*` abbrevs.

  This is the **destination-creating** migration (T43's side of the ADR-041 §7
  file-touch partition) — zero references to any CRM table.

    * `dwp_project` — a container noun (name/status/owner). No PII.
    * `dwt_task`    — the canonical Task (ADR-041 §3.2, field-for-field). No PII.

  Both tables carry `<abbrev>_archived_at` (ADR-040 §5.9 — archivable true).
  """
  use Samen.Migration

  @resources [
    Driftwood.Work.Project,
    Driftwood.Work.Task
  ]

  def up do
    create table(:dwp_project, primary_key: false) do
      add(:dwp_name, :text, null: false)
      add(:dwp_status, :text, default: "active")
      add(:dwp_owner_id, :uuid)
      add(:dwp_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:dwp_org_id, :uuid, null: false)
      add(:dwp_inserted_at, :utc_datetime, null: false)
      add(:dwp_updated_at, :utc_datetime, null: false)
      add(:dwp_archived_at, :utc_datetime_usec)
    end

    create(index(:dwp_project, [:dwp_org_id]))

    create table(:dwt_task, primary_key: false) do
      add(:dwt_kind, :text, default: "task")
      add(:dwt_title, :text)
      add(:dwt_body, :text)
      add(:dwt_status, :text, default: "pending")
      add(:dwt_priority, :integer, default: 20)
      add(:dwt_due_at, :utc_datetime)
      add(:dwt_completed_at, :utc_datetime)
      add(:dwt_subject_key, :text)
      add(:dwt_subject_id, :uuid)
      add(:dwt_custom, :map, default: fragment("'{}'::jsonb"))
      add(:dwt_owner_id, :uuid)
      add(:dwt_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:dwt_org_id, :uuid, null: false)
      add(:dwt_inserted_at, :utc_datetime, null: false)
      add(:dwt_updated_at, :utc_datetime, null: false)
      add(:dwt_archived_at, :utc_datetime_usec)

      add(
        :dwt_parent_id,
        references(:dwt_task,
          column: :dwt_id,
          name: "dwt_task_dwt_parent_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :dwt_project_id,
        references(:dwp_project,
          column: :dwp_id,
          name: "dwt_task_dwt_project_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )
    end

    create(index(:dwt_task, [:dwt_org_id]))
    create(index(:dwt_task, [:dwt_parent_id]))
    create(index(:dwt_task, [:dwt_project_id]))
    create(index(:dwt_task, [:dwt_subject_key, :dwt_subject_id]))

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(constraint(:dwt_task, "dwt_task_dwt_project_id_fkey"))
    drop(constraint(:dwt_task, "dwt_task_dwt_parent_id_fkey"))
    drop(table(:dwt_task))
    drop(table(:dwp_project))
  end
end
