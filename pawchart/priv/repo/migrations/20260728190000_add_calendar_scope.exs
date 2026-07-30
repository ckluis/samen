defmodule PawChart.Repo.Migrations.AddCalendarScope do
  @moduledoc """
  Mounts the Calendar universal scope (F2, T44) into the pawchart host's one
  Postgres, and catalogs the resource in the SAME migration transaction
  (ADR-004 catalog-in-tx). Mirrors `20260727180000_add_work_scope.exs`.

    * `pce_event` — Event/Meeting: start/end, 🔒 vaulted `attendees`
      (`Samen.Type.Emails`, `vault: :pii_attendees`, no `pii_` prefix), an
      optional `recurrence` rule (jsonb map). Archivable (ADR-040 §5.9).
  """
  use Samen.Migration

  @resources [
    PawChart.Calendar.Event
  ]

  def up do
    create table(:pce_event, primary_key: false) do
      add(:pce_kind, :text, default: "event")
      add(:pce_title, :text)
      add(:pce_description, :text)
      add(:pce_starts_at, :utc_datetime_usec, null: false)
      add(:pce_ends_at, :utc_datetime_usec)
      add(:pce_location, :text)
      add(:pce_timezone, :text, default: "Etc/UTC")
      add(:pce_recurrence, :map)
      add(:pce_custom, :map)
      add(:pce_owner_id, :uuid)
      add(:pce_attendees, :text)
      add(:pce_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:pce_org_id, :uuid, null: false)
      add(:pce_inserted_at, :utc_datetime, null: false)
      add(:pce_updated_at, :utc_datetime, null: false)
      add(:pce_archived_at, :utc_datetime_usec)
    end

    create(index(:pce_event, [:pce_org_id]))
    create(index(:pce_event, [:pce_starts_at]))

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)
    drop(table(:pce_event))
  end
end
