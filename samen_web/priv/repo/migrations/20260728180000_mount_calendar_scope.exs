defmodule Samen.WebTest.Repo.Migrations.MountCalendarScope do
  @moduledoc """
  Mounts the Calendar universal scope (F2, T44) into the samen_web test host's
  one Postgres, and catalogs the resource in the SAME migration transaction
  (ADR-004 catalog-in-tx). Mirrors `20260727160000_mount_work_scope.exs`.

  Fresh `wce` abbrev.

    * `wce_event` — Event/Meeting: start/end, 🔒 vaulted `attendees`
      (`Samen.Type.Emails`, `vault: :pii_attendees`, no `pii_` prefix — the
      composite convention), location, an optional recurrence rule (a plain
      jsonb map). Archivable (ADR-040 §5.9).
  """
  use Samen.Migration

  @resources [
    Samen.WebTest.Calendar.Event
  ]

  def up do
    create table(:wce_event, primary_key: false) do
      add(:wce_kind, :text, default: "event")
      add(:wce_title, :text)
      add(:wce_description, :text)
      add(:wce_starts_at, :utc_datetime_usec, null: false)
      add(:wce_ends_at, :utc_datetime_usec)
      add(:wce_location, :text)
      add(:wce_timezone, :text, default: "Etc/UTC")
      add(:wce_recurrence, :map)
      add(:wce_custom, :map)
      add(:wce_owner_id, :uuid)
      # Composite PII vault token: attendees routes by vault name (no pii_ prefix).
      add(:wce_attendees, :text)
      add(:wce_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wce_org_id, :uuid, null: false)
      add(:wce_inserted_at, :utc_datetime, null: false)
      add(:wce_updated_at, :utc_datetime, null: false)
      add(:wce_archived_at, :utc_datetime_usec)
    end

    create(index(:wce_event, [:wce_org_id]))
    create(index(:wce_event, [:wce_starts_at]))

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)
    drop(table(:wce_event))
  end
end
