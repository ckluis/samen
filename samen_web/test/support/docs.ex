defmodule Samen.WebTest.Docs do
  @moduledoc """
  The samen_web test-support Docs domain — mounts the samen_core Docs scope
  blueprint (ADR-004; F3, T45). Fresh `wdd`/`wdn` abbrevs (append-only registry
  rows for the test host, reserved via `mix samen.abbrev.reserve`). Feeds
  `Samen.Web.DocsMaskingTest` (the INV-1 masking three-proof + the org-scoped
  object-ref attach red-path, `Samen.Web.Docs.attach/5`).
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Docs,
    otp_app: :samen_web,
    repo: Samen.WebTest.Repo,
    namespace: Samen.WebTest.Docs,
    abbrevs: %{doc: "wdd", note: "wdn"}
end
