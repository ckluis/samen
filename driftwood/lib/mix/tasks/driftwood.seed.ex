defmodule Mix.Tasks.Driftwood.Seed do
  @shortdoc "Seed the dev DB for the Blue Ridge Logistics tenant (freight + inherited scopes)"
  @moduledoc """
  Seed the Driftwood DEV database with the Blue Ridge Logistics tenant scenario so the
  TENANT and OPERATOR plane pages — including the INHERITED universal-scope pages
  (CRM · Billing · Support) — render REAL freight-flavored data.

  This wraps `Driftwood.Seeds.dev_seed/0`: it builds the freight fleet (carriers /
  shippers / drivers / loads / dispatch / settlement + broker rollup) for the FIXED
  Blue Ridge org, layers the inherited-scope rows on top (CRM contacts + opportunities,
  Billing customers/subscriptions/invoices/payments, Support tickets/conversations/
  messages/agents/SLA/CSAT), and rebuilds the cross-tenant aggregate. Idempotent-ish
  (guarded by markers), so re-running is safe.

  Usage:

      MIX_ENV=dev mix driftwood.seed

  It prints the seeded org id; the dev LiveViews read it via `?org=<uuid>` (e.g.
  `/broker?org=<uuid>`).
  """
  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(_args) do
    org_id = Driftwood.Seeds.dev_seed()
    Mix.shell().info("Seeded Blue Ridge Logistics tenant org: #{org_id}")
    Mix.shell().info("Open: /broker?org=#{org_id}")
    org_id
  end
end
