defmodule Samen.WebTest.Repo.Migrations.MountMarketingScope do
  @moduledoc """
  Mounts the samen_web test-support Marketing scope (fresh abbrevs wmc/wmg/wms/wmt/wmn/wme/wmp)
  and catalogs every resource in the SAME transaction (ADR-004 catalog-in-tx; ADR-011 §7).
  Column shape mirrors the Marketing blueprint. Copied+remapped from demo's Marketing mount
  migration so the test host's materialized Marketing tables match the blueprint exactly.

  The `pii_wms_email` column on `wms_subscriber` is the scalar PII column (vault-routed;
  carries a `vt_*` token — plaintext never lands here). FK order: Subscriber → Suppression;
  Subscriber → Send → EmailEvent (Suppression created BEFORE Send so a suppression check has
  its table).
  """
  use Samen.Migration

  @resources [
    Samen.WebTest.Marketing.Campaign,
    Samen.WebTest.Marketing.Segment,
    Samen.WebTest.Marketing.Subscriber,
    Samen.WebTest.Marketing.Template,
    Samen.WebTest.Marketing.Send,
    Samen.WebTest.Marketing.EmailEvent,
    Samen.WebTest.Marketing.Suppression
  ]

  def up do
    # --- wmc_campaign : a marketing campaign ---
    create table(:wmc_campaign, primary_key: false) do
      add(:wmc_name, :text, null: false)
      add(:wmc_description, :text)
      add(:wmc_status, :text, default: "draft")
      add(:wmc_scheduled_at, :utc_datetime)
      add(:wmc_sent_at, :utc_datetime)
      add(:wmc_custom, :map, default: fragment("'{}'::jsonb"))
      add(:wmc_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wmc_org_id, :uuid, null: false)
      add(:wmc_inserted_at, :utc_datetime, null: false)
      add(:wmc_updated_at, :utc_datetime, null: false)
    end

    # --- wmg_segment : an audience segment ---
    create table(:wmg_segment, primary_key: false) do
      add(:wmg_name, :text, null: false)
      add(:wmg_description, :text)
      add(:wmg_filter_criteria, :map, default: fragment("'{}'::jsonb"))
      add(:wmg_subscriber_count, :integer, default: 0)
      add(:wmg_custom, :map, default: fragment("'{}'::jsonb"))
      add(:wmg_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wmg_org_id, :uuid, null: false)
      add(:wmg_inserted_at, :utc_datetime, null: false)
      add(:wmg_updated_at, :utc_datetime, null: false)
    end

    # --- wms_subscriber : 🔒 subscriber (email vault-routed) ---
    create table(:wms_subscriber, primary_key: false) do
      add(:wms_status, :text, default: "active")
      add(:wms_consent_at, :utc_datetime)
      add(:wms_source, :text)
      add(:wms_custom, :map, default: fragment("'{}'::jsonb"))
      add(:pii_wms_email, :text)
      add(:wms_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wms_org_id, :uuid, null: false)
      add(:wms_inserted_at, :utc_datetime, null: false)
      add(:wms_updated_at, :utc_datetime, null: false)
    end

    # --- wmt_template : Tier-0 config rows ---
    create table(:wmt_template, primary_key: false) do
      add(:wmt_name, :text, null: false)
      add(:wmt_subject_line, :text, null: false)
      add(:wmt_body_html, :text)
      add(:wmt_body_text, :text)
      add(:wmt_from_name, :text)
      add(:wmt_from_address, :text)
      add(:wmt_enabled, :boolean, default: true)
      add(:wmt_custom, :map, default: fragment("'{}'::jsonb"))
      add(:wmt_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wmt_org_id, :uuid, null: false)
      add(:wmt_inserted_at, :utc_datetime, null: false)
      add(:wmt_updated_at, :utc_datetime, null: false)
    end

    # --- wmp_suppression : consent/suppression list (BEFORE wmn_send) ---
    create table(:wmp_suppression, primary_key: false) do
      add(:wmp_reason, :text, null: false)
      add(:wmp_active, :boolean, default: true)
      add(:wmp_suppressed_at, :utc_datetime)
      add(:wmp_notes, :text)

      add(
        :wmp_subscriber_id,
        references(:wms_subscriber,
          column: :wms_id,
          name: "wmp_suppression_wmp_subscriber_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:wmp_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wmp_org_id, :uuid, null: false)
      add(:wmp_inserted_at, :utc_datetime, null: false)
      add(:wmp_updated_at, :utc_datetime, null: false)
    end

    # --- wmn_send : a single send event ---
    create table(:wmn_send, primary_key: false) do
      add(:wmn_status, :text, default: "queued")
      add(:wmn_queued_at, :utc_datetime)
      add(:wmn_sent_at, :utc_datetime)
      add(:wmn_idempotency_key, :text)
      add(:wmn_custom, :map, default: fragment("'{}'::jsonb"))

      add(
        :wmn_subscriber_id,
        references(:wms_subscriber,
          column: :wms_id,
          name: "wmn_send_wmn_subscriber_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :wmn_campaign_id,
        references(:wmc_campaign,
          column: :wmc_id,
          name: "wmn_send_wmn_campaign_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :wmn_template_id,
        references(:wmt_template,
          column: :wmt_id,
          name: "wmn_send_wmn_template_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:wmn_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wmn_org_id, :uuid, null: false)
      add(:wmn_inserted_at, :utc_datetime, null: false)
      add(:wmn_updated_at, :utc_datetime, null: false)
    end

    # --- wme_email_event : delivery/open/click/bounce events ---
    create table(:wme_email_event, primary_key: false) do
      add(:wme_event_type, :text, null: false)
      add(:wme_occurred_at, :utc_datetime)
      add(:wme_metadata, :map, default: fragment("'{}'::jsonb"))

      add(
        :wme_send_id,
        references(:wmn_send,
          column: :wmn_id,
          name: "wme_email_event_wme_send_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :wme_subscriber_id,
        references(:wms_subscriber,
          column: :wms_id,
          name: "wme_email_event_wme_subscriber_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:wme_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wme_org_id, :uuid, null: false)
      add(:wme_inserted_at, :utc_datetime, null: false)
      add(:wme_updated_at, :utc_datetime, null: false)
    end

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(constraint(:wme_email_event, "wme_email_event_wme_subscriber_id_fkey"))
    drop(constraint(:wme_email_event, "wme_email_event_wme_send_id_fkey"))
    drop(table(:wme_email_event))

    drop(constraint(:wmn_send, "wmn_send_wmn_template_id_fkey"))
    drop(constraint(:wmn_send, "wmn_send_wmn_campaign_id_fkey"))
    drop(constraint(:wmn_send, "wmn_send_wmn_subscriber_id_fkey"))
    drop(table(:wmn_send))

    drop(constraint(:wmp_suppression, "wmp_suppression_wmp_subscriber_id_fkey"))
    drop(table(:wmp_suppression))

    drop(table(:wmt_template))
    drop(table(:wms_subscriber))
    drop(table(:wmg_segment))
    drop(table(:wmc_campaign))
  end
end
