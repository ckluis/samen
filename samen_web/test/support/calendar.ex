defmodule Samen.WebTest.Calendar do
  @moduledoc """
  The samen_web test-support Calendar domain — mounts the samen_core Calendar
  scope blueprint (ADR-004; F2, T44). Fresh `wce` abbrev (append-only registry
  row for the test host, reserved via `mix samen.abbrev.reserve`). Feeds
  `Samen.Web.IcsMaskingTest` (the ICS export INV-1 masking three-proof).
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Calendar,
    otp_app: :samen_web,
    repo: Samen.WebTest.Repo,
    namespace: Samen.WebTest.Calendar,
    abbrevs: %{event: "wce"}
end
