defmodule Driftwood.Repo.Migrations.AddCalendarScope do
  @moduledoc """
  Mounts the Calendar universal scope (F2, T44) into the driftwood host's one
  Postgres, and catalogs the resource in the SAME migration transaction
  (ADR-004 catalog-in-tx). Mirrors `20260727170000_add_work_scope.exs`.

    * `fce_event` — Event/Meeting: start/end, 🔒 vaulted `attendees`
      (`Samen.Type.Emails`, `vault: :pii_attendees`, no `pii_` prefix), an
      optional `recurrence` rule (jsonb map). Archivable (ADR-040 §5.9).
  """
  use Samen.Migration

  @resources [
    Driftwood.Calendar.Event
  ]

  def up do
    create table(:fce_event, primary_key: false) do
      add(:fce_kind, :text, default: "event")
      add(:fce_title, :text)
      add(:fce_description, :text)
      add(:fce_starts_at, :utc_datetime_usec, null: false)
      add(:fce_ends_at, :utc_datetime_usec)
      add(:fce_location, :text)
      add(:fce_timezone, :text, default: "Etc/UTC")
      add(:fce_recurrence, :map)
      add(:fce_custom, :map)
      add(:fce_owner_id, :uuid)
      add(:fce_attendees, :text)
      add(:fce_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fce_org_id, :uuid, null: false)
      add(:fce_inserted_at, :utc_datetime, null: false)
      add(:fce_updated_at, :utc_datetime, null: false)
      add(:fce_archived_at, :utc_datetime_usec)
    end

    create(index(:fce_event, [:fce_org_id]))
    create(index(:fce_event, [:fce_starts_at]))

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)
    drop(table(:fce_event))
  end
end
