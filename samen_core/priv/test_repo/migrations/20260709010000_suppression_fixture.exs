defmodule SamenCore.TestRepo.Migrations.SuppressionFixture do
  @moduledoc """
  ADR-014 §4 RP-D3 fixture tables: the Marketing scope mounted under NON-`msp` abbrevs
  (`sxc/sxg/sxs/sxt/sxn/sxe/sxp`), so the kernel suppression check must resolve
  `sxp_suppression` (not the old hardcoded `msp_suppression`).

  Column shape mirrors the Marketing blueprint exactly (copied+remapped from the
  samen_web test host's Marketing mount migration). The `pii_sxs_email` column on
  `sxs_subscriber` is the scalar PII column (vault-routed; carries a `vt_*` token).
  FK order: Subscriber → Suppression; Subscriber → Send → EmailEvent (Suppression
  created BEFORE Send so a suppression check has its table).
  """
  use Samen.Migration

  @resources [
    SamenCore.Support.SuppressionFixture.Campaign,
    SamenCore.Support.SuppressionFixture.Segment,
    SamenCore.Support.SuppressionFixture.Subscriber,
    SamenCore.Support.SuppressionFixture.Template,
    SamenCore.Support.SuppressionFixture.Send,
    SamenCore.Support.SuppressionFixture.EmailEvent,
    SamenCore.Support.SuppressionFixture.Suppression,
    SamenCore.Support.SuppressionFixture.ConsentEvent
  ]

  def up do
    # --- sxc_campaign ---
    create table(:sxc_campaign, primary_key: false) do
      add(:sxc_name, :text, null: false)
      add(:sxc_description, :text)
      add(:sxc_status, :text, default: "draft")
      add(:sxc_scheduled_at, :utc_datetime)
      add(:sxc_sent_at, :utc_datetime)
      add(:sxc_custom, :map, default: fragment("'{}'::jsonb"))
      add(:sxc_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:sxc_org_id, :uuid, null: false)
      add(:sxc_inserted_at, :utc_datetime, null: false)
      add(:sxc_updated_at, :utc_datetime, null: false)
    end

    # --- sxg_segment ---
    create table(:sxg_segment, primary_key: false) do
      add(:sxg_name, :text, null: false)
      add(:sxg_description, :text)
      add(:sxg_filter_criteria, :map, default: fragment("'{}'::jsonb"))
      add(:sxg_subscriber_count, :integer, default: 0)
      add(:sxg_custom, :map, default: fragment("'{}'::jsonb"))
      add(:sxg_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:sxg_org_id, :uuid, null: false)
      add(:sxg_inserted_at, :utc_datetime, null: false)
      add(:sxg_updated_at, :utc_datetime, null: false)
    end

    # --- sxs_subscriber : 🔒 subscriber (email vault-routed, matches the blueprint) ---
    # The `pii_sxs_email` column is the scalar vault-routed PII column the Marketing
    # blueprint declares on Subscriber. It matches the cataloged field (catalog_parity),
    # but because this RP-D3 fixture domain is NOT in `:ash_domains`, the
    # `vault_declared_parity` verifier cannot discover its route — so the pair is
    # allow-listed in config/test.exs (`:vault_declared_parity_allow_list`).
    create table(:sxs_subscriber, primary_key: false) do
      add(:sxs_status, :text, default: "active")
      add(:sxs_consent_at, :utc_datetime)
      add(:sxs_source, :text)
      add(:sxs_custom, :map, default: fragment("'{}'::jsonb"))
      add(:pii_sxs_email, :text)
      add(:sxs_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:sxs_org_id, :uuid, null: false)
      add(:sxs_inserted_at, :utc_datetime, null: false)
      add(:sxs_updated_at, :utc_datetime, null: false)
    end

    # --- sxt_template ---
    create table(:sxt_template, primary_key: false) do
      add(:sxt_name, :text, null: false)
      add(:sxt_subject_line, :text, null: false)
      add(:sxt_body_html, :text)
      add(:sxt_body_text, :text)
      add(:sxt_from_name, :text)
      add(:sxt_from_address, :text)
      add(:sxt_enabled, :boolean, default: true)
      add(:sxt_custom, :map, default: fragment("'{}'::jsonb"))
      add(:sxt_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:sxt_org_id, :uuid, null: false)
      add(:sxt_inserted_at, :utc_datetime, null: false)
      add(:sxt_updated_at, :utc_datetime, null: false)
    end

    # --- sxp_suppression : consent/suppression list (BEFORE sxn_send) ---
    create table(:sxp_suppression, primary_key: false) do
      add(:sxp_reason, :text, null: false)
      add(:sxp_active, :boolean, default: true)
      add(:sxp_suppressed_at, :utc_datetime)
      add(:sxp_notes, :text)

      add(
        :sxp_subscriber_id,
        references(:sxs_subscriber,
          column: :sxs_id,
          name: "sxp_suppression_sxp_subscriber_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:sxp_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:sxp_org_id, :uuid, null: false)
      add(:sxp_inserted_at, :utc_datetime, null: false)
      add(:sxp_updated_at, :utc_datetime, null: false)
    end

    # --- sxn_send : a single send event ---
    create table(:sxn_send, primary_key: false) do
      add(:sxn_status, :text, default: "queued")
      add(:sxn_queued_at, :utc_datetime)
      add(:sxn_sent_at, :utc_datetime)
      add(:sxn_idempotency_key, :text)
      add(:sxn_custom, :map, default: fragment("'{}'::jsonb"))

      add(
        :sxn_subscriber_id,
        references(:sxs_subscriber,
          column: :sxs_id,
          name: "sxn_send_sxn_subscriber_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :sxn_campaign_id,
        references(:sxc_campaign,
          column: :sxc_id,
          name: "sxn_send_sxn_campaign_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :sxn_template_id,
        references(:sxt_template,
          column: :sxt_id,
          name: "sxn_send_sxn_template_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:sxn_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:sxn_org_id, :uuid, null: false)
      add(:sxn_inserted_at, :utc_datetime, null: false)
      add(:sxn_updated_at, :utc_datetime, null: false)
    end

    # --- sxe_email_event ---
    create table(:sxe_email_event, primary_key: false) do
      add(:sxe_event_type, :text, null: false)
      add(:sxe_occurred_at, :utc_datetime)
      add(:sxe_metadata, :map, default: fragment("'{}'::jsonb"))

      add(
        :sxe_send_id,
        references(:sxn_send,
          column: :sxn_id,
          name: "sxe_email_event_sxe_send_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :sxe_subscriber_id,
        references(:sxs_subscriber,
          column: :sxs_id,
          name: "sxe_email_event_sxe_subscriber_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:sxe_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:sxe_org_id, :uuid, null: false)
      add(:sxe_inserted_at, :utc_datetime, null: false)
      add(:sxe_updated_at, :utc_datetime, null: false)
    end

    # --- sxv_consent_event : append-only consent ledger (F3 Unit 1) ---
    create table(:sxv_consent_event, primary_key: false) do
      add(:sxv_subscriber_id, :uuid, null: false)
      add(:sxv_event, :text, null: false)
      add(:sxv_source, :text)
      add(:sxv_purpose, :text, default: "marketing")
      add(:sxv_subject_hash, :text)
      add(:sxv_occurred_at, :utc_datetime_usec, null: false)
      add(:sxv_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:sxv_org_id, :uuid, null: false)
      add(:sxv_inserted_at, :utc_datetime, null: false)
      add(:sxv_updated_at, :utc_datetime, null: false)
    end

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(table(:sxv_consent_event))

    drop(constraint(:sxe_email_event, "sxe_email_event_sxe_subscriber_id_fkey"))
    drop(constraint(:sxe_email_event, "sxe_email_event_sxe_send_id_fkey"))
    drop(table(:sxe_email_event))

    drop(constraint(:sxn_send, "sxn_send_sxn_template_id_fkey"))
    drop(constraint(:sxn_send, "sxn_send_sxn_campaign_id_fkey"))
    drop(constraint(:sxn_send, "sxn_send_sxn_subscriber_id_fkey"))
    drop(table(:sxn_send))

    drop(constraint(:sxp_suppression, "sxp_suppression_sxp_subscriber_id_fkey"))
    drop(table(:sxp_suppression))

    drop(table(:sxt_template))
    drop(table(:sxs_subscriber))
    drop(table(:sxg_segment))
    drop(table(:sxc_campaign))
  end
end
