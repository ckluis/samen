defmodule PawChart.Repo.Migrations.PawchartCrmSupportScopes do
  @moduledoc """
  Mounts the inherited CRM + Support universal scopes into PawChart's Postgres
  (product thesis "inherit the 80%"), and catalogs every resource in the SAME
  migration transaction (ADR-004 catalog-in-tx).

  Fresh `vc*` abbrevs for CRM (vet-CRM) and `vs*` abbrevs for Support (vet-support)
  are reserved in the global registry (append-only). This is the additive proof:
  PawChart mounts BOTH scopes AS-IS with ZERO reshape.

  ## CRM tables (abbrevs vca/vcb/vcc/vcd/vce/vcf)

    * `vca_company`     — clinic CRM companies (referring vets, labs, vendors). No PII.
    * `vcb_person`      — 🔒 clinic contacts (CorePerson folded in; full_name/emails/phones
      vault-routed as composite tokens — no pii_ prefix per the composite rule).
    * `vcc_pipeline`    — Tier-0 config rows: clinic onboarding pipeline stages.
    * `vcd_opportunity` — pipeline deals/prospects.
    * `vce_activity`    — call-logs, follow-ups.
    * `vcf_attachment`  — file refs (referral letters, insurance forms).

  ## Support tables (abbrevs vsa/vsb/vsc/vsd/vse/vsf/vsg)

    * `vse_sla`          — Tier-0 config rows: SLA policies per org.
    * `vsa_ticket`       — the top-level support ticket. No PII in header.
    * `vsb_conversation` — a conversation thread on a ticket. No PII.
    * `vsd_agent`        — 🔒 full_name (composite vault token) + pii_vsd_email (scalar).
    * `vsc_message`      — 🔒 pii_vsc_body (scalar vault token; free-text body).
    * `vsf_macro`        — Tier-0 canned response macros.
    * `vsg_csat`         — customer satisfaction survey responses.

  ## PII columns (vault vt_* tokens — plaintext never lands here)

  - `vcb_person.vcb_full_name`   — composite vault token (VaultField; no pii_ prefix)
  - `vcb_person.vcb_emails`      — composite vault token (no pii_ prefix)
  - `vcb_person.vcb_phones`      — composite vault token (no pii_ prefix)
  - `vsd_agent.vsd_full_name`    — composite vault token (no pii_ prefix)
  - `vsd_agent.pii_vsd_email`    — scalar vault token (pii_ prefix)
  - `vsc_message.pii_vsc_body`   — scalar vault token (pii_ prefix; free-text)

  FK order:
    CRM:     vca_company ← vcb_person ← vce_activity/vcf_attachment
             vca_company/vcc_pipeline ← vcd_opportunity
    Support: vse_sla ← vsa_ticket ← vsb_conversation ← vsc_message → vsd_agent
             vsa_ticket ← vsg_csat → vsd_agent
  """
  use Samen.Migration

  @resources [
    # CRM
    PawChart.Crm.Company,
    PawChart.Crm.Person,
    PawChart.Crm.Pipeline,
    PawChart.Crm.Opportunity,
    PawChart.Crm.Activity,
    PawChart.Crm.Attachment,
    # Support
    PawChart.Support.Sla,
    PawChart.Support.Ticket,
    PawChart.Support.Conversation,
    PawChart.Support.Agent,
    PawChart.Support.Message,
    PawChart.Support.Macro,
    PawChart.Support.Csat
  ]

  def up do
    # =========================================================================
    # CRM
    # =========================================================================

    # --- vca_company : clinic CRM company rows (referring vets, labs, vendors) ---
    create table(:vca_company, primary_key: false) do
      add(:vca_name, :text, null: false)
      add(:vca_domain, :text)
      add(:vca_industry, :text)
      add(:vca_size, :text)
      add(:vca_website, :text)
      add(:vca_notes, :text)
      add(:vca_custom, :map, default: fragment("'{}'::jsonb"))
      add(:vca_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:vca_org_id, :uuid, null: false)
      add(:vca_inserted_at, :utc_datetime, null: false)
      add(:vca_updated_at, :utc_datetime, null: false)
    end

    # --- vcb_person : 🔒 clinic contact (CorePerson folded in — composite vault tokens) ---
    create table(:vcb_person, primary_key: false) do
      add(:vcb_display_name, :text)
      # Composite PII vault tokens (VaultField; no pii_ prefix per the composite rule):
      add(:vcb_full_name, :text)
      add(:vcb_emails, :text)
      add(:vcb_phones, :text)
      add(:vcb_job_title, :text)
      add(:vcb_custom, :map, default: fragment("'{}'::jsonb"))

      add(
        :vcb_company_id,
        references(:vca_company,
          column: :vca_id,
          name: "vcb_person_vcb_company_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:vcb_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:vcb_org_id, :uuid, null: false)
      add(:vcb_inserted_at, :utc_datetime, null: false)
      add(:vcb_updated_at, :utc_datetime, null: false)
    end

    # --- vcc_pipeline : clinic onboarding pipeline stages (Tier-0 config rows) ---
    create table(:vcc_pipeline, primary_key: false) do
      add(:vcc_name, :text, null: false)
      add(:vcc_label, :text)
      add(:vcc_stage_order, :integer, default: 0)
      add(:vcc_enabled, :boolean, default: true)
      add(:vcc_stage_type, :text, default: "open")
      add(:vcc_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:vcc_org_id, :uuid, null: false)
      add(:vcc_inserted_at, :utc_datetime, null: false)
      add(:vcc_updated_at, :utc_datetime, null: false)
    end

    # --- vcd_opportunity : pipeline deals/prospects ---
    create table(:vcd_opportunity, primary_key: false) do
      add(:vcd_name, :text, null: false)
      add(:vcd_value_cents, :integer, default: 0)
      add(:vcd_currency, :text, default: "USD")
      add(:vcd_probability, :integer, default: 0)
      add(:vcd_status, :text, default: "open")
      add(:vcd_close_date, :date)
      add(:vcd_notes, :text)
      add(:vcd_custom, :map, default: fragment("'{}'::jsonb"))

      add(
        :vcd_company_id,
        references(:vca_company,
          column: :vca_id,
          name: "vcd_opportunity_vcd_company_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :vcd_pipeline_id,
        references(:vcc_pipeline,
          column: :vcc_id,
          name: "vcd_opportunity_vcd_pipeline_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:vcd_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:vcd_org_id, :uuid, null: false)
      add(:vcd_inserted_at, :utc_datetime, null: false)
      add(:vcd_updated_at, :utc_datetime, null: false)
    end

    # --- vce_activity : call-logs, follow-ups against the pipeline ---
    create table(:vce_activity, primary_key: false) do
      add(:vce_type, :text, null: false)
      add(:vce_subject, :text)
      add(:vce_body, :text)
      add(:vce_status, :text, default: "pending")
      add(:vce_due_at, :utc_datetime)
      add(:vce_completed_at, :utc_datetime)
      add(:vce_custom, :map, default: fragment("'{}'::jsonb"))

      add(
        :vce_company_id,
        references(:vca_company,
          column: :vca_id,
          name: "vce_activity_vce_company_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :vce_person_id,
        references(:vcb_person,
          column: :vcb_id,
          name: "vce_activity_vce_person_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :vce_opportunity_id,
        references(:vcd_opportunity,
          column: :vcd_id,
          name: "vce_activity_vce_opportunity_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:vce_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:vce_org_id, :uuid, null: false)
      add(:vce_inserted_at, :utc_datetime, null: false)
      add(:vce_updated_at, :utc_datetime, null: false)
    end

    # --- vcf_attachment : file refs (referral letters, insurance forms) ---
    create table(:vcf_attachment, primary_key: false) do
      add(:vcf_file_name, :text, null: false)
      add(:vcf_content_type, :text)
      add(:vcf_size_bytes, :integer)
      add(:vcf_storage_key, :text)

      add(
        :vcf_company_id,
        references(:vca_company,
          column: :vca_id,
          name: "vcf_attachment_vcf_company_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :vcf_person_id,
        references(:vcb_person,
          column: :vcb_id,
          name: "vcf_attachment_vcf_person_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :vcf_opportunity_id,
        references(:vcd_opportunity,
          column: :vcd_id,
          name: "vcf_attachment_vcf_opportunity_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:vcf_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:vcf_org_id, :uuid, null: false)
      add(:vcf_inserted_at, :utc_datetime, null: false)
      add(:vcf_updated_at, :utc_datetime, null: false)
    end

    # =========================================================================
    # SUPPORT
    # =========================================================================

    # --- vse_sla : Tier-0 SLA policy rows per org ---
    create table(:vse_sla, primary_key: false) do
      add(:vse_name, :text, null: false)
      add(:vse_label, :text)
      add(:vse_first_response_minutes, :integer, default: 60)
      add(:vse_resolve_minutes, :integer, default: 480)
      add(:vse_priority, :text, default: "normal")
      add(:vse_enabled, :boolean, default: true)
      add(:vse_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:vse_org_id, :uuid, null: false)
      add(:vse_inserted_at, :utc_datetime, null: false)
      add(:vse_updated_at, :utc_datetime, null: false)
    end

    # --- vsa_ticket : the top-level support ticket (no PII in header) ---
    create table(:vsa_ticket, primary_key: false) do
      add(:vsa_subject, :text, null: false)
      add(:vsa_status, :text, default: "open")
      add(:vsa_priority, :text, default: "normal")
      add(:vsa_sla_breach_at, :utc_datetime)
      add(:vsa_breached, :boolean, default: false, null: false)
      add(:vsa_resolved_at, :utc_datetime)
      add(:vsa_closed_at, :utc_datetime)
      add(:vsa_tags, {:array, :text}, default: [])
      add(:vsa_custom, :map, default: fragment("'{}'::jsonb"))
      add(:vsa_external_id, :text)

      add(
        :vsa_sla_id,
        references(:vse_sla,
          column: :vse_id,
          name: "vsa_ticket_vsa_sla_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:vsa_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:vsa_org_id, :uuid, null: false)
      add(:vsa_inserted_at, :utc_datetime, null: false)
      add(:vsa_updated_at, :utc_datetime, null: false)
    end

    # Index for the SlaBreachWorker cron.
    create(
      index(:vsa_ticket, [:vsa_sla_breach_at, :vsa_breached],
        name: "vsa_ticket_sla_breach_idx",
        where: "vsa_sla_breach_at IS NOT NULL AND vsa_breached = false"
      )
    )

    # --- vsb_conversation : a conversation thread on a ticket (no PII) ---
    create table(:vsb_conversation, primary_key: false) do
      add(:vsb_channel, :text, default: "email")
      add(:vsb_status, :text, default: "open")
      add(:vsb_subject, :text)

      add(
        :vsb_ticket_id,
        references(:vsa_ticket,
          column: :vsa_id,
          name: "vsb_conversation_vsb_ticket_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )

      add(:vsb_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:vsb_org_id, :uuid, null: false)
      add(:vsb_inserted_at, :utc_datetime, null: false)
      add(:vsb_updated_at, :utc_datetime, null: false)
    end

    # --- vsd_agent : 🔒 PII: full_name (composite vault token) + pii_vsd_email (scalar) ---
    create table(:vsd_agent, primary_key: false) do
      add(:vsd_handle, :text)
      add(:vsd_status, :text, default: "active")
      add(:vsd_role, :text, default: "agent")
      add(:vsd_external_id, :text)
      add(:vsd_timezone, :text)
      add(:vsd_custom, :map, default: fragment("'{}'::jsonb"))
      # Composite PII vault token (VaultField; no pii_ prefix):
      add(:vsd_full_name, :text)
      # Scalar PII vault token (pii_ prefix):
      add(:pii_vsd_email, :text)
      add(:vsd_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:vsd_org_id, :uuid, null: false)
      add(:vsd_inserted_at, :utc_datetime, null: false)
      add(:vsd_updated_at, :utc_datetime, null: false)
    end

    # --- vsc_message : 🔒 PII: pii_vsc_body (scalar vault token; free-text body) ---
    create table(:vsc_message, primary_key: false) do
      add(:vsc_sender_type, :text, default: "customer")
      add(:vsc_sender_id, :uuid)
      add(:vsc_message_type, :text, default: "reply")
      add(:vsc_attachments, {:array, :text}, default: [])
      add(:vsc_created_via, :text, default: "web")
      # Scalar PII vault token: body carries the pii_ prefix (pii_vsc_body).
      add(:pii_vsc_body, :text)

      add(
        :vsc_conversation_id,
        references(:vsb_conversation,
          column: :vsb_id,
          name: "vsc_message_vsc_conversation_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )

      add(
        :vsc_agent_id,
        references(:vsd_agent,
          column: :vsd_id,
          name: "vsc_message_vsc_agent_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:vsc_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:vsc_org_id, :uuid, null: false)
      add(:vsc_inserted_at, :utc_datetime, null: false)
      add(:vsc_updated_at, :utc_datetime, null: false)
    end

    # --- vsf_macro : Tier-0 canned response macros per org ---
    create table(:vsf_macro, primary_key: false) do
      add(:vsf_name, :text, null: false)
      add(:vsf_description, :text)
      add(:vsf_body_template, :text)
      add(:vsf_tags, {:array, :text}, default: [])
      add(:vsf_enabled, :boolean, default: true)
      add(:vsf_category, :text)
      add(:vsf_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:vsf_org_id, :uuid, null: false)
      add(:vsf_inserted_at, :utc_datetime, null: false)
      add(:vsf_updated_at, :utc_datetime, null: false)
    end

    # --- vsg_csat : customer satisfaction survey responses ---
    create table(:vsg_csat, primary_key: false) do
      add(:vsg_score, :integer, null: false)
      add(:vsg_comments, :text)
      add(:vsg_channel, :text, default: "email")
      add(:vsg_responded_at, :utc_datetime)

      add(
        :vsg_ticket_id,
        references(:vsa_ticket,
          column: :vsa_id,
          name: "vsg_csat_vsg_ticket_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )

      add(
        :vsg_agent_id,
        references(:vsd_agent,
          column: :vsd_id,
          name: "vsg_csat_vsg_agent_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:vsg_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:vsg_org_id, :uuid, null: false)
      add(:vsg_inserted_at, :utc_datetime, null: false)
      add(:vsg_updated_at, :utc_datetime, null: false)
    end

    # --- catalog all 13 CRM + Support resources in THIS transaction ---
    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    # --- Support (reverse FK order) ---
    drop(constraint(:vsg_csat, "vsg_csat_vsg_agent_id_fkey"))
    drop(constraint(:vsg_csat, "vsg_csat_vsg_ticket_id_fkey"))
    drop(table(:vsg_csat))

    drop(table(:vsf_macro))

    drop(constraint(:vsc_message, "vsc_message_vsc_agent_id_fkey"))
    drop(constraint(:vsc_message, "vsc_message_vsc_conversation_id_fkey"))
    drop(table(:vsc_message))

    drop(table(:vsd_agent))

    drop(constraint(:vsb_conversation, "vsb_conversation_vsb_ticket_id_fkey"))
    drop(table(:vsb_conversation))

    drop(index(:vsa_ticket, [:vsa_sla_breach_at, :vsa_breached], name: "vsa_ticket_sla_breach_idx"))
    drop(constraint(:vsa_ticket, "vsa_ticket_vsa_sla_id_fkey"))
    drop(table(:vsa_ticket))

    drop(table(:vse_sla))

    # --- CRM (reverse FK order) ---
    drop(constraint(:vcf_attachment, "vcf_attachment_vcf_opportunity_id_fkey"))
    drop(constraint(:vcf_attachment, "vcf_attachment_vcf_person_id_fkey"))
    drop(constraint(:vcf_attachment, "vcf_attachment_vcf_company_id_fkey"))
    drop(table(:vcf_attachment))

    drop(constraint(:vce_activity, "vce_activity_vce_opportunity_id_fkey"))
    drop(constraint(:vce_activity, "vce_activity_vce_person_id_fkey"))
    drop(constraint(:vce_activity, "vce_activity_vce_company_id_fkey"))
    drop(table(:vce_activity))

    drop(constraint(:vcd_opportunity, "vcd_opportunity_vcd_pipeline_id_fkey"))
    drop(constraint(:vcd_opportunity, "vcd_opportunity_vcd_company_id_fkey"))
    drop(table(:vcd_opportunity))

    drop(table(:vcc_pipeline))

    drop(constraint(:vcb_person, "vcb_person_vcb_company_id_fkey"))
    drop(table(:vcb_person))

    drop(table(:vca_company))
  end
end
