defmodule PawChart.Operator do
  @moduledoc """
  PawChart's OPERATOR namespace (ADR-010 §8.1) — a SECOND mount of the Identity + Billing +
  Support blueprints, alongside the vet vertical's own tenant mounts (`PawChart.Crm` /
  `PawChart.Billing` / `PawChart.Support`). Its rows describe the SaaS company's OWN book of
  business as a vendor: its tenant-org ACCOUNTS (`Identity.Org` — the clinics), those accounts'
  tenant-ADMINS (`Identity.User` — PII the SaaS OWNS, CLEAR to the operator), each clinic's
  subscription-to-the-SaaS (`Billing`), and the tickets clinics file WITH the SaaS (`Support`).

  This is the T157 second-vertical proof: the framework advertises the operator plane as
  inherited-at-≈0-LOC, and pawchart ADOPTS it by MOUNT (this domain + a router `samen_operator_routes`
  call + a roster), NOT by re-implementing operator-plane behavior. The accounts/billing/revenue
  platform views + the per-tenant drill-ins are the framework's OWN `Samen.Web.Operator.*` LiveViews
  rendering pawchart's (vet-shaped) book of business — validating the framework-first claim across
  TWO verticals (driftwood freight + pawchart vet).

  ## The identity line as a mount boundary (ADR-010 §3.1)

  The operator's `Identity.User` rows (clinic-admins) are the SaaS's OWN customers — CLEAR on the
  operator's tenant plane. A clinic's downstream subjects (pet owners / patients) live in the
  VERTICAL namespace (`PawChart.Clinic`) and stay MASKED to the operator (impersonation). Two
  namespaces ⇒ `OrgScope` cannot leak one into the other.

  ## Abbrevs — fresh `po*` (Identity) / `pm*` (Billing) / `pq*` (Support)

  The Identity/Billing/Support scope-default abbrevs are owned elsewhere; PawChart's operator
  namespace takes fresh prefixes (reserved append-only via `mix samen.abbrev.reserve`, ADR-023).
  No samen_core CODE changed — only the data-file registry gained append-only rows (ADR-006).
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Identity,
    otp_app: :pawchart,
    repo: PawChart.Repo,
    namespace: PawChart.Operator,
    abbrevs: %{
      org: "poo",
      user: "pou",
      membership: "pom",
      role: "por",
      api_key: "pok",
      invitation: "pon",
      credential: "poc",
      auth_token: "pot",
      session: "pos",
      user_identity: "poi",
      login_failure: "pol"
    }

  use Samen.Scopes.Billing,
    otp_app: :pawchart,
    repo: PawChart.Repo,
    namespace: PawChart.Operator,
    abbrevs: %{
      customer: "pmc",
      subscription: "pms",
      plan: "pmp",
      price: "pmr",
      invoice: "pmi",
      payment: "pmy",
      usage: "pmu",
      entitlement: "pme",
      subscription_event: "pmv"
    }

  use Samen.Scopes.Support,
    otp_app: :pawchart,
    repo: PawChart.Repo,
    namespace: PawChart.Operator,
    abbrevs: %{
      ticket: "pqk",
      conversation: "pqc",
      message: "pqm",
      agent: "pqg",
      sla: "pql",
      macro: "pqn",
      csat: "pqs",
      csat_survey_token: "pqo"
    }
end
