defmodule Demo.BillingScope do
  @moduledoc """
  The Demo host's Billing domain — mounted from the `samen_core` Billing scope
  blueprint (ADR-004; T3.3).

  One `use Samen.Scopes.Billing` expands into eight host-owned resources
  (`Demo.BillingScope.{Customer,Subscription,Plan,Price,Invoice,Payment,Usage,Entitlement}`),
  each a normal `use Samen.Resource` in the DEMO's `otp_app`/`repo`, so:

    * their columns are catalogued in the DEMO's `tam_table`/`fld_field`
      (the `AddBillingScope` migration's `catalog_sync/1`);
    * the DEMO's unchanged verifiers scan them;
    * `Customer` PII (billing_name/billing_email) routes into the DEMO's one Postgres vault;
    * org-scope + RBAC policies are inherited, not re-authored.

  ## Scope shape

  The Billing scope is a **Stripe-mirror shape**: no live Stripe calls. Sync is an
  opt-in host concern via `Samen.Scopes.Billing.SyncAdapter`. The default adapter
  (`Stub`) is used in demo/test environments.

  ## Tier-0 config rows

  `Plan` and `Price` are the Tier-0 config resources. `demo/priv/repo/seeds/billing_scope.exs`
  seeds the default free/pro/enterprise plan + price rows so the entitlement check
  helper works in the demo.

  ## Thin smoke usage (T3.3 acceptance: "thin smoke usage per scope proves host-mounting works")

  `Demo.BillingScope.Smoke.run/1` exercises one round-trip per resource — a customer
  (with vaulted PII), a plan, a price, a subscription, an invoice, a payment, a usage
  record, and an entitlement — confirming host-mount and vault routing work end-to-end.
  The `demo/test/billing_scope_*_test.exs` suite runs this against a real Postgres DB.
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Billing,
    otp_app: :demo,
    repo: Demo.Repo,
    namespace: Demo.BillingScope
end
