defmodule Samen.WebTest.Views do
  @moduledoc """
  The samen_web test-support Views domain — mounts the samen_core Views scope blueprint
  (ADR-004; G10, T58) exactly as driftwood/demo would, giving `samen_web` its OWN
  materialized `SavedView` resource to exercise the framework saved-views capability
  (`Samen.Web.SavedViews`) against. Fresh `wvs` abbrev (append-only registry row for the
  test host, reserved via `mix samen.abbrev.reserve` — no samen_core code change).

  This is the reference ≈0-LOC adopter: one `use` line mounts per-user, org-scoped saved
  views for every list surface on the host.
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Views,
    otp_app: :samen_web,
    repo: Samen.WebTest.Repo,
    namespace: Samen.WebTest.Views,
    abbrevs: %{saved_view: "wvs"}
end
