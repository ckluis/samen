defmodule Driftwood.Crm do
  @moduledoc """
  Driftwood's CRM domain — mounted from the samen_core CRM scope blueprint
  (ADR-004; T3.2), exactly as `demo/` mounts it. One `use Samen.Scopes.Crm`
  expands into six host-owned resources in `Driftwood.Crm.*`:

    * `Driftwood.Crm.Company`     — the freight COMPANY row. Under `Driftwood.Context`
      it is re-identified as **Carrier** AND **Shipper** (two `alias_resource`
      renames over ONE kernel Company, design DECISION C2), with the role carried in
      the `company_role` Tier-1 custom field.
    * `Driftwood.Crm.Person`      — broker-side contacts (dispatchers, AP clerks);
      composes CorePerson so name/emails/phones ride the vault.
    * `Driftwood.Crm.Pipeline`    — the Load-lifecycle stages (Tier-0 config rows).
    * `Driftwood.Crm.Opportunity` — re-identified as **Load** (`alias_resource`,
      DECISION L) — the freight load/shipment being brokered.
    * `Driftwood.Crm.Activity`    — re-identified as **CheckCall** (DECISION A) — the
      routine check-call / load-status event stream.
    * `Driftwood.Crm.Attachment`  — rate confirmations, BOLs, PODs (file refs).

  ## Abbrev allocation (DECISION AB + the built-substrate reality)

  The design's DECISION AB assumed a per-APP abbrev registry, so Driftwood could
  keep the scope-default abbrevs (`cmp/per/…`). The BUILT substrate reads a single
  GLOBAL registry (`samen_core/priv/abbrev_registry.json`, `:code.priv_dir(:samen_core)`),
  in which `cmp/per/pip/opp/act/att` are already owned by the demo mount. Two hosts
  mounting the same scope with default abbrevs therefore COLLIDE at the compile-time
  `Samen.Verifiers.AbbrevRegistry`. So Driftwood takes FRESH abbrevs
  (`fcm/fpr/fpp/fop/fac/fat`) via the blueprint's `abbrevs:` override. This is a real
  finding for the extraction retro (T6.1): the abbrev registry is global, not
  per-host, contradicting DECISION AB. No samen_core CODE changed — only the
  data-file registry gained Driftwood's reserved rows (append-only).
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Crm,
    otp_app: :driftwood,
    repo: Driftwood.Repo,
    namespace: Driftwood.Crm,
    abbrevs: %{
      company: "fcm",
      person: "fpr",
      pipeline: "fpp",
      opportunity: "fop",
      activity: "fac",
      attachment: "fat"
    }
end
