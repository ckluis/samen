defmodule Driftwood.Operator do
  @moduledoc """
  Driftwood's OPERATOR namespace (ADR-010 §8.1) — a SECOND mount of the Identity + Billing +
  Support blueprints, alongside the vertical's own tenant mounts (`Driftwood.Crm` /
  `Driftwood.Billing` / `Driftwood.Support`). Its rows describe the SaaS company's OWN book of
  business as a vendor: its tenant-org ACCOUNTS (`Identity.Org`), those accounts' tenant-ADMINS
  (`Identity.User` — PII the SaaS OWNS, CLEAR to the operator), each tenant's subscription-to-
  the-SaaS (`Billing`), and the tickets tenants file WITH the SaaS (`Support`).

  This gives Driftwood its FIRST Identity mount — correct, because the operator's accounts ARE
  `Identity.Org`s (ADR-010 §8.1). The vertical's own tenant population is the freight orgs; the
  operator's accounts are those orgs mirrored as the SaaS's customers (Bridge-B).

  ## The identity line as a mount boundary (ADR-010 §3.1)

  The operator's `Identity.User` rows (tenant-admins) are the SaaS's OWN customers — CLEAR on
  the operator's tenant plane. A tenant's downstream end-customers (Blue Ridge's drivers/
  shippers) live in the VERTICAL namespace and stay MASKED to the operator (impersonation).
  Two namespaces ⇒ `OrgScope` cannot leak one into the other.

  ## Abbrevs — fresh `do*/dp*/dq*` (driftwood operator), append-only registry rows

  The Identity/Billing/Support scope-default abbrevs are owned elsewhere; Driftwood's operator
  namespace takes fresh prefixes (`do` Identity, `dp` Billing, `dq` Support). No samen_core CODE
  changed — only the data-file registry gained append-only rows (ADR-006).
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Identity,
    otp_app: :driftwood,
    repo: Driftwood.Repo,
    namespace: Driftwood.Operator,
    abbrevs: %{
      org: "doo",
      user: "dou",
      membership: "dom",
      role: "dor",
      api_key: "dok",
      invitation: "don",
      credential: "doc",
      auth_token: "dot",
      session: "dos",
      user_identity: "doi",
      login_failure: "dol"
    }

  use Samen.Scopes.Billing,
    otp_app: :driftwood,
    repo: Driftwood.Repo,
    namespace: Driftwood.Operator,
    abbrevs: %{
      customer: "dpc",
      subscription: "dps",
      plan: "dpp",
      price: "dpr",
      invoice: "dpi",
      payment: "dpy",
      usage: "dpu",
      entitlement: "dpe",
      subscription_event: "dpv"
    }

  use Samen.Scopes.Support,
    otp_app: :driftwood,
    repo: Driftwood.Repo,
    namespace: Driftwood.Operator,
    abbrevs: %{
      ticket: "dqk",
      conversation: "dqc",
      message: "dqm",
      agent: "dqg",
      sla: "dql",
      macro: "dqn",
      csat: "dqs",
      csat_survey_token: "dco"
    }
end
