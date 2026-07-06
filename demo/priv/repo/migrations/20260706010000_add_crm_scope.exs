defmodule Demo.Repo.Migrations.AddCrmScope do
  @moduledoc """
  Mounts the CRM scope tables into the Demo host's one Postgres, and catalogs
  them in the SAME migration transaction (ADR-004 §"Migrations": the
  catalog-in-tx guarantee requires DDL + catalog_sync in one transaction in the
  host's repo).

  Resources:
    * `cmp_company`     — a B2B company record (no PII)
    * `per_person`      — a CRM person 🔒 (full_name/emails/phones vault-routed)
    * `pip_pipeline`    — Tier-0 config rows (deal-stage catalog per org)
    * `opp_opportunity` — a deal linked to company + pipeline stage
    * `act_activity`    — call/email/meeting/note linked to any CRM object
    * `att_attachment`  — file reference linked to any CRM object

  The `per_person` table is the canonical vault case from the vision doc
  (§core "The proof — one base, many shapes"): it composes
  `Samen.Fragments.CorePerson`, so `per_full_name`, `per_emails`, `per_phones`
  hold vault `vt_*` tokens — plaintext never lands here.

  Pipeline stages (pip_stage_type) are Tier-0 config rows seeded in
  `Demo.Repo.Seeds.CrmScope.run/1` (called from the host's seed task).
  """
  use Samen.Migration

  @resources [
    Demo.CrmScope.Company,
    Demo.CrmScope.Person,
    Demo.CrmScope.Pipeline,
    Demo.CrmScope.Opportunity,
    Demo.CrmScope.Activity,
    Demo.CrmScope.Attachment
  ]

  def up do
    # --- cmp_company : a B2B company record (no PII) ---
    create table(:cmp_company, primary_key: false) do
      add(:cmp_name, :text, null: false)
      add(:cmp_domain, :text)
      add(:cmp_industry, :text)
      add(:cmp_size, :text)
      add(:cmp_website, :text)
      add(:cmp_notes, :text)
      add(:cmp_custom, :map, default: fragment("'{}'::jsonb"))
      add(:cmp_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:cmp_org_id, :uuid, null: false)
      add(:cmp_inserted_at, :utc_datetime, null: false)
      add(:cmp_updated_at, :utc_datetime, null: false)
    end

    # --- per_person : CRM person 🔒 (Core.Person fragment folded in) ---
    # per_full_name, per_emails, per_phones are composite PII → vault vt_* tokens.
    # per_job_title and per_custom come from the Core.Person fragment.
    create table(:per_person, primary_key: false) do
      add(:per_display_name, :text)
      # Composite PII token columns (vault-routed, stored as vt_* tokens):
      add(:per_full_name, :text)
      add(:per_emails, :text)
      add(:per_phones, :text)
      # Non-PII fragment columns:
      add(:per_job_title, :text)
      add(:per_custom, :map, default: fragment("'{}'::jsonb"))

      add(
        :per_company_id,
        references(:cmp_company,
          column: :cmp_id,
          name: "per_person_per_company_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:per_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:per_org_id, :uuid, null: false)
      add(:per_inserted_at, :utc_datetime, null: false)
      add(:per_updated_at, :utc_datetime, null: false)
    end

    # --- pip_pipeline : Tier-0 config rows (deal-stage catalog per org) ---
    create table(:pip_pipeline, primary_key: false) do
      add(:pip_name, :text, null: false)
      add(:pip_label, :text)
      add(:pip_stage_order, :integer, default: 0)
      add(:pip_enabled, :boolean, default: true)
      add(:pip_stage_type, :text, default: "open")
      add(:pip_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:pip_org_id, :uuid, null: false)
      add(:pip_inserted_at, :utc_datetime, null: false)
      add(:pip_updated_at, :utc_datetime, null: false)
    end

    # --- opp_opportunity : a deal/opportunity record ---
    create table(:opp_opportunity, primary_key: false) do
      add(:opp_name, :text, null: false)
      add(:opp_value_cents, :integer, default: 0)
      add(:opp_currency, :text, default: "USD")
      add(:opp_probability, :integer, default: 0)
      add(:opp_status, :text, default: "open")
      add(:opp_close_date, :date)
      add(:opp_notes, :text)
      add(:opp_custom, :map, default: fragment("'{}'::jsonb"))

      add(
        :opp_company_id,
        references(:cmp_company,
          column: :cmp_id,
          name: "opp_opportunity_opp_company_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :opp_pipeline_id,
        references(:pip_pipeline,
          column: :pip_id,
          name: "opp_opportunity_opp_pipeline_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:opp_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:opp_org_id, :uuid, null: false)
      add(:opp_inserted_at, :utc_datetime, null: false)
      add(:opp_updated_at, :utc_datetime, null: false)
    end

    # --- act_activity : a CRM activity (call/email/meeting/note) ---
    create table(:act_activity, primary_key: false) do
      add(:act_type, :text, null: false)
      add(:act_subject, :text)
      add(:act_body, :text)
      add(:act_status, :text, default: "pending")
      add(:act_due_at, :utc_datetime)
      add(:act_completed_at, :utc_datetime)
      add(:act_custom, :map, default: fragment("'{}'::jsonb"))

      add(
        :act_company_id,
        references(:cmp_company,
          column: :cmp_id,
          name: "act_activity_act_company_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :act_person_id,
        references(:per_person,
          column: :per_id,
          name: "act_activity_act_person_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :act_opportunity_id,
        references(:opp_opportunity,
          column: :opp_id,
          name: "act_activity_act_opportunity_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:act_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:act_org_id, :uuid, null: false)
      add(:act_inserted_at, :utc_datetime, null: false)
      add(:act_updated_at, :utc_datetime, null: false)
    end

    # --- att_attachment : a file reference linked to any CRM object ---
    create table(:att_attachment, primary_key: false) do
      add(:att_file_name, :text, null: false)
      add(:att_content_type, :text)
      add(:att_size_bytes, :integer)
      add(:att_storage_key, :text)

      add(
        :att_company_id,
        references(:cmp_company,
          column: :cmp_id,
          name: "att_attachment_att_company_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :att_person_id,
        references(:per_person,
          column: :per_id,
          name: "att_attachment_att_person_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :att_opportunity_id,
        references(:opp_opportunity,
          column: :opp_id,
          name: "att_attachment_att_opportunity_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:att_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:att_org_id, :uuid, null: false)
      add(:att_inserted_at, :utc_datetime, null: false)
      add(:att_updated_at, :utc_datetime, null: false)
    end

    # --- catalog all six CRM resources in THIS transaction ---
    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    # Drop in reverse FK order.
    drop(constraint(:att_attachment, "att_attachment_att_opportunity_id_fkey"))
    drop(constraint(:att_attachment, "att_attachment_att_person_id_fkey"))
    drop(constraint(:att_attachment, "att_attachment_att_company_id_fkey"))
    drop(table(:att_attachment))

    drop(constraint(:act_activity, "act_activity_act_opportunity_id_fkey"))
    drop(constraint(:act_activity, "act_activity_act_person_id_fkey"))
    drop(constraint(:act_activity, "act_activity_act_company_id_fkey"))
    drop(table(:act_activity))

    drop(constraint(:opp_opportunity, "opp_opportunity_opp_pipeline_id_fkey"))
    drop(constraint(:opp_opportunity, "opp_opportunity_opp_company_id_fkey"))
    drop(table(:opp_opportunity))

    drop(table(:pip_pipeline))

    drop(constraint(:per_person, "per_person_per_company_id_fkey"))
    drop(table(:per_person))

    drop(table(:cmp_company))
  end
end
