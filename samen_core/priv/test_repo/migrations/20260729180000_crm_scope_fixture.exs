defmodule SamenCore.TestRepo.Migrations.CrmScopeFixture do
  @moduledoc """
  Tables for the REAL CRM scope (T3.2, `Samen.Scopes.Crm`) mounted in
  `samen_core`'s own test suite via `test/support/crm_scope_fixture.ex` — the
  Lead-conversion TARGET for the SalesOps scope fixture (F6+F7, T48).

    * `scc_company`     — a B2B company record (no PII)
    * `scp_person`      — a CRM person 🔒 (full_name/emails/phones vault-routed,
      `Samen.Fragments.CorePerson` folded in)
    * `csp_pipeline`    — Tier-0 config rows (deal-stage catalog per org)
    * `sco_opportunity` — a deal, `sco_value` typed `money_with_currency`
      (H1/T12 — declared directly here, no historical two-step migration; this
      fixture is brand new)
    * `sca_attachment`  — a file reference linked to any CRM object

  Requires `20260721163038_install_ash_money_v5_extension` (the
  `money_with_currency` Postgres composite type) to have run first.

  Catalog rows are written by `catalog_sync/1` in the SAME transaction (ADR-004).
  """
  use Samen.Migration

  @resources [
    SamenCore.Support.CrmScopeFixture.Company,
    SamenCore.Support.CrmScopeFixture.Person,
    SamenCore.Support.CrmScopeFixture.Pipeline,
    SamenCore.Support.CrmScopeFixture.Opportunity,
    SamenCore.Support.CrmScopeFixture.Attachment
  ]

  def up do
    # --- scc_company : a B2B company record (no PII) ---
    create table(:scc_company, primary_key: false) do
      add(:scc_name, :text, null: false)
      add(:scc_domain, :text)
      add(:scc_industry, :text)
      add(:scc_size, :text)
      add(:scc_website, :text)
      add(:scc_notes, :text)
      add(:scc_custom, :map, default: fragment("'{}'::jsonb"))
      add(:scc_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:scc_org_id, :uuid, null: false)
      add(:scc_inserted_at, :utc_datetime, null: false)
      add(:scc_updated_at, :utc_datetime, null: false)
    end

    # --- scp_person : CRM person 🔒 (Core.Person fragment folded in) ---
    create table(:scp_person, primary_key: false) do
      add(:scp_display_name, :text)
      add(:scp_full_name, :text)
      add(:scp_emails, :text)
      add(:scp_phones, :text)
      add(:scp_job_title, :text)
      add(:scp_custom, :map, default: fragment("'{}'::jsonb"))

      add(
        :scp_company_id,
        references(:scc_company,
          column: :scc_id,
          name: "scp_person_scp_company_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:scp_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:scp_org_id, :uuid, null: false)
      add(:scp_inserted_at, :utc_datetime, null: false)
      add(:scp_updated_at, :utc_datetime, null: false)
    end

    # --- csp_pipeline : Tier-0 config rows (deal-stage catalog per org) ---
    create table(:csp_pipeline, primary_key: false) do
      add(:csp_name, :text, null: false)
      add(:csp_label, :text)
      add(:csp_stage_order, :integer, default: 0)
      add(:csp_enabled, :boolean, default: true)
      add(:csp_stage_type, :text, default: "open")
      add(:csp_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:csp_org_id, :uuid, null: false)
      add(:csp_inserted_at, :utc_datetime, null: false)
      add(:csp_updated_at, :utc_datetime, null: false)
    end

    # --- sco_opportunity : a deal/opportunity record (value: money_with_currency) ---
    create table(:sco_opportunity, primary_key: false) do
      add(:sco_name, :text, null: false)
      add(:sco_value, :money_with_currency)
      add(:sco_probability, :integer, default: 0)
      add(:sco_status, :text, default: "open")
      add(:sco_close_date, :date)
      add(:sco_notes, :text)
      add(:sco_custom, :map, default: fragment("'{}'::jsonb"))

      add(
        :sco_company_id,
        references(:scc_company,
          column: :scc_id,
          name: "sco_opportunity_sco_company_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :sco_pipeline_id,
        references(:csp_pipeline,
          column: :csp_id,
          name: "sco_opportunity_sco_pipeline_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:sco_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:sco_org_id, :uuid, null: false)
      add(:sco_inserted_at, :utc_datetime, null: false)
      add(:sco_updated_at, :utc_datetime, null: false)
    end

    # --- sca_attachment : a file reference linked to any CRM object ---
    create table(:sca_attachment, primary_key: false) do
      add(:sca_file_name, :text, null: false)
      add(:sca_content_type, :text)
      add(:sca_size_bytes, :integer)
      add(:sca_storage_key, :text)

      add(
        :sca_company_id,
        references(:scc_company,
          column: :scc_id,
          name: "sca_attachment_sca_company_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :sca_person_id,
        references(:scp_person,
          column: :scp_id,
          name: "sca_attachment_sca_person_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :sca_opportunity_id,
        references(:sco_opportunity,
          column: :sco_id,
          name: "sca_attachment_sca_opportunity_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:sca_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:sca_org_id, :uuid, null: false)
      add(:sca_inserted_at, :utc_datetime, null: false)
      add(:sca_updated_at, :utc_datetime, null: false)
    end

    create(index(:scp_person, [:scp_org_id]))
    create(index(:sco_opportunity, [:sco_org_id]))
    create(index(:sca_attachment, [:sca_org_id]))
    create(index(:scc_company, [:scc_org_id]))
    create(index(:csp_pipeline, [:csp_org_id]))

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)
    drop(table(:sca_attachment))
    drop(table(:sco_opportunity))
    drop(table(:csp_pipeline))
    drop(table(:scp_person))
    drop(table(:scc_company))
  end
end
