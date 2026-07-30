defmodule Demo.Repo.Migrations.AddCalendarScope do
  @moduledoc """
  Mounts the Calendar universal scope (F2, T44) into the demo host's one
  Postgres, and catalogs the resource in the SAME migration transaction
  (ADR-004 catalog-in-tx). Mirrors `20260727150000_add_work_scope.exs`.

    * `dce_event` — Event/Meeting (`kind` distinguishes): start/end, 🔒
      vaulted `attendees` (`Samen.Type.Emails`, `vault: :pii_attendees`, no
      `pii_` prefix — the composite convention), `location`, an optional
      `recurrence` rule (a plain jsonb map, expanded via
      `Samen.Scopes.Calendar.Recurrence.expand/4,5`). Archivable (ADR-040 §5.9).
  """
  use Samen.Migration

  @resources [
    Demo.CalendarScope.Event
  ]

  def up do
    create table(:dce_event, primary_key: false) do
      add(:dce_kind, :text, default: "event")
      add(:dce_title, :text)
      add(:dce_description, :text)
      add(:dce_starts_at, :utc_datetime_usec, null: false)
      add(:dce_ends_at, :utc_datetime_usec)
      add(:dce_location, :text)
      add(:dce_timezone, :text, default: "Etc/UTC")
      add(:dce_recurrence, :map)
      add(:dce_custom, :map)
      add(:dce_owner_id, :uuid)
      # Composite PII vault token: attendees routes by vault name (no pii_ prefix).
      add(:dce_attendees, :text)
      add(:dce_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:dce_org_id, :uuid, null: false)
      add(:dce_inserted_at, :utc_datetime, null: false)
      add(:dce_updated_at, :utc_datetime, null: false)
      add(:dce_archived_at, :utc_datetime_usec)
    end

    create(index(:dce_event, [:dce_org_id]))
    create(index(:dce_event, [:dce_starts_at]))

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)
    drop(table(:dce_event))
  end
end
