defmodule Mix.Tasks.Driftwood.Seed do
  @shortdoc "Seed the dev DB — 5 fully-populated brokerages + the operator book of business"
  @moduledoc """
  Seed the Driftwood DEV database (ADR-013 §8) with FIVE named freight brokerages, each FULLY
  populated across every module + plane, plus the OPERATOR org's book of business over all five —
  so the TENANT and OPERATOR plane pages (including the INHERITED CRM · Billing · Support ·
  Marketing · Chat pages) render REAL, VARIED freight data with NOTHING empty.

  This wraps `Driftwood.Seeds.dev_seed/0`. Per brokerage it builds the freight fleet (carriers /
  shippers / drivers incl. valid/expiring/expired FMCSA / loads across statuses / dispatch /
  settlement + broker rollup), then layers the inherited-scope rows on top (CRM contacts +
  companies + pipeline + activities, Billing customers / subscriptions / invoices / payments,
  Support tickets / conversations / messages / agents / SLA / CSAT, Marketing campaign / segment /
  subscribers, 3 Chat threads incl. a cross-plane object-unfurl thread). Each brokerage gets its
  OWN branded book (carriers / shippers / contacts / emails / loads), so drilling into Summit shows
  Summit's data — not a Blue-Ridge clone. Then it rebuilds the cross-tenant aggregate and stands up
  the operator accounts / platform billing (2 past-due for dunning) / desk / leads. Idempotent
  (guarded by per-org markers), so re-running is safe.

  Usage:

      MIX_ENV=dev mix driftwood.seed

  It prints the tenant list + ids. The dev app resolves the current org from the SESSION (no typed
  UUID needed); `?org=<uuid>` deep links still work.
  """
  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(_args) do
    org_id = Driftwood.Seeds.dev_seed()

    Mix.shell().info("Seeded 5 brokerages + the operator book of business.\n")
    Mix.shell().info("Tenant brokerages:")

    for spec <- Driftwood.Seeds.brokerages() do
      mrr = :erlang.float_to_binary(spec.mrr_cents / 100, decimals: 0)

      Mix.shell().info(
        "  #{spec.org_id}  #{String.pad_trailing(spec.name, 24)} #{String.pad_trailing(spec.lane, 8)} #{String.pad_trailing(spec.tier, 8)} $#{mrr}/mo"
      )
    end

    Mix.shell().info(
      "  #{Driftwood.Seeds.empty_org_id()}  #{String.pad_trailing("Lakeline Freight Co", 24)} (just onboarded — EMPTY tenant: first-run + empty states)"
    )

    Mix.shell().info("\nOperator org (Driftwood Ops / Samen SaaS, Inc.): #{Driftwood.OperatorSeeds.operator_org_id()}")
    Mix.shell().info("Open: / (lands on the Driftwood Ops dashboard — all 6 accounts, no params).")

    org_id
  end
end
