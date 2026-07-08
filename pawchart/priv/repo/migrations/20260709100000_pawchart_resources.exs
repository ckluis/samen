defmodule PawChart.Repo.Migrations.PawchartResources do
  @moduledoc """
  Mounts PawChart's Billing scope (fresh abbrevs pbc/pbs/pbl/ppc/pbi/pby/pbu/pbe) AS-IS
  (plain subscriptions — NO reshape, the additive contrast to Driftwood's settlement
  reshape) + the vertical Clinical tables (own_patient / pet_pet) + the token-blind
  aggregate projection (pag), and catalogs every resource in the SAME migration
  transaction (ADR-004 catalog-in-tx).

  Patient folds in CorePerson (own_full_name/own_emails/own_phones vault tokens +
  own_job_title/own_custom) — the human OWNER is the PII subject. Pet carries the scalar
  vault field pii_pet_microchip (vt_* token) + non-PII clinical columns (species/breed/
  weight/temperament) + the owner FK. The doc's "two PII subjects, one relationship".
  """
  use Samen.Migration

  @resources [
    PawChart.Billing.Customer,
    PawChart.Billing.Subscription,
    PawChart.Billing.Plan,
    PawChart.Billing.Price,
    PawChart.Billing.Invoice,
    PawChart.Billing.Payment,
    PawChart.Billing.Usage,
    PawChart.Billing.Entitlement,
    PawChart.Clinic.Patient,
    PawChart.Clinic.Pet,
    PawChart.Aggregate.PatientVolumeBySpecies
  ]

  def up do
    # =========================================================================
    # Billing scope (Stripe-mirror shape) — mounted AS-IS, no reshape.
    # =========================================================================

    # --- pbc_customer : a billing customer 🔒 (billing_name/billing_email vault-routed) ---
    create table(:pbc_customer, primary_key: false) do
      add(:pbc_stripe_customer_id, :text)
      add(:pbc_status, :text, default: "active")
      add(:pbc_currency, :text, default: "USD")
      add(:pbc_custom, :map, default: fragment("'{}'::jsonb"))
      add(:pii_pbc_billing_name, :text)
      add(:pii_pbc_billing_email, :text)
      add(:pbc_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:pbc_org_id, :uuid, null: false)
      add(:pbc_inserted_at, :utc_datetime, null: false)
      add(:pbc_updated_at, :utc_datetime, null: false)
    end

    # --- pbl_plan : Tier-0 config rows (billing plan catalog per org) ---
    create table(:pbl_plan, primary_key: false) do
      add(:pbl_name, :text, null: false)
      add(:pbl_label, :text)
      add(:pbl_description, :text)
      add(:pbl_stripe_plan_id, :text)
      add(:pbl_interval, :text, default: "monthly")
      add(:pbl_enabled, :boolean, default: true)
      add(:pbl_features, :map, default: fragment("'{}'::jsonb"))
      add(:pbl_custom, :map, default: fragment("'{}'::jsonb"))
      add(:pbl_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:pbl_org_id, :uuid, null: false)
      add(:pbl_inserted_at, :utc_datetime, null: false)
      add(:pbl_updated_at, :utc_datetime, null: false)
    end

    # --- ppc_price : Tier-0 config rows (price per plan) ---
    create table(:ppc_price, primary_key: false) do
      add(:ppc_stripe_price_id, :text)
      add(:ppc_unit_amount_cents, :integer, null: false)
      add(:ppc_currency, :text, null: false, default: "USD")
      add(:ppc_interval, :text, default: "monthly")
      add(:ppc_active, :boolean, default: true)
      add(:ppc_custom, :map, default: fragment("'{}'::jsonb"))

      add(
        :ppc_plan_id,
        references(:pbl_plan,
          column: :pbl_id,
          name: "ppc_price_ppc_plan_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:ppc_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:ppc_org_id, :uuid, null: false)
      add(:ppc_inserted_at, :utc_datetime, null: false)
      add(:ppc_updated_at, :utc_datetime, null: false)
    end

    # --- pbs_subscription : an active billing subscription (REUSED AS-IS) ---
    create table(:pbs_subscription, primary_key: false) do
      add(:pbs_stripe_subscription_id, :text)
      add(:pbs_status, :text, default: "active")
      add(:pbs_current_period_start, :utc_datetime)
      add(:pbs_current_period_end, :utc_datetime)
      add(:pbs_trial_end, :utc_datetime)
      add(:pbs_cancel_at, :utc_datetime)
      add(:pbs_cancelled_at, :utc_datetime)
      add(:pbs_custom, :map, default: fragment("'{}'::jsonb"))

      add(
        :pbs_customer_id,
        references(:pbc_customer,
          column: :pbc_id,
          name: "pbs_subscription_pbs_customer_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :pbs_plan_id,
        references(:pbl_plan,
          column: :pbl_id,
          name: "pbs_subscription_pbs_plan_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:pbs_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:pbs_org_id, :uuid, null: false)
      add(:pbs_inserted_at, :utc_datetime, null: false)
      add(:pbs_updated_at, :utc_datetime, null: false)
    end

    # --- pbi_invoice : a billing invoice ---
    create table(:pbi_invoice, primary_key: false) do
      add(:pbi_stripe_invoice_id, :text)
      add(:pbi_status, :text, default: "draft")
      add(:pbi_amount_due_cents, :integer, default: 0)
      add(:pbi_amount_paid_cents, :integer, default: 0)
      add(:pbi_currency, :text, default: "USD")
      add(:pbi_period_start, :utc_datetime)
      add(:pbi_period_end, :utc_datetime)
      add(:pbi_due_date, :utc_datetime)
      add(:pbi_paid_at, :utc_datetime)
      add(:pbi_line_items, {:array, :map}, default: fragment("ARRAY[]::jsonb[]"))
      add(:pbi_custom, :map, default: fragment("'{}'::jsonb"))

      add(
        :pbi_customer_id,
        references(:pbc_customer,
          column: :pbc_id,
          name: "pbi_invoice_pbi_customer_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :pbi_subscription_id,
        references(:pbs_subscription,
          column: :pbs_id,
          name: "pbi_invoice_pbi_subscription_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:pbi_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:pbi_org_id, :uuid, null: false)
      add(:pbi_inserted_at, :utc_datetime, null: false)
      add(:pbi_updated_at, :utc_datetime, null: false)
    end

    # --- pby_payment : a payment record (no raw card data) ---
    create table(:pby_payment, primary_key: false) do
      add(:pby_stripe_payment_intent_id, :text)
      add(:pby_status, :text, default: "pending")
      add(:pby_amount_cents, :integer, null: false)
      add(:pby_currency, :text, default: "USD")
      add(:pby_payment_method_type, :text, default: "card")
      add(:pby_last4, :text)
      add(:pby_paid_at, :utc_datetime)
      add(:pby_failure_code, :text)
      add(:pby_custom, :map, default: fragment("'{}'::jsonb"))

      add(
        :pby_invoice_id,
        references(:pbi_invoice,
          column: :pbi_id,
          name: "pby_payment_pby_invoice_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :pby_customer_id,
        references(:pbc_customer,
          column: :pbc_id,
          name: "pby_payment_pby_customer_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:pby_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:pby_org_id, :uuid, null: false)
      add(:pby_inserted_at, :utc_datetime, null: false)
      add(:pby_updated_at, :utc_datetime, null: false)
    end

    # --- pbu_usage : metered usage for a subscription ---
    create table(:pbu_usage, primary_key: false) do
      add(:pbu_metric, :text, null: false)
      add(:pbu_quantity, :integer, default: 0)
      add(:pbu_period_start, :utc_datetime)
      add(:pbu_period_end, :utc_datetime)
      add(:pbu_reported_at, :utc_datetime)

      add(
        :pbu_subscription_id,
        references(:pbs_subscription,
          column: :pbs_id,
          name: "pbu_usage_pbu_subscription_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:pbu_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:pbu_org_id, :uuid, null: false)
      add(:pbu_inserted_at, :utc_datetime, null: false)
      add(:pbu_updated_at, :utc_datetime, null: false)
    end

    # --- pbe_entitlement : feature entitlement for a subscription ---
    create table(:pbe_entitlement, primary_key: false) do
      add(:pbe_feature, :text, null: false)
      add(:pbe_granted, :boolean, default: true)
      add(:pbe_expires_at, :utc_datetime)
      add(:pbe_custom, :map, default: fragment("'{}'::jsonb"))

      add(
        :pbe_subscription_id,
        references(:pbs_subscription,
          column: :pbs_id,
          name: "pbe_entitlement_pbe_subscription_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :pbe_plan_id,
        references(:pbl_plan,
          column: :pbl_id,
          name: "pbe_entitlement_pbe_plan_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:pbe_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:pbe_org_id, :uuid, null: false)
      add(:pbe_inserted_at, :utc_datetime, null: false)
      add(:pbe_updated_at, :utc_datetime, null: false)
    end

    # =========================================================================
    # Clinical vertical (the authored 20%).
    # =========================================================================

    # --- own_patient : the HUMAN OWNER (CorePerson folded in, vault-routed) ---
    create table(:own_patient, primary_key: false) do
      # CorePerson composite PII (vault vt_* tokens):
      add(:own_full_name, :text)
      add(:own_emails, :text)
      add(:own_phones, :text)
      add(:own_job_title, :text)
      add(:own_custom, :map, default: fragment("'{}'::jsonb"))
      # Authored non-PII domain column:
      add(:own_marketing_opt_in, :boolean, default: false)
      add(:own_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:own_org_id, :uuid, null: false)
      add(:own_inserted_at, :utc_datetime, null: false)
      add(:own_updated_at, :utc_datetime, null: false)
    end

    # --- pet_pet : the ANIMAL / clinical record + microchip PII + Tier-0 temperament ---
    create table(:pet_pet, primary_key: false) do
      # Scalar pii_ vault field: microchip UID → pii_pet_microchip (vt_* token):
      add(:pii_pet_microchip, :text)
      add(:pet_name, :text)
      add(:pet_species, :text)
      add(:pet_breed, :text)
      add(:pet_weight_kg, :decimal)
      add(:pet_temperament, :text, default: "unknown")

      add(
        :pet_owner_id,
        references(:own_patient,
          column: :own_id,
          name: "pet_pet_pet_owner_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:pet_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:pet_org_id, :uuid, null: false)
      add(:pet_inserted_at, :utc_datetime, null: false)
      add(:pet_updated_at, :utc_datetime, null: false)
    end

    # =========================================================================
    # Token-blind aggregate plane projection (vault-excluded, no pii_ columns).
    # =========================================================================

    # --- pag_patient_volume_by_species : cross-tenant pet volume by species ---
    create table(:pag_patient_volume_by_species, primary_key: false) do
      add(:pag_species, :text, null: false)
      add(:pag_clinic_count, :integer, default: 0)
      add(:pag_pet_count, :integer, default: 0)
      add(:pag_refreshed_at, :utc_datetime)
      add(:pag_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      # Cross-tenant: org_id stays NULL (the aggregate actor has no org).
      add(:pag_org_id, :uuid)
      add(:pag_inserted_at, :utc_datetime, null: false)
      add(:pag_updated_at, :utc_datetime, null: false)
    end

    # --- catalog every resource in THIS transaction ---
    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(table(:pag_patient_volume_by_species))

    drop(constraint(:pet_pet, "pet_pet_pet_owner_id_fkey"))
    drop(table(:pet_pet))
    drop(table(:own_patient))

    drop(constraint(:pbe_entitlement, "pbe_entitlement_pbe_plan_id_fkey"))
    drop(constraint(:pbe_entitlement, "pbe_entitlement_pbe_subscription_id_fkey"))
    drop(table(:pbe_entitlement))

    drop(constraint(:pbu_usage, "pbu_usage_pbu_subscription_id_fkey"))
    drop(table(:pbu_usage))

    drop(constraint(:pby_payment, "pby_payment_pby_customer_id_fkey"))
    drop(constraint(:pby_payment, "pby_payment_pby_invoice_id_fkey"))
    drop(table(:pby_payment))

    drop(constraint(:pbi_invoice, "pbi_invoice_pbi_subscription_id_fkey"))
    drop(constraint(:pbi_invoice, "pbi_invoice_pbi_customer_id_fkey"))
    drop(table(:pbi_invoice))

    drop(constraint(:pbs_subscription, "pbs_subscription_pbs_plan_id_fkey"))
    drop(constraint(:pbs_subscription, "pbs_subscription_pbs_customer_id_fkey"))
    drop(table(:pbs_subscription))

    drop(constraint(:ppc_price, "ppc_price_ppc_plan_id_fkey"))
    drop(table(:ppc_price))

    drop(table(:pbl_plan))
    drop(table(:pbc_customer))
  end
end
