defmodule Mix.Tasks.Pawchart.Seed do
  @shortdoc "Seed the dev DB for the Happy Paws Clinic tenant (CRM/Billing/Support)"
  @moduledoc """
  Seed the PawChart DEV database with the Happy Paws Clinic tenant scenario so the
  inherited universal-scope pages (CRM · Billing · Support) render REAL clinic-flavored
  data via the samen_web mounts.

  This wraps `PawChart.Seeds.run/0` which seeds:

    * CRM — referring vets, labs, vendors (clinic contacts), pipeline stages, a deal
    * Billing — a clinic VetPro plan subscription + paid invoice
    * Support — clinic tickets filed with the platform + agents

  Usage:

      MIX_ENV=dev mix pawchart.seed

  It prints the seeded org id; use `?org=<uuid>` on the LiveView URLs.
  """
  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(_args) do
    org_id = PawChart.Seeds.run()
    Mix.shell().info("Seeded Happy Paws Clinic tenant org: #{org_id}")
    Mix.shell().info("Open: /crm/contacts?org=#{org_id}")
    Mix.shell().info("Open: /billing?org=#{org_id}")
    Mix.shell().info("Open: /support?org=#{org_id}")
    org_id
  end
end
