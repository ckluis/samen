defmodule PawChart.Billing do
  @moduledoc """
  PawChart's Billing domain — the samen_core Billing scope MOUNTED AS-IS.

  This is the load-bearing REUSE claim of T6.2: PawChart is the vision doc's EASY
  ADDITIVE case ("Billing: kept as plain subscriptions"). ONE `use Samen.Scopes.Billing`
  expands into the eight host-owned Billing resources with ZERO vertical billing code
  and ZERO reshape — the exact contrast the doc draws with Driftwood, which had to
  reshape Invoice into a carrier-settlement netting money model under an anti-corruption
  layer (`reshape Settlement do … end`).

  PawChart writes NO `Samen.Context`, NO `reshape`, NO `alias_resource` over Billing:
  a vet clinic bills monthly subscriptions exactly the way the kernel already models
  them (Customer🔒 → Subscription → Plan/Price → Invoice → Payment → Usage →
  Entitlement). The whole Billing scope — Stripe-mirror shape, the customer🔒 vault
  routing, org-scope, catalog parity, audit, crypto-shred — is inherited free.

  The `abbrevs:` override takes FRESH abbrevs (`pbc/pbs/pbl/ppc/pbi/pby/pbu/pbe`)
  because the substrate reads a single GLOBAL abbrev registry
  (`samen_core/priv/abbrev_registry.json`) in which the scope-default abbrevs
  (`bcu/bsb/…`) are already owned by the demo mount — the same global-registry reality
  Driftwood's CRM mount documents (T6.1 extraction-retro finding). No samen_core CODE
  changed; the data-file registry gained PawChart's reserved rows (append-only).
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Billing,
    otp_app: :pawchart,
    repo: PawChart.Repo,
    namespace: PawChart.Billing,
    abbrevs: %{
      customer: "pbc",
      subscription: "pbs",
      plan: "pbl",
      price: "ppc",
      invoice: "pbi",
      payment: "pby",
      usage: "pbu",
      entitlement: "pbe"
    }
end
