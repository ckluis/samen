defmodule Driftwood.Marketing do
  @moduledoc """
  Driftwood's Marketing domain — mounted from the samen_core Marketing scope blueprint
  (ADR-004; ADR-011 §7), exactly as `demo/` mounts it. One `use Samen.Scopes.Marketing`
  expands into seven host-owned resources in `Driftwood.Marketing.*`:

    * `Driftwood.Marketing.Campaign`    — a carrier/shipper outreach campaign (name/status/schedule)
    * `Driftwood.Marketing.Segment`     — an audience segment (filter criteria as jsonb)
    * `Driftwood.Marketing.Subscriber`  — 🔒 (email vault-routed; consent/status tracked)
    * `Driftwood.Marketing.Template`    — Tier-0: a reusable email template per org
    * `Driftwood.Marketing.Send`        — a single send event (campaign → subscriber)
    * `Driftwood.Marketing.EmailEvent`  — delivery/open/click/bounce/unsubscribe events
    * `Driftwood.Marketing.Suppression` — opt-out / bounce / unsubscribe suppression list

  ## Abbrev allocation

  The BUILT substrate reads a single GLOBAL registry
  (`samen_core/priv/abbrev_registry.json`), in which the scope-default `m*` abbrevs are
  already owned by the demo mount. So Driftwood takes FRESH abbrevs
  (`fmc/fmg/fms/fmt/fmn/fme/fmp`) via the blueprint's `abbrevs:` override (append-only rows in
  the registry — the ONLY sanctioned kernel change, a data file). This mirrors
  `Driftwood.Crm`'s `f`-prefixed allocation.

  ## Consent / suppression

  The framework outreach surface (`Samen.Web.Marketing.Reads.enqueue_send/3`) enforces
  suppression at the framework layer via an Ash read of THIS domain's `Suppression` resource
  (host-abbrev-agnostic), then creates the send through the kernel's `Send.:create_checked`
  action and enqueues `Samen.Scopes.Marketing.SendWorker` (Oban, `:webhooks_out`).
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Marketing,
    otp_app: :driftwood,
    repo: Driftwood.Repo,
    namespace: Driftwood.Marketing,
    abbrevs: %{
      campaign: "fmc",
      segment: "fmg",
      subscriber: "fms",
      template: "fmt",
      send: "fmn",
      email_event: "fme",
      suppression: "fmp"
    }
end
