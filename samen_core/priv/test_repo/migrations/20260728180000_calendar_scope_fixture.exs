defmodule SamenCore.TestRepo.Migrations.CalendarScopeFixture do
  @moduledoc """
  Table for the Calendar scope (F2, T44): `sce_event`, mounted in `samen_core`
  tests via `test/support/calendar_fixture.ex`.

  `sce_attendees` is the vaulted composite (`Samen.Type.Emails`, `vault:
  :pii_attendees`) — NO `pii_` prefix (composite convention, ADR-036 D4,
  identical to Support's `sag_full_name`). `sce_recurrence` is a plain jsonb
  map (`Samen.Scopes.Calendar.Recurrence.rule()` shape once cast) — non-PII.

  Catalog rows are written by `catalog_sync/1` in the SAME transaction (ADR-004).
  """
  use Samen.Migration

  @resources [
    SamenCore.Support.CalendarFixture.Event
  ]

  def up do
    create table(:sce_event, primary_key: false) do
      add(:sce_kind, :text, default: "event")
      add(:sce_title, :text)
      add(:sce_description, :text)
      add(:sce_starts_at, :utc_datetime_usec, null: false)
      add(:sce_ends_at, :utc_datetime_usec)
      add(:sce_location, :text)
      add(:sce_timezone, :text, default: "Etc/UTC")
      add(:sce_recurrence, :map)
      add(:sce_custom, :map)
      add(:sce_owner_id, :uuid)
      # Composite PII vault token: attendees routes by vault name (no pii_ prefix).
      add(:sce_attendees, :text)
      add(:sce_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:sce_org_id, :uuid, null: false)
      add(:sce_inserted_at, :utc_datetime, null: false)
      add(:sce_updated_at, :utc_datetime, null: false)
      add(:sce_archived_at, :utc_datetime_usec)
    end

    create(index(:sce_event, [:sce_org_id]))
    create(index(:sce_event, [:sce_starts_at]))

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)
    drop(table(:sce_event))
  end
end
