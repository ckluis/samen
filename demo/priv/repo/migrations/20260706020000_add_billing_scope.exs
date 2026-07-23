defmodule Demo.Repo.Migrations.AddBillingScope do
  @moduledoc """
  Mounts the Billing scope tables into the Demo host's one Postgres, and catalogs
  them in the SAME migration transaction (ADR-004 §"Migrations": the catalog-in-tx
  guarantee requires DDL + catalog_sync in one transaction in the host's repo).

  T3.3 — the Billing scope (Stripe-mirror shape):

    * `bcu_customer`     — 🔒 (billing_name/billing_email vault-routed via pii_ columns)
    * `bsb_subscription` — active billing subscription
    * `bpl_plan`         — Tier-0 config rows: billing plan catalog
    * `bpr_price`        — Tier-0 config rows: price point per plan
    * `bin_invoice`      — billing invoice (line_items as jsonb)
    * `bpy_payment`      — payment record (Stripe-mirror; no raw card data)
    * `bus_usage`        — metered usage for a subscription
    * `ben_entitlement`  — feature entitlement per subscription

  PII columns on `bcu_customer` are `pii_bcu_billing_name` and `pii_bcu_billing_email`
  — scalar PII fields carry the `pii_` prefix per the storage convention. These hold
  vault `vt_*` tokens — plaintext never lands here.

  FK order: Plan → Customer → Subscription → Invoice → Payment
                                            → Entitlement, Usage
  """
  use Samen.Migration

  @resources [
    Demo.BillingScope.Customer,
    Demo.BillingScope.Subscription,
    Demo.BillingScope.Plan,
    Demo.BillingScope.Price,
    Demo.BillingScope.Invoice,
    Demo.BillingScope.Payment,
    Demo.BillingScope.Usage,
    Demo.BillingScope.Entitlement
  ]

  def up do
    # --- bcu_customer : a billing customer 🔒 (billing_name/billing_email vault-routed) ---
    create table(:bcu_customer, primary_key: false) do
      add(:bcu_provider_customer_ref, :text)
      add(:bcu_status, :text, default: "active")
      add(:bcu_currency, :text, default: "USD")
      add(:bcu_custom, :map, default: fragment("'{}'::jsonb"))
      # Scalar PII token columns (vault-routed; pii_ prefix per storage convention):
      add(:pii_bcu_billing_name, :text)
      add(:pii_bcu_billing_email, :text)
      add(:bcu_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:bcu_org_id, :uuid, null: false)
      add(:bcu_inserted_at, :utc_datetime, null: false)
      add(:bcu_updated_at, :utc_datetime, null: false)
    end

    # --- bpl_plan : Tier-0 config rows (billing plan catalog per org) ---
    create table(:bpl_plan, primary_key: false) do
      add(:bpl_name, :text, null: false)
      add(:bpl_label, :text)
      add(:bpl_description, :text)
      add(:bpl_provider_plan_ref, :text)
      add(:bpl_interval, :text, default: "monthly")
      add(:bpl_enabled, :boolean, default: true)
      add(:bpl_features, :map, default: fragment("'{}'::jsonb"))
      add(:bpl_custom, :map, default: fragment("'{}'::jsonb"))
      add(:bpl_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:bpl_org_id, :uuid, null: false)
      add(:bpl_inserted_at, :utc_datetime, null: false)
      add(:bpl_updated_at, :utc_datetime, null: false)
    end

    # --- bpr_price : Tier-0 config rows (price per plan) ---
    create table(:bpr_price, primary_key: false) do
      add(:bpr_provider_price_ref, :text)
      add(:bpr_unit_amount_cents, :integer, null: false)
      add(:bpr_currency, :text, null: false, default: "USD")
      add(:bpr_interval, :text, default: "monthly")
      add(:bpr_active, :boolean, default: true)
      add(:bpr_custom, :map, default: fragment("'{}'::jsonb"))

      add(
        :bpr_plan_id,
        references(:bpl_plan,
          column: :bpl_id,
          name: "bpr_price_bpr_plan_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:bpr_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:bpr_org_id, :uuid, null: false)
      add(:bpr_inserted_at, :utc_datetime, null: false)
      add(:bpr_updated_at, :utc_datetime, null: false)
    end

    # --- bsb_subscription : an active billing subscription ---
    create table(:bsb_subscription, primary_key: false) do
      add(:bsb_provider_subscription_ref, :text)
      add(:bsb_status, :text, default: "active")
      add(:bsb_current_period_start, :utc_datetime)
      add(:bsb_current_period_end, :utc_datetime)
      add(:bsb_trial_end, :utc_datetime)
      add(:bsb_cancel_at, :utc_datetime)
      add(:bsb_cancelled_at, :utc_datetime)
      add(:bsb_custom, :map, default: fragment("'{}'::jsonb"))

      add(
        :bsb_customer_id,
        references(:bcu_customer,
          column: :bcu_id,
          name: "bsb_subscription_bsb_customer_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :bsb_plan_id,
        references(:bpl_plan,
          column: :bpl_id,
          name: "bsb_subscription_bsb_plan_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:bsb_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:bsb_org_id, :uuid, null: false)
      add(:bsb_inserted_at, :utc_datetime, null: false)
      add(:bsb_updated_at, :utc_datetime, null: false)
    end

    # T106 decision (e): DB-unique-fence on the provider-subscription-ref — the
    # idempotency guard for the checkout-seeded + lifecycle mirror convergence
    # (ADR-038 addendum). Nullable column, so local rows with no provider ref are
    # unconstrained (Postgres allows multiple NULLs); non-null provider refs collide.
    create(unique_index(:bsb_subscription, [:bsb_provider_subscription_ref], name: "bsb_subscription_provider_ref_index"))

    # --- bin_invoice : a billing invoice ---
    create table(:bin_invoice, primary_key: false) do
      add(:bin_provider_invoice_ref, :text)
      add(:bin_status, :text, default: "draft")
      add(:bin_amount_due_cents, :integer, default: 0)
      add(:bin_amount_paid_cents, :integer, default: 0)
      add(:bin_currency, :text, default: "USD")
      add(:bin_period_start, :utc_datetime)
      add(:bin_period_end, :utc_datetime)
      add(:bin_due_date, :utc_datetime)
      add(:bin_paid_at, :utc_datetime)
      add(:bin_line_items, {:array, :map}, default: fragment("ARRAY[]::jsonb[]"))
      add(:bin_custom, :map, default: fragment("'{}'::jsonb"))

      add(
        :bin_customer_id,
        references(:bcu_customer,
          column: :bcu_id,
          name: "bin_invoice_bin_customer_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :bin_subscription_id,
        references(:bsb_subscription,
          column: :bsb_id,
          name: "bin_invoice_bin_subscription_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:bin_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:bin_org_id, :uuid, null: false)
      add(:bin_inserted_at, :utc_datetime, null: false)
      add(:bin_updated_at, :utc_datetime, null: false)
    end

    # --- bpy_payment : a payment record (no raw card data) ---
    create table(:bpy_payment, primary_key: false) do
      add(:bpy_provider_payment_ref, :text)
      add(:bpy_status, :text, default: "pending")
      add(:bpy_amount_cents, :integer, null: false)
      add(:bpy_currency, :text, default: "USD")
      add(:bpy_payment_method_type, :text, default: "card")
      add(:bpy_last4, :text)
      add(:bpy_paid_at, :utc_datetime)
      add(:bpy_failure_code, :text)
      add(:bpy_custom, :map, default: fragment("'{}'::jsonb"))

      add(
        :bpy_invoice_id,
        references(:bin_invoice,
          column: :bin_id,
          name: "bpy_payment_bpy_invoice_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :bpy_customer_id,
        references(:bcu_customer,
          column: :bcu_id,
          name: "bpy_payment_bpy_customer_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:bpy_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:bpy_org_id, :uuid, null: false)
      add(:bpy_inserted_at, :utc_datetime, null: false)
      add(:bpy_updated_at, :utc_datetime, null: false)
    end

    # --- bus_usage : metered usage for a subscription ---
    create table(:bus_usage, primary_key: false) do
      add(:bus_metric, :text, null: false)
      add(:bus_quantity, :integer, default: 0)
      add(:bus_period_start, :utc_datetime)
      add(:bus_period_end, :utc_datetime)
      add(:bus_reported_at, :utc_datetime)

      add(
        :bus_subscription_id,
        references(:bsb_subscription,
          column: :bsb_id,
          name: "bus_usage_bus_subscription_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:bus_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:bus_org_id, :uuid, null: false)
      add(:bus_inserted_at, :utc_datetime, null: false)
      add(:bus_updated_at, :utc_datetime, null: false)
    end

    # --- ben_entitlement : feature entitlement for a subscription ---
    create table(:ben_entitlement, primary_key: false) do
      add(:ben_feature, :text, null: false)
      add(:ben_granted, :boolean, default: true)
      add(:ben_expires_at, :utc_datetime)
      add(:ben_custom, :map, default: fragment("'{}'::jsonb"))

      add(
        :ben_subscription_id,
        references(:bsb_subscription,
          column: :bsb_id,
          name: "ben_entitlement_ben_subscription_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :ben_plan_id,
        references(:bpl_plan,
          column: :bpl_id,
          name: "ben_entitlement_ben_plan_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:ben_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:ben_org_id, :uuid, null: false)
      add(:ben_inserted_at, :utc_datetime, null: false)
      add(:ben_updated_at, :utc_datetime, null: false)
    end

    # --- catalog all eight Billing resources in THIS transaction ---
    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    # Drop in reverse FK order.
    drop(constraint(:ben_entitlement, "ben_entitlement_ben_plan_id_fkey"))
    drop(constraint(:ben_entitlement, "ben_entitlement_ben_subscription_id_fkey"))
    drop(table(:ben_entitlement))

    drop(constraint(:bus_usage, "bus_usage_bus_subscription_id_fkey"))
    drop(table(:bus_usage))

    drop(constraint(:bpy_payment, "bpy_payment_bpy_customer_id_fkey"))
    drop(constraint(:bpy_payment, "bpy_payment_bpy_invoice_id_fkey"))
    drop(table(:bpy_payment))

    drop(constraint(:bin_invoice, "bin_invoice_bin_subscription_id_fkey"))
    drop(constraint(:bin_invoice, "bin_invoice_bin_customer_id_fkey"))
    drop(table(:bin_invoice))

    drop(constraint(:bsb_subscription, "bsb_subscription_bsb_plan_id_fkey"))
    drop(constraint(:bsb_subscription, "bsb_subscription_bsb_customer_id_fkey"))
    drop(table(:bsb_subscription))

    drop(constraint(:bpr_price, "bpr_price_bpr_plan_id_fkey"))
    drop(table(:bpr_price))

    drop(table(:bpl_plan))
    drop(table(:bcu_customer))
  end
end
