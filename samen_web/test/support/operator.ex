defmodule Samen.WebTest.Operator do
  @moduledoc """
  The samen_web test-support OPERATOR namespace (ADR-010 §8.2). This is a SECOND mount of the
  Identity + Billing + Support blueprints — alongside the tenant-facing `Samen.WebTest.Crm` /
  `Billing` / `Support` mounts — but its rows describe the SaaS company's OWN book of business:
  its tenant-org ACCOUNTS (`Identity.Org`), those accounts' tenant-ADMINS (`Identity.User` via
  admin `Membership`), each tenant's subscription-to-the-SaaS (`Billing`), and the tickets
  tenants file WITH the SaaS (`Support`).

  ## Why a separate namespace (the identity line as a mount boundary — ADR-010 §3.1)

  The two PII populations are under DIFFERENT ownership. The operator's `Identity.User` rows are
  the SaaS's OWN customers (the tenant-admins it signed up) — operator-owned PII, CLEAR to the
  operator on its own tenant plane. A tenant's downstream end-customers live in the VERTICAL
  namespace (`Samen.WebTest.Crm`) — tenant-owned PII, MASKED to the operator (impersonation).
  Two mounts ⇒ `OrgScope` cannot leak one into the other; the line is a mount boundary.

  Fresh `wo*` abbrevs — append-only registry rows for the operator test host (no samen_core
  code change; ADR-006). This mount gives samen_web its FIRST Identity mount, exactly as
  ADR-010 §8.1 notes Driftwood's operator namespace does.
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Identity,
    otp_app: :samen_web,
    repo: Samen.WebTest.Repo,
    namespace: Samen.WebTest.Operator,
    abbrevs: %{
      org: "woo",
      user: "wou",
      membership: "wom",
      role: "wor",
      api_key: "wok",
      invitation: "won",
      credential: "woc",
      auth_token: "wot",
      session: "wos",
      user_identity: "woi",
      login_failure: "wol"
    }

  use Samen.Scopes.Billing,
    otp_app: :samen_web,
    repo: Samen.WebTest.Repo,
    namespace: Samen.WebTest.Operator,
    abbrevs: %{
      customer: "wpc",
      subscription: "wps",
      plan: "wpp",
      price: "wpr",
      invoice: "wpi",
      payment: "wpy",
      usage: "wpu",
      entitlement: "wpe",
      subscription_event: "wpv"
    }

  use Samen.Scopes.Support,
    otp_app: :samen_web,
    repo: Samen.WebTest.Repo,
    namespace: Samen.WebTest.Operator,
    abbrevs: %{
      ticket: "wqk",
      conversation: "wqc",
      message: "wqm",
      agent: "wqg",
      sla: "wql",
      macro: "wqn",
      csat: "wqs",
      csat_survey_token: "wco"
    }
end
