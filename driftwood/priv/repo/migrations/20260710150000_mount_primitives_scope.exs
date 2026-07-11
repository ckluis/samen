defmodule Driftwood.Repo.Migrations.MountPrimitivesScope do
  @moduledoc """
  WS-A A5 (inheritance proof) — mounts the Primitives scope tables for Driftwood
  (`Driftwood.Primitives`, abbrevs `fnt/fnp/ffl/fsh/fwh/fff`) and catalogs them in
  the SAME migration transaction (ADR-004 catalog-in-tx). Mirrors demo's
  `add_primitives_scope` + `add_notification_preference` and the samen_web test
  host's `mount_primitives_scope`.

  Load-bearing tables for the inherited notifications inbox:

    * `fnt_notification` — 🔒 PII: rendered_body (vault token; `pii_fnt_rendered_body`)
    * `fnp_notification_preference` — per-recipient dispatch preference (NO PII)

  The remaining four (`ffl_file`, `fsh_search_index`, `fwh_webhook`,
  `fff_feature_flag`) mirror the Primitives blueprint so the mount compiles +
  catalogs cleanly.
  """
  use Samen.Migration

  @resources [
    Driftwood.Primitives.Notification,
    Driftwood.Primitives.NotificationPreference,
    Driftwood.Primitives.File,
    Driftwood.Primitives.SearchIndex,
    Driftwood.Primitives.Webhook,
    Driftwood.Primitives.FeatureFlag
  ]

  def up do
    # --- fnt_notification : 🔒 PII: rendered_body ---
    create table(:fnt_notification, primary_key: false) do
      add(:fnt_recipient_id, :uuid, null: false)
      add(:fnt_channel, :text, default: "in_app")
      add(:fnt_event_type, :text, null: false)
      add(:fnt_status, :text, default: "pending")
      add(:fnt_sent_at, :utc_datetime)
      add(:fnt_read_at, :utc_datetime)
      add(:fnt_metadata, :map, default: fragment("'{}'::jsonb"))
      add(:pii_fnt_rendered_body, :text)
      add(:fnt_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fnt_org_id, :uuid, null: false)
      add(:fnt_inserted_at, :utc_datetime, null: false)
      add(:fnt_updated_at, :utc_datetime, null: false)
    end

    create(
      index(:fnt_notification, [:fnt_recipient_id, :fnt_org_id],
        name: "fnt_notification_recipient_org_idx"
      )
    )

    create(
      index(:fnt_notification, [:fnt_status, :fnt_org_id],
        name: "fnt_notification_status_org_idx"
      )
    )

    # --- fnp_notification_preference : per-recipient dispatch prefs (no PII) ---
    create table(:fnp_notification_preference, primary_key: false) do
      add(:fnp_recipient_id, :uuid, null: false)
      add(:fnp_event_type, :text, null: false)
      add(:fnp_in_app_enabled, :boolean, default: true)
      add(:fnp_email_enabled, :boolean, default: false)
      add(:fnp_quiet_hours, :map, default: fragment("'{}'::jsonb"))
      add(:fnp_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fnp_org_id, :uuid, null: false)
      add(:fnp_inserted_at, :utc_datetime, null: false)
      add(:fnp_updated_at, :utc_datetime, null: false)
    end

    create(
      index(:fnp_notification_preference, [:fnp_recipient_id, :fnp_event_type, :fnp_org_id],
        name: "fnp_notification_preference_recipient_event_org_idx",
        unique: true
      )
    )

    # --- ffl_file ---
    create table(:ffl_file, primary_key: false) do
      add(:ffl_filename, :text, null: false)
      add(:ffl_content_type, :text)
      add(:ffl_size_bytes, :integer)
      add(:ffl_storage_key, :text, null: false)
      add(:ffl_status, :text, default: "active")
      add(:ffl_uploaded_by_id, :uuid)
      add(:ffl_metadata, :map, default: fragment("'{}'::jsonb"))
      add(:ffl_search_vector, :text)
      add(:ffl_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:ffl_org_id, :uuid, null: false)
      add(:ffl_inserted_at, :utc_datetime, null: false)
      add(:ffl_updated_at, :utc_datetime, null: false)
    end

    # --- fsh_search_index ---
    create table(:fsh_search_index, primary_key: false) do
      add(:fsh_resource_name, :text, null: false)
      add(:fsh_field_name, :text, null: false)
      add(:fsh_vector_column, :text, null: false)
      add(:fsh_description, :text)
      add(:fsh_enabled, :boolean, default: true)
      add(:fsh_ts_config, :text, default: "english")
      add(:fsh_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fsh_org_id, :uuid, null: false)
      add(:fsh_inserted_at, :utc_datetime, null: false)
      add(:fsh_updated_at, :utc_datetime, null: false)
    end

    # --- fwh_webhook : 🔒 PII: signing_secret ---
    create table(:fwh_webhook, primary_key: false) do
      add(:fwh_url, :text, null: false)
      add(:fwh_label, :text)
      add(:fwh_event_types, {:array, :text}, default: [])
      add(:fwh_status, :text, default: "active")
      add(:fwh_failure_count, :integer, default: 0)
      add(:fwh_last_delivered_at, :utc_datetime)
      add(:fwh_metadata, :map, default: fragment("'{}'::jsonb"))
      add(:pii_fwh_signing_secret, :text)
      add(:fwh_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fwh_org_id, :uuid, null: false)
      add(:fwh_inserted_at, :utc_datetime, null: false)
      add(:fwh_updated_at, :utc_datetime, null: false)
    end

    # --- fff_feature_flag ---
    create table(:fff_feature_flag, primary_key: false) do
      add(:fff_name, :text, null: false)
      add(:fff_description, :text)
      add(:fff_enabled, :boolean, default: false)
      add(:fff_rollout_pct, :integer, default: 100)
      add(:fff_stage, :text, default: "beta")
      add(:fff_metadata, :map, default: fragment("'{}'::jsonb"))
      add(:fff_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fff_org_id, :uuid, null: false)
      add(:fff_inserted_at, :utc_datetime, null: false)
      add(:fff_updated_at, :utc_datetime, null: false)
    end

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(table(:fff_feature_flag))
    drop(table(:fwh_webhook))
    drop(table(:fsh_search_index))
    drop(table(:ffl_file))

    drop(
      index(:fnp_notification_preference, [:fnp_recipient_id, :fnp_event_type, :fnp_org_id],
        name: "fnp_notification_preference_recipient_event_org_idx"
      )
    )

    drop(table(:fnp_notification_preference))

    drop(
      index(:fnt_notification, [:fnt_status, :fnt_org_id],
        name: "fnt_notification_status_org_idx"
      )
    )

    drop(
      index(:fnt_notification, [:fnt_recipient_id, :fnt_org_id],
        name: "fnt_notification_recipient_org_idx"
      )
    )

    drop(table(:fnt_notification))
  end
end
