defmodule Samen.Scopes.Billing.Blueprint do
  @moduledoc """
  Resource-definition macros for the Billing scope (T3.3; ADR-004 blueprint).

  Objects: `customer🔒 · subscription · plan · price · invoice · payment · usage · entitlement`
  (doc §"The inherited 80%" scope table).

  ## Shape — Stripe-mirror

  The Billing scope is modelled as a **Stripe-mirror shape**: the eight objects map to
  Stripe's Customer / Subscription / Plan / Price / Invoice / PaymentIntent /
  UsageRecord / Entitlement surface. No live Stripe calls happen in the resources —
  that is the concern of the host's `SyncAdapter` implementation. The mirror shape is
  the internal, governed representation.

  ## PII map (🔒)

  | Resource | Field         | Vault      | Column type                        |
  |----------|---------------|------------|------------------------------------|
  | customer | billing_name  | :pii_name  | scalar (column: pii_bcu_billing_name)  |
  | customer | billing_email | :pii_email | scalar (column: pii_bcu_billing_email) |

  Scalar `pii_attribute`s carry the `pii_` prefix per the scope-authoring guide §5.
  All other resources carry only opaque IDs and bounded data — no subject PII.

  ## Tier-0 config rows

  `Plan` and `Price` are the Tier-0 config-row resources (malleability ladder §7):
  one row per plan/price per org. Tenants set up their billing catalog without forking
  the product. Admin-gated writes.

  ## Storage-name discipline

  Every column is `<abbrev>_<name>` (self-qualifying storage, injected by the Samen
  base macro). PII scalar fields carry the `pii_` prefix FIRST — the canonical shape
  `pii_<abbrev>_<name>` the `MaterializePii` transformer emits (e.g. `pii_bcu_billing_name`).
  The public API/catalog only ever sees the logical name.

  ## Sync adapter seam

  Host applications that want to sync with Stripe implement the
  `Samen.Scopes.Billing.SyncAdapter` behaviour. The resource layer here is the
  governed internal mirror; the sync adapter is an opt-in host concern.
  """

  # ---------------------------------------------------------------------------
  # Customer — 🔒 PII: billing_name (vault :pii_name), billing_email (vault :pii_email).
  # Org-scoped. A Stripe-mirror customer record.
  # ---------------------------------------------------------------------------
  defmacro define_customer(module, otp_app, domain, repo, abbrev) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Billing.Customer — a billing customer record 🔒 (doc scope table `customer🔒`).

        `billing_name` and `billing_email` are vault-routed PII (masked by default;
        plaintext only via the declared reveal action under a grant). Org-scoped.

        Maps to Stripe Customer. The Stripe customer ID (`stripe_customer_id`) is an
        opaque external reference — NOT PII, NOT vault-routed (it is a vendor ID, not
        subject identity data).
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_customer")
          repo(unquote(repo))
        end

        attributes do
          # Opaque Stripe vendor ID. Not PII (it is a vendor reference, not a subject
          # identity field). Non-pii! by design: Stripe generates it, it never names
          # or identifies a natural person by itself.
          attribute(:stripe_customer_id, :string, public?: true)
          attribute(:status, :atom,
            public?: true,
            default: :active,
            constraints: [one_of: [:active, :inactive, :deleted]]
          )
          # Non-PII currency preference.
          attribute(:currency, :string, public?: true, default: "USD")
          # Tier-1 custom bag.
          attribute(:custom, :map, public?: true)
        end

        pii do
          vault(:pii_name)
          vault(:pii_email)

          # Scalar PII: columns carry the pii_ prefix (pii_bcu_billing_name, pii_bcu_billing_email).
          pii_attribute(:billing_name, :string, vault: :pii_name)
          pii_attribute(:billing_email, :string, vault: :pii_email)

          reveal(:reveal_customer)
        end

        actions do
          defaults([:read, :destroy, create: :*, update: :*])

          # The declared reveal action (plaintext under a grant only).
          action :reveal_customer, :map do
            argument(:actor_id, :string, allow_nil?: false)
            argument(:subject_id, :string, allow_nil?: false)

            run(fn input, _ctx ->
              ctx = %Samen.Reveal.Context{
                actor: input.arguments.actor_id,
                subject_id: input.arguments.subject_id,
                resource: __MODULE__,
                action: :reveal_customer,
                label: :billing_email
              }

              if Samen.Reveal.grant_checker().granted?(ctx) do
                {:ok, %{status: "granted", subject_id: input.arguments.subject_id}}
              else
                {:error, :denied}
              end
            end)
          end
        end

        policies do
          policy action_type([:read, :create, :update, :destroy]) do
            authorize_if(Samen.Policy.OrgScope)
          end

          # The reveal action's grant gate (inside run/2) is the real control.
          # Allow it to run for any actor — the grant check denies by default.
          policy action(:reveal_customer) do
            authorize_if(always())
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Subscription — active/inactive billing subscription. Org-scoped. No PII.
  # Belongs to a customer + plan.
  # ---------------------------------------------------------------------------
  defmacro define_subscription(
             module,
             otp_app,
             domain,
             repo,
             abbrev,
             customer_mod,
             plan_mod,
             event_mod,
             price_mod
           ) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Billing.Subscription — an active billing subscription (doc scope table
        `subscription`). Tied to a customer and a plan. Org-scoped. No PII.

        Maps to Stripe Subscription. `stripe_subscription_id` is an opaque vendor
        reference, not PII.
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_subscription")
          repo(unquote(repo))
        end

        attributes do
          attribute(:stripe_subscription_id, :string, public?: true)
          attribute(:status, :atom,
            public?: true,
            default: :active,
            constraints: [one_of: [:active, :inactive, :trialing, :past_due, :cancelled, :unpaid]]
          )
          attribute(:current_period_start, :utc_datetime, public?: true)
          attribute(:current_period_end, :utc_datetime, public?: true)
          attribute(:trial_end, :utc_datetime, public?: true)
          attribute(:cancel_at, :utc_datetime, public?: true)
          attribute(:cancelled_at, :utc_datetime, public?: true)
          # Tier-1 custom bag.
          attribute(:custom, :map, public?: true)
        end

        relationships do
          belongs_to :customer, unquote(customer_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(false)
          end

          belongs_to :plan, unquote(plan_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(true)
          end
        end

        actions do
          defaults([:read, :destroy, create: :*, update: :*])
        end

        # F3.2 same-org FK: a subscription may only reference a same-org customer/plan.
        changes do
          change({Samen.Policy.SameOrgFk, relationships: [:customer, :plan]})

          # WS-B / G7 (ADR-017): the movement-capture seam. On every subscription
          # create/update, append ONE bounded, non-PII `mov` row via the pure
          # MovementClassifier — best-effort (an append failure NEVER aborts the
          # subscription write; the state is load-bearing, the ledger rides along),
          # exactly like the Invoice StatusChange seam. Verticals inherit emission
          # at 0 LOC (the change is on the kernel blueprint).
          change(
            {Samen.Billing.SubscriptionMovement,
             event_resource: unquote(event_mod),
             plan_resource: unquote(plan_mod),
             price_resource: unquote(price_mod)}
          )
        end

        policies do
          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end

          policy action_type([:create, :update, :destroy]) do
            forbid_unless(Samen.Policy.OrgScope)
            forbid_unless({Samen.Policy.RoleAtLeast, role: :admin})
            authorize_if(always())
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Plan — Tier-0 config rows: the per-org billing plan catalog. Org-scoped.
  # Admin-gated writes. The malleability ladder's bottom rung.
  # ---------------------------------------------------------------------------
  defmacro define_plan(module, otp_app, domain, repo, abbrev) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Billing.Plan — Tier-0 config rows (doc scope table `plan`; malleability
        ladder §7 "config rows cover ~70%"). One row per billing plan per org.
        Tenants set up their plan catalog (Free / Pro / Enterprise) without forking
        the product. Admin-gated writes. Org-scoped.

        Maps to Stripe Plan / Product. `stripe_plan_id` is an opaque vendor reference.
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_plan")
          repo(unquote(repo))
        end

        attributes do
          attribute(:name, :string, public?: true, allow_nil?: false)
          attribute(:label, :string, public?: true)
          attribute(:description, :string, public?: true)
          attribute(:stripe_plan_id, :string, public?: true)
          attribute(:interval, :atom,
            public?: true,
            default: :monthly,
            constraints: [one_of: [:monthly, :annual, :weekly, :daily, :one_time]]
          )
          attribute(:enabled, :boolean, public?: true, default: true)
          # Feature entitlements granted by this plan (bounded map: %{feature_key => true}).
          attribute(:features, :map, public?: true, default: %{})
          # Tier-1 custom bag.
          attribute(:custom, :map, public?: true)
        end

        actions do
          defaults([:read, :destroy, create: :*, update: :*])
        end

        policies do
          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end

          policy action_type([:create, :update, :destroy]) do
            forbid_unless(Samen.Policy.OrgScope)
            forbid_unless({Samen.Policy.RoleAtLeast, role: :admin})
            authorize_if(always())
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Price — Tier-0 config rows: a price point for a plan. Org-scoped.
  # Admin-gated writes. Belongs to a Plan.
  # ---------------------------------------------------------------------------
  defmacro define_price(module, otp_app, domain, repo, abbrev, plan_mod) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Billing.Price — Tier-0 config rows (doc scope table `price`). One price
        point per plan per org (e.g. $29/mo for Pro Monthly, $290/yr for Pro Annual).
        Admin-gated writes. Org-scoped.

        Maps to Stripe Price. `stripe_price_id` is an opaque vendor reference.
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_price")
          repo(unquote(repo))
        end

        attributes do
          attribute(:stripe_price_id, :string, public?: true)
          attribute(:unit_amount_cents, :integer, public?: true, allow_nil?: false)
          attribute(:currency, :string, public?: true, allow_nil?: false, default: "USD")
          attribute(:interval, :atom,
            public?: true,
            default: :monthly,
            constraints: [one_of: [:monthly, :annual, :weekly, :daily, :one_time]]
          )
          attribute(:active, :boolean, public?: true, default: true)
          # Tier-1 custom bag.
          attribute(:custom, :map, public?: true)
        end

        relationships do
          belongs_to :plan, unquote(plan_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(false)
          end
        end

        # F3.5 same-org FK: a price may only reference a same-org plan.
        changes do
          change({Samen.Policy.SameOrgFk, relationships: [:plan]})
        end

        actions do
          defaults([:read, :destroy, create: :*, update: :*])
        end

        policies do
          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end

          policy action_type([:create, :update, :destroy]) do
            forbid_unless(Samen.Policy.OrgScope)
            forbid_unless({Samen.Policy.RoleAtLeast, role: :admin})
            authorize_if(always())
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Invoice — a billing invoice. Org-scoped. No PII. Belongs to customer + subscription.
  # ---------------------------------------------------------------------------
  defmacro define_invoice(module, otp_app, domain, repo, abbrev, customer_mod, subscription_mod) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Billing.Invoice — a billing invoice (doc scope table `invoice`). Linked to a
        customer and subscription. Line items stored as a bounded jsonb map.
        Org-scoped. No PII (customer references are opaque IDs).

        Maps to Stripe Invoice. `stripe_invoice_id` is an opaque vendor reference.
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_invoice")
          repo(unquote(repo))
        end

        attributes do
          attribute(:stripe_invoice_id, :string, public?: true)
          attribute(:status, :atom,
            public?: true,
            default: :draft,
            constraints: [one_of: [:draft, :open, :paid, :void, :uncollectible]]
          )
          attribute(:amount_due_cents, :integer, public?: true, default: 0)
          attribute(:amount_paid_cents, :integer, public?: true, default: 0)
          attribute(:currency, :string, public?: true, default: "USD")
          attribute(:period_start, :utc_datetime, public?: true)
          attribute(:period_end, :utc_datetime, public?: true)
          attribute(:due_date, :utc_datetime, public?: true)
          attribute(:paid_at, :utc_datetime, public?: true)
          # Line items as bounded jsonb: [%{description:, amount_cents:, quantity:}]
          attribute(:line_items, {:array, :map}, public?: true, default: [])
          # Tier-1 custom bag.
          attribute(:custom, :map, public?: true)
        end

        relationships do
          belongs_to :customer, unquote(customer_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(false)
          end

          belongs_to :subscription, unquote(subscription_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(true)
          end
        end

        actions do
          defaults([:read, :destroy, create: :*, update: :*])
        end

        # F3.2 same-org FK: an invoice may only reference a same-org customer/subscription.
        changes do
          change({Samen.Policy.SameOrgFk, relationships: [:customer, :subscription]})

          # WS-A A4 event source (design §2.3 "invoice events"): a status TRANSITION
          # to open/paid/void/uncollectible emits an in-app notification through
          # Samen.Notifications.Engine.emit/1 — best-effort (an unwired engine or an
          # engine error never aborts the invoice write) and preference-gated (a
          # suppressed event type writes NO record). Bounded ids + framework copy
          # only; the subject travels as an object REF, never denormalized data.
          change(
            {Samen.Notifications.StatusChange,
             event_prefix: "invoice",
             ref_key: "billing.invoice",
             statuses: [:open, :paid, :void, :uncollectible]}
          )
        end

        policies do
          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end

          policy action_type([:create, :update, :destroy]) do
            forbid_unless(Samen.Policy.OrgScope)
            forbid_unless({Samen.Policy.RoleAtLeast, role: :admin})
            authorize_if(always())
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Payment — a payment record. Org-scoped. No PII. Belongs to invoice + customer.
  # ---------------------------------------------------------------------------
  defmacro define_payment(module, otp_app, domain, repo, abbrev, invoice_mod, customer_mod) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Billing.Payment — a payment record (doc scope table `payment`). Linked to an
        invoice and a customer. Org-scoped. No PII.

        Maps to Stripe PaymentIntent. `stripe_payment_intent_id` is an opaque vendor
        reference. Card/bank details are NEVER stored here — those live in Stripe's
        vault. This record carries only amounts, status, and opaque IDs.
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_payment")
          repo(unquote(repo))
        end

        attributes do
          attribute(:stripe_payment_intent_id, :string, public?: true)
          attribute(:status, :atom,
            public?: true,
            default: :pending,
            constraints: [
              one_of: [:pending, :succeeded, :failed, :cancelled, :requires_action, :processing]
            ]
          )
          attribute(:amount_cents, :integer, public?: true, allow_nil?: false)
          attribute(:currency, :string, public?: true, default: "USD")
          attribute(:payment_method_type, :atom,
            public?: true,
            default: :card,
            constraints: [one_of: [:card, :bank_transfer, :sepa, :ach, :other]]
          )
          # Last 4 digits of card (non-PII metadata safe to display; never full PAN).
          attribute(:last4, :string, public?: true)
          attribute(:paid_at, :utc_datetime, public?: true)
          attribute(:failure_code, :string, public?: true)
          # Tier-1 custom bag.
          attribute(:custom, :map, public?: true)
        end

        relationships do
          belongs_to :invoice, unquote(invoice_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(true)
          end

          belongs_to :customer, unquote(customer_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(false)
          end
        end

        actions do
          defaults([:read, :destroy, create: :*, update: :*])
        end

        # F3.2 same-org FK: a payment may only reference a same-org invoice/customer.
        changes do
          change({Samen.Policy.SameOrgFk, relationships: [:invoice, :customer]})
        end

        policies do
          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end

          policy action_type([:create, :update, :destroy]) do
            forbid_unless(Samen.Policy.OrgScope)
            forbid_unless({Samen.Policy.RoleAtLeast, role: :admin})
            authorize_if(always())
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Usage — metered usage for a subscription. Org-scoped. No PII.
  # ---------------------------------------------------------------------------
  defmacro define_usage(module, otp_app, domain, repo, abbrev, subscription_mod) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Billing.Usage — metered usage for a subscription (doc scope table `usage`).
        One row per metric per billing window per subscription. Org-scoped. No PII.

        Maps to Stripe UsageRecord. Used to track seat-count, API calls, storage, etc.
        for usage-based billing plans.
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_usage")
          repo(unquote(repo))
        end

        attributes do
          # The metric being measured (e.g. :api_calls, :seats, :storage_gb).
          # Bounded atom to prevent free-text cardinality explosion.
          attribute(:metric, :atom,
            public?: true,
            allow_nil?: false,
            constraints: [
              one_of: [:api_calls, :seats, :storage_gb, :events, :messages, :custom_metric]
            ]
          )
          attribute(:quantity, :integer, public?: true, allow_nil?: false, default: 0)
          attribute(:period_start, :utc_datetime, public?: true)
          attribute(:period_end, :utc_datetime, public?: true)
          attribute(:reported_at, :utc_datetime, public?: true)
        end

        relationships do
          belongs_to :subscription, unquote(subscription_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(false)
          end
        end

        # F3.5 same-org FK: a usage row may only reference a same-org subscription.
        changes do
          change({Samen.Policy.SameOrgFk, relationships: [:subscription]})
        end

        actions do
          defaults([:read, :destroy, create: :*, update: :*])
        end

        policies do
          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end

          policy action_type([:create, :update, :destroy]) do
            forbid_unless(Samen.Policy.OrgScope)
            forbid_unless({Samen.Policy.RoleAtLeast, role: :member})
            authorize_if(always())
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # SubscriptionEvent (`mov`) — the append-only subscription-movement ledger
  # (WS-B / G7; ADR-017). One row per subscription create/update, appended by the
  # `Samen.Billing.SubscriptionMovement` change. Token-blind by construction: every
  # column is a bounded id / enum / integer / timestamp — NO PII. Org-scoped.
  # Belongs (soft ref, id only) to a subscription/customer/plan.
  # ---------------------------------------------------------------------------
  defmacro define_subscription_event(module, otp_app, domain, repo, abbrev) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Billing.SubscriptionEvent (`mov`) — the append-only subscription-movement
        ledger (ADR-017; WS-B / G7 revenue analytics). One row is appended per
        subscription create/update by `Samen.Billing.SubscriptionMovement`, carrying
        the movement `kind` (new/expansion/contraction/churn/reactivation/noop), the
        SIGNED `mrr_delta_cents`, and the `mrr_before_cents`/`mrr_after_cents` so the
        ledger reconciles without a re-join to price history (Invariant R1).

        ## Append-only

        No `:update` / `:destroy` action is exposed — a movement is an immutable
        historical fact. Rows shred via the standard rollup erasure arm (subject-keyed
        on `customer_id`), never mutated in place.

        ## No PII by construction

        Every column is a bounded id (uuid ref), an enum, a signed integer, or a
        timestamp — the same discipline as `Samen.WideEvent`. A name/email/freeform
        string CANNOT enter a `mov` row; the resource carries no `pii do` block and no
        plain string attribute. This is what lets `mov` mirror cleanly through the
        vault-excluded CDC projection and feed cross-tenant revenue tiers under the
        k-anon floors without a masking fork (ADR-017 §3).

        Org-scoped: `OrgScope` read + admin-gated create (the change writes with
        `authorize?: false` as a framework emit, like the notifications engine).
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_subscription_event")
          repo(unquote(repo))
        end

        attributes do
          # Bounded soft refs (id only — NOT belongs_to, so a shredded/deleted
          # subscription never blocks the immutable historical row). No FK cascade:
          # the ledger outlives the mutable subscription row it describes.
          attribute(:subscription_id, :uuid, public?: true, allow_nil?: false)
          attribute(:customer_id, :uuid, public?: true)
          attribute(:plan_id, :uuid, public?: true)
          attribute(:from_plan_id, :uuid, public?: true)

          # The classified movement kind (bounded enum — from MovementClassifier).
          attribute(:kind, :atom,
            public?: true,
            allow_nil?: false,
            constraints: [
              one_of: [:new, :expansion, :contraction, :churn, :reactivation, :noop]
            ]
          )

          # The reconciliation quantity: signed MRR delta + self-contained before/after.
          attribute(:mrr_delta_cents, :integer, public?: true, allow_nil?: false, default: 0)
          attribute(:mrr_before_cents, :integer, public?: true, allow_nil?: false, default: 0)
          attribute(:mrr_after_cents, :integer, public?: true, allow_nil?: false, default: 0)

          # The from/to status pair the movement was classified from (bounded enums —
          # auditability of the classification without a re-derivation).
          attribute(:from_status, :atom,
            public?: true,
            constraints: [
              one_of: [:active, :inactive, :trialing, :past_due, :cancelled, :unpaid]
            ]
          )

          attribute(:to_status, :atom,
            public?: true,
            constraints: [
              one_of: [:active, :inactive, :trialing, :past_due, :cancelled, :unpaid]
            ]
          )

          # The bounded reason for the movement (why the row exists).
          attribute(:reason, :atom,
            public?: true,
            default: :status_change,
            constraints: [
              one_of: [:status_change, :price_change, :backfill_snapshot]
            ]
          )

          attribute(:occurred_at, :utc_datetime, public?: true, allow_nil?: false)
        end

        actions do
          # Append-only: read + a bounded create action ONLY. No update/destroy — a
          # movement is an immutable fact. (Erasure shreds via the rollup arm, not a
          # per-row destroy exposed to callers.)
          defaults([:read])

          create :append do
            accept([
              :subscription_id,
              :customer_id,
              :plan_id,
              :from_plan_id,
              :kind,
              :mrr_delta_cents,
              :mrr_before_cents,
              :mrr_after_cents,
              :from_status,
              :to_status,
              :reason,
              :occurred_at,
              :org_id
            ])
          end
        end

        policies do
          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end

          # Append is admin-gated on the tenant plane; the framework change writes
          # with authorize?: false (a system-emitted row, like the notifications
          # engine), so this gate governs any DIRECT caller.
          policy action_type(:create) do
            forbid_unless(Samen.Policy.OrgScope)
            forbid_unless({Samen.Policy.RoleAtLeast, role: :admin})
            authorize_if(always())
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Entitlement — a feature entitlement for a subscription. Org-scoped. No PII.
  # Belongs to subscription + plan.
  # ---------------------------------------------------------------------------
  defmacro define_entitlement(
             module,
             otp_app,
             domain,
             repo,
             abbrev,
             subscription_mod,
             plan_mod
           ) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Billing.Entitlement — a feature entitlement for a subscription (doc scope table
        `entitlement`). One row per feature per subscription; the `entitled?/3` check
        helper gates feature access by querying these rows.

        Org-scoped. No PII. Feature keys are bounded atoms.

        Example check:

            Samen.Scopes.Billing.Entitlement.entitled?(org_id, :advanced_reporting, repo)
            # => {:ok, true} | {:ok, false}
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_entitlement")
          repo(unquote(repo))
        end

        attributes do
          # The feature this entitlement grants. Bounded atom: product-defined feature
          # keys. A plan grants a set of features (Plan.features map); this row is the
          # per-subscription materialized entitlement.
          attribute(:feature, :atom,
            public?: true,
            allow_nil?: false,
            constraints: [
              one_of: [
                :basic,
                :advanced_reporting,
                :api_access,
                :custom_domains,
                :sso,
                :audit_log,
                :priority_support,
                :unlimited_seats,
                :custom_metric
              ]
            ]
          )
          attribute(:granted, :boolean, public?: true, default: true)
          attribute(:expires_at, :utc_datetime, public?: true)
          # Tier-1 custom bag.
          attribute(:custom, :map, public?: true)
        end

        relationships do
          belongs_to :subscription, unquote(subscription_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(false)
          end

          belongs_to :plan, unquote(plan_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(true)
          end
        end

        # F3.5 same-org FK: an entitlement may only reference a same-org subscription/plan.
        changes do
          change({Samen.Policy.SameOrgFk, relationships: [:subscription, :plan]})
        end

        actions do
          defaults([:read, :destroy, create: :*, update: :*])
        end

        policies do
          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end

          policy action_type([:create, :update, :destroy]) do
            forbid_unless(Samen.Policy.OrgScope)
            forbid_unless({Samen.Policy.RoleAtLeast, role: :admin})
            authorize_if(always())
          end
        end
      end
    end
  end
end
