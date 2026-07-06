defmodule Demo.Repo.Migrations.AddMarketingScope do
  @moduledoc """
  Mounts the Marketing scope tables into the Demo host's one Postgres, and catalogs
  them in the SAME migration transaction (ADR-004 §"Migrations": the catalog-in-tx
  guarantee requires DDL + catalog_sync in one transaction in the host's repo).

  T3.4 — the Marketing scope:

    * `mca_campaign`    — a marketing campaign (name/status/schedule)
    * `msg_segment`     — an audience segment (filter criteria as jsonb)
    * `msu_subscriber`  — 🔒 subscriber (email vault-routed via pii_ column)
    * `mtp_template`    — Tier-0 config rows: reusable email templates per org
    * `msn_send`        — a single send event (campaign → subscriber); suppression-gated
    * `mee_email_event` — delivery/open/click/bounce/unsubscribe events
    * `msp_suppression` — consent/suppression list; checked before every send

  PII column on `msu_subscriber` is `pii_msu_email` — scalar PII field carries the
  `pii_` prefix per the storage convention. Holds a vault `vt_*` token — plaintext
  never lands here.

  FK order: Subscriber → Send → EmailEvent
                Subscriber → Suppression
  Campaign and Template are referenced by Send.

  ## Suppression gate

  The `msp_suppression` table is created BEFORE `msn_send` so that the application's
  suppression check (querying `msp_suppression` in the Send `:create_checked` action)
  always has the table to query. The check is at application layer, not a DB FK —
  the enforcement is runtime, not DDL.
  """
  use Samen.Migration

  @resources [
    Demo.MarketingScope.Campaign,
    Demo.MarketingScope.Segment,
    Demo.MarketingScope.Subscriber,
    Demo.MarketingScope.Template,
    Demo.MarketingScope.Send,
    Demo.MarketingScope.EmailEvent,
    Demo.MarketingScope.Suppression
  ]

  def up do
    # --- mca_campaign : a marketing campaign ---
    create table(:mca_campaign, primary_key: false) do
      add(:mca_name, :text, null: false)
      add(:mca_description, :text)
      add(:mca_status, :text, default: "draft")
      add(:mca_scheduled_at, :utc_datetime)
      add(:mca_sent_at, :utc_datetime)
      add(:mca_custom, :map, default: fragment("'{}'::jsonb"))
      add(:mca_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:mca_org_id, :uuid, null: false)
      add(:mca_inserted_at, :utc_datetime, null: false)
      add(:mca_updated_at, :utc_datetime, null: false)
    end

    # --- msg_segment : an audience segment ---
    create table(:msg_segment, primary_key: false) do
      add(:msg_name, :text, null: false)
      add(:msg_description, :text)
      add(:msg_filter_criteria, :map, default: fragment("'{}'::jsonb"))
      add(:msg_subscriber_count, :integer, default: 0)
      add(:msg_custom, :map, default: fragment("'{}'::jsonb"))
      add(:msg_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:msg_org_id, :uuid, null: false)
      add(:msg_inserted_at, :utc_datetime, null: false)
      add(:msg_updated_at, :utc_datetime, null: false)
    end

    # --- msu_subscriber : 🔒 subscriber (email vault-routed) ---
    create table(:msu_subscriber, primary_key: false) do
      add(:msu_status, :text, default: "active")
      add(:msu_consent_at, :utc_datetime)
      add(:msu_source, :text)
      add(:msu_custom, :map, default: fragment("'{}'::jsonb"))
      # Scalar PII token column (vault-routed; pii_ prefix per storage convention):
      add(:pii_msu_email, :text)
      add(:msu_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:msu_org_id, :uuid, null: false)
      add(:msu_inserted_at, :utc_datetime, null: false)
      add(:msu_updated_at, :utc_datetime, null: false)
    end

    # --- mtp_template : Tier-0 config rows (reusable email templates per org) ---
    create table(:mtp_template, primary_key: false) do
      add(:mtp_name, :text, null: false)
      add(:mtp_subject_line, :text, null: false)
      add(:mtp_body_html, :text)
      add(:mtp_body_text, :text)
      add(:mtp_from_name, :text)
      add(:mtp_from_address, :text)
      add(:mtp_enabled, :boolean, default: true)
      add(:mtp_custom, :map, default: fragment("'{}'::jsonb"))
      add(:mtp_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:mtp_org_id, :uuid, null: false)
      add(:mtp_inserted_at, :utc_datetime, null: false)
      add(:mtp_updated_at, :utc_datetime, null: false)
    end

    # --- msp_suppression : consent/suppression list (BEFORE msn_send!) ---
    # Created before msn_send because the send action checks this table at runtime.
    create table(:msp_suppression, primary_key: false) do
      add(:msp_reason, :text, null: false)
      add(:msp_active, :boolean, default: true)
      add(:msp_suppressed_at, :utc_datetime)
      add(:msp_notes, :text)

      add(
        :msp_subscriber_id,
        references(:msu_subscriber,
          column: :msu_id,
          name: "msp_suppression_msp_subscriber_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:msp_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:msp_org_id, :uuid, null: false)
      add(:msp_inserted_at, :utc_datetime, null: false)
      add(:msp_updated_at, :utc_datetime, null: false)
    end

    # --- msn_send : a single send event (campaign → subscriber) ---
    create table(:msn_send, primary_key: false) do
      add(:msn_status, :text, default: "queued")
      add(:msn_queued_at, :utc_datetime)
      add(:msn_sent_at, :utc_datetime)
      add(:msn_idempotency_key, :text)
      add(:msn_custom, :map, default: fragment("'{}'::jsonb"))

      add(
        :msn_subscriber_id,
        references(:msu_subscriber,
          column: :msu_id,
          name: "msn_send_msn_subscriber_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :msn_campaign_id,
        references(:mca_campaign,
          column: :mca_id,
          name: "msn_send_msn_campaign_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :msn_template_id,
        references(:mtp_template,
          column: :mtp_id,
          name: "msn_send_msn_template_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:msn_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:msn_org_id, :uuid, null: false)
      add(:msn_inserted_at, :utc_datetime, null: false)
      add(:msn_updated_at, :utc_datetime, null: false)
    end

    # --- mee_email_event : delivery/open/click/bounce events ---
    create table(:mee_email_event, primary_key: false) do
      add(:mee_event_type, :text, null: false)
      add(:mee_occurred_at, :utc_datetime)
      add(:mee_metadata, :map, default: fragment("'{}'::jsonb"))

      add(
        :mee_send_id,
        references(:msn_send,
          column: :msn_id,
          name: "mee_email_event_mee_send_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :mee_subscriber_id,
        references(:msu_subscriber,
          column: :msu_id,
          name: "mee_email_event_mee_subscriber_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:mee_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:mee_org_id, :uuid, null: false)
      add(:mee_inserted_at, :utc_datetime, null: false)
      add(:mee_updated_at, :utc_datetime, null: false)
    end

    # --- catalog all seven Marketing resources in THIS transaction ---
    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    # Drop in reverse FK order.
    drop(constraint(:mee_email_event, "mee_email_event_mee_subscriber_id_fkey"))
    drop(constraint(:mee_email_event, "mee_email_event_mee_send_id_fkey"))
    drop(table(:mee_email_event))

    drop(constraint(:msn_send, "msn_send_msn_template_id_fkey"))
    drop(constraint(:msn_send, "msn_send_msn_campaign_id_fkey"))
    drop(constraint(:msn_send, "msn_send_msn_subscriber_id_fkey"))
    drop(table(:msn_send))

    drop(constraint(:msp_suppression, "msp_suppression_msp_subscriber_id_fkey"))
    drop(table(:msp_suppression))

    drop(table(:mtp_template))
    drop(table(:msu_subscriber))
    drop(table(:msg_segment))
    drop(table(:mca_campaign))
  end
end
