defmodule PawChart.Marketing do
  @moduledoc """
  PawChart's Marketing domain — the samen_core Marketing scope blueprint MOUNTED AS-IS for
  the vet vertical (ADR-004; ADR-011 §7), exactly as Driftwood and `demo/` mount it. One
  `use Samen.Scopes.Marketing` expands into seven host-owned resources in
  `PawChart.Marketing.*`:

    * `PawChart.Marketing.Campaign`    — a clinic outreach campaign (wellness reminders,
      referral thank-yous). Non-PII name/status/schedule.
    * `PawChart.Marketing.Segment`     — an audience segment (filter criteria as jsonb).
    * `PawChart.Marketing.Subscriber`  — 🔒 clinic contact enrolled for outreach (email
      vault-routed; consent/status tracked → •••• on the operator plane, clear on tenant).
    * `PawChart.Marketing.Template`    — Tier-0: a reusable email template per org.
    * `PawChart.Marketing.Send`        — a single send event (campaign → subscriber).
    * `PawChart.Marketing.EmailEvent`  — delivery/open/click/bounce/unsubscribe events.
    * `PawChart.Marketing.Suppression` — opt-out / bounce / unsubscribe suppression list.

  ## Why this mounts cleanly (the second-vertical proof)

  This is the whole point of the FRAMEWORK CRM enrichment: the outreach/consent surface
  (`Samen.Web.Marketing.*` + `Samen.Web.Marketing.Reads.enqueue_send/3`'s fail-closed
  suppression check) is host-abbrev-agnostic, so mounting the scope here lets the clinic
  inherit the ENTIRE outreach surface with ZERO PawChart LiveView code — the clinic only
  supplies the three host facts (repo/namespace/abbrevs). The `:crm_namespace` label on the
  Marketing mount (router.ex) wires the Leads lens over `PawChart.Crm.Person`.

  ## Abbrev allocation

  Fresh `vm*` abbrevs (vet-Marketing prefix, `vmc/vmg/vms/vmt/vmn/vme/vmp`) reserved in the
  global registry (`samen_core/priv/abbrev_registry.json`) — append-only, the ONLY sanctioned
  kernel change (a data file), mirroring `PawChart.Crm`'s `vc*` and Driftwood's `fm*`.
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Marketing,
    otp_app: :pawchart,
    repo: PawChart.Repo,
    namespace: PawChart.Marketing,
    abbrevs: %{
      campaign: "vmc",
      segment: "vmg",
      subscriber: "vms",
      template: "vmt",
      send: "vmn",
      email_event: "vme",
      suppression: "vmp"
    }
end
