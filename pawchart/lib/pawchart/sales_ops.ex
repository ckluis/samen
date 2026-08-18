defmodule PawChart.SalesOps do
  @moduledoc """
  PawChart's SalesOps domain — the samen_core SalesOps scope MOUNTED AS-IS for
  the vet vertical (ADR-004; F6+F7, T48), exactly as `PawChart.Docs`/
  `PawChart.Tags`/`PawChart.Locations` mount their scopes.

  One `use Samen.Scopes.SalesOps` expands into two host-owned resources:

    * `PawChart.SalesOps.Vendor` — for a vet clinic SaaS this is a pharmaceutical/
      medical-supply/lab vendor. 🔒 vaulted `contact_name`/`contact_emails`/
      `contact_phones`. Archivable.
    * `PawChart.SalesOps.Lead` — a prospective clinic-client lead, distinct from
      `PawChart.Marketing.Subscriber`. `:convert` creates a `PawChart.Crm.Person`
      (clinic contact) + `PawChart.Crm.Opportunity` (a pipeline deal/prospect).
      🔒 vaulted `full_name`/`emails`/`phones`. Archivable.

  ## Why this mounts cleanly (the additive proof)

  Zero vertical reshape — same posture as `PawChart.Docs`/`PawChart.Tags`/
  `PawChart.Locations`.

  ## Abbrev allocation

  Fresh `psv`/`psl` abbrevs (allocator-proposed, no cross-host collision).
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.SalesOps,
    otp_app: :pawchart,
    repo: PawChart.Repo,
    namespace: PawChart.SalesOps,
    person_mod: PawChart.Crm.Person,
    opportunity_mod: PawChart.Crm.Opportunity,
    company_mod: PawChart.Crm.Company,
    abbrevs: %{vendor: "psv", lead: "psl"}
end
