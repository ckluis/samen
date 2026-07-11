defmodule SamenCore.TestRepo.Migrations.NotificationFixture do
  @moduledoc """
  WS-A A4 UNIT 1 fixture tables: the Primitives scope mounted under `ne*` abbrevs so
  the `Samen.Notifications.Engine` can be exercised against a real Postgres DB in
  `samen_core` (`test/support/notification_fixture.ex`).

  Load-bearing tables:

    * `nen_notification` — 🔒 PII: rendered_body (vault token; `pii_nen_rendered_body`)
    * `nep_notification_preference` — per-recipient dispatch preference (NO PII;
      bounded id + enums + bools + a map of bounded ints)

  The remaining four (`nef_file`, `nes_search_index`, `nwh_webhook`, `ngf_feature_flag`)
  mirror the Primitives blueprint so the mount compiles/catalogs cleanly; only the
  first two are used by the engine tests.

  The `pii_nen_rendered_body` column is allow-listed in `config/test.exs`
  (`:vault_declared_parity_allow_list`) because this fixture domain is not in
  `:ash_domains`.
  """
  use Samen.Migration

  @resources [
    SamenCore.Support.NotificationFixture.Notification,
    SamenCore.Support.NotificationFixture.NotificationPreference,
    SamenCore.Support.NotificationFixture.File,
    SamenCore.Support.NotificationFixture.SearchIndex,
    SamenCore.Support.NotificationFixture.Webhook,
    SamenCore.Support.NotificationFixture.FeatureFlag
  ]

  def up do
    # --- nen_notification : 🔒 PII: rendered_body ---
    create table(:nen_notification, primary_key: false) do
      add(:nen_recipient_id, :uuid, null: false)
      add(:nen_channel, :text, default: "in_app")
      add(:nen_event_type, :text, null: false)
      add(:nen_status, :text, default: "pending")
      add(:nen_sent_at, :utc_datetime)
      add(:nen_read_at, :utc_datetime)
      add(:nen_metadata, :map, default: fragment("'{}'::jsonb"))
      add(:pii_nen_rendered_body, :text)
      add(:nen_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:nen_org_id, :uuid, null: false)
      add(:nen_inserted_at, :utc_datetime, null: false)
      add(:nen_updated_at, :utc_datetime, null: false)
    end

    create(
      index(:nen_notification, [:nen_recipient_id, :nen_org_id],
        name: "nen_notification_recipient_org_idx"
      )
    )

    # --- nep_notification_preference : per-recipient dispatch prefs (no PII) ---
    create table(:nep_notification_preference, primary_key: false) do
      add(:nep_recipient_id, :uuid, null: false)
      add(:nep_event_type, :text, null: false)
      add(:nep_in_app_enabled, :boolean, default: true)
      add(:nep_email_enabled, :boolean, default: false)
      add(:nep_quiet_hours, :map, default: fragment("'{}'::jsonb"))
      add(:nep_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:nep_org_id, :uuid, null: false)
      add(:nep_inserted_at, :utc_datetime, null: false)
      add(:nep_updated_at, :utc_datetime, null: false)
    end

    create(
      index(:nep_notification_preference, [:nep_recipient_id, :nep_event_type, :nep_org_id],
        name: "nep_notification_preference_recipient_event_org_idx",
        unique: true
      )
    )

    # --- nef_file ---
    create table(:nef_file, primary_key: false) do
      add(:nef_filename, :text, null: false)
      add(:nef_content_type, :text)
      add(:nef_size_bytes, :integer)
      add(:nef_storage_key, :text, null: false)
      add(:nef_status, :text, default: "active")
      add(:nef_uploaded_by_id, :uuid)
      add(:nef_metadata, :map, default: fragment("'{}'::jsonb"))
      add(:nef_search_vector, :text)
      add(:nef_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:nef_org_id, :uuid, null: false)
      add(:nef_inserted_at, :utc_datetime, null: false)
      add(:nef_updated_at, :utc_datetime, null: false)
    end

    # --- nes_search_index ---
    create table(:nes_search_index, primary_key: false) do
      add(:nes_resource_name, :text, null: false)
      add(:nes_field_name, :text, null: false)
      add(:nes_vector_column, :text, null: false)
      add(:nes_description, :text)
      add(:nes_enabled, :boolean, default: true)
      add(:nes_ts_config, :text, default: "english")
      add(:nes_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:nes_org_id, :uuid, null: false)
      add(:nes_inserted_at, :utc_datetime, null: false)
      add(:nes_updated_at, :utc_datetime, null: false)
    end

    # --- nwh_webhook : 🔒 PII: signing_secret ---
    create table(:nwh_webhook, primary_key: false) do
      add(:nwh_url, :text, null: false)
      add(:nwh_label, :text)
      add(:nwh_event_types, {:array, :text}, default: [])
      add(:nwh_status, :text, default: "active")
      add(:nwh_failure_count, :integer, default: 0)
      add(:nwh_last_delivered_at, :utc_datetime)
      add(:nwh_metadata, :map, default: fragment("'{}'::jsonb"))
      add(:pii_nwh_signing_secret, :text)
      add(:nwh_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:nwh_org_id, :uuid, null: false)
      add(:nwh_inserted_at, :utc_datetime, null: false)
      add(:nwh_updated_at, :utc_datetime, null: false)
    end

    # --- ngf_feature_flag ---
    create table(:ngf_feature_flag, primary_key: false) do
      add(:ngf_name, :text, null: false)
      add(:ngf_description, :text)
      add(:ngf_enabled, :boolean, default: false)
      add(:ngf_rollout_pct, :integer, default: 100)
      add(:ngf_stage, :text, default: "beta")
      add(:ngf_metadata, :map, default: fragment("'{}'::jsonb"))
      add(:ngf_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:ngf_org_id, :uuid, null: false)
      add(:ngf_inserted_at, :utc_datetime, null: false)
      add(:ngf_updated_at, :utc_datetime, null: false)
    end

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(table(:ngf_feature_flag))
    drop(table(:nwh_webhook))
    drop(table(:nes_search_index))
    drop(table(:nef_file))

    drop(
      index(:nep_notification_preference, [:nep_recipient_id, :nep_event_type, :nep_org_id],
        name: "nep_notification_preference_recipient_event_org_idx"
      )
    )

    drop(table(:nep_notification_preference))

    drop(
      index(:nen_notification, [:nen_recipient_id, :nen_org_id],
        name: "nen_notification_recipient_org_idx"
      )
    )

    drop(table(:nen_notification))
  end
end
