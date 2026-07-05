defmodule Demo.Repo do
  use AshPostgres.Repo,
    otp_app: :demo,
    adapter: Ecto.Adapters.Postgres,
    warn_on_missing_ash_functions?: false

  def installed_extensions do
    ["uuid-ossp", "citext"]
  end

  def min_pg_version do
    %Version{major: 14, minor: 0, patch: 0}
  end
end
