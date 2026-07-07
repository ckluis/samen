defmodule Demo.Repo.Migrations.AddPrimitivesScope do
  @moduledoc """
  Mounts the Primitives scope tables into the Demo host's one Postgres, and catalogs
  them in the SAME migration transaction (ADR-004 §"Migrations": the
  catalog-in-tx guarantee requires DDL + catalog_sync in one transaction in the
  host's repo).

  T3.7 — the Primitives scope (doc §"The inherited 80%" scope table:
  `notification🔒 · file · search · audit · webhook🔒 · feature_flag`):

    * `pnt_notification` — 🔒 PII: rendered_body (scalar, vault :pii_body; pii_ prefix)
    * `pfl_file`         — file metadata record (no PII; tsvector search_vector column)
    * `psh_search_index` — tokenized index convention registry (no PII)
    * `pwh_webhook`      — 🔒 PII: signing_secret (scalar, vault :pii_secret; pii_ prefix)
    * `pff_feature_flag` — Tier-0 config rows (no PII)

  Audit rides the existing `aud_event` tier — no new audit table.

  ## PII columns

  - `pnt_notification.pii_pnt_rendered_body` — scalar vault token (`pii_` prefix)
  - `pwh_webhook.pii_pwh_signing_secret`      — scalar vault token (`pii_` prefix)

  ## FK order

  No FK dependencies between Primitives tables. Each table is independent.
  """
  use Samen.Migration

  @resources [
    Demo.PrimitivesScope.Notification,
    Demo.PrimitivesScope.File,
    Demo.PrimitivesScope.SearchIndex,
    Demo.PrimitivesScope.Webhook,
    Demo.PrimitivesScope.FeatureFlag
  ]

  def up do
    # --- pnt_notification : 🔒 PII: rendered_body ---
    create table(:pnt_notification, primary_key: false) do
      # Opaque UUID reference to the recipient. NOT PII.
      add(:pnt_recipient_id, :uuid, null: false)
      add(:pnt_channel, :text, default: "in_app")
      # A namespaced event type. Bounded label.
      add(:pnt_event_type, :text, null: false)
      add(:pnt_status, :text, default: "pending")
      add(:pnt_sent_at, :utc_datetime)
      add(:pnt_read_at, :utc_datetime)
      add(:pnt_metadata, :map, default: fragment("'{}'::jsonb"))
      # Scalar PII vault token: rendered_body carries the pii_ prefix.
      add(:pii_pnt_rendered_body, :text)
      add(:pnt_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:pnt_org_id, :uuid, null: false)
      add(:pnt_inserted_at, :utc_datetime, null: false)
      add(:pnt_updated_at, :utc_datetime, null: false)
    end

    # Index for recipient-based lookup (non-PII column).
    create(
      index(:pnt_notification, [:pnt_recipient_id, :pnt_org_id],
        name: "pnt_notification_recipient_org_idx"
      )
    )

    # Index for status-based lookup (e.g. unread notifications).
    create(
      index(:pnt_notification, [:pnt_status, :pnt_org_id],
        name: "pnt_notification_status_org_idx"
      )
    )

    # --- pfl_file : file metadata record (no PII) ---
    create table(:pfl_file, primary_key: false) do
      # Human-readable filename — not PII in this base resource.
      add(:pfl_filename, :text, null: false)
      add(:pfl_content_type, :text)
      add(:pfl_size_bytes, :integer)
      # Opaque storage backend key. NOT PII (not subject identity data).
      add(:pfl_storage_key, :text, null: false)
      add(:pfl_status, :text, default: "active")
      # Opaque reference to the uploading actor.
      add(:pfl_uploaded_by_id, :uuid)
      add(:pfl_metadata, :map, default: fragment("'{}'::jsonb"))
      # Tsvector search index column (populated by host convention — non-PII fields only).
      # Type :text so Ecto/Ash can read it back; the actual tsvector computation is
      # DB-side (trigger or function). Per T3.7 spec: search = tokenized index over
      # non-PII catalogued fields.
      add(:pfl_search_vector, :text)
      add(:pfl_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:pfl_org_id, :uuid, null: false)
      add(:pfl_inserted_at, :utc_datetime, null: false)
      add(:pfl_updated_at, :utc_datetime, null: false)
    end

    # Full-text search index on the tsvector column (when populated).
    # Using GIN index — the standard for tsvector search.
    # Note: the vector is stored as text in this migration; the host may alter to
    # tsvector native type in a subsequent expand migration.
    create(
      index(:pfl_file, [:pfl_status, :pfl_org_id],
        name: "pfl_file_status_org_idx"
      )
    )

    # --- psh_search_index : tokenized index convention registry ---
    create table(:psh_search_index, primary_key: false) do
      add(:psh_resource_name, :text, null: false)
      add(:psh_field_name, :text, null: false)
      add(:psh_vector_column, :text, null: false)
      add(:psh_description, :text)
      add(:psh_enabled, :boolean, default: true)
      add(:psh_ts_config, :text, default: "english")
      add(:psh_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:psh_org_id, :uuid, null: false)
      add(:psh_inserted_at, :utc_datetime, null: false)
      add(:psh_updated_at, :utc_datetime, null: false)
    end

    # Unique index: one entry per (resource, field, org).
    create(
      index(:psh_search_index, [:psh_resource_name, :psh_field_name, :psh_org_id],
        name: "psh_search_index_unique_idx",
        unique: true
      )
    )

    # --- pwh_webhook : 🔒 PII: signing_secret; Tier-0 config rows ---
    create table(:pwh_webhook, primary_key: false) do
      add(:pwh_url, :text, null: false)
      add(:pwh_label, :text)
      add(:pwh_event_types, {:array, :text}, default: [])
      add(:pwh_status, :text, default: "active")
      add(:pwh_failure_count, :integer, default: 0)
      add(:pwh_last_delivered_at, :utc_datetime)
      add(:pwh_metadata, :map, default: fragment("'{}'::jsonb"))
      # Scalar PII vault token: signing_secret carries the pii_ prefix.
      add(:pii_pwh_signing_secret, :text)
      add(:pwh_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:pwh_org_id, :uuid, null: false)
      add(:pwh_inserted_at, :utc_datetime, null: false)
      add(:pwh_updated_at, :utc_datetime, null: false)
    end

    # Index for delivery status checks.
    create(
      index(:pwh_webhook, [:pwh_status, :pwh_org_id],
        name: "pwh_webhook_status_org_idx"
      )
    )

    # --- pff_feature_flag : Tier-0 config rows (no PII) ---
    create table(:pff_feature_flag, primary_key: false) do
      add(:pff_name, :text, null: false)
      add(:pff_description, :text)
      add(:pff_enabled, :boolean, default: false)
      add(:pff_rollout_pct, :integer, default: 100)
      add(:pff_stage, :text, default: "beta")
      add(:pff_metadata, :map, default: fragment("'{}'::jsonb"))
      add(:pff_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:pff_org_id, :uuid, null: false)
      add(:pff_inserted_at, :utc_datetime, null: false)
      add(:pff_updated_at, :utc_datetime, null: false)
    end

    # Unique flag name per org.
    create(
      index(:pff_feature_flag, [:pff_name, :pff_org_id],
        name: "pff_feature_flag_name_org_idx",
        unique: true
      )
    )

    # --- catalog all five Primitives resources in THIS transaction ---
    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    # Drop in reverse order (no FK dependencies between Primitives tables).
    drop(index(:pff_feature_flag, [:pff_name, :pff_org_id], name: "pff_feature_flag_name_org_idx"))
    drop(table(:pff_feature_flag))

    drop(index(:pwh_webhook, [:pwh_status, :pwh_org_id], name: "pwh_webhook_status_org_idx"))
    drop(table(:pwh_webhook))

    drop(
      index(:psh_search_index, [:psh_resource_name, :psh_field_name, :psh_org_id],
        name: "psh_search_index_unique_idx"
      )
    )

    drop(table(:psh_search_index))

    drop(index(:pfl_file, [:pfl_status, :pfl_org_id], name: "pfl_file_status_org_idx"))
    drop(table(:pfl_file))

    drop(
      index(:pnt_notification, [:pnt_status, :pnt_org_id], name: "pnt_notification_status_org_idx")
    )

    drop(
      index(:pnt_notification, [:pnt_recipient_id, :pnt_org_id],
        name: "pnt_notification_recipient_org_idx"
      )
    )

    drop(table(:pnt_notification))
  end
end
