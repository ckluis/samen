defmodule Driftwood.Repo.Migrations.DriftwoodResources do
  @moduledoc """
  Mounts Driftwood's CRM scope (fresh abbrevs fcm/fpr/fpp/fop/fac/fat) + the vertical
  Freight tables (drv/stl/dsp), and catalogs every resource in the SAME migration
  transaction (ADR-004 catalog-in-tx). Column names mirror the CRM blueprint shape;
  Driver folds in CorePerson (drv_full_name/drv_emails/drv_phones vault tokens +
  drv_job_title/drv_custom) plus pii_drv_cdl_number (scalar vault) and the non-PII
  CDL/medical dates + eld_provider (Tier-0) + status.
  """
  use Samen.Migration

  @resources [
    Driftwood.Crm.Company,
    Driftwood.Crm.Person,
    Driftwood.Crm.Pipeline,
    Driftwood.Crm.Opportunity,
    Driftwood.Crm.Activity,
    Driftwood.Crm.Attachment,
    Driftwood.Freight.Driver,
    Driftwood.Freight.Settlement,
    Driftwood.Freight.DispatchEvent
  ]

  def up do
    # --- fcm_company : the freight company (Carrier/Shipper under the Context) ---
    create table(:fcm_company, primary_key: false) do
      add(:fcm_name, :text, null: false)
      add(:fcm_domain, :text)
      add(:fcm_industry, :text)
      add(:fcm_size, :text)
      add(:fcm_website, :text)
      add(:fcm_notes, :text)
      add(:fcm_custom, :map, default: fragment("'{}'::jsonb"))
      add(:fcm_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fcm_org_id, :uuid, null: false)
      add(:fcm_inserted_at, :utc_datetime, null: false)
      add(:fcm_updated_at, :utc_datetime, null: false)
    end

    # --- fpr_person : broker-side CRM contact (CorePerson folded in, vault-routed) ---
    create table(:fpr_person, primary_key: false) do
      add(:fpr_display_name, :text)
      add(:fpr_full_name, :text)
      add(:fpr_emails, :text)
      add(:fpr_phones, :text)
      add(:fpr_job_title, :text)
      add(:fpr_custom, :map, default: fragment("'{}'::jsonb"))

      add(
        :fpr_company_id,
        references(:fcm_company,
          column: :fcm_id,
          name: "fpr_person_fpr_company_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:fpr_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fpr_org_id, :uuid, null: false)
      add(:fpr_inserted_at, :utc_datetime, null: false)
      add(:fpr_updated_at, :utc_datetime, null: false)
    end

    # --- fpp_pipeline : Load-lifecycle stages (Tier-0 config rows) ---
    create table(:fpp_pipeline, primary_key: false) do
      add(:fpp_name, :text, null: false)
      add(:fpp_label, :text)
      add(:fpp_stage_order, :integer, default: 0)
      add(:fpp_enabled, :boolean, default: true)
      add(:fpp_stage_type, :text, default: "open")
      add(:fpp_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fpp_org_id, :uuid, null: false)
      add(:fpp_inserted_at, :utc_datetime, null: false)
      add(:fpp_updated_at, :utc_datetime, null: false)
    end

    # --- fop_opportunity : the LOAD (re-identified via the Context alias) ---
    create table(:fop_opportunity, primary_key: false) do
      add(:fop_name, :text, null: false)
      add(:fop_value_cents, :integer, default: 0)
      add(:fop_currency, :text, default: "USD")
      add(:fop_probability, :integer, default: 0)
      add(:fop_status, :text, default: "open")
      add(:fop_close_date, :date)
      add(:fop_notes, :text)
      add(:fop_custom, :map, default: fragment("'{}'::jsonb"))

      add(
        :fop_company_id,
        references(:fcm_company,
          column: :fcm_id,
          name: "fop_opportunity_fop_company_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :fop_pipeline_id,
        references(:fpp_pipeline,
          column: :fpp_id,
          name: "fop_opportunity_fop_pipeline_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:fop_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fop_org_id, :uuid, null: false)
      add(:fop_inserted_at, :utc_datetime, null: false)
      add(:fop_updated_at, :utc_datetime, null: false)
    end

    # --- fac_activity : the CHECK-CALL event stream (re-identified via the Context) ---
    create table(:fac_activity, primary_key: false) do
      add(:fac_type, :text, null: false)
      add(:fac_subject, :text)
      add(:fac_body, :text)
      add(:fac_status, :text, default: "pending")
      add(:fac_due_at, :utc_datetime)
      add(:fac_completed_at, :utc_datetime)
      add(:fac_custom, :map, default: fragment("'{}'::jsonb"))

      add(
        :fac_company_id,
        references(:fcm_company,
          column: :fcm_id,
          name: "fac_activity_fac_company_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :fac_person_id,
        references(:fpr_person,
          column: :fpr_id,
          name: "fac_activity_fac_person_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :fac_opportunity_id,
        references(:fop_opportunity,
          column: :fop_id,
          name: "fac_activity_fac_opportunity_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:fac_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fac_org_id, :uuid, null: false)
      add(:fac_inserted_at, :utc_datetime, null: false)
      add(:fac_updated_at, :utc_datetime, null: false)
    end

    # --- fat_attachment : rate cons, BOLs, PODs (file refs) ---
    create table(:fat_attachment, primary_key: false) do
      add(:fat_file_name, :text, null: false)
      add(:fat_content_type, :text)
      add(:fat_size_bytes, :integer)
      add(:fat_storage_key, :text)

      add(
        :fat_company_id,
        references(:fcm_company,
          column: :fcm_id,
          name: "fat_attachment_fat_company_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :fat_person_id,
        references(:fpr_person,
          column: :fpr_id,
          name: "fat_attachment_fat_person_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :fat_opportunity_id,
        references(:fop_opportunity,
          column: :fop_id,
          name: "fat_attachment_fat_opportunity_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:fat_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fat_org_id, :uuid, null: false)
      add(:fat_inserted_at, :utc_datetime, null: false)
      add(:fat_updated_at, :utc_datetime, null: false)
    end

    # --- drv_driver : the DRIVER (CorePerson folded in) + CDL/medical PII + Tier-0 ---
    create table(:drv_driver, primary_key: false) do
      # CorePerson composite PII (vault vt_* tokens):
      add(:drv_full_name, :text)
      add(:drv_emails, :text)
      add(:drv_phones, :text)
      add(:drv_job_title, :text)
      add(:drv_custom, :map, default: fragment("'{}'::jsonb"))
      # Scalar pii_ vault field: CDL number → pii_drv_cdl_number (vt_* token):
      add(:pii_drv_cdl_number, :text)
      # Non-PII columns (reviewed non_pii! for the cdl_* names, design OR-2):
      add(:drv_cdl_state, :text)
      # drv_cdl_expiry is ISO-8601 TEXT (a reviewed non_pii! column erased by the
      # text-redaction arm on driver crypto-shred; see the Driver resource note).
      add(:drv_cdl_expiry, :text)
      add(:drv_medical_card_expiry, :date)
      add(:drv_eld_provider, :text)
      add(:drv_status, :text, default: "available")

      add(
        :drv_carrier_id,
        references(:fcm_company,
          column: :fcm_id,
          name: "drv_driver_drv_carrier_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:drv_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:drv_org_id, :uuid, null: false)
      add(:drv_inserted_at, :utc_datetime, null: false)
      add(:drv_updated_at, :utc_datetime, null: false)
    end

    # --- stl_settlement : the carrier-settlement stored inputs (typed integer cents) ---
    create table(:stl_settlement, primary_key: false) do
      add(:stl_linehaul_cents, :integer, default: 0)
      add(:stl_advances_cents, :integer, default: 0)
      add(:stl_fuel_surcharge_cents, :integer, default: 0)
      add(:stl_accessorial_cents, :integer, default: 0)
      add(:stl_claim_deduction_cents, :integer, default: 0)
      add(:stl_factoring_rate_bps, :integer, default: 0)
      add(:stl_currency, :text, default: "USD")
      add(:stl_status, :text, default: "draft")

      add(
        :stl_load_id,
        references(:fop_opportunity,
          column: :fop_id,
          name: "stl_settlement_stl_load_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :stl_carrier_id,
        references(:fcm_company,
          column: :fcm_id,
          name: "stl_settlement_stl_carrier_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:stl_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:stl_org_id, :uuid, null: false)
      add(:stl_inserted_at, :utc_datetime, null: false)
      add(:stl_updated_at, :utc_datetime, null: false)
    end

    # --- dsp_dispatch_event : the FMCSA-gated dispatch (Driver → Load) ---
    create table(:dsp_dispatch_event, primary_key: false) do
      add(:dsp_status, :text, default: "dispatched")
      add(:dsp_dispatched_at, :utc_datetime)

      add(
        :dsp_driver_id,
        references(:drv_driver,
          column: :drv_id,
          name: "dsp_dispatch_event_dsp_driver_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )

      add(
        :dsp_load_id,
        references(:fop_opportunity,
          column: :fop_id,
          name: "dsp_dispatch_event_dsp_load_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )

      add(:dsp_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:dsp_org_id, :uuid, null: false)
      add(:dsp_inserted_at, :utc_datetime, null: false)
      add(:dsp_updated_at, :utc_datetime, null: false)
    end

    # --- catalog every resource in THIS transaction ---
    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(constraint(:dsp_dispatch_event, "dsp_dispatch_event_dsp_load_id_fkey"))
    drop(constraint(:dsp_dispatch_event, "dsp_dispatch_event_dsp_driver_id_fkey"))
    drop(table(:dsp_dispatch_event))

    drop(constraint(:stl_settlement, "stl_settlement_stl_carrier_id_fkey"))
    drop(constraint(:stl_settlement, "stl_settlement_stl_load_id_fkey"))
    drop(table(:stl_settlement))

    drop(constraint(:drv_driver, "drv_driver_drv_carrier_id_fkey"))
    drop(table(:drv_driver))

    drop(constraint(:fat_attachment, "fat_attachment_fat_opportunity_id_fkey"))
    drop(constraint(:fat_attachment, "fat_attachment_fat_person_id_fkey"))
    drop(constraint(:fat_attachment, "fat_attachment_fat_company_id_fkey"))
    drop(table(:fat_attachment))

    drop(constraint(:fac_activity, "fac_activity_fac_opportunity_id_fkey"))
    drop(constraint(:fac_activity, "fac_activity_fac_person_id_fkey"))
    drop(constraint(:fac_activity, "fac_activity_fac_company_id_fkey"))
    drop(table(:fac_activity))

    drop(constraint(:fop_opportunity, "fop_opportunity_fop_pipeline_id_fkey"))
    drop(constraint(:fop_opportunity, "fop_opportunity_fop_company_id_fkey"))
    drop(table(:fop_opportunity))

    drop(table(:fpp_pipeline))

    drop(constraint(:fpr_person, "fpr_person_fpr_company_id_fkey"))
    drop(table(:fpr_person))

    drop(table(:fcm_company))
  end
end
