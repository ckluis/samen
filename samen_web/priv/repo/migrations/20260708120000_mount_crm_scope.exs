defmodule Samen.WebTest.Repo.Migrations.MountCrmScope do
  @moduledoc """
  Mounts the samen_web test-support CRM scope (fresh abbrevs swc/swp/swi/swo/swa/swt) and
  catalogs every resource in the SAME transaction (ADR-004 catalog-in-tx). Column shape
  mirrors the CRM blueprint. Copied+remapped from driftwood's CRM mount migration so the
  test host's materialized CRM tables match the blueprint exactly.
  """
  use Samen.Migration

  @resources [
    Samen.WebTest.Crm.Company,
    Samen.WebTest.Crm.Person,
    Samen.WebTest.Crm.Pipeline,
    Samen.WebTest.Crm.Opportunity,
    Samen.WebTest.Crm.Activity,
    Samen.WebTest.Crm.Attachment
  ]

  def up do

    # --- swc_company : the freight company (Carrier/Shipper under the Context) ---
    create table(:swc_company, primary_key: false) do
      add(:swc_name, :text, null: false)
      add(:swc_domain, :text)
      add(:swc_industry, :text)
      add(:swc_size, :text)
      add(:swc_website, :text)
      add(:swc_notes, :text)
      add(:swc_custom, :map, default: fragment("'{}'::jsonb"))
      add(:swc_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:swc_org_id, :uuid, null: false)
      add(:swc_inserted_at, :utc_datetime, null: false)
      add(:swc_updated_at, :utc_datetime, null: false)
    end

    # --- swp_person : broker-side CRM contact (CorePerson folded in, vault-routed) ---
    create table(:swp_person, primary_key: false) do
      add(:swp_display_name, :text)
      add(:swp_full_name, :text)
      add(:swp_emails, :text)
      add(:swp_phones, :text)
      add(:swp_job_title, :text)
      add(:swp_custom, :map, default: fragment("'{}'::jsonb"))

      add(
        :swp_company_id,
        references(:swc_company,
          column: :swc_id,
          name: "swp_person_swp_company_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:swp_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:swp_org_id, :uuid, null: false)
      add(:swp_inserted_at, :utc_datetime, null: false)
      add(:swp_updated_at, :utc_datetime, null: false)
    end

    # --- swi_pipeline : Load-lifecycle stages (Tier-0 config rows) ---
    create table(:swi_pipeline, primary_key: false) do
      add(:swi_name, :text, null: false)
      add(:swi_label, :text)
      add(:swi_stage_order, :integer, default: 0)
      add(:swi_enabled, :boolean, default: true)
      add(:swi_stage_type, :text, default: "open")
      add(:swi_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:swi_org_id, :uuid, null: false)
      add(:swi_inserted_at, :utc_datetime, null: false)
      add(:swi_updated_at, :utc_datetime, null: false)
    end

    # --- swo_opportunity : the LOAD (re-identified via the Context alias) ---
    create table(:swo_opportunity, primary_key: false) do
      add(:swo_name, :text, null: false)
      add(:swo_value_cents, :integer, default: 0)
      add(:swo_currency, :text, default: "USD")
      add(:swo_probability, :integer, default: 0)
      add(:swo_status, :text, default: "open")
      add(:swo_close_date, :date)
      add(:swo_notes, :text)
      add(:swo_custom, :map, default: fragment("'{}'::jsonb"))

      add(
        :swo_company_id,
        references(:swc_company,
          column: :swc_id,
          name: "swo_opportunity_swo_company_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :swo_pipeline_id,
        references(:swi_pipeline,
          column: :swi_id,
          name: "swo_opportunity_swo_pipeline_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:swo_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:swo_org_id, :uuid, null: false)
      add(:swo_inserted_at, :utc_datetime, null: false)
      add(:swo_updated_at, :utc_datetime, null: false)
    end

    # --- swa_activity : the CHECK-CALL event stream (re-identified via the Context) ---
    create table(:swa_activity, primary_key: false) do
      add(:swa_type, :text, null: false)
      add(:swa_subject, :text)
      add(:swa_body, :text)
      add(:swa_status, :text, default: "pending")
      add(:swa_due_at, :utc_datetime)
      add(:swa_completed_at, :utc_datetime)
      add(:swa_custom, :map, default: fragment("'{}'::jsonb"))

      add(
        :swa_company_id,
        references(:swc_company,
          column: :swc_id,
          name: "swa_activity_swa_company_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :swa_person_id,
        references(:swp_person,
          column: :swp_id,
          name: "swa_activity_swa_person_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :swa_opportunity_id,
        references(:swo_opportunity,
          column: :swo_id,
          name: "swa_activity_swa_opportunity_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:swa_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:swa_org_id, :uuid, null: false)
      add(:swa_inserted_at, :utc_datetime, null: false)
      add(:swa_updated_at, :utc_datetime, null: false)
    end

    # --- swt_attachment : rate cons, BOLs, PODs (file refs) ---
    create table(:swt_attachment, primary_key: false) do
      add(:swt_file_name, :text, null: false)
      add(:swt_content_type, :text)
      add(:swt_size_bytes, :integer)
      add(:swt_storage_key, :text)

      add(
        :swt_company_id,
        references(:swc_company,
          column: :swc_id,
          name: "swt_attachment_swt_company_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :swt_person_id,
        references(:swp_person,
          column: :swp_id,
          name: "swt_attachment_swt_person_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :swt_opportunity_id,
        references(:swo_opportunity,
          column: :swo_id,
          name: "swt_attachment_swt_opportunity_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:swt_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:swt_org_id, :uuid, null: false)
      add(:swt_inserted_at, :utc_datetime, null: false)
      add(:swt_updated_at, :utc_datetime, null: false)
    end

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(constraint(:swt_attachment, "swt_attachment_swt_opportunity_id_fkey"))
    drop(constraint(:swt_attachment, "swt_attachment_swt_person_id_fkey"))
    drop(constraint(:swt_attachment, "swt_attachment_swt_company_id_fkey"))
    drop(table(:swt_attachment))

    drop(constraint(:swa_activity, "swa_activity_swa_opportunity_id_fkey"))
    drop(constraint(:swa_activity, "swa_activity_swa_person_id_fkey"))
    drop(constraint(:swa_activity, "swa_activity_swa_company_id_fkey"))
    drop(table(:swa_activity))

    drop(constraint(:swo_opportunity, "swo_opportunity_swo_pipeline_id_fkey"))
    drop(constraint(:swo_opportunity, "swo_opportunity_swo_company_id_fkey"))
    drop(table(:swo_opportunity))

    drop(table(:swi_pipeline))

    drop(constraint(:swp_person, "swp_person_swp_company_id_fkey"))
    drop(table(:swp_person))

    drop(table(:swc_company))
  end
end
