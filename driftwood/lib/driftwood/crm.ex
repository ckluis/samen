defmodule Driftwood.Crm do
  @moduledoc """
  Driftwood's CRM domain — mounted from the samen_core CRM scope blueprint
  (ADR-004; T3.2), exactly as `demo/` mounts it. One `use Samen.Scopes.Crm`
  expands into five host-owned resources in `Driftwood.Crm.*`:

    * `Driftwood.Crm.Company`     — the freight COMPANY row. Under `Driftwood.Context`
      it is re-identified as **Carrier** AND **Shipper** (two `alias_resource`
      renames over ONE kernel Company, design DECISION C2), with the role carried in
      the `company_role` Tier-1 custom field.
    * `Driftwood.Crm.Person`      — broker-side contacts (dispatchers, AP clerks);
      composes CorePerson so name/emails/phones ride the vault.
    * `Driftwood.Crm.Pipeline`    — the Load-lifecycle stages (Tier-0 config rows).
    * `Driftwood.Crm.Opportunity` — re-identified as **Load** (`alias_resource`,
      DECISION L) — the freight load/shipment being brokered.
    * `Driftwood.Crm.Attachment`  — rate confirmations, BOLs, PODs (file refs).

  The former `Driftwood.Crm.Activity` was destructively migrated into the canonical
  Work-scope `Task` and removed (ADR-041 §5, ruling M5). Its DECISION-A **CheckCall**
  re-identification now aliases `Driftwood.Work.Task` (the migration destination) —
  the routine check-call / load-status event stream is a Work Task anchored to the
  load/carrier via the generic `(subject_key, subject_id)` object-ref.

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
      attachment: "fat"
    }
end
