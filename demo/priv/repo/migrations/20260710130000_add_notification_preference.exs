defmodule Demo.Repo.Migrations.AddNotificationPreference do
  @moduledoc """
  WS-A A4 (design §5; ADR-016 §4): materialize the Primitives scope's
  `NotificationPreference` table for the demo host — `npr_notification_preference`
  (abbrev `npr`, registry row `Demo.PrimitivesScope.NotificationPreference`).

  The `Samen.Scopes.Primitives` blueprint now mounts `NotificationPreference`
  (the engine's per-recipient dispatch gate: a suppressed event type writes NO
  `Notification` record). NO PII by construction — every column is a bounded id,
  enum, boolean, or a map of bounded ints (`quiet_hours`), so there is no vault
  route and nothing for `pii_classify` to flag.

  `catalog_sync/1` catalogues the columns into `tam_table`/`fld_field` so
  `catalog_parity` stays green (the ghost-table drift this migration closes).
  """
  use Samen.Migration

  @resources [Demo.PrimitivesScope.NotificationPreference]

  def up do
    create table(:npr_notification_preference, primary_key: false) do
      add(:npr_recipient_id, :uuid, null: false)
      add(:npr_event_type, :text, null: false)
      add(:npr_in_app_enabled, :boolean, default: true)
      add(:npr_email_enabled, :boolean, default: false)
      add(:npr_quiet_hours, :map, default: fragment("'{}'::jsonb"))

      add(:npr_id, :uuid,
        null: false,
        default: fragment("gen_random_uuid()"),
        primary_key: true
      )

      add(:npr_org_id, :uuid, null: false)
      add(:npr_inserted_at, :utc_datetime, null: false)
      add(:npr_updated_at, :utc_datetime, null: false)
    end

    create(
      index(:npr_notification_preference, [:npr_recipient_id, :npr_event_type, :npr_org_id],
        name: "npr_notification_preference_recipient_event_org_idx",
        unique: true
      )
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(
      index(:npr_notification_preference, [:npr_recipient_id, :npr_event_type, :npr_org_id],
        name: "npr_notification_preference_recipient_event_org_idx"
      )
    )

    drop(table(:npr_notification_preference))
  end
end
