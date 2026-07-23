defmodule Samen.WebTest.Repo.Migrations.MountOperatorScopes do
  @moduledoc """
  Mounts the OPERATOR namespace (ADR-010 §8.2) into the samen_web test host's one Postgres:
  a SECOND mount of Identity + Billing + Support whose rows describe the SaaS company's OWN
  book of business — its tenant-org ACCOUNTS, their tenant-ADMINS (PII the SaaS owns, CLEAR),
  each tenant's subscription-to-the-SaaS, and the tickets tenants file WITH the SaaS.

  Fresh `wo*` (Identity) / `wp*` (Billing) / `wq*` (Support) abbrevs — append-only registry
  rows for the operator test host. Catalogued in the SAME transaction (ADR-004 catalog-in-tx).

  PII columns hold vault `vt_*` tokens (plaintext never lands here):
    * `wou_user.wou_full_name` / `wou_user.wou_emails`  — the tenant-admin's name/email
    * `wpc_customer.pii_wpc_billing_name` / `pii_wpc_billing_email`
    * `wqg_agent.wqg_full_name` / `pii_wqg_email`, `wqm_message.pii_wqm_body`
  """
  use Samen.Migration

  @resources [
    # Identity (operator: accounts + admins)
    Samen.WebTest.Operator.Org,
    Samen.WebTest.Operator.User,
    Samen.WebTest.Operator.Membership,
    Samen.WebTest.Operator.Role,
    Samen.WebTest.Operator.ApiKey,
    Samen.WebTest.Operator.Invitation,
    # Billing (operator: tenant subscriptions-to-the-SaaS)
    Samen.WebTest.Operator.Customer,
    Samen.WebTest.Operator.Subscription,
    Samen.WebTest.Operator.Plan,
    Samen.WebTest.Operator.Price,
    Samen.WebTest.Operator.Invoice,
    Samen.WebTest.Operator.Payment,
    Samen.WebTest.Operator.Usage,
    Samen.WebTest.Operator.Entitlement,
    # Support (operator: tenant-filed desk tickets)
    Samen.WebTest.Operator.Sla,
    Samen.WebTest.Operator.Ticket,
    Samen.WebTest.Operator.Conversation,
    Samen.WebTest.Operator.Agent,
    Samen.WebTest.Operator.Message,
    Samen.WebTest.Operator.Macro,
    Samen.WebTest.Operator.Csat
  ]

  def up do
    # =========================================================================
    # IDENTITY — accounts (Org) + admins (User) + membership + role/key/invite
    # =========================================================================

    # --- woo_org : the tenant anchor. Here: an ACCOUNT (a tenant org mirrored). The
    #     `woo_slug` carries the tenant_org_id back-reference (ADR-010 Bridge-B join key). ---
    create table(:woo_org, primary_key: false) do
      add(:woo_name, :text, null: false)
      add(:woo_slug, :text)
      add(:woo_plan, :text, default: "free")
      add(:woo_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:woo_org_id, :uuid)
      add(:woo_inserted_at, :utc_datetime, null: false)
      add(:woo_updated_at, :utc_datetime, null: false)
    end

    # --- wou_user : the tenant-ADMIN 🔒 (full_name/emails vault-routed; the SaaS's OWN
    #     signup contact — CLEAR to the operator on its own tenant plane). ---
    create table(:wou_user, primary_key: false) do
      add(:wou_handle, :text)
      add(:wou_status, :text, default: "active")
      add(:wou_full_name, :text)
      add(:wou_emails, :text)
      add(:wou_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wou_org_id, :uuid, null: false)
      add(:wou_inserted_at, :utc_datetime, null: false)
      add(:wou_updated_at, :utc_datetime, null: false)
    end

    # --- wom_membership : (user, org, role) — role == :admin marks a primary contact. ---
    create table(:wom_membership, primary_key: false) do
      add(:wom_role, :text, default: "member")
      add(:wom_status, :text, default: "active")

      add(
        :wom_user_id,
        references(:wou_user,
          column: :wou_id,
          name: "wom_membership_wom_user_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:wom_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wom_org_id, :uuid, null: false)
      add(:wom_inserted_at, :utc_datetime, null: false)
      add(:wom_updated_at, :utc_datetime, null: false)
    end

    # --- wor_role : Tier-0 config rows (per-org role catalog) ---
    create table(:wor_role, primary_key: false) do
      add(:wor_name, :text, null: false)
      add(:wor_label, :text)
      add(:wor_rank, :integer, null: false)
      add(:wor_enabled, :boolean, default: true)
      add(:wor_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wor_org_id, :uuid, null: false)
      add(:wor_inserted_at, :utc_datetime, null: false)
      add(:wor_updated_at, :utc_datetime, null: false)
    end

    # --- wok_api_key : scoped credential (two planes) ---
    create table(:wok_api_key, primary_key: false) do
      add(:wok_token_digest, :text, null: false)
      add(:wok_plane, :text, null: false, default: "tenant")
      add(:wok_scopes, :map, default: fragment("'{}'::jsonb"))
      add(:wok_minter_role, :text)
      add(:wok_revoked_at, :utc_datetime)

      add(
        :wok_membership_id,
        references(:wom_membership,
          column: :wom_id,
          name: "wok_api_key_wok_membership_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:wok_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wok_org_id, :uuid, null: false)
      add(:wok_inserted_at, :utc_datetime, null: false)
      add(:wok_updated_at, :utc_datetime, null: false)
    end

    # --- won_invitation : a pending invite 🔒 (email vault-routed) ---
    create table(:won_invitation, primary_key: false) do
      add(:won_role, :text, default: "member")
      add(:won_status, :text, default: "pending")
      add(:won_accept_token, :text)
      add(:won_email, :text)
      add(:won_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:won_org_id, :uuid, null: false)
      add(:won_inserted_at, :utc_datetime, null: false)
      add(:won_updated_at, :utc_datetime, null: false)
    end

    # =========================================================================
    # BILLING — each tenant's subscription TO the SaaS
    # =========================================================================

    create table(:wpc_customer, primary_key: false) do
      add(:wpc_provider_customer_ref, :text)
      add(:wpc_status, :text, default: "active")
      add(:wpc_currency, :text, default: "USD")
      add(:wpc_custom, :map, default: fragment("'{}'::jsonb"))
      add(:pii_wpc_billing_name, :text)
      add(:pii_wpc_billing_email, :text)
      add(:wpc_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wpc_org_id, :uuid, null: false)
      add(:wpc_inserted_at, :utc_datetime, null: false)
      add(:wpc_updated_at, :utc_datetime, null: false)
    end

    create table(:wpp_plan, primary_key: false) do
      add(:wpp_name, :text, null: false)
      add(:wpp_label, :text)
      add(:wpp_description, :text)
      add(:wpp_provider_plan_ref, :text)
      add(:wpp_interval, :text, default: "monthly")
      add(:wpp_enabled, :boolean, default: true)
      add(:wpp_features, :map, default: fragment("'{}'::jsonb"))
      add(:wpp_custom, :map, default: fragment("'{}'::jsonb"))
      add(:wpp_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wpp_org_id, :uuid, null: false)
      add(:wpp_inserted_at, :utc_datetime, null: false)
      add(:wpp_updated_at, :utc_datetime, null: false)
    end

    create table(:wpr_price, primary_key: false) do
      add(:wpr_provider_price_ref, :text)
      add(:wpr_unit_amount_cents, :integer, null: false)
      add(:wpr_currency, :text, null: false, default: "USD")
      add(:wpr_interval, :text, default: "monthly")
      add(:wpr_active, :boolean, default: true)
      add(:wpr_custom, :map, default: fragment("'{}'::jsonb"))

      add(
        :wpr_plan_id,
        references(:wpp_plan,
          column: :wpp_id,
          name: "wpr_price_wpr_plan_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:wpr_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wpr_org_id, :uuid, null: false)
      add(:wpr_inserted_at, :utc_datetime, null: false)
      add(:wpr_updated_at, :utc_datetime, null: false)
    end

    create table(:wps_subscription, primary_key: false) do
      add(:wps_provider_subscription_ref, :text)
      add(:wps_status, :text, default: "active")
      add(:wps_current_period_start, :utc_datetime)
      add(:wps_current_period_end, :utc_datetime)
      add(:wps_trial_end, :utc_datetime)
      add(:wps_cancel_at, :utc_datetime)
      add(:wps_cancelled_at, :utc_datetime)
      add(:wps_custom, :map, default: fragment("'{}'::jsonb"))

      add(
        :wps_customer_id,
        references(:wpc_customer,
          column: :wpc_id,
          name: "wps_subscription_wps_customer_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :wps_plan_id,
        references(:wpp_plan,
          column: :wpp_id,
          name: "wps_subscription_wps_plan_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:wps_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wps_org_id, :uuid, null: false)
      add(:wps_inserted_at, :utc_datetime, null: false)
      add(:wps_updated_at, :utc_datetime, null: false)
    end

    # T106 decision (e): DB-unique-fence on the provider-subscription-ref — the
    # idempotency guard for the checkout-seeded + lifecycle mirror convergence
    # (ADR-038 addendum). Nullable column, so local rows with no provider ref are
    # unconstrained (Postgres allows multiple NULLs); non-null provider refs collide.
    create(unique_index(:wps_subscription, [:wps_provider_subscription_ref], name: "wps_subscription_provider_ref_index"))

    create table(:wpi_invoice, primary_key: false) do
      add(:wpi_provider_invoice_ref, :text)
      add(:wpi_status, :text, default: "draft")
      add(:wpi_amount_due_cents, :integer, default: 0)
      add(:wpi_amount_paid_cents, :integer, default: 0)
      add(:wpi_currency, :text, default: "USD")
      add(:wpi_period_start, :utc_datetime)
      add(:wpi_period_end, :utc_datetime)
      add(:wpi_due_date, :utc_datetime)
      add(:wpi_paid_at, :utc_datetime)
      add(:wpi_line_items, {:array, :map}, default: fragment("ARRAY[]::jsonb[]"))
      add(:wpi_custom, :map, default: fragment("'{}'::jsonb"))

      add(
        :wpi_customer_id,
        references(:wpc_customer,
          column: :wpc_id,
          name: "wpi_invoice_wpi_customer_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :wpi_subscription_id,
        references(:wps_subscription,
          column: :wps_id,
          name: "wpi_invoice_wpi_subscription_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:wpi_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wpi_org_id, :uuid, null: false)
      add(:wpi_inserted_at, :utc_datetime, null: false)
      add(:wpi_updated_at, :utc_datetime, null: false)
    end

    create table(:wpy_payment, primary_key: false) do
      add(:wpy_provider_payment_ref, :text)
      add(:wpy_status, :text, default: "pending")
      add(:wpy_amount_cents, :integer, null: false)
      add(:wpy_currency, :text, default: "USD")
      add(:wpy_payment_method_type, :text, default: "card")
      add(:wpy_last4, :text)
      add(:wpy_paid_at, :utc_datetime)
      add(:wpy_failure_code, :text)
      add(:wpy_custom, :map, default: fragment("'{}'::jsonb"))

      add(
        :wpy_invoice_id,
        references(:wpi_invoice,
          column: :wpi_id,
          name: "wpy_payment_wpy_invoice_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :wpy_customer_id,
        references(:wpc_customer,
          column: :wpc_id,
          name: "wpy_payment_wpy_customer_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:wpy_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wpy_org_id, :uuid, null: false)
      add(:wpy_inserted_at, :utc_datetime, null: false)
      add(:wpy_updated_at, :utc_datetime, null: false)
    end

    create table(:wpu_usage, primary_key: false) do
      add(:wpu_metric, :text, null: false)
      add(:wpu_quantity, :integer, default: 0)
      add(:wpu_period_start, :utc_datetime)
      add(:wpu_period_end, :utc_datetime)
      add(:wpu_reported_at, :utc_datetime)

      add(
        :wpu_subscription_id,
        references(:wps_subscription,
          column: :wps_id,
          name: "wpu_usage_wpu_subscription_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:wpu_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wpu_org_id, :uuid, null: false)
      add(:wpu_inserted_at, :utc_datetime, null: false)
      add(:wpu_updated_at, :utc_datetime, null: false)
    end

    create table(:wpe_entitlement, primary_key: false) do
      add(:wpe_feature, :text, null: false)
      add(:wpe_granted, :boolean, default: true)
      add(:wpe_expires_at, :utc_datetime)
      add(:wpe_custom, :map, default: fragment("'{}'::jsonb"))

      add(
        :wpe_subscription_id,
        references(:wps_subscription,
          column: :wps_id,
          name: "wpe_entitlement_wpe_subscription_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :wpe_plan_id,
        references(:wpp_plan,
          column: :wpp_id,
          name: "wpe_entitlement_wpe_plan_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:wpe_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wpe_org_id, :uuid, null: false)
      add(:wpe_inserted_at, :utc_datetime, null: false)
      add(:wpe_updated_at, :utc_datetime, null: false)
    end

    # =========================================================================
    # SUPPORT — the SaaS help desk (tenants file tickets WITH the SaaS)
    # =========================================================================

    create table(:wql_sla, primary_key: false) do
      add(:wql_name, :text, null: false)
      add(:wql_label, :text)
      add(:wql_first_response_minutes, :integer, default: 60)
      add(:wql_resolve_minutes, :integer, default: 480)
      add(:wql_priority, :text, default: "normal")
      add(:wql_enabled, :boolean, default: true)
      add(:wql_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wql_org_id, :uuid, null: false)
      add(:wql_inserted_at, :utc_datetime, null: false)
      add(:wql_updated_at, :utc_datetime, null: false)
    end

    # The ticket's `wqk_custom` bag carries the requester back-references
    # (`requester_org_id` → account Org, `requester_user_id` → tenant-admin User).
    create table(:wqk_ticket, primary_key: false) do
      add(:wqk_subject, :text, null: false)
      add(:wqk_status, :text, default: "open")
      add(:wqk_priority, :text, default: "normal")
      add(:wqk_sla_breach_at, :utc_datetime)
      add(:wqk_breached, :boolean, default: false, null: false)
      add(:wqk_resolved_at, :utc_datetime)
      add(:wqk_closed_at, :utc_datetime)
      add(:wqk_tags, {:array, :text}, default: [])
      add(:wqk_custom, :map, default: fragment("'{}'::jsonb"))
      add(:wqk_external_id, :text)

      add(
        :wqk_sla_id,
        references(:wql_sla,
          column: :wql_id,
          name: "wqk_ticket_wqk_sla_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:wqk_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wqk_org_id, :uuid, null: false)
      add(:wqk_inserted_at, :utc_datetime, null: false)
      add(:wqk_updated_at, :utc_datetime, null: false)
    end

    create(
      index(:wqk_ticket, [:wqk_sla_breach_at, :wqk_breached],
        name: "wqk_ticket_sla_breach_idx",
        where: "wqk_sla_breach_at IS NOT NULL AND wqk_breached = false"
      )
    )

    create table(:wqc_conversation, primary_key: false) do
      add(:wqc_channel, :text, default: "email")
      add(:wqc_status, :text, default: "open")
      add(:wqc_subject, :text)

      add(
        :wqc_ticket_id,
        references(:wqk_ticket,
          column: :wqk_id,
          name: "wqc_conversation_wqc_ticket_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )

      add(:wqc_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wqc_org_id, :uuid, null: false)
      add(:wqc_inserted_at, :utc_datetime, null: false)
      add(:wqc_updated_at, :utc_datetime, null: false)
    end

    # The SaaS support AGENT 🔒 (the SaaS's own employee — CLEAR on the operator's own plane).
    create table(:wqg_agent, primary_key: false) do
      add(:wqg_handle, :text)
      add(:wqg_status, :text, default: "active")
      add(:wqg_role, :text, default: "agent")
      add(:wqg_external_id, :text)
      add(:wqg_timezone, :text)
      add(:wqg_custom, :map, default: fragment("'{}'::jsonb"))
      add(:wqg_full_name, :text)
      add(:pii_wqg_email, :text)
      add(:wqg_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wqg_org_id, :uuid, null: false)
      add(:wqg_inserted_at, :utc_datetime, null: false)
      add(:wqg_updated_at, :utc_datetime, null: false)
    end

    create table(:wqm_message, primary_key: false) do
      add(:wqm_sender_type, :text, default: "customer")
      add(:wqm_sender_id, :uuid)
      add(:wqm_message_type, :text, default: "reply")
      add(:wqm_attachments, {:array, :text}, default: [])
      add(:wqm_created_via, :text, default: "web")
      add(:pii_wqm_body, :text)

      add(
        :wqm_conversation_id,
        references(:wqc_conversation,
          column: :wqc_id,
          name: "wqm_message_wqm_conversation_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )

      add(
        :wqm_agent_id,
        references(:wqg_agent,
          column: :wqg_id,
          name: "wqm_message_wqm_agent_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:wqm_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wqm_org_id, :uuid, null: false)
      add(:wqm_inserted_at, :utc_datetime, null: false)
      add(:wqm_updated_at, :utc_datetime, null: false)
    end

    create table(:wqn_macro, primary_key: false) do
      add(:wqn_name, :text, null: false)
      add(:wqn_description, :text)
      add(:wqn_body_template, :text)
      add(:wqn_tags, {:array, :text}, default: [])
      add(:wqn_enabled, :boolean, default: true)
      add(:wqn_category, :text)
      add(:wqn_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wqn_org_id, :uuid, null: false)
      add(:wqn_inserted_at, :utc_datetime, null: false)
      add(:wqn_updated_at, :utc_datetime, null: false)
    end

    create table(:wqs_csat, primary_key: false) do
      add(:wqs_score, :integer, null: false)
      add(:wqs_comments, :text)
      add(:wqs_channel, :text, default: "email")
      add(:wqs_responded_at, :utc_datetime)

      add(
        :wqs_ticket_id,
        references(:wqk_ticket,
          column: :wqk_id,
          name: "wqs_csat_wqs_ticket_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )

      add(
        :wqs_agent_id,
        references(:wqg_agent,
          column: :wqg_id,
          name: "wqs_csat_wqs_agent_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:wqs_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wqs_org_id, :uuid, null: false)
      add(:wqs_inserted_at, :utc_datetime, null: false)
      add(:wqs_updated_at, :utc_datetime, null: false)
    end

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    # --- Support (reverse FK order) ---
    drop(constraint(:wqs_csat, "wqs_csat_wqs_agent_id_fkey"))
    drop(constraint(:wqs_csat, "wqs_csat_wqs_ticket_id_fkey"))
    drop(table(:wqs_csat))
    drop(table(:wqn_macro))
    drop(constraint(:wqm_message, "wqm_message_wqm_agent_id_fkey"))
    drop(constraint(:wqm_message, "wqm_message_wqm_conversation_id_fkey"))
    drop(table(:wqm_message))
    drop(table(:wqg_agent))
    drop(constraint(:wqc_conversation, "wqc_conversation_wqc_ticket_id_fkey"))
    drop(table(:wqc_conversation))
    drop(index(:wqk_ticket, [:wqk_sla_breach_at, :wqk_breached], name: "wqk_ticket_sla_breach_idx"))
    drop(constraint(:wqk_ticket, "wqk_ticket_wqk_sla_id_fkey"))
    drop(table(:wqk_ticket))
    drop(table(:wql_sla))

    # --- Billing (reverse FK order) ---
    drop(constraint(:wpe_entitlement, "wpe_entitlement_wpe_plan_id_fkey"))
    drop(constraint(:wpe_entitlement, "wpe_entitlement_wpe_subscription_id_fkey"))
    drop(table(:wpe_entitlement))
    drop(constraint(:wpu_usage, "wpu_usage_wpu_subscription_id_fkey"))
    drop(table(:wpu_usage))
    drop(constraint(:wpy_payment, "wpy_payment_wpy_customer_id_fkey"))
    drop(constraint(:wpy_payment, "wpy_payment_wpy_invoice_id_fkey"))
    drop(table(:wpy_payment))
    drop(constraint(:wpi_invoice, "wpi_invoice_wpi_subscription_id_fkey"))
    drop(constraint(:wpi_invoice, "wpi_invoice_wpi_customer_id_fkey"))
    drop(table(:wpi_invoice))
    drop(constraint(:wps_subscription, "wps_subscription_wps_plan_id_fkey"))
    drop(constraint(:wps_subscription, "wps_subscription_wps_customer_id_fkey"))
    drop(table(:wps_subscription))
    drop(constraint(:wpr_price, "wpr_price_wpr_plan_id_fkey"))
    drop(table(:wpr_price))
    drop(table(:wpp_plan))
    drop(table(:wpc_customer))

    # --- Identity (reverse FK order) ---
    drop(constraint(:wok_api_key, "wok_api_key_wok_membership_id_fkey"))
    drop(table(:wok_api_key))
    drop(table(:won_invitation))
    drop(table(:wor_role))
    drop(constraint(:wom_membership, "wom_membership_wom_user_id_fkey"))
    drop(table(:wom_membership))
    drop(table(:wou_user))
    drop(table(:woo_org))
  end
end
