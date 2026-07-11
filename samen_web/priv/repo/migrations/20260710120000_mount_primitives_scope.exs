defmodule Samen.WebTest.Repo.Migrations.MountPrimitivesScope do
  @moduledoc """
  WS-A A4 UNIT 2 — mounts the Primitives scope tables for the samen_web test host
  (`Samen.WebTest.Primitives`, abbrevs `wn*`), and catalogs them in the SAME migration
  transaction (ADR-004 catalog-in-tx). Mirrors demo's `add_primitives_scope` and the
  samen_core `notification_fixture` migration.

  Load-bearing tables for the notifications inbox:

    * `wnn_notification` — 🔒 PII: rendered_body (vault token; `pii_wnn_rendered_body`)
    * `wnp_notification_preference` — per-recipient dispatch preference (NO PII)

  The remaining four (`wnf_file`, `wns_search_index`, `wnw_webhook`, `wng_feature_flag`)
  mirror the Primitives blueprint so the mount compiles/catalogs cleanly.
  """
  use Samen.Migration

  @resources [
    Samen.WebTest.Primitives.Notification,
    Samen.WebTest.Primitives.NotificationPreference,
    Samen.WebTest.Primitives.File,
    Samen.WebTest.Primitives.SearchIndex,
    Samen.WebTest.Primitives.Webhook,
    Samen.WebTest.Primitives.FeatureFlag
  ]

  def up do
    # --- wnn_notification : 🔒 PII: rendered_body ---
    create table(:wnn_notification, primary_key: false) do
      add(:wnn_recipient_id, :uuid, null: false)
      add(:wnn_channel, :text, default: "in_app")
      add(:wnn_event_type, :text, null: false)
      add(:wnn_status, :text, default: "pending")
      add(:wnn_sent_at, :utc_datetime)
      add(:wnn_read_at, :utc_datetime)
      add(:wnn_metadata, :map, default: fragment("'{}'::jsonb"))
      add(:pii_wnn_rendered_body, :text)
      add(:wnn_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wnn_org_id, :uuid, null: false)
      add(:wnn_inserted_at, :utc_datetime, null: false)
      add(:wnn_updated_at, :utc_datetime, null: false)
    end

    create(
      index(:wnn_notification, [:wnn_recipient_id, :wnn_org_id],
        name: "wnn_notification_recipient_org_idx"
      )
    )

    create(
      index(:wnn_notification, [:wnn_status, :wnn_org_id],
        name: "wnn_notification_status_org_idx"
      )
    )

    # --- wnp_notification_preference : per-recipient dispatch prefs (no PII) ---
    create table(:wnp_notification_preference, primary_key: false) do
      add(:wnp_recipient_id, :uuid, null: false)
      add(:wnp_event_type, :text, null: false)
      add(:wnp_in_app_enabled, :boolean, default: true)
      add(:wnp_email_enabled, :boolean, default: false)
      add(:wnp_quiet_hours, :map, default: fragment("'{}'::jsonb"))
      add(:wnp_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wnp_org_id, :uuid, null: false)
      add(:wnp_inserted_at, :utc_datetime, null: false)
      add(:wnp_updated_at, :utc_datetime, null: false)
    end

    create(
      index(:wnp_notification_preference, [:wnp_recipient_id, :wnp_event_type, :wnp_org_id],
        name: "wnp_notification_preference_recipient_event_org_idx",
        unique: true
      )
    )

    # --- wnf_file ---
    create table(:wnf_file, primary_key: false) do
      add(:wnf_filename, :text, null: false)
      add(:wnf_content_type, :text)
      add(:wnf_size_bytes, :integer)
      add(:wnf_storage_key, :text, null: false)
      add(:wnf_status, :text, default: "active")
      add(:wnf_uploaded_by_id, :uuid)
      add(:wnf_metadata, :map, default: fragment("'{}'::jsonb"))
      add(:wnf_search_vector, :text)
      add(:wnf_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wnf_org_id, :uuid, null: false)
      add(:wnf_inserted_at, :utc_datetime, null: false)
      add(:wnf_updated_at, :utc_datetime, null: false)
    end

    # --- wns_search_index ---
    create table(:wns_search_index, primary_key: false) do
      add(:wns_resource_name, :text, null: false)
      add(:wns_field_name, :text, null: false)
      add(:wns_vector_column, :text, null: false)
      add(:wns_description, :text)
      add(:wns_enabled, :boolean, default: true)
      add(:wns_ts_config, :text, default: "english")
      add(:wns_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wns_org_id, :uuid, null: false)
      add(:wns_inserted_at, :utc_datetime, null: false)
      add(:wns_updated_at, :utc_datetime, null: false)
    end

    # --- wnw_webhook : 🔒 PII: signing_secret ---
    create table(:wnw_webhook, primary_key: false) do
      add(:wnw_url, :text, null: false)
      add(:wnw_label, :text)
      add(:wnw_event_types, {:array, :text}, default: [])
      add(:wnw_status, :text, default: "active")
      add(:wnw_failure_count, :integer, default: 0)
      add(:wnw_last_delivered_at, :utc_datetime)
      add(:wnw_metadata, :map, default: fragment("'{}'::jsonb"))
      add(:pii_wnw_signing_secret, :text)
      add(:wnw_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wnw_org_id, :uuid, null: false)
      add(:wnw_inserted_at, :utc_datetime, null: false)
      add(:wnw_updated_at, :utc_datetime, null: false)
    end

    # --- wng_feature_flag ---
    create table(:wng_feature_flag, primary_key: false) do
      add(:wng_name, :text, null: false)
      add(:wng_description, :text)
      add(:wng_enabled, :boolean, default: false)
      add(:wng_rollout_pct, :integer, default: 100)
      add(:wng_stage, :text, default: "beta")
      add(:wng_metadata, :map, default: fragment("'{}'::jsonb"))
      add(:wng_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wng_org_id, :uuid, null: false)
      add(:wng_inserted_at, :utc_datetime, null: false)
      add(:wng_updated_at, :utc_datetime, null: false)
    end

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(table(:wng_feature_flag))
    drop(table(:wnw_webhook))
    drop(table(:wns_search_index))
    drop(table(:wnf_file))

    drop(
      index(:wnp_notification_preference, [:wnp_recipient_id, :wnp_event_type, :wnp_org_id],
        name: "wnp_notification_preference_recipient_event_org_idx"
      )
    )

    drop(table(:wnp_notification_preference))

    drop(
      index(:wnn_notification, [:wnn_status, :wnn_org_id],
        name: "wnn_notification_status_org_idx"
      )
    )

    drop(
      index(:wnn_notification, [:wnn_recipient_id, :wnn_org_id],
        name: "wnn_notification_recipient_org_idx"
      )
    )

    drop(table(:wnn_notification))
  end
end
