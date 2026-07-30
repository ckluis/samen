defmodule Driftwood.SalesOps do
  @moduledoc """
  Driftwood's SalesOps domain — mounted from the samen_core SalesOps scope
  blueprint (ADR-004; F6+F7, T48), exactly as `Driftwood.Docs`/`Driftwood.Tags`/
  `Driftwood.Locations` mount their scopes.

  One `use Samen.Scopes.SalesOps` expands into two host-owned resources:

    * `Driftwood.SalesOps.Vendor` — for a freight brokerage this is a fuel/parts/
      equipment supplier or a subcontracted carrier's back-office vendor record
      (distinct from `Driftwood.Crm.Company`, which under `Driftwood.Context` is
      re-identified as Carrier/Shipper — the companies Driftwood transacts
      LOADS with, not buys FROM). 🔒 vaulted `contact_name`/`contact_emails`/
      `contact_phones`. Archivable.
    * `Driftwood.SalesOps.Lead` — a prospective shipper/carrier lead, distinct
      from `Driftwood.Marketing.Subscriber`. `:convert` creates a
      `Driftwood.Crm.Person` (broker-side contact) + `Driftwood.Crm.Opportunity`
      (re-identified as **Load** under `Driftwood.Context` — DECISION L; the
      created Opportunity row IS what the freight UI shows as a Load). 🔒
      vaulted `full_name`/`emails`/`phones`. Archivable.

  ## Why this mounts cleanly (the additive proof)

  `Lead.convert` targets `Driftwood.Crm.Person`/`Opportunity`/`Company` — the
  SAME resources `Driftwood.Freight` already cross-references from a DIFFERENT
  file (`belongs_to :carrier, Driftwood.Crm.Company`), so this is the same
  established cross-file resource-reference pattern, not a new one.

  ## Abbrev allocation

  Fresh `dvs`/`dls` abbrevs (allocator-proposed) — no cross-host collision this
  time (T123's hardened proposer union-checks every host namespace up front).
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.SalesOps,
    otp_app: :driftwood,
    repo: Driftwood.Repo,
    namespace: Driftwood.SalesOps,
    person_mod: Driftwood.Crm.Person,
    opportunity_mod: Driftwood.Crm.Opportunity,
    company_mod: Driftwood.Crm.Company,
    abbrevs: %{vendor: "dvs", lead: "dls"}
end
