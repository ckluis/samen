defmodule Driftwood.Repo.Migrations.MountOperatorScopes do
  @moduledoc """
  Mounts the OPERATOR namespace (ADR-010 §8.2) into the Driftwood host's one Postgres:
  a SECOND mount of Identity + Billing + Support whose rows describe the SaaS company's OWN
  book of business — its tenant-org ACCOUNTS, their tenant-ADMINS (PII the SaaS owns, CLEAR),
  each tenant's subscription-to-the-SaaS, and the tickets tenants file WITH the SaaS.

  Fresh `do*` (Identity) / `dp*` (Billing) / `dq*` (Support) abbrevs — append-only registry
  rows for the operator namespace. Catalogued in the SAME transaction (ADR-004 catalog-in-tx).

  PII columns hold vault `vt_*` tokens (plaintext never lands here):
    * `dou_user.dou_full_name` / `dou_user.dou_emails`  — the tenant-admin's name/email
    * `dpc_customer.pii_dpc_billing_name` / `pii_dpc_billing_email`
    * `dqg_agent.dqg_full_name` / `pii_dqg_email`, `dqm_message.pii_dqm_body`
  """
  use Samen.Migration

  @resources [
    # Identity (operator: accounts + admins)
    Driftwood.Operator.Org,
    Driftwood.Operator.User,
    Driftwood.Operator.Membership,
    Driftwood.Operator.Role,
    Driftwood.Operator.ApiKey,
    Driftwood.Operator.Invitation,
    # Billing (operator: tenant subscriptions-to-the-SaaS)
    Driftwood.Operator.Customer,
    Driftwood.Operator.Subscription,
    Driftwood.Operator.Plan,
    Driftwood.Operator.Price,
    Driftwood.Operator.Invoice,
    Driftwood.Operator.Payment,
    Driftwood.Operator.Usage,
    Driftwood.Operator.Entitlement,
    # Support (operator: tenant-filed desk tickets)
    Driftwood.Operator.Sla,
    Driftwood.Operator.Ticket,
    Driftwood.Operator.Conversation,
    Driftwood.Operator.Agent,
    Driftwood.Operator.Message,
    Driftwood.Operator.Macro,
    Driftwood.Operator.Csat
  ]

  def up do
    # =========================================================================
    # IDENTITY — accounts (Org) + admins (User) + membership + role/key/invite
    # =========================================================================

    # --- doo_org : the tenant anchor. Here: an ACCOUNT (a tenant org mirrored). The
    #     `doo_slug` carries the tenant_org_id back-reference (ADR-010 Bridge-B join key). ---
    create table(:doo_org, primary_key: false) do
      add(:doo_name, :text, null: false)
      add(:doo_slug, :text)
      add(:doo_plan, :text, default: "free")
      add(:doo_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:doo_org_id, :uuid)
      add(:doo_inserted_at, :utc_datetime, null: false)
      add(:doo_updated_at, :utc_datetime, null: false)
    end

    # --- dou_user : the tenant-ADMIN 🔒 (full_name/emails vault-routed; the SaaS's OWN
    #     signup contact — CLEAR to the operator on its own tenant plane). ---
    create table(:dou_user, primary_key: false) do
      add(:dou_handle, :text)
      add(:dou_status, :text, default: "active")
      add(:dou_full_name, :text)
      add(:dou_emails, :text)
      add(:dou_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:dou_org_id, :uuid, null: false)
      add(:dou_inserted_at, :utc_datetime, null: false)
      add(:dou_updated_at, :utc_datetime, null: false)
    end

    # --- dom_membership : (user, org, role) — role == :admin marks a primary contact. ---
    create table(:dom_membership, primary_key: false) do
      add(:dom_role, :text, default: "member")
      add(:dom_status, :text, default: "active")

      add(
        :dom_user_id,
        references(:dou_user,
          column: :dou_id,
          name: "dom_membership_dom_user_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:dom_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:dom_org_id, :uuid, null: false)
      add(:dom_inserted_at, :utc_datetime, null: false)
      add(:dom_updated_at, :utc_datetime, null: false)
    end

    # --- dor_role : Tier-0 config rows (per-org role catalog) ---
    create table(:dor_role, primary_key: false) do
      add(:dor_name, :text, null: false)
      add(:dor_label, :text)
      add(:dor_rank, :integer, null: false)
      add(:dor_enabled, :boolean, default: true)
      add(:dor_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:dor_org_id, :uuid, null: false)
      add(:dor_inserted_at, :utc_datetime, null: false)
      add(:dor_updated_at, :utc_datetime, null: false)
    end

    # --- dok_api_key : scoped credential (two planes) ---
    create table(:dok_api_key, primary_key: false) do
      add(:dok_token_digest, :text, null: false)
      add(:dok_plane, :text, null: false, default: "tenant")
      add(:dok_scopes, :map, default: fragment("'{}'::jsonb"))
      add(:dok_minter_role, :text)
      add(:dok_revoked_at, :utc_datetime)

      add(
        :dok_membership_id,
        references(:dom_membership,
          column: :dom_id,
          name: "dok_api_key_dok_membership_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:dok_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:dok_org_id, :uuid, null: false)
      add(:dok_inserted_at, :utc_datetime, null: false)
      add(:dok_updated_at, :utc_datetime, null: false)
    end

    # --- don_invitation : a pending invite 🔒 (email vault-routed) ---
    create table(:don_invitation, primary_key: false) do
      add(:don_role, :text, default: "member")
      add(:don_status, :text, default: "pending")
      add(:don_accept_token, :text)
      add(:don_email, :text)
      add(:don_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:don_org_id, :uuid, null: false)
      add(:don_inserted_at, :utc_datetime, null: false)
      add(:don_updated_at, :utc_datetime, null: false)
    end

    # =========================================================================
    # BILLING — each tenant's subscription TO the SaaS
    # =========================================================================

    create table(:dpc_customer, primary_key: false) do
      add(:dpc_stripe_customer_id, :text)
      add(:dpc_status, :text, default: "active")
      add(:dpc_currency, :text, default: "USD")
      add(:dpc_custom, :map, default: fragment("'{}'::jsonb"))
      add(:pii_dpc_billing_name, :text)
      add(:pii_dpc_billing_email, :text)
      add(:dpc_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:dpc_org_id, :uuid, null: false)
      add(:dpc_inserted_at, :utc_datetime, null: false)
      add(:dpc_updated_at, :utc_datetime, null: false)
    end

    create table(:dpp_plan, primary_key: false) do
      add(:dpp_name, :text, null: false)
      add(:dpp_label, :text)
      add(:dpp_description, :text)
      add(:dpp_stripe_plan_id, :text)
      add(:dpp_interval, :text, default: "monthly")
      add(:dpp_enabled, :boolean, default: true)
      add(:dpp_features, :map, default: fragment("'{}'::jsonb"))
      add(:dpp_custom, :map, default: fragment("'{}'::jsonb"))
      add(:dpp_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:dpp_org_id, :uuid, null: false)
      add(:dpp_inserted_at, :utc_datetime, null: false)
      add(:dpp_updated_at, :utc_datetime, null: false)
    end

    create table(:dpr_price, primary_key: false) do
      add(:dpr_stripe_price_id, :text)
      add(:dpr_unit_amount_cents, :integer, null: false)
      add(:dpr_currency, :text, null: false, default: "USD")
      add(:dpr_interval, :text, default: "monthly")
      add(:dpr_active, :boolean, default: true)
      add(:dpr_custom, :map, default: fragment("'{}'::jsonb"))

      add(
        :dpr_plan_id,
        references(:dpp_plan,
          column: :dpp_id,
          name: "dpr_price_dpr_plan_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:dpr_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:dpr_org_id, :uuid, null: false)
      add(:dpr_inserted_at, :utc_datetime, null: false)
      add(:dpr_updated_at, :utc_datetime, null: false)
    end

    create table(:dps_subscription, primary_key: false) do
      add(:dps_stripe_subscription_id, :text)
      add(:dps_status, :text, default: "active")
      add(:dps_current_period_start, :utc_datetime)
      add(:dps_current_period_end, :utc_datetime)
      add(:dps_trial_end, :utc_datetime)
      add(:dps_cancel_at, :utc_datetime)
      add(:dps_cancelled_at, :utc_datetime)
      add(:dps_custom, :map, default: fragment("'{}'::jsonb"))

      add(
        :dps_customer_id,
        references(:dpc_customer,
          column: :dpc_id,
          name: "dps_subscription_dps_customer_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :dps_plan_id,
        references(:dpp_plan,
          column: :dpp_id,
          name: "dps_subscription_dps_plan_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:dps_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:dps_org_id, :uuid, null: false)
      add(:dps_inserted_at, :utc_datetime, null: false)
      add(:dps_updated_at, :utc_datetime, null: false)
    end

    create table(:dpi_invoice, primary_key: false) do
      add(:dpi_stripe_invoice_id, :text)
      add(:dpi_status, :text, default: "draft")
      add(:dpi_amount_due_cents, :integer, default: 0)
      add(:dpi_amount_paid_cents, :integer, default: 0)
      add(:dpi_currency, :text, default: "USD")
      add(:dpi_period_start, :utc_datetime)
      add(:dpi_period_end, :utc_datetime)
      add(:dpi_due_date, :utc_datetime)
      add(:dpi_paid_at, :utc_datetime)
      add(:dpi_line_items, {:array, :map}, default: fragment("ARRAY[]::jsonb[]"))
      add(:dpi_custom, :map, default: fragment("'{}'::jsonb"))

      add(
        :dpi_customer_id,
        references(:dpc_customer,
          column: :dpc_id,
          name: "dpi_invoice_dpi_customer_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :dpi_subscription_id,
        references(:dps_subscription,
          column: :dps_id,
          name: "dpi_invoice_dpi_subscription_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:dpi_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:dpi_org_id, :uuid, null: false)
      add(:dpi_inserted_at, :utc_datetime, null: false)
      add(:dpi_updated_at, :utc_datetime, null: false)
    end

    create table(:dpy_payment, primary_key: false) do
      add(:dpy_stripe_payment_intent_id, :text)
      add(:dpy_status, :text, default: "pending")
      add(:dpy_amount_cents, :integer, null: false)
      add(:dpy_currency, :text, default: "USD")
      add(:dpy_payment_method_type, :text, default: "card")
      add(:dpy_last4, :text)
      add(:dpy_paid_at, :utc_datetime)
      add(:dpy_failure_code, :text)
      add(:dpy_custom, :map, default: fragment("'{}'::jsonb"))

      add(
        :dpy_invoice_id,
        references(:dpi_invoice,
          column: :dpi_id,
          name: "dpy_payment_dpy_invoice_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :dpy_customer_id,
        references(:dpc_customer,
          column: :dpc_id,
          name: "dpy_payment_dpy_customer_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:dpy_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:dpy_org_id, :uuid, null: false)
      add(:dpy_inserted_at, :utc_datetime, null: false)
      add(:dpy_updated_at, :utc_datetime, null: false)
    end

    create table(:dpu_usage, primary_key: false) do
      add(:dpu_metric, :text, null: false)
      add(:dpu_quantity, :integer, default: 0)
      add(:dpu_period_start, :utc_datetime)
      add(:dpu_period_end, :utc_datetime)
      add(:dpu_reported_at, :utc_datetime)

      add(
        :dpu_subscription_id,
        references(:dps_subscription,
          column: :dps_id,
          name: "dpu_usage_dpu_subscription_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:dpu_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:dpu_org_id, :uuid, null: false)
      add(:dpu_inserted_at, :utc_datetime, null: false)
      add(:dpu_updated_at, :utc_datetime, null: false)
    end

    create table(:dpe_entitlement, primary_key: false) do
      add(:dpe_feature, :text, null: false)
      add(:dpe_granted, :boolean, default: true)
      add(:dpe_expires_at, :utc_datetime)
      add(:dpe_custom, :map, default: fragment("'{}'::jsonb"))

      add(
        :dpe_subscription_id,
        references(:dps_subscription,
          column: :dps_id,
          name: "dpe_entitlement_dpe_subscription_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :dpe_plan_id,
        references(:dpp_plan,
          column: :dpp_id,
          name: "dpe_entitlement_dpe_plan_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:dpe_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:dpe_org_id, :uuid, null: false)
      add(:dpe_inserted_at, :utc_datetime, null: false)
      add(:dpe_updated_at, :utc_datetime, null: false)
    end

    # =========================================================================
    # SUPPORT — the SaaS help desk (tenants file tickets WITH the SaaS)
    # =========================================================================

    create table(:dql_sla, primary_key: false) do
      add(:dql_name, :text, null: false)
      add(:dql_label, :text)
      add(:dql_first_response_minutes, :integer, default: 60)
      add(:dql_resolve_minutes, :integer, default: 480)
      add(:dql_priority, :text, default: "normal")
      add(:dql_enabled, :boolean, default: true)
      add(:dql_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:dql_org_id, :uuid, null: false)
      add(:dql_inserted_at, :utc_datetime, null: false)
      add(:dql_updated_at, :utc_datetime, null: false)
    end

    # The ticket's `dqk_custom` bag carries the requester back-references
    # (`requester_org_id` → account Org, `requester_user_id` → tenant-admin User).
    create table(:dqk_ticket, primary_key: false) do
      add(:dqk_subject, :text, null: false)
      add(:dqk_status, :text, default: "open")
      add(:dqk_priority, :text, default: "normal")
      add(:dqk_sla_breach_at, :utc_datetime)
      add(:dqk_breached, :boolean, default: false, null: false)
      add(:dqk_resolved_at, :utc_datetime)
      add(:dqk_closed_at, :utc_datetime)
      add(:dqk_tags, {:array, :text}, default: [])
      add(:dqk_custom, :map, default: fragment("'{}'::jsonb"))
      add(:dqk_external_id, :text)

      add(
        :dqk_sla_id,
        references(:dql_sla,
          column: :dql_id,
          name: "dqk_ticket_dqk_sla_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:dqk_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:dqk_org_id, :uuid, null: false)
      add(:dqk_inserted_at, :utc_datetime, null: false)
      add(:dqk_updated_at, :utc_datetime, null: false)
    end

    create(
      index(:dqk_ticket, [:dqk_sla_breach_at, :dqk_breached],
        name: "dqk_ticket_sla_breach_idx",
        where: "dqk_sla_breach_at IS NOT NULL AND dqk_breached = false"
      )
    )

    create table(:dqc_conversation, primary_key: false) do
      add(:dqc_channel, :text, default: "email")
      add(:dqc_status, :text, default: "open")
      add(:dqc_subject, :text)

      add(
        :dqc_ticket_id,
        references(:dqk_ticket,
          column: :dqk_id,
          name: "dqc_conversation_dqc_ticket_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )

      add(:dqc_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:dqc_org_id, :uuid, null: false)
      add(:dqc_inserted_at, :utc_datetime, null: false)
      add(:dqc_updated_at, :utc_datetime, null: false)
    end

    # The SaaS support AGENT 🔒 (the SaaS's own employee — CLEAR on the operator's own plane).
    create table(:dqg_agent, primary_key: false) do
      add(:dqg_handle, :text)
      add(:dqg_status, :text, default: "active")
      add(:dqg_role, :text, default: "agent")
      add(:dqg_external_id, :text)
      add(:dqg_timezone, :text)
      add(:dqg_custom, :map, default: fragment("'{}'::jsonb"))
      add(:dqg_full_name, :text)
      add(:pii_dqg_email, :text)
      add(:dqg_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:dqg_org_id, :uuid, null: false)
      add(:dqg_inserted_at, :utc_datetime, null: false)
      add(:dqg_updated_at, :utc_datetime, null: false)
    end

    create table(:dqm_message, primary_key: false) do
      add(:dqm_sender_type, :text, default: "customer")
      add(:dqm_sender_id, :uuid)
      add(:dqm_message_type, :text, default: "reply")
      add(:dqm_attachments, {:array, :text}, default: [])
      add(:dqm_created_via, :text, default: "web")
      add(:pii_dqm_body, :text)

      add(
        :dqm_conversation_id,
        references(:dqc_conversation,
          column: :dqc_id,
          name: "dqm_message_dqm_conversation_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )

      add(
        :dqm_agent_id,
        references(:dqg_agent,
          column: :dqg_id,
          name: "dqm_message_dqm_agent_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:dqm_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:dqm_org_id, :uuid, null: false)
      add(:dqm_inserted_at, :utc_datetime, null: false)
      add(:dqm_updated_at, :utc_datetime, null: false)
    end

    create table(:dqn_macro, primary_key: false) do
      add(:dqn_name, :text, null: false)
      add(:dqn_description, :text)
      add(:dqn_body_template, :text)
      add(:dqn_tags, {:array, :text}, default: [])
      add(:dqn_enabled, :boolean, default: true)
      add(:dqn_category, :text)
      add(:dqn_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:dqn_org_id, :uuid, null: false)
      add(:dqn_inserted_at, :utc_datetime, null: false)
      add(:dqn_updated_at, :utc_datetime, null: false)
    end

    create table(:dqs_csat, primary_key: false) do
      add(:dqs_score, :integer, null: false)
      add(:dqs_comments, :text)
      add(:dqs_channel, :text, default: "email")
      add(:dqs_responded_at, :utc_datetime)

      add(
        :dqs_ticket_id,
        references(:dqk_ticket,
          column: :dqk_id,
          name: "dqs_csat_dqs_ticket_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )

      add(
        :dqs_agent_id,
        references(:dqg_agent,
          column: :dqg_id,
          name: "dqs_csat_dqs_agent_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:dqs_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:dqs_org_id, :uuid, null: false)
      add(:dqs_inserted_at, :utc_datetime, null: false)
      add(:dqs_updated_at, :utc_datetime, null: false)
    end

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    # --- Support (reverse FK order) ---
    drop(constraint(:dqs_csat, "dqs_csat_dqs_agent_id_fkey"))
    drop(constraint(:dqs_csat, "dqs_csat_dqs_ticket_id_fkey"))
    drop(table(:dqs_csat))
    drop(table(:dqn_macro))
    drop(constraint(:dqm_message, "dqm_message_dqm_agent_id_fkey"))
    drop(constraint(:dqm_message, "dqm_message_dqm_conversation_id_fkey"))
    drop(table(:dqm_message))
    drop(table(:dqg_agent))
    drop(constraint(:dqc_conversation, "dqc_conversation_dqc_ticket_id_fkey"))
    drop(table(:dqc_conversation))
    drop(index(:dqk_ticket, [:dqk_sla_breach_at, :dqk_breached], name: "dqk_ticket_sla_breach_idx"))
    drop(constraint(:dqk_ticket, "dqk_ticket_dqk_sla_id_fkey"))
    drop(table(:dqk_ticket))
    drop(table(:dql_sla))

    # --- Billing (reverse FK order) ---
    drop(constraint(:dpe_entitlement, "dpe_entitlement_dpe_plan_id_fkey"))
    drop(constraint(:dpe_entitlement, "dpe_entitlement_dpe_subscription_id_fkey"))
    drop(table(:dpe_entitlement))
    drop(constraint(:dpu_usage, "dpu_usage_dpu_subscription_id_fkey"))
    drop(table(:dpu_usage))
    drop(constraint(:dpy_payment, "dpy_payment_dpy_customer_id_fkey"))
    drop(constraint(:dpy_payment, "dpy_payment_dpy_invoice_id_fkey"))
    drop(table(:dpy_payment))
    drop(constraint(:dpi_invoice, "dpi_invoice_dpi_subscription_id_fkey"))
    drop(constraint(:dpi_invoice, "dpi_invoice_dpi_customer_id_fkey"))
    drop(table(:dpi_invoice))
    drop(constraint(:dps_subscription, "dps_subscription_dps_plan_id_fkey"))
    drop(constraint(:dps_subscription, "dps_subscription_dps_customer_id_fkey"))
    drop(table(:dps_subscription))
    drop(constraint(:dpr_price, "dpr_price_dpr_plan_id_fkey"))
    drop(table(:dpr_price))
    drop(table(:dpp_plan))
    drop(table(:dpc_customer))

    # --- Identity (reverse FK order) ---
    drop(constraint(:dok_api_key, "dok_api_key_dok_membership_id_fkey"))
    drop(table(:dok_api_key))
    drop(table(:don_invitation))
    drop(table(:dor_role))
    drop(constraint(:dom_membership, "dom_membership_dom_user_id_fkey"))
    drop(table(:dom_membership))
    drop(table(:dou_user))
    drop(table(:doo_org))
  end
end
