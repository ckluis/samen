defmodule Driftwood.Repo.Migrations.MountMarketingScope do
  @moduledoc """
  Mounts the Driftwood Marketing scope tables (fresh abbrevs fmc/fmg/fms/fmt/fmn/fme/fmp) and
  catalogs every resource in the SAME migration transaction (ADR-004 catalog-in-tx; ADR-011
  §7). Column shape mirrors the Marketing blueprint. Copied+remapped from demo's Marketing
  mount migration so Driftwood's materialized Marketing tables match the blueprint exactly.

  The `pii_fms_email` column on `fms_subscriber` is the scalar PII column (vault-routed;
  holds a `vt_*` token — plaintext never lands here). FK order: Subscriber → Suppression;
  Subscriber → Send → EmailEvent (Suppression created BEFORE Send so a suppression check has
  its table to query).
  """
  use Samen.Migration

  @resources [
    Driftwood.Marketing.Campaign,
    Driftwood.Marketing.Segment,
    Driftwood.Marketing.Subscriber,
    Driftwood.Marketing.Template,
    Driftwood.Marketing.Send,
    Driftwood.Marketing.EmailEvent,
    Driftwood.Marketing.Suppression
  ]

  def up do
    # --- fmc_campaign : a marketing campaign ---
    create table(:fmc_campaign, primary_key: false) do
      add(:fmc_name, :text, null: false)
      add(:fmc_description, :text)
      add(:fmc_status, :text, default: "draft")
      add(:fmc_scheduled_at, :utc_datetime)
      add(:fmc_sent_at, :utc_datetime)
      add(:fmc_custom, :map, default: fragment("'{}'::jsonb"))
      add(:fmc_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fmc_org_id, :uuid, null: false)
      add(:fmc_inserted_at, :utc_datetime, null: false)
      add(:fmc_updated_at, :utc_datetime, null: false)
    end

    # --- fmg_segment : an audience segment ---
    create table(:fmg_segment, primary_key: false) do
      add(:fmg_name, :text, null: false)
      add(:fmg_description, :text)
      add(:fmg_filter_criteria, :map, default: fragment("'{}'::jsonb"))
      add(:fmg_subscriber_count, :integer, default: 0)
      add(:fmg_custom, :map, default: fragment("'{}'::jsonb"))
      add(:fmg_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fmg_org_id, :uuid, null: false)
      add(:fmg_inserted_at, :utc_datetime, null: false)
      add(:fmg_updated_at, :utc_datetime, null: false)
    end

    # --- fms_subscriber : 🔒 subscriber (email vault-routed) ---
    create table(:fms_subscriber, primary_key: false) do
      add(:fms_status, :text, default: "active")
      add(:fms_consent_at, :utc_datetime)
      add(:fms_source, :text)
      add(:fms_custom, :map, default: fragment("'{}'::jsonb"))
      add(:pii_fms_email, :text)
      add(:fms_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fms_org_id, :uuid, null: false)
      add(:fms_inserted_at, :utc_datetime, null: false)
      add(:fms_updated_at, :utc_datetime, null: false)
    end

    # --- fmt_template : Tier-0 config rows ---
    create table(:fmt_template, primary_key: false) do
      add(:fmt_name, :text, null: false)
      add(:fmt_subject_line, :text, null: false)
      add(:fmt_body_html, :text)
      add(:fmt_body_text, :text)
      add(:fmt_from_name, :text)
      add(:fmt_from_address, :text)
      add(:fmt_enabled, :boolean, default: true)
      add(:fmt_custom, :map, default: fragment("'{}'::jsonb"))
      add(:fmt_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fmt_org_id, :uuid, null: false)
      add(:fmt_inserted_at, :utc_datetime, null: false)
      add(:fmt_updated_at, :utc_datetime, null: false)
    end

    # --- fmp_suppression : consent/suppression list (BEFORE fmn_send) ---
    create table(:fmp_suppression, primary_key: false) do
      add(:fmp_reason, :text, null: false)
      add(:fmp_active, :boolean, default: true)
      add(:fmp_suppressed_at, :utc_datetime)
      add(:fmp_notes, :text)

      add(
        :fmp_subscriber_id,
        references(:fms_subscriber,
          column: :fms_id,
          name: "fmp_suppression_fmp_subscriber_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:fmp_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fmp_org_id, :uuid, null: false)
      add(:fmp_inserted_at, :utc_datetime, null: false)
      add(:fmp_updated_at, :utc_datetime, null: false)
    end

    # --- fmn_send : a single send event ---
    create table(:fmn_send, primary_key: false) do
      add(:fmn_status, :text, default: "queued")
      add(:fmn_queued_at, :utc_datetime)
      add(:fmn_sent_at, :utc_datetime)
      add(:fmn_idempotency_key, :text)
      add(:fmn_custom, :map, default: fragment("'{}'::jsonb"))

      add(
        :fmn_subscriber_id,
        references(:fms_subscriber,
          column: :fms_id,
          name: "fmn_send_fmn_subscriber_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :fmn_campaign_id,
        references(:fmc_campaign,
          column: :fmc_id,
          name: "fmn_send_fmn_campaign_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :fmn_template_id,
        references(:fmt_template,
          column: :fmt_id,
          name: "fmn_send_fmn_template_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:fmn_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fmn_org_id, :uuid, null: false)
      add(:fmn_inserted_at, :utc_datetime, null: false)
      add(:fmn_updated_at, :utc_datetime, null: false)
    end

    # --- fme_email_event : delivery/open/click/bounce events ---
    create table(:fme_email_event, primary_key: false) do
      add(:fme_event_type, :text, null: false)
      add(:fme_occurred_at, :utc_datetime)
      add(:fme_metadata, :map, default: fragment("'{}'::jsonb"))

      add(
        :fme_send_id,
        references(:fmn_send,
          column: :fmn_id,
          name: "fme_email_event_fme_send_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :fme_subscriber_id,
        references(:fms_subscriber,
          column: :fms_id,
          name: "fme_email_event_fme_subscriber_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:fme_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fme_org_id, :uuid, null: false)
      add(:fme_inserted_at, :utc_datetime, null: false)
      add(:fme_updated_at, :utc_datetime, null: false)
    end

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(constraint(:fme_email_event, "fme_email_event_fme_subscriber_id_fkey"))
    drop(constraint(:fme_email_event, "fme_email_event_fme_send_id_fkey"))
    drop(table(:fme_email_event))

    drop(constraint(:fmn_send, "fmn_send_fmn_template_id_fkey"))
    drop(constraint(:fmn_send, "fmn_send_fmn_campaign_id_fkey"))
    drop(constraint(:fmn_send, "fmn_send_fmn_subscriber_id_fkey"))
    drop(table(:fmn_send))

    drop(constraint(:fmp_suppression, "fmp_suppression_fmp_subscriber_id_fkey"))
    drop(table(:fmp_suppression))

    drop(table(:fmt_template))
    drop(table(:fms_subscriber))
    drop(table(:fmg_segment))
    drop(table(:fmc_campaign))
  end
end
