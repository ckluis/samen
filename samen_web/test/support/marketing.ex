defmodule Samen.WebTest.Marketing do
  @moduledoc """
  The samen_web test-support Marketing domain — mounts the samen_core Marketing scope
  blueprint (ADR-004; ADR-011 §7) exactly as driftwood/demo do, giving `samen_web` its OWN
  materialized Marketing resources to render + enqueue against in test. Fresh `wm*` abbrevs
  (the global registry already owns the scope-default `m*` + driftwood's `fm*`; append-only
  rows for the test host — no samen_core code change, ADR-009 §6 / ADR-011 §2).
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Marketing,
    otp_app: :samen_web,
    repo: Samen.WebTest.Repo,
    namespace: Samen.WebTest.Marketing,
    abbrevs: %{
      campaign: "wmc",
      segment: "wmg",
      subscriber: "wms",
      template: "wmt",
      send: "wmn",
      email_event: "wme",
      suppression: "wmp"
    }
end
