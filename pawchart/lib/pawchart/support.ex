defmodule PawChart.Support do
  @moduledoc """
  PawChart's Support domain — the samen_core Support scope MOUNTED AS-IS for the vet vertical.

  One `use Samen.Scopes.Support` expands into seven host-owned Support resources in
  `PawChart.Support.*`:

    * `PawChart.Support.Ticket`       — the top-level support ticket. For a vet clinic SaaS
      this is a ticket a clinic files with the platform (billing questions, feature requests,
      software issues). No PII in the header.
    * `PawChart.Support.Conversation` — a message thread on a ticket. No PII.
    * `PawChart.Support.Message`      — the message body (vault-routed PII: free-text, scalar
      `pii_vsc_body`). On the TENANT plane (the clinic sees its own tickets) in the clear;
      on the OPERATOR plane (the SaaS team reviews a clinic's tickets) masked to ••••.
    * `PawChart.Support.Agent`        — 🔒 full_name (composite vault) + email (scalar
      `pii_vsd_email`). Support agents = platform support staff whose contact info is PII.
    * `PawChart.Support.Sla`          — Tier-0 config rows: per-org SLA policies.
    * `PawChart.Support.Macro`        — Tier-0 config rows: canned response macros.
    * `PawChart.Support.Csat`         — a customer satisfaction survey response.

  ## Why this mounts cleanly (the additive proof)

  A vet clinic SaaS uses the Support scope for exactly the purpose it was designed: tenants
  (clinics) file tickets with the operator (the SaaS company). The scope mounts with ZERO
  vertical reshape — the Support model is universal across B2B SaaS verticals.

  ## Abbrev allocation

  Fresh `vs*` abbrevs (vet-support prefix, `vsa/vsb/vsc/vsd/vse/vsf/vsg`) reserved in the
  global registry. Scope-default abbrevs (`stk/scv/smg/sag/ssl/smc/scs`) are owned by the
  demo mount; Driftwood owns `fsk/fsc/…`. Append-only registry update.
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Support,
    otp_app: :pawchart,
    repo: PawChart.Repo,
    namespace: PawChart.Support,
    abbrevs: %{
      ticket: "vsa",
      conversation: "vsb",
      message: "vsc",
      agent: "vsd",
      sla: "vse",
      macro: "vsf",
      csat: "vsg",
      csat_survey_token: "psc"
    }
end
