defmodule PawChart.Crm do
  @moduledoc """
  PawChart's CRM domain — the samen_core CRM scope MOUNTED AS-IS for the vet vertical.

  One `use Samen.Scopes.Crm` expands into five host-owned CRM resources in `PawChart.Crm.*`:

    * `PawChart.Crm.Company`     — the vet clinic's CRM company rows (referring vets, labs,
      insurance companies, pet-supply vendors). Non-PII name/industry/size.
    * `PawChart.Crm.Person`      — clinic contacts (receptionists, referring vet reps, billing
      contacts); composes CorePerson so full_name/emails/phones ride the vault (PII ••••
      on the operator plane, clear on the tenant plane).
    * `PawChart.Crm.Pipeline`    — the clinic's sales/onboarding pipeline stages. Tier-0
      config rows per org.
    * `PawChart.Crm.Opportunity` — the clinic's pipeline deals/prospects.
    * `PawChart.Crm.Attachment`  — file attachments (referral letters, insurance forms).

  The former `PawChart.Crm.Activity` (call-logs, follow-ups) was destructively migrated
  into the canonical Work-scope `Task` and removed (ADR-041 §5, ruling M5) — a clinic
  follow-up is now a Work Task anchored to the CRM object via `(subject_key, subject_id)`.

  ## Why this mounts cleanly (the additive proof)

  PawChart's clinical model (Patient + Pet) is orthogonal to the CRM scope — clinic contacts
  are the BUSINESS relationship layer (referring vets, labs, vendors), separate from the
  clinical patient records. The CRM scope mounts with ZERO vertical reshape, exactly as the
  Billing scope does.

  ## Abbrev allocation

  Fresh `vc*` abbrevs (vet-CRM prefix, `vca/vcb/vcc/vcd/vce/vcf`) reserved in the global
  registry (`samen_core/priv/abbrev_registry.json`). Scope-default abbrevs
  (`cmp/per/pip/opp/act/att`) are owned by the demo mount; Driftwood owns `fcm/fpr/…`.
  Append-only registry update, no samen_core CODE change.
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Crm,
    otp_app: :pawchart,
    repo: PawChart.Repo,
    namespace: PawChart.Crm,
    abbrevs: %{
      company: "vca",
      person: "vcb",
      pipeline: "vcc",
      opportunity: "vcd",
      attachment: "vcf"
    }
end
