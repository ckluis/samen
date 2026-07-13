defmodule Driftwood.Billing do
  @moduledoc """
  Driftwood's Billing domain — mounted from the samen_core Billing scope blueprint
  (ADR-004; product thesis "inherit the 80%"), exactly as `demo/` mounts it and
  exactly as `Driftwood.Crm` mounts the CRM scope. One `use Samen.Scopes.Billing`
  expands into eight host-owned resources in `Driftwood.Billing.*`:

    * `Driftwood.Billing.Customer`     — 🔒 the billing customer (billing_name/billing_email
      vault-routed via the `pii_fbc_*` scalar columns). This is the freight brokerage's
      billing view of its shippers/carriers — the org reads its OWN customers in the clear
      on the TENANT plane (PiiResolution), masked to •••• under OPERATOR impersonation.
    * `Driftwood.Billing.Subscription` — an active billing subscription tied to a customer + plan.
    * `Driftwood.Billing.Plan`         — Tier-0 config rows: the per-org billing plan catalog.
    * `Driftwood.Billing.Price`        — Tier-0 config rows: a price point for a plan.
    * `Driftwood.Billing.Invoice`      — a billing invoice (line items as jsonb).
    * `Driftwood.Billing.Payment`      — a payment record (Stripe-mirror; no raw card data).
    * `Driftwood.Billing.Usage`        — metered usage for a subscription.
    * `Driftwood.Billing.Entitlement`  — a feature entitlement for a subscription.

  ## Abbrev allocation (fresh abbrevs — the built-substrate reality)

  The BUILT substrate reads a single GLOBAL registry
  (`samen_core/priv/abbrev_registry.json`, `:code.priv_dir(:samen_core)`), in which the
  Billing scope-DEFAULT abbrevs (`bcu/bsb/bpl/bpr/bin/bpy/bus/ben`) are already owned by
  the demo mount. Two hosts mounting the same scope with default abbrevs COLLIDE at the
  compile-time `Samen.Verifiers.AbbrevRegistry`. So Driftwood takes FRESH abbrevs
  (`fbc/fbs/fbp/fbr/fbi/fby/fbu/fbe` — the `f`-for-freight prefix Driftwood already uses
  for its CRM mount `fcm/fpr/…`) via the blueprint's `abbrevs:` override. No samen_core
  CODE changed — only the data-file registry gained Driftwood's reserved rows (append-only).
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Billing,
    otp_app: :driftwood,
    repo: Driftwood.Repo,
    namespace: Driftwood.Billing,
    abbrevs: %{
      customer: "fbc",
      subscription: "fbs",
      plan: "fbp",
      price: "fbr",
      invoice: "fbi",
      payment: "fby",
      usage: "fbu",
      entitlement: "fbe",
      subscription_event: "fbv"
    }
end
