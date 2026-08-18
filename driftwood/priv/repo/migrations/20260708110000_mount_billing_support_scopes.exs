defmodule Driftwood.Repo.Migrations.MountBillingSupportScopes do
  @moduledoc """
  Mounts the inherited Billing + Support universal scopes into Driftwood's one
  Postgres (product thesis "inherit the 80%"), and catalogs every resource in the
  SAME migration transaction (ADR-004 catalog-in-tx: DDL + catalog_sync in one tx in
  the host's repo). Same pattern as `20260707100000_driftwood_resources.exs` mounted
  the CRM scope. Fresh f-prefixed abbrevs (see `Driftwood.Billing` / `Driftwood.Support`
  moduledocs — the global registry already owns the scope-default abbrevs via demo).

  ## Billing (Stripe-mirror shape) — fbc/fbs/fbp/fbr/fbi/fby/fbu/fbe

    * `fbc_customer`     — 🔒 (billing_name/billing_email vault-routed via pii_ columns)
    * `fbs_subscription` — active billing subscription (customer + plan)
    * `fbp_plan`         — Tier-0 config rows: billing plan catalog
    * `fbr_price`        — Tier-0 config rows: price point per plan
    * `fbi_invoice`      — billing invoice (line_items as jsonb)
    * `fby_payment`      — payment record (no raw card data)
    * `fbu_usage`        — metered usage for a subscription
    * `fbe_entitlement`  — feature entitlement per subscription

  ## Support — fsk/fsc/fsm/fsa/fsl/fsn/fss

    * `fsl_sla`          — Tier-0 config rows: SLA policies per org
    * `fsk_ticket`       — the top-level ticket (SLA deadline/priority/status; no PII)
    * `fsc_conversation` — a conversation thread on a ticket (no PII)
    * `fsa_agent`        — 🔒 PII: full_name (composite vault token) + email (scalar pii_)
    * `fsm_message`      — 🔒 PII: body (scalar pii_ token; free-text vault blob)
    * `fsn_macro`        — Tier-0 config rows: canned response macros per org
    * `fss_csat`         — customer satisfaction survey responses

  ## PII columns (vault vt_* tokens — plaintext never lands here)

  - `fbc_customer.pii_fbc_billing_name`  — scalar vault token (pii_ prefix)
  - `fbc_customer.pii_fbc_billing_email` — scalar vault token (pii_ prefix)
  - `fsa_agent.fsa_full_name`            — composite vault token (VaultField; no pii_ prefix)
  - `fsa_agent.pii_fsa_email`            — scalar vault token (pii_ prefix)
  - `fsm_message.pii_fsm_body`           — scalar vault token (pii_ prefix; free-text)

  ## FK order (SameOrgFk guards every org-scoped FK at the resource layer)

  Billing:  fbp_plan ← fbc_customer ← fbs_subscription ← fbi_invoice ← fby_payment
                                                        ← fbe_entitlement, fbu_usage
  Support:  fsl_sla ← fsk_ticket ← fsc_conversation ← fsm_message → fsa_agent
            fsk_ticket ← fss_csat → fsa_agent
  """
  use Samen.Migration

  @resources [
    # Billing
    Driftwood.Billing.Customer,
    Driftwood.Billing.Subscription,
    Driftwood.Billing.Plan,
    Driftwood.Billing.Price,
    Driftwood.Billing.Invoice,
    Driftwood.Billing.Payment,
    Driftwood.Billing.Usage,
    Driftwood.Billing.Entitlement,
    # Support
    Driftwood.Support.Sla,
    Driftwood.Support.Ticket,
    Driftwood.Support.Conversation,
    Driftwood.Support.Agent,
    Driftwood.Support.Message,
    Driftwood.Support.Macro,
    Driftwood.Support.Csat
  ]

  def up do
    # =========================================================================
    # BILLING
    # =========================================================================

    # --- fbc_customer : 🔒 (billing_name/billing_email vault-routed) ---
    create table(:fbc_customer, primary_key: false) do
      add(:fbc_provider_customer_ref, :text)
      add(:fbc_status, :text, default: "active")
      add(:fbc_currency, :text, default: "USD")
      add(:fbc_custom, :map, default: fragment("'{}'::jsonb"))
      # Scalar PII token columns (vault-routed; pii_ prefix per storage convention):
      add(:pii_fbc_billing_name, :text)
      add(:pii_fbc_billing_email, :text)
      add(:fbc_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fbc_org_id, :uuid, null: false)
      add(:fbc_inserted_at, :utc_datetime, null: false)
      add(:fbc_updated_at, :utc_datetime, null: false)
    end

    # --- fbp_plan : Tier-0 config rows (billing plan catalog per org) ---
    create table(:fbp_plan, primary_key: false) do
      add(:fbp_name, :text, null: false)
      add(:fbp_label, :text)
      add(:fbp_description, :text)
      add(:fbp_provider_plan_ref, :text)
      add(:fbp_interval, :text, default: "monthly")
      add(:fbp_enabled, :boolean, default: true)
      add(:fbp_features, :map, default: fragment("'{}'::jsonb"))
      add(:fbp_custom, :map, default: fragment("'{}'::jsonb"))
      add(:fbp_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fbp_org_id, :uuid, null: false)
      add(:fbp_inserted_at, :utc_datetime, null: false)
      add(:fbp_updated_at, :utc_datetime, null: false)
    end

    # --- fbr_price : Tier-0 config rows (price per plan) ---
    create table(:fbr_price, primary_key: false) do
      add(:fbr_provider_price_ref, :text)
      add(:fbr_unit_amount_cents, :integer, null: false)
      add(:fbr_currency, :text, null: false, default: "USD")
      add(:fbr_interval, :text, default: "monthly")
      add(:fbr_active, :boolean, default: true)
      add(:fbr_custom, :map, default: fragment("'{}'::jsonb"))

      add(
        :fbr_plan_id,
        references(:fbp_plan,
          column: :fbp_id,
          name: "fbr_price_fbr_plan_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:fbr_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fbr_org_id, :uuid, null: false)
      add(:fbr_inserted_at, :utc_datetime, null: false)
      add(:fbr_updated_at, :utc_datetime, null: false)
    end

    # --- fbs_subscription : an active billing subscription ---
    create table(:fbs_subscription, primary_key: false) do
      add(:fbs_provider_subscription_ref, :text)
      add(:fbs_status, :text, default: "active")
      add(:fbs_current_period_start, :utc_datetime)
      add(:fbs_current_period_end, :utc_datetime)
      add(:fbs_trial_end, :utc_datetime)
      add(:fbs_cancel_at, :utc_datetime)
      add(:fbs_cancelled_at, :utc_datetime)
      add(:fbs_custom, :map, default: fragment("'{}'::jsonb"))

      add(
        :fbs_customer_id,
        references(:fbc_customer,
          column: :fbc_id,
          name: "fbs_subscription_fbs_customer_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :fbs_plan_id,
        references(:fbp_plan,
          column: :fbp_id,
          name: "fbs_subscription_fbs_plan_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:fbs_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fbs_org_id, :uuid, null: false)
      add(:fbs_inserted_at, :utc_datetime, null: false)
      add(:fbs_updated_at, :utc_datetime, null: false)
    end

    # T106 decision (e): DB-unique-fence on the provider-subscription-ref — the
    # idempotency guard for the checkout-seeded + lifecycle mirror convergence
    # (ADR-038 addendum). Nullable column, so local rows with no provider ref are
    # unconstrained (Postgres allows multiple NULLs); non-null provider refs collide.
    create(unique_index(:fbs_subscription, [:fbs_provider_subscription_ref], name: "fbs_subscription_provider_ref_index"))

    # --- fbi_invoice : a billing invoice ---
    create table(:fbi_invoice, primary_key: false) do
      add(:fbi_provider_invoice_ref, :text)
      add(:fbi_status, :text, default: "draft")
      add(:fbi_amount_due_cents, :integer, default: 0)
      add(:fbi_amount_paid_cents, :integer, default: 0)
      add(:fbi_currency, :text, default: "USD")
      add(:fbi_period_start, :utc_datetime)
      add(:fbi_period_end, :utc_datetime)
      add(:fbi_due_date, :utc_datetime)
      add(:fbi_paid_at, :utc_datetime)
      add(:fbi_line_items, {:array, :map}, default: fragment("ARRAY[]::jsonb[]"))
      add(:fbi_custom, :map, default: fragment("'{}'::jsonb"))

      add(
        :fbi_customer_id,
        references(:fbc_customer,
          column: :fbc_id,
          name: "fbi_invoice_fbi_customer_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :fbi_subscription_id,
        references(:fbs_subscription,
          column: :fbs_id,
          name: "fbi_invoice_fbi_subscription_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:fbi_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fbi_org_id, :uuid, null: false)
      add(:fbi_inserted_at, :utc_datetime, null: false)
      add(:fbi_updated_at, :utc_datetime, null: false)
    end

    # --- fby_payment : a payment record (no raw card data) ---
    create table(:fby_payment, primary_key: false) do
      add(:fby_provider_payment_ref, :text)
      add(:fby_status, :text, default: "pending")
      add(:fby_amount_cents, :integer, null: false)
      add(:fby_currency, :text, default: "USD")
      add(:fby_payment_method_type, :text, default: "card")
      add(:fby_last4, :text)
      add(:fby_paid_at, :utc_datetime)
      add(:fby_failure_code, :text)
      add(:fby_custom, :map, default: fragment("'{}'::jsonb"))

      add(
        :fby_invoice_id,
        references(:fbi_invoice,
          column: :fbi_id,
          name: "fby_payment_fby_invoice_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :fby_customer_id,
        references(:fbc_customer,
          column: :fbc_id,
          name: "fby_payment_fby_customer_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:fby_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fby_org_id, :uuid, null: false)
      add(:fby_inserted_at, :utc_datetime, null: false)
      add(:fby_updated_at, :utc_datetime, null: false)
    end

    # --- fbu_usage : metered usage for a subscription ---
    create table(:fbu_usage, primary_key: false) do
      add(:fbu_metric, :text, null: false)
      add(:fbu_quantity, :integer, default: 0)
      add(:fbu_period_start, :utc_datetime)
      add(:fbu_period_end, :utc_datetime)
      add(:fbu_reported_at, :utc_datetime)

      add(
        :fbu_subscription_id,
        references(:fbs_subscription,
          column: :fbs_id,
          name: "fbu_usage_fbu_subscription_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:fbu_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fbu_org_id, :uuid, null: false)
      add(:fbu_inserted_at, :utc_datetime, null: false)
      add(:fbu_updated_at, :utc_datetime, null: false)
    end

    # --- fbe_entitlement : feature entitlement for a subscription ---
    create table(:fbe_entitlement, primary_key: false) do
      add(:fbe_feature, :text, null: false)
      add(:fbe_granted, :boolean, default: true)
      add(:fbe_expires_at, :utc_datetime)
      add(:fbe_custom, :map, default: fragment("'{}'::jsonb"))

      add(
        :fbe_subscription_id,
        references(:fbs_subscription,
          column: :fbs_id,
          name: "fbe_entitlement_fbe_subscription_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :fbe_plan_id,
        references(:fbp_plan,
          column: :fbp_id,
          name: "fbe_entitlement_fbe_plan_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:fbe_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fbe_org_id, :uuid, null: false)
      add(:fbe_inserted_at, :utc_datetime, null: false)
      add(:fbe_updated_at, :utc_datetime, null: false)
    end

    # =========================================================================
    # SUPPORT
    # =========================================================================

    # --- fsl_sla : Tier-0 SLA policy rows ---
    create table(:fsl_sla, primary_key: false) do
      add(:fsl_name, :text, null: false)
      add(:fsl_label, :text)
      add(:fsl_first_response_minutes, :integer, default: 60)
      add(:fsl_resolve_minutes, :integer, default: 480)
      add(:fsl_priority, :text, default: "normal")
      add(:fsl_enabled, :boolean, default: true)
      add(:fsl_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fsl_org_id, :uuid, null: false)
      add(:fsl_inserted_at, :utc_datetime, null: false)
      add(:fsl_updated_at, :utc_datetime, null: false)
    end

    # --- fsk_ticket : the top-level support ticket ---
    create table(:fsk_ticket, primary_key: false) do
      add(:fsk_subject, :text, null: false)
      add(:fsk_status, :text, default: "open")
      add(:fsk_priority, :text, default: "normal")
      # SLA deadline — set at create time; the SlaBreachWorker cron scans this.
      add(:fsk_sla_breach_at, :utc_datetime)
      add(:fsk_breached, :boolean, default: false, null: false)
      add(:fsk_resolved_at, :utc_datetime)
      add(:fsk_closed_at, :utc_datetime)
      add(:fsk_tags, {:array, :text}, default: [])
      add(:fsk_custom, :map, default: fragment("'{}'::jsonb"))
      add(:fsk_external_id, :text)

      add(
        :fsk_sla_id,
        references(:fsl_sla,
          column: :fsl_id,
          name: "fsk_ticket_fsk_sla_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:fsk_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fsk_org_id, :uuid, null: false)
      add(:fsk_inserted_at, :utc_datetime, null: false)
      add(:fsk_updated_at, :utc_datetime, null: false)
    end

    # Index for the SlaBreachWorker cron query performance.
    create(
      index(:fsk_ticket, [:fsk_sla_breach_at, :fsk_breached],
        name: "fsk_ticket_sla_breach_idx",
        where: "fsk_sla_breach_at IS NOT NULL AND fsk_breached = false"
      )
    )

    # --- fsc_conversation : a conversation thread on a ticket ---
    create table(:fsc_conversation, primary_key: false) do
      add(:fsc_channel, :text, default: "email")
      add(:fsc_status, :text, default: "open")
      add(:fsc_subject, :text)

      add(
        :fsc_ticket_id,
        references(:fsk_ticket,
          column: :fsk_id,
          name: "fsc_conversation_fsc_ticket_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )

      add(:fsc_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fsc_org_id, :uuid, null: false)
      add(:fsc_inserted_at, :utc_datetime, null: false)
      add(:fsc_updated_at, :utc_datetime, null: false)
    end

    # --- fsa_agent : 🔒 PII: full_name (composite vault token) + email (scalar pii_ token) ---
    create table(:fsa_agent, primary_key: false) do
      add(:fsa_handle, :text)
      add(:fsa_status, :text, default: "active")
      add(:fsa_role, :text, default: "agent")
      add(:fsa_external_id, :text)
      add(:fsa_timezone, :text)
      add(:fsa_custom, :map, default: fragment("'{}'::jsonb"))
      # Composite PII vault token: full_name routes by vault name (no pii_ prefix).
      add(:fsa_full_name, :text)
      # Scalar PII vault token: email carries the pii_ prefix (pii_fsa_email).
      add(:pii_fsa_email, :text)
      add(:fsa_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fsa_org_id, :uuid, null: false)
      add(:fsa_inserted_at, :utc_datetime, null: false)
      add(:fsa_updated_at, :utc_datetime, null: false)
    end

    # --- fsm_message : 🔒 PII: body (scalar pii_ token — free-text vault) ---
    create table(:fsm_message, primary_key: false) do
      add(:fsm_sender_type, :text, default: "customer")
      add(:fsm_sender_id, :uuid)
      add(:fsm_message_type, :text, default: "reply")
      add(:fsm_attachments, {:array, :text}, default: [])
      add(:fsm_created_via, :text, default: "web")
      # Scalar PII vault token: body carries the pii_ prefix (pii_fsm_body).
      # Free-text message content — vaulted as a single ciphertext blob.
      add(:pii_fsm_body, :text)

      add(
        :fsm_conversation_id,
        references(:fsc_conversation,
          column: :fsc_id,
          name: "fsm_message_fsm_conversation_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )

      add(
        :fsm_agent_id,
        references(:fsa_agent,
          column: :fsa_id,
          name: "fsm_message_fsm_agent_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:fsm_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fsm_org_id, :uuid, null: false)
      add(:fsm_inserted_at, :utc_datetime, null: false)
      add(:fsm_updated_at, :utc_datetime, null: false)
    end

    # --- fsn_macro : Tier-0 canned response macros per org ---
    create table(:fsn_macro, primary_key: false) do
      add(:fsn_name, :text, null: false)
      add(:fsn_description, :text)
      # body_template: operator-authored template text — non-PII.
      add(:fsn_body_template, :text)
      add(:fsn_tags, {:array, :text}, default: [])
      add(:fsn_enabled, :boolean, default: true)
      add(:fsn_category, :text)
      add(:fsn_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fsn_org_id, :uuid, null: false)
      add(:fsn_inserted_at, :utc_datetime, null: false)
      add(:fsn_updated_at, :utc_datetime, null: false)
    end

    # --- fss_csat : customer satisfaction survey responses ---
    create table(:fss_csat, primary_key: false) do
      add(:fss_score, :integer, null: false)
      # fss_comments: free-text survey response — non-PII (aggregate metric surface).
      add(:fss_comments, :text)
      add(:fss_channel, :text, default: "email")
      add(:fss_responded_at, :utc_datetime)

      add(
        :fss_ticket_id,
        references(:fsk_ticket,
          column: :fsk_id,
          name: "fss_csat_fss_ticket_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )

      add(
        :fss_agent_id,
        references(:fsa_agent,
          column: :fsa_id,
          name: "fss_csat_fss_agent_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:fss_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fss_org_id, :uuid, null: false)
      add(:fss_inserted_at, :utc_datetime, null: false)
      add(:fss_updated_at, :utc_datetime, null: false)
    end

    # --- catalog all fifteen Billing + Support resources in THIS transaction ---
    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    # --- Support (reverse FK order) ---
    drop(constraint(:fss_csat, "fss_csat_fss_agent_id_fkey"))
    drop(constraint(:fss_csat, "fss_csat_fss_ticket_id_fkey"))
    drop(table(:fss_csat))

    drop(table(:fsn_macro))

    drop(constraint(:fsm_message, "fsm_message_fsm_agent_id_fkey"))
    drop(constraint(:fsm_message, "fsm_message_fsm_conversation_id_fkey"))
    drop(table(:fsm_message))

    drop(table(:fsa_agent))

    drop(constraint(:fsc_conversation, "fsc_conversation_fsc_ticket_id_fkey"))
    drop(table(:fsc_conversation))

    drop(index(:fsk_ticket, [:fsk_sla_breach_at, :fsk_breached], name: "fsk_ticket_sla_breach_idx"))
    drop(constraint(:fsk_ticket, "fsk_ticket_fsk_sla_id_fkey"))
    drop(table(:fsk_ticket))

    drop(table(:fsl_sla))

    # --- Billing (reverse FK order) ---
    drop(constraint(:fbe_entitlement, "fbe_entitlement_fbe_plan_id_fkey"))
    drop(constraint(:fbe_entitlement, "fbe_entitlement_fbe_subscription_id_fkey"))
    drop(table(:fbe_entitlement))

    drop(constraint(:fbu_usage, "fbu_usage_fbu_subscription_id_fkey"))
    drop(table(:fbu_usage))

    drop(constraint(:fby_payment, "fby_payment_fby_customer_id_fkey"))
    drop(constraint(:fby_payment, "fby_payment_fby_invoice_id_fkey"))
    drop(table(:fby_payment))

    drop(constraint(:fbi_invoice, "fbi_invoice_fbi_subscription_id_fkey"))
    drop(constraint(:fbi_invoice, "fbi_invoice_fbi_customer_id_fkey"))
    drop(table(:fbi_invoice))

    drop(constraint(:fbs_subscription, "fbs_subscription_fbs_plan_id_fkey"))
    drop(constraint(:fbs_subscription, "fbs_subscription_fbs_customer_id_fkey"))
    drop(table(:fbs_subscription))

    drop(constraint(:fbr_price, "fbr_price_fbr_plan_id_fkey"))
    drop(table(:fbr_price))

    drop(table(:fbp_plan))
    drop(table(:fbc_customer))
  end
end
