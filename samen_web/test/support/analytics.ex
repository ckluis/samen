defmodule Samen.WebTest.Analytics do
  @moduledoc """
  The samen_web test-support ANALYTICS domain (WS-B / Phase B7; ADR-021) — mounts the
  samen_core Analytics scope blueprint (ADR-004; `Samen.Scopes.Analytics`) exactly as
  demo does, giving `samen_web` its OWN materialized `ProductEvent` (`pae`) ledger so the
  framework choke-point emitters (`Samen.Web.ListLive` search, `Samen.Web.FirstRun`
  record-created, the session controller) can be driven through a REAL flow and asserted
  to land a real `pae` row — with NO dependency on any vertical.

  Fresh `wan` abbrev (WebTest ANalytics ProductEvent), appended to
  `samen_core/priv/abbrev_registry.json` (the sanctioned kernel touch for the test host,
  ADR-006/ADR-009 §6). Wired as the framework emit target in the integration test via
  `config :samen_core, Samen.Analytics, product_event_resource: Samen.WebTest.Analytics.ProductEvent`.
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Analytics,
    otp_app: :samen_web,
    repo: Samen.WebTest.Repo,
    namespace: Samen.WebTest.Analytics,
    abbrevs: %{product_event: "wan"}
end
