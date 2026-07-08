defmodule Samen.WebTest.Repo do
  @moduledoc """
  The scratch AshPostgres repo backing `samen_web`'s standalone render tests (ADR-009 §6).
  A throwaway `samen_web_test` DB, created + migrated by `mix samen_web.test_setup`, so the
  framework LiveViews have REAL materialized scope resources + vault routing to read — with
  NO dependency on any vertical.
  """
  use AshPostgres.Repo,
    otp_app: :samen_web,
    adapter: Ecto.Adapters.Postgres,
    warn_on_missing_ash_functions?: false

  def installed_extensions, do: ["uuid-ossp", "citext"]

  def min_pg_version, do: %Version{major: 14, minor: 0, patch: 0}
end
