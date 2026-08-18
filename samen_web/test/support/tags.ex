defmodule Samen.WebTest.Tags do
  @moduledoc """
  The samen_web test-support Tags domain — mounts the samen_core Tags scope
  blueprint (ADR-004; F4, T46). Fresh `wtt`/`twt` abbrevs (append-only registry
  rows for the test host, reserved via `mix samen.abbrev.reserve`). Feeds
  `Samen.Web.TagsTest` (the org-scoped object-ref attach red-path,
  `Samen.Web.Tags.attach/5`) and `Samen.Web.TicketTagsMigrationTest` (the F4
  Ticket-tags migration proof, alongside `Samen.WebTest.Support`).
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Tags,
    otp_app: :samen_web,
    repo: Samen.WebTest.Repo,
    namespace: Samen.WebTest.Tags,
    abbrevs: %{tag: "wtt", tagging: "twt"}
end
