defmodule Samen.WebTest.Support do
  @moduledoc """
  The samen_web test-support Support domain — mounts the samen_core Support scope blueprint
  (ADR-004). Fresh `ws*` abbrevs (append-only registry rows for the test host).
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Support,
    otp_app: :samen_web,
    repo: Samen.WebTest.Repo,
    namespace: Samen.WebTest.Support,
    abbrevs: %{
      ticket: "wsk",
      conversation: "wsc",
      message: "wsm",
      agent: "wsg",
      sla: "wsl",
      macro: "wsn",
      csat: "wss",
      csat_survey_token: "scw"
    }
end
