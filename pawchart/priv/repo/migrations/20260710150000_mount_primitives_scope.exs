defmodule PawChart.Repo.Migrations.MountPrimitivesScope do
  @moduledoc """
  WS-A A5 (inheritance proof) — mounts the Primitives scope tables for PawChart
  (`PawChart.Primitives`, abbrevs `vnt/vnp/vfl/vsh/vwh/vff`) and catalogs them in
  the SAME migration transaction (ADR-004 catalog-in-tx). Mirrors demo's
  `add_primitives_scope` + `add_notification_preference` and the samen_web test
  host's `mount_primitives_scope`.

  Load-bearing tables for the inherited notifications inbox:

    * `vnt_notification` — 🔒 PII: rendered_body (vault token; `pii_vnt_rendered_body`)
    * `vnp_notification_preference` — per-recipient dispatch preference (NO PII)

  The remaining four (`vfl_file`, `vsh_search_index`, `vwh_webhook`,
  `vff_feature_flag`) mirror the Primitives blueprint so the mount compiles +
  catalogs cleanly.
  """
  use Samen.Migration

  @resources [
    PawChart.Primitives.Notification,
    PawChart.Primitives.NotificationPreference,
    PawChart.Primitives.File,
    PawChart.Primitives.SearchIndex,
    PawChart.Primitives.Webhook,
    PawChart.Primitives.FeatureFlag
  ]

  def up do
    # --- vnt_notification : 🔒 PII: rendered_body ---
    create table(:vnt_notification, primary_key: false) do
      add(:vnt_recipient_id, :uuid, null: false)
      add(:vnt_channel, :text, default: "in_app")
      add(:vnt_event_type, :text, null: false)
      add(:vnt_status, :text, default: "pending")
      add(:vnt_sent_at, :utc_datetime)
      add(:vnt_read_at, :utc_datetime)
      add(:vnt_metadata, :map, default: fragment("'{}'::jsonb"))
      add(:pii_vnt_rendered_body, :text)
      add(:vnt_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:vnt_org_id, :uuid, null: false)
      add(:vnt_inserted_at, :utc_datetime, null: false)
      add(:vnt_updated_at, :utc_datetime, null: false)
    end

    create(
      index(:vnt_notification, [:vnt_recipient_id, :vnt_org_id],
        name: "vnt_notification_recipient_org_idx"
      )
    )

    create(
      index(:vnt_notification, [:vnt_status, :vnt_org_id],
        name: "vnt_notification_status_org_idx"
      )
    )

    # --- vnp_notification_preference : per-recipient dispatch prefs (no PII) ---
    create table(:vnp_notification_preference, primary_key: false) do
      add(:vnp_recipient_id, :uuid, null: false)
      add(:vnp_event_type, :text, null: false)
      add(:vnp_in_app_enabled, :boolean, default: true)
      add(:vnp_email_enabled, :boolean, default: false)
      add(:vnp_quiet_hours, :map, default: fragment("'{}'::jsonb"))
      add(:vnp_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:vnp_org_id, :uuid, null: false)
      add(:vnp_inserted_at, :utc_datetime, null: false)
      add(:vnp_updated_at, :utc_datetime, null: false)
    end

    create(
      index(:vnp_notification_preference, [:vnp_recipient_id, :vnp_event_type, :vnp_org_id],
        name: "vnp_notification_preference_recipient_event_org_idx",
        unique: true
      )
    )

    # --- vfl_file ---
    create table(:vfl_file, primary_key: false) do
      add(:vfl_filename, :text, null: false)
      add(:vfl_content_type, :text)
      add(:vfl_size_bytes, :integer)
      add(:vfl_storage_key, :text, null: false)
      add(:vfl_status, :text, default: "active")
      add(:vfl_uploaded_by_id, :uuid)
      add(:vfl_metadata, :map, default: fragment("'{}'::jsonb"))
      add(:vfl_search_vector, :text)
      add(:vfl_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:vfl_org_id, :uuid, null: false)
      add(:vfl_inserted_at, :utc_datetime, null: false)
      add(:vfl_updated_at, :utc_datetime, null: false)
    end

    # --- vsh_search_index ---
    create table(:vsh_search_index, primary_key: false) do
      add(:vsh_resource_name, :text, null: false)
      add(:vsh_field_name, :text, null: false)
      add(:vsh_vector_column, :text, null: false)
      add(:vsh_description, :text)
      add(:vsh_enabled, :boolean, default: true)
      add(:vsh_ts_config, :text, default: "english")
      add(:vsh_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:vsh_org_id, :uuid, null: false)
      add(:vsh_inserted_at, :utc_datetime, null: false)
      add(:vsh_updated_at, :utc_datetime, null: false)
    end

    # --- vwh_webhook : 🔒 PII: signing_secret ---
    create table(:vwh_webhook, primary_key: false) do
      add(:vwh_url, :text, null: false)
      add(:vwh_label, :text)
      add(:vwh_event_types, {:array, :text}, default: [])
      add(:vwh_status, :text, default: "active")
      add(:vwh_failure_count, :integer, default: 0)
      add(:vwh_last_delivered_at, :utc_datetime)
      add(:vwh_metadata, :map, default: fragment("'{}'::jsonb"))
      add(:pii_vwh_signing_secret, :text)
      add(:vwh_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:vwh_org_id, :uuid, null: false)
      add(:vwh_inserted_at, :utc_datetime, null: false)
      add(:vwh_updated_at, :utc_datetime, null: false)
    end

    # --- vff_feature_flag ---
    create table(:vff_feature_flag, primary_key: false) do
      add(:vff_name, :text, null: false)
      add(:vff_description, :text)
      add(:vff_enabled, :boolean, default: false)
      add(:vff_rollout_pct, :integer, default: 100)
      add(:vff_stage, :text, default: "beta")
      add(:vff_metadata, :map, default: fragment("'{}'::jsonb"))
      add(:vff_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:vff_org_id, :uuid, null: false)
      add(:vff_inserted_at, :utc_datetime, null: false)
      add(:vff_updated_at, :utc_datetime, null: false)
    end

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(table(:vff_feature_flag))
    drop(table(:vwh_webhook))
    drop(table(:vsh_search_index))
    drop(table(:vfl_file))

    drop(
      index(:vnp_notification_preference, [:vnp_recipient_id, :vnp_event_type, :vnp_org_id],
        name: "vnp_notification_preference_recipient_event_org_idx"
      )
    )

    drop(table(:vnp_notification_preference))

    drop(
      index(:vnt_notification, [:vnt_status, :vnt_org_id],
        name: "vnt_notification_status_org_idx"
      )
    )

    drop(
      index(:vnt_notification, [:vnt_recipient_id, :vnt_org_id],
        name: "vnt_notification_recipient_org_idx"
      )
    )

    drop(table(:vnt_notification))
  end
end
