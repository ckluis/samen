defmodule Samen.WebTest.Repo.Migrations.MountBillingSupportScopes do
  @moduledoc """
  Mounts the inherited Billing + Support universal scopes into the samen_web test host's one
  Postgres (product thesis "inherit the 80%"), and catalogs every resource in the
  SAME migration transaction (ADR-004 catalog-in-tx: DDL + catalog_sync in one tx in
  the host's repo). Same pattern as `20260707100000_driftwood_resources.exs` mounted
  the CRM scope. Fresh f-prefixed abbrevs (see `Samen.WebTest.Billing` / `Samen.WebTest.Support`
  moduledocs — the global registry already owns the scope-default abbrevs via demo).

  ## Billing (Stripe-mirror shape) — fbc/fbs/fbp/fbr/fbi/fby/fbu/fbe

    * `wbc_customer`     — 🔒 (billing_name/billing_email vault-routed via pii_ columns)
    * `wbs_subscription` — active billing subscription (customer + plan)
    * `wbp_plan`         — Tier-0 config rows: billing plan catalog
    * `wbr_price`        — Tier-0 config rows: price point per plan
    * `wbi_invoice`      — billing invoice (line_items as jsonb)
    * `wby_payment`      — payment record (no raw card data)
    * `wbu_usage`        — metered usage for a subscription
    * `wbe_entitlement`  — feature entitlement per subscription

  ## Support — fsk/fsc/fsm/fsa/fsl/fsn/fss

    * `wsl_sla`          — Tier-0 config rows: SLA policies per org
    * `wsk_ticket`       — the top-level ticket (SLA deadline/priority/status; no PII)
    * `wsc_conversation` — a conversation thread on a ticket (no PII)
    * `wsg_agent`        — 🔒 PII: full_name (composite vault token) + email (scalar pii_)
    * `wsm_message`      — 🔒 PII: body (scalar pii_ token; free-text vault blob)
    * `wsn_macro`        — Tier-0 config rows: canned response macros per org
    * `wss_csat`         — customer satisfaction survey responses

  ## PII columns (vault vt_* tokens — plaintext never lands here)

  - `wbc_customer.pii_wbc_billing_name`  — scalar vault token (pii_ prefix)
  - `wbc_customer.pii_wbc_billing_email` — scalar vault token (pii_ prefix)
  - `wsg_agent.wsg_full_name`            — composite vault token (VaultField; no pii_ prefix)
  - `wsg_agent.pii_wsg_email`            — scalar vault token (pii_ prefix)
  - `wsm_message.pii_wsm_body`           — scalar vault token (pii_ prefix; free-text)

  ## FK order (SameOrgFk guards every org-scoped FK at the resource layer)

  Billing:  wbp_plan ← wbc_customer ← wbs_subscription ← wbi_invoice ← wby_payment
                                                        ← wbe_entitlement, wbu_usage
  Support:  wsl_sla ← wsk_ticket ← wsc_conversation ← wsm_message → wsg_agent
            wsk_ticket ← wss_csat → wsg_agent
  """
  use Samen.Migration

  @resources [
    # Billing
    Samen.WebTest.Billing.Customer,
    Samen.WebTest.Billing.Subscription,
    Samen.WebTest.Billing.Plan,
    Samen.WebTest.Billing.Price,
    Samen.WebTest.Billing.Invoice,
    Samen.WebTest.Billing.Payment,
    Samen.WebTest.Billing.Usage,
    Samen.WebTest.Billing.Entitlement,
    # Support
    Samen.WebTest.Support.Sla,
    Samen.WebTest.Support.Ticket,
    Samen.WebTest.Support.Conversation,
    Samen.WebTest.Support.Agent,
    Samen.WebTest.Support.Message,
    Samen.WebTest.Support.Macro,
    Samen.WebTest.Support.Csat
  ]

  def up do
    # =========================================================================
    # BILLING
    # =========================================================================

    # --- wbc_customer : 🔒 (billing_name/billing_email vault-routed) ---
    create table(:wbc_customer, primary_key: false) do
      add(:wbc_stripe_customer_id, :text)
      add(:wbc_status, :text, default: "active")
      add(:wbc_currency, :text, default: "USD")
      add(:wbc_custom, :map, default: fragment("'{}'::jsonb"))
      # Scalar PII token columns (vault-routed; pii_ prefix per storage convention):
      add(:pii_wbc_billing_name, :text)
      add(:pii_wbc_billing_email, :text)
      add(:wbc_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wbc_org_id, :uuid, null: false)
      add(:wbc_inserted_at, :utc_datetime, null: false)
      add(:wbc_updated_at, :utc_datetime, null: false)
    end

    # --- wbp_plan : Tier-0 config rows (billing plan catalog per org) ---
    create table(:wbp_plan, primary_key: false) do
      add(:wbp_name, :text, null: false)
      add(:wbp_label, :text)
      add(:wbp_description, :text)
      add(:wbp_stripe_plan_id, :text)
      add(:wbp_interval, :text, default: "monthly")
      add(:wbp_enabled, :boolean, default: true)
      add(:wbp_features, :map, default: fragment("'{}'::jsonb"))
      add(:wbp_custom, :map, default: fragment("'{}'::jsonb"))
      add(:wbp_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wbp_org_id, :uuid, null: false)
      add(:wbp_inserted_at, :utc_datetime, null: false)
      add(:wbp_updated_at, :utc_datetime, null: false)
    end

    # --- wbr_price : Tier-0 config rows (price per plan) ---
    create table(:wbr_price, primary_key: false) do
      add(:wbr_stripe_price_id, :text)
      add(:wbr_unit_amount_cents, :integer, null: false)
      add(:wbr_currency, :text, null: false, default: "USD")
      add(:wbr_interval, :text, default: "monthly")
      add(:wbr_active, :boolean, default: true)
      add(:wbr_custom, :map, default: fragment("'{}'::jsonb"))

      add(
        :wbr_plan_id,
        references(:wbp_plan,
          column: :wbp_id,
          name: "wbr_price_wbr_plan_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:wbr_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wbr_org_id, :uuid, null: false)
      add(:wbr_inserted_at, :utc_datetime, null: false)
      add(:wbr_updated_at, :utc_datetime, null: false)
    end

    # --- wbs_subscription : an active billing subscription ---
    create table(:wbs_subscription, primary_key: false) do
      add(:wbs_stripe_subscription_id, :text)
      add(:wbs_status, :text, default: "active")
      add(:wbs_current_period_start, :utc_datetime)
      add(:wbs_current_period_end, :utc_datetime)
      add(:wbs_trial_end, :utc_datetime)
      add(:wbs_cancel_at, :utc_datetime)
      add(:wbs_cancelled_at, :utc_datetime)
      add(:wbs_custom, :map, default: fragment("'{}'::jsonb"))

      add(
        :wbs_customer_id,
        references(:wbc_customer,
          column: :wbc_id,
          name: "wbs_subscription_wbs_customer_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :wbs_plan_id,
        references(:wbp_plan,
          column: :wbp_id,
          name: "wbs_subscription_wbs_plan_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:wbs_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wbs_org_id, :uuid, null: false)
      add(:wbs_inserted_at, :utc_datetime, null: false)
      add(:wbs_updated_at, :utc_datetime, null: false)
    end

    # --- wbi_invoice : a billing invoice ---
    create table(:wbi_invoice, primary_key: false) do
      add(:wbi_stripe_invoice_id, :text)
      add(:wbi_status, :text, default: "draft")
      add(:wbi_amount_due_cents, :integer, default: 0)
      add(:wbi_amount_paid_cents, :integer, default: 0)
      add(:wbi_currency, :text, default: "USD")
      add(:wbi_period_start, :utc_datetime)
      add(:wbi_period_end, :utc_datetime)
      add(:wbi_due_date, :utc_datetime)
      add(:wbi_paid_at, :utc_datetime)
      add(:wbi_line_items, {:array, :map}, default: fragment("ARRAY[]::jsonb[]"))
      add(:wbi_custom, :map, default: fragment("'{}'::jsonb"))

      add(
        :wbi_customer_id,
        references(:wbc_customer,
          column: :wbc_id,
          name: "wbi_invoice_wbi_customer_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :wbi_subscription_id,
        references(:wbs_subscription,
          column: :wbs_id,
          name: "wbi_invoice_wbi_subscription_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:wbi_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wbi_org_id, :uuid, null: false)
      add(:wbi_inserted_at, :utc_datetime, null: false)
      add(:wbi_updated_at, :utc_datetime, null: false)
    end

    # --- wby_payment : a payment record (no raw card data) ---
    create table(:wby_payment, primary_key: false) do
      add(:wby_stripe_payment_intent_id, :text)
      add(:wby_status, :text, default: "pending")
      add(:wby_amount_cents, :integer, null: false)
      add(:wby_currency, :text, default: "USD")
      add(:wby_payment_method_type, :text, default: "card")
      add(:wby_last4, :text)
      add(:wby_paid_at, :utc_datetime)
      add(:wby_failure_code, :text)
      add(:wby_custom, :map, default: fragment("'{}'::jsonb"))

      add(
        :wby_invoice_id,
        references(:wbi_invoice,
          column: :wbi_id,
          name: "wby_payment_wby_invoice_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :wby_customer_id,
        references(:wbc_customer,
          column: :wbc_id,
          name: "wby_payment_wby_customer_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:wby_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wby_org_id, :uuid, null: false)
      add(:wby_inserted_at, :utc_datetime, null: false)
      add(:wby_updated_at, :utc_datetime, null: false)
    end

    # --- wbu_usage : metered usage for a subscription ---
    create table(:wbu_usage, primary_key: false) do
      add(:wbu_metric, :text, null: false)
      add(:wbu_quantity, :integer, default: 0)
      add(:wbu_period_start, :utc_datetime)
      add(:wbu_period_end, :utc_datetime)
      add(:wbu_reported_at, :utc_datetime)

      add(
        :wbu_subscription_id,
        references(:wbs_subscription,
          column: :wbs_id,
          name: "wbu_usage_wbu_subscription_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:wbu_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wbu_org_id, :uuid, null: false)
      add(:wbu_inserted_at, :utc_datetime, null: false)
      add(:wbu_updated_at, :utc_datetime, null: false)
    end

    # --- wbe_entitlement : feature entitlement for a subscription ---
    create table(:wbe_entitlement, primary_key: false) do
      add(:wbe_feature, :text, null: false)
      add(:wbe_granted, :boolean, default: true)
      add(:wbe_expires_at, :utc_datetime)
      add(:wbe_custom, :map, default: fragment("'{}'::jsonb"))

      add(
        :wbe_subscription_id,
        references(:wbs_subscription,
          column: :wbs_id,
          name: "wbe_entitlement_wbe_subscription_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :wbe_plan_id,
        references(:wbp_plan,
          column: :wbp_id,
          name: "wbe_entitlement_wbe_plan_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:wbe_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wbe_org_id, :uuid, null: false)
      add(:wbe_inserted_at, :utc_datetime, null: false)
      add(:wbe_updated_at, :utc_datetime, null: false)
    end

    # =========================================================================
    # SUPPORT
    # =========================================================================

    # --- wsl_sla : Tier-0 SLA policy rows ---
    create table(:wsl_sla, primary_key: false) do
      add(:wsl_name, :text, null: false)
      add(:wsl_label, :text)
      add(:wsl_first_response_minutes, :integer, default: 60)
      add(:wsl_resolve_minutes, :integer, default: 480)
      add(:wsl_priority, :text, default: "normal")
      add(:wsl_enabled, :boolean, default: true)
      add(:wsl_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wsl_org_id, :uuid, null: false)
      add(:wsl_inserted_at, :utc_datetime, null: false)
      add(:wsl_updated_at, :utc_datetime, null: false)
    end

    # --- wsk_ticket : the top-level support ticket ---
    create table(:wsk_ticket, primary_key: false) do
      add(:wsk_subject, :text, null: false)
      add(:wsk_status, :text, default: "open")
      add(:wsk_priority, :text, default: "normal")
      # SLA deadline — set at create time; the SlaBreachWorker cron scans this.
      add(:wsk_sla_breach_at, :utc_datetime)
      add(:wsk_breached, :boolean, default: false, null: false)
      add(:wsk_resolved_at, :utc_datetime)
      add(:wsk_closed_at, :utc_datetime)
      add(:wsk_tags, {:array, :text}, default: [])
      add(:wsk_custom, :map, default: fragment("'{}'::jsonb"))
      add(:wsk_external_id, :text)

      add(
        :wsk_sla_id,
        references(:wsl_sla,
          column: :wsl_id,
          name: "wsk_ticket_wsk_sla_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:wsk_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wsk_org_id, :uuid, null: false)
      add(:wsk_inserted_at, :utc_datetime, null: false)
      add(:wsk_updated_at, :utc_datetime, null: false)
    end

    # Index for the SlaBreachWorker cron query performance.
    create(
      index(:wsk_ticket, [:wsk_sla_breach_at, :wsk_breached],
        name: "wsk_ticket_sla_breach_idx",
        where: "wsk_sla_breach_at IS NOT NULL AND wsk_breached = false"
      )
    )

    # --- wsc_conversation : a conversation thread on a ticket ---
    create table(:wsc_conversation, primary_key: false) do
      add(:wsc_channel, :text, default: "email")
      add(:wsc_status, :text, default: "open")
      add(:wsc_subject, :text)

      add(
        :wsc_ticket_id,
        references(:wsk_ticket,
          column: :wsk_id,
          name: "wsc_conversation_wsc_ticket_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )

      add(:wsc_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wsc_org_id, :uuid, null: false)
      add(:wsc_inserted_at, :utc_datetime, null: false)
      add(:wsc_updated_at, :utc_datetime, null: false)
    end

    # --- wsg_agent : 🔒 PII: full_name (composite vault token) + email (scalar pii_ token) ---
    create table(:wsg_agent, primary_key: false) do
      add(:wsg_handle, :text)
      add(:wsg_status, :text, default: "active")
      add(:wsg_role, :text, default: "agent")
      add(:wsg_external_id, :text)
      add(:wsg_timezone, :text)
      add(:wsg_custom, :map, default: fragment("'{}'::jsonb"))
      # Composite PII vault token: full_name routes by vault name (no pii_ prefix).
      add(:wsg_full_name, :text)
      # Scalar PII vault token: email carries the pii_ prefix (pii_wsg_email).
      add(:pii_wsg_email, :text)
      add(:wsg_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wsg_org_id, :uuid, null: false)
      add(:wsg_inserted_at, :utc_datetime, null: false)
      add(:wsg_updated_at, :utc_datetime, null: false)
    end

    # --- wsm_message : 🔒 PII: body (scalar pii_ token — free-text vault) ---
    create table(:wsm_message, primary_key: false) do
      add(:wsm_sender_type, :text, default: "customer")
      add(:wsm_sender_id, :uuid)
      add(:wsm_message_type, :text, default: "reply")
      add(:wsm_attachments, {:array, :text}, default: [])
      add(:wsm_created_via, :text, default: "web")
      # Scalar PII vault token: body carries the pii_ prefix (pii_wsm_body).
      # Free-text message content — vaulted as a single ciphertext blob.
      add(:pii_wsm_body, :text)

      add(
        :wsm_conversation_id,
        references(:wsc_conversation,
          column: :wsc_id,
          name: "wsm_message_wsm_conversation_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )

      add(
        :wsm_agent_id,
        references(:wsg_agent,
          column: :wsg_id,
          name: "wsm_message_wsm_agent_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:wsm_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wsm_org_id, :uuid, null: false)
      add(:wsm_inserted_at, :utc_datetime, null: false)
      add(:wsm_updated_at, :utc_datetime, null: false)
    end

    # --- wsn_macro : Tier-0 canned response macros per org ---
    create table(:wsn_macro, primary_key: false) do
      add(:wsn_name, :text, null: false)
      add(:wsn_description, :text)
      # body_template: operator-authored template text — non-PII.
      add(:wsn_body_template, :text)
      add(:wsn_tags, {:array, :text}, default: [])
      add(:wsn_enabled, :boolean, default: true)
      add(:wsn_category, :text)
      add(:wsn_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wsn_org_id, :uuid, null: false)
      add(:wsn_inserted_at, :utc_datetime, null: false)
      add(:wsn_updated_at, :utc_datetime, null: false)
    end

    # --- wss_csat : customer satisfaction survey responses ---
    create table(:wss_csat, primary_key: false) do
      add(:wss_score, :integer, null: false)
      # wss_comments: free-text survey response — non-PII (aggregate metric surface).
      add(:wss_comments, :text)
      add(:wss_channel, :text, default: "email")
      add(:wss_responded_at, :utc_datetime)

      add(
        :wss_ticket_id,
        references(:wsk_ticket,
          column: :wsk_id,
          name: "wss_csat_wss_ticket_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )

      add(
        :wss_agent_id,
        references(:wsg_agent,
          column: :wsg_id,
          name: "wss_csat_wss_agent_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:wss_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wss_org_id, :uuid, null: false)
      add(:wss_inserted_at, :utc_datetime, null: false)
      add(:wss_updated_at, :utc_datetime, null: false)
    end

    # --- catalog all fifteen Billing + Support resources in THIS transaction ---
    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    # --- Support (reverse FK order) ---
    drop(constraint(:wss_csat, "wss_csat_wss_agent_id_fkey"))
    drop(constraint(:wss_csat, "wss_csat_wss_ticket_id_fkey"))
    drop(table(:wss_csat))

    drop(table(:wsn_macro))

    drop(constraint(:wsm_message, "wsm_message_wsm_agent_id_fkey"))
    drop(constraint(:wsm_message, "wsm_message_wsm_conversation_id_fkey"))
    drop(table(:wsm_message))

    drop(table(:wsg_agent))

    drop(constraint(:wsc_conversation, "wsc_conversation_wsc_ticket_id_fkey"))
    drop(table(:wsc_conversation))

    drop(index(:wsk_ticket, [:wsk_sla_breach_at, :wsk_breached], name: "wsk_ticket_sla_breach_idx"))
    drop(constraint(:wsk_ticket, "wsk_ticket_wsk_sla_id_fkey"))
    drop(table(:wsk_ticket))

    drop(table(:wsl_sla))

    # --- Billing (reverse FK order) ---
    drop(constraint(:wbe_entitlement, "wbe_entitlement_wbe_plan_id_fkey"))
    drop(constraint(:wbe_entitlement, "wbe_entitlement_wbe_subscription_id_fkey"))
    drop(table(:wbe_entitlement))

    drop(constraint(:wbu_usage, "wbu_usage_wbu_subscription_id_fkey"))
    drop(table(:wbu_usage))

    drop(constraint(:wby_payment, "wby_payment_wby_customer_id_fkey"))
    drop(constraint(:wby_payment, "wby_payment_wby_invoice_id_fkey"))
    drop(table(:wby_payment))

    drop(constraint(:wbi_invoice, "wbi_invoice_wbi_subscription_id_fkey"))
    drop(constraint(:wbi_invoice, "wbi_invoice_wbi_customer_id_fkey"))
    drop(table(:wbi_invoice))

    drop(constraint(:wbs_subscription, "wbs_subscription_wbs_plan_id_fkey"))
    drop(constraint(:wbs_subscription, "wbs_subscription_wbs_customer_id_fkey"))
    drop(table(:wbs_subscription))

    drop(constraint(:wbr_price, "wbr_price_wbr_plan_id_fkey"))
    drop(table(:wbr_price))

    drop(table(:wbp_plan))
    drop(table(:wbc_customer))
  end
end
