defmodule PawChart.Repo.Migrations.MountMarketingScope do
  @moduledoc """
  Mounts the PawChart Marketing scope tables (fresh abbrevs vmc/vmg/vms/vmt/vmn/vme/vmp) and
  catalogs every resource in the SAME migration transaction (ADR-004 catalog-in-tx; ADR-011
  §7). Column shape mirrors the Marketing blueprint (copied+remapped from Driftwood's
  Marketing mount so PawChart's materialized tables match the blueprint exactly).

  The `pii_vms_email` column on `vms_subscriber` is the scalar PII column (vault-routed;
  holds a `vt_*` token — plaintext never lands here). FK order: Subscriber → Suppression;
  Subscriber → Send → EmailEvent (Suppression created BEFORE Send so a suppression check has
  its table to query).

  This is the SECOND-VERTICAL proof of the outreach/consent surface: the clinic inherits the
  framework Marketing pages + the fail-closed suppression red path with ZERO PawChart
  LiveView code.
  """
  use Samen.Migration

  @resources [
    PawChart.Marketing.Campaign,
    PawChart.Marketing.Segment,
    PawChart.Marketing.Subscriber,
    PawChart.Marketing.Template,
    PawChart.Marketing.Send,
    PawChart.Marketing.EmailEvent,
    PawChart.Marketing.Suppression
  ]

  def up do
    # --- vmc_campaign : a marketing campaign ---
    create table(:vmc_campaign, primary_key: false) do
      add(:vmc_name, :text, null: false)
      add(:vmc_description, :text)
      add(:vmc_status, :text, default: "draft")
      add(:vmc_scheduled_at, :utc_datetime)
      add(:vmc_sent_at, :utc_datetime)
      add(:vmc_custom, :map, default: fragment("'{}'::jsonb"))
      add(:vmc_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:vmc_org_id, :uuid, null: false)
      add(:vmc_inserted_at, :utc_datetime, null: false)
      add(:vmc_updated_at, :utc_datetime, null: false)
    end

    # --- vmg_segment : an audience segment ---
    create table(:vmg_segment, primary_key: false) do
      add(:vmg_name, :text, null: false)
      add(:vmg_description, :text)
      add(:vmg_filter_criteria, :map, default: fragment("'{}'::jsonb"))
      add(:vmg_subscriber_count, :integer, default: 0)
      add(:vmg_custom, :map, default: fragment("'{}'::jsonb"))
      add(:vmg_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:vmg_org_id, :uuid, null: false)
      add(:vmg_inserted_at, :utc_datetime, null: false)
      add(:vmg_updated_at, :utc_datetime, null: false)
    end

    # --- vms_subscriber : 🔒 subscriber (email vault-routed) ---
    create table(:vms_subscriber, primary_key: false) do
      add(:vms_status, :text, default: "active")
      add(:vms_consent_at, :utc_datetime)
      add(:vms_source, :text)
      add(:vms_custom, :map, default: fragment("'{}'::jsonb"))
      add(:pii_vms_email, :text)
      add(:vms_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:vms_org_id, :uuid, null: false)
      add(:vms_inserted_at, :utc_datetime, null: false)
      add(:vms_updated_at, :utc_datetime, null: false)
    end

    # --- vmt_template : Tier-0 config rows ---
    create table(:vmt_template, primary_key: false) do
      add(:vmt_name, :text, null: false)
      add(:vmt_subject_line, :text, null: false)
      add(:vmt_body_html, :text)
      add(:vmt_body_text, :text)
      add(:vmt_from_name, :text)
      add(:vmt_from_address, :text)
      add(:vmt_enabled, :boolean, default: true)
      add(:vmt_custom, :map, default: fragment("'{}'::jsonb"))
      add(:vmt_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:vmt_org_id, :uuid, null: false)
      add(:vmt_inserted_at, :utc_datetime, null: false)
      add(:vmt_updated_at, :utc_datetime, null: false)
    end

    # --- vmp_suppression : consent/suppression list (BEFORE vmn_send) ---
    create table(:vmp_suppression, primary_key: false) do
      add(:vmp_reason, :text, null: false)
      add(:vmp_active, :boolean, default: true)
      add(:vmp_suppressed_at, :utc_datetime)
      add(:vmp_notes, :text)

      add(
        :vmp_subscriber_id,
        references(:vms_subscriber,
          column: :vms_id,
          name: "vmp_suppression_vmp_subscriber_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:vmp_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:vmp_org_id, :uuid, null: false)
      add(:vmp_inserted_at, :utc_datetime, null: false)
      add(:vmp_updated_at, :utc_datetime, null: false)
    end

    # --- vmn_send : a single send event ---
    create table(:vmn_send, primary_key: false) do
      add(:vmn_status, :text, default: "queued")
      add(:vmn_queued_at, :utc_datetime)
      add(:vmn_sent_at, :utc_datetime)
      add(:vmn_idempotency_key, :text)
      add(:vmn_custom, :map, default: fragment("'{}'::jsonb"))

      add(
        :vmn_subscriber_id,
        references(:vms_subscriber,
          column: :vms_id,
          name: "vmn_send_vmn_subscriber_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :vmn_campaign_id,
        references(:vmc_campaign,
          column: :vmc_id,
          name: "vmn_send_vmn_campaign_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :vmn_template_id,
        references(:vmt_template,
          column: :vmt_id,
          name: "vmn_send_vmn_template_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:vmn_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:vmn_org_id, :uuid, null: false)
      add(:vmn_inserted_at, :utc_datetime, null: false)
      add(:vmn_updated_at, :utc_datetime, null: false)
    end

    # --- vme_email_event : delivery/open/click/bounce events ---
    create table(:vme_email_event, primary_key: false) do
      add(:vme_event_type, :text, null: false)
      add(:vme_occurred_at, :utc_datetime)
      add(:vme_metadata, :map, default: fragment("'{}'::jsonb"))

      add(
        :vme_send_id,
        references(:vmn_send,
          column: :vmn_id,
          name: "vme_email_event_vme_send_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :vme_subscriber_id,
        references(:vms_subscriber,
          column: :vms_id,
          name: "vme_email_event_vme_subscriber_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:vme_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:vme_org_id, :uuid, null: false)
      add(:vme_inserted_at, :utc_datetime, null: false)
      add(:vme_updated_at, :utc_datetime, null: false)
    end

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(constraint(:vme_email_event, "vme_email_event_vme_subscriber_id_fkey"))
    drop(constraint(:vme_email_event, "vme_email_event_vme_send_id_fkey"))
    drop(table(:vme_email_event))

    drop(constraint(:vmn_send, "vmn_send_vmn_template_id_fkey"))
    drop(constraint(:vmn_send, "vmn_send_vmn_campaign_id_fkey"))
    drop(constraint(:vmn_send, "vmn_send_vmn_subscriber_id_fkey"))
    drop(table(:vmn_send))

    drop(constraint(:vmp_suppression, "vmp_suppression_vmp_subscriber_id_fkey"))
    drop(table(:vmp_suppression))

    drop(table(:vmt_template))
    drop(table(:vms_subscriber))
    drop(table(:vmg_segment))
    drop(table(:vmc_campaign))
  end
end
