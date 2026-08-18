defmodule Samen.WebTest.Cms do
  @moduledoc """
  The samen_web test-support CMS domain — mounts the samen_core CMS scope
  blueprint (ADR-004; T3.5). FIRST samen_web materialization of this scope
  (T78, spec §I5): the helpdesk knowledge base reuses `Post` as the KB article
  ("no parallel article resource" done-criterion) — a `visibility` attribute
  (`:internal | :public`) distinguishes an internal-only article from one
  deflected to the unauthenticated portal. Fresh `cw*`/`w*` abbrevs
  (allocator-proposed, `mix samen.abbrev.reserve --host samen_web`) — append-only
  registry rows for the test host, same convention as `Samen.WebTest.Support`.
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Cms,
    otp_app: :samen_web,
    repo: Samen.WebTest.Repo,
    namespace: Samen.WebTest.Cms,
    abbrevs: %{
      page: "cwp",
      post: "cpw",
      block: "wcb",
      media: "cwm",
      navigation: "wcn",
      seo_meta: "wcs"
    }
end
