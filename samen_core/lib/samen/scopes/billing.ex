defmodule Samen.Scopes.Billing do
  @moduledoc """
  The **Billing** universal scope (T3.3; doc §"The inherited 80%" scope table:
  `customer🔒 · subscription · plan · price · invoice · payment · usage · entitlement`).

  Ships as a **library-authored blueprint** (ADR-004): `use`-ing this module inside a
  host's Ash domain expands into eight host-owned resources in the host's namespace
  — each a normal `use Samen.Resource` with the host's `otp_app`, `repo`, and `domain`.

  ## Provider-mirror shape

  Billing is modelled as a **provider-mirror shape**: the eight objects map directly
  to a hosted billing provider's Customer / Subscription / Plan / Price / Invoice /
  PaymentIntent / UsageRecord / Entitlement surface. **No live provider calls are
  made here** — this is the internal mirror. Synchronization with the external
  provider is the concern of the `Samen.Billing.Provider` behaviour (ADR-038 §3),
  which a separate, first-party-but-separate adapter package implements; core
  tests select the honest `Samen.Billing.FakeProvider` double instead of a live
  vendor.

  ## PII — customer🔒

  `customer🔒` is the only 🔒 object in this scope. It carries:

    * `billing_name`  → vault `:pii_name`  (scalar; column `pii_bcu_billing_name`)
    * `billing_email` → vault `:pii_email` (scalar; column `pii_bcu_billing_email`)

  All other resources carry only opaque IDs and bounded data — no subject identity.

  ## Tier-0 config rows

  `Plan` and `Price` are the Billing scope's Tier-0 config-row resources: one row per
  plan/price per org. Admins set up their billing catalog without forking the product
  (malleability ladder bottom rung, doc §"A malleability ladder").

  ## Entitlement check helper

  `Samen.Scopes.Billing.Entitlement.entitled?/3` checks whether an org is entitled
  to a named feature given its active subscription:

      Samen.Scopes.Billing.Entitlement.entitled?(org_id, :feature_name, repo)
      # => {:ok, true} | {:ok, false} | {:error, reason}

  ## Mounting Billing (the host side)

      defmodule Demo.BillingScope do
        use Ash.Domain, validate_config_inclusion?: false

        use Samen.Scopes.Billing,
          otp_app: :demo,
          repo: Demo.Repo,
          namespace: Demo.BillingScope
      end

  This defines, in the host's namespace:

    * `Demo.BillingScope.Customer`     — 🔒 (billing_name/billing_email vault-routed)
    * `Demo.BillingScope.Subscription` — active/inactive sub tied to a customer
    * `Demo.BillingScope.Plan`         — Tier-0: a billing plan config row
    * `Demo.BillingScope.Price`        — Tier-0: a price point for a plan
    * `Demo.BillingScope.Invoice`      — a billing invoice (lines as jsonb)
    * `Demo.BillingScope.Payment`      — a payment record (provider-mirror)
    * `Demo.BillingScope.Usage`        — metered usage for a subscription
    * `Demo.BillingScope.Entitlement`  — feature entitlement for a subscription

  ## Abbrevs (permanent, registry-checked)

  Each resource carries a permanent 3-letter abbrev, reserved in
  `samen_core/priv/abbrev_registry.json` under the HOST module name:

    * `Demo.BillingScope.Customer`     → `bcu`
    * `Demo.BillingScope.Subscription` → `bsb`
    * `Demo.BillingScope.Plan`         → `bpl`
    * `Demo.BillingScope.Price`        → `bpr`
    * `Demo.BillingScope.Invoice`      → `bin`
    * `Demo.BillingScope.Payment`      → `bpy`
    * `Demo.BillingScope.Usage`        → `bus`
    * `Demo.BillingScope.Entitlement`  → `ben`

  The macro does NOT invent abbrevs. Defaults are provided for the demo mount.
  """

  @default_abbrevs %{
    customer: "bcu",
    subscription: "bsb",
    plan: "bpl",
    price: "bpr",
    invoice: "bin",
    payment: "bpy",
    usage: "bus",
    entitlement: "ben",
    # WS-B / G7 (ADR-017): the append-only subscription-movement ledger.
    subscription_event: "mov"
  }

  @doc false
  def default_abbrevs, do: @default_abbrevs

  defmacro __using__(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app) |> Macro.expand(__CALLER__)
    repo = Keyword.fetch!(opts, :repo) |> Macro.expand(__CALLER__)
    namespace = Keyword.fetch!(opts, :namespace) |> Macro.expand(__CALLER__)
    domain = __CALLER__.module

    # Resolve abbrevs to a plain %{atom => string} map AT EXPANSION TIME so each
    # blueprint call receives a LITERAL abbrev string (the base macro validates abbrevs
    # caller-side and requires a compile-time literal — do NOT pass an `abbrevs.foo` AST
    # expression into the blueprint).
    abbrevs = resolve_abbrevs(Keyword.get(opts, :abbrevs), __CALLER__)

    customer_mod = Module.concat(namespace, Customer)
    subscription_mod = Module.concat(namespace, Subscription)
    plan_mod = Module.concat(namespace, Plan)
    price_mod = Module.concat(namespace, Price)
    invoice_mod = Module.concat(namespace, Invoice)
    payment_mod = Module.concat(namespace, Payment)
    usage_mod = Module.concat(namespace, Usage)
    entitlement_mod = Module.concat(namespace, Entitlement)
    subscription_event_mod = Module.concat(namespace, SubscriptionEvent)

    quote do
      require Samen.Scopes.Billing.Blueprint

      # Register the eight Billing resources in the host domain.
      resources do
        resource(unquote(customer_mod))
        resource(unquote(subscription_mod))
        resource(unquote(plan_mod))
        resource(unquote(price_mod))
        resource(unquote(invoice_mod))
        resource(unquote(payment_mod))
        resource(unquote(usage_mod))
        resource(unquote(entitlement_mod))
        resource(unquote(subscription_event_mod))
      end

      # Materialize resource modules in the host namespace. Each is a normal Samen
      # resource; the blueprint threads the host's otp_app/repo/domain and the
      # resource's literal, registry-checked abbrev.
      Samen.Scopes.Billing.Blueprint.define_customer(
        unquote(customer_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.customer)
      )

      Samen.Scopes.Billing.Blueprint.define_subscription(
        unquote(subscription_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.subscription),
        unquote(customer_mod),
        unquote(plan_mod),
        unquote(subscription_event_mod),
        unquote(price_mod)
      )

      # WS-B / G7 (ADR-017): the append-only subscription-movement ledger (`mov`).
      Samen.Scopes.Billing.Blueprint.define_subscription_event(
        unquote(subscription_event_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.subscription_event)
      )

      Samen.Scopes.Billing.Blueprint.define_plan(
        unquote(plan_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.plan)
      )

      Samen.Scopes.Billing.Blueprint.define_price(
        unquote(price_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.price),
        unquote(plan_mod)
      )

      Samen.Scopes.Billing.Blueprint.define_invoice(
        unquote(invoice_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.invoice),
        unquote(customer_mod),
        unquote(subscription_mod)
      )

      Samen.Scopes.Billing.Blueprint.define_payment(
        unquote(payment_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.payment),
        unquote(invoice_mod),
        unquote(customer_mod)
      )

      Samen.Scopes.Billing.Blueprint.define_usage(
        unquote(usage_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.usage),
        unquote(subscription_mod)
      )

      Samen.Scopes.Billing.Blueprint.define_entitlement(
        unquote(entitlement_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.entitlement),
        unquote(subscription_mod),
        unquote(plan_mod)
      )
    end
  end

  # Resolve the abbrev override (an AST map literal or nil) to a plain
  # %{atom => string} map, merged over the defaults. Fail closed if a caller passes
  # a non-map or a non-string abbrev.
  defp resolve_abbrevs(nil, _caller), do: @default_abbrevs

  defp resolve_abbrevs({:%{}, _, pairs}, caller) do
    override =
      Map.new(pairs, fn {k, v} ->
        {Macro.expand(k, caller), Macro.expand(v, caller)}
      end)

    Map.merge(@default_abbrevs, override)
  end

  defp resolve_abbrevs(other, _caller) do
    raise ArgumentError,
          "use Samen.Scopes.Billing, abbrevs: must be a compile-time map literal " <>
            "(%{customer: \"abc\", ...}). Got: #{Macro.to_string(other)}"
  end
end
