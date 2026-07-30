defmodule Samen.WebTest.Work do
  @moduledoc """
  The samen_web test-support Work domain — mounts the samen_core Work scope
  blueprint (ADR-004; F1, ADR-041 §3, T43). Fresh `ww*` abbrevs (append-only
  registry rows for the test host, reserved via `mix samen.abbrev.reserve`).
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Work,
    otp_app: :samen_web,
    repo: Samen.WebTest.Repo,
    namespace: Samen.WebTest.Work,
    abbrevs: %{
      project: "wwp",
      task: "wwt"
    }
end
