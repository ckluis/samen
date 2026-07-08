defmodule Driftwood.Support do
  @moduledoc """
  Driftwood's Support domain — mounted from the samen_core Support scope blueprint
  (ADR-004; product thesis "inherit the 80%"), exactly as `demo/` mounts it and
  exactly as `Driftwood.Crm` mounts the CRM scope. One `use Samen.Scopes.Support`
  expands into seven host-owned resources in `Driftwood.Support.*`:

    * `Driftwood.Support.Ticket`       — the top-level support ticket (SLA deadline,
      priority, status). No PII in the header.
    * `Driftwood.Support.Conversation` — a message thread on a ticket. No PII.
    * `Driftwood.Support.Message`      — 🔒 the message body is vault-routed (free-text;
      scalar `pii_fsm_body`). On the TENANT plane the org reads its own message bodies in
      the clear (PiiResolution); under OPERATOR impersonation the SAME rows mask to ••••.
    * `Driftwood.Support.Agent`        — 🔒 full_name (composite, vault :pii_name) + email
      (scalar `pii_fsa_email`). Same tenant-clear / operator-masked plane behaviour.
    * `Driftwood.Support.Sla`          — Tier-0 config rows: per-org SLA policies.
    * `Driftwood.Support.Macro`        — Tier-0 config rows: per-org canned response macros.
    * `Driftwood.Support.Csat`         — a customer satisfaction survey response.

  ## Abbrev allocation (fresh abbrevs — the built-substrate reality)

  The BUILT substrate reads a single GLOBAL registry
  (`samen_core/priv/abbrev_registry.json`, `:code.priv_dir(:samen_core)`), in which the
  Support scope-DEFAULT abbrevs (`stk/scv/smg/sag/ssl/smc/scs`) are already owned by the
  demo mount. Two hosts mounting the same scope with default abbrevs COLLIDE at the
  compile-time `Samen.Verifiers.AbbrevRegistry`. So Driftwood takes FRESH abbrevs
  (`fsk/fsc/fsm/fsa/fsl/fsn/fss` — the `f`-for-freight prefix Driftwood already uses for
  its CRM mount `fcm/fpr/…`) via the blueprint's `abbrevs:` override. No samen_core CODE
  changed — only the data-file registry gained Driftwood's reserved rows (append-only).

  Note: the SLA breach-detection cron (`Samen.Scopes.Support.SlaBreachWorker`) is NOT
  wired here — mounting the resources does not obligate the host to run the cron. Wiring
  it (and the `:support_sla_breach_ticket_resource` config) is a follow-on UI/ops concern.
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Support,
    otp_app: :driftwood,
    repo: Driftwood.Repo,
    namespace: Driftwood.Support,
    abbrevs: %{
      ticket: "fsk",
      conversation: "fsc",
      message: "fsm",
      agent: "fsa",
      sla: "fsl",
      macro: "fsn",
      csat: "fss"
    }
end
