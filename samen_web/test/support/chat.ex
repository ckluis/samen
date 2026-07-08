defmodule Samen.WebTest.Chat do
  @moduledoc """
  The samen_web test-support Chat domain — mounts the `Samen.Scopes.Chat` blueprint (ADR-012)
  exactly as a real vertical would, giving `samen_web` its OWN materialized chat resources to
  render + broadcast against in test. Fresh `wc*` abbrevs (append-only registry rows for the
  test host — no samen_core code change beyond the sanctioned abbrev append, ADR-012 §11).
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Chat,
    otp_app: :samen_web,
    repo: Samen.WebTest.Repo,
    namespace: Samen.WebTest.Chat,
    abbrevs: %{
      thread: "wct",
      participant: "wcp",
      message: "wcm",
      disclosure_setting: "wcd"
    }
end
