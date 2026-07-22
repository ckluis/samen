defmodule Demo.Repo do
  use AshPostgres.Repo,
    otp_app: :demo,
    adapter: Ecto.Adapters.Postgres,
    warn_on_missing_ash_functions?: false

  def installed_extensions do
    # AshMoney.AshPostgresExtension (ADR-036 D1/D7; ADR-037 §5.2): installs the
    # money_with_currency composite type + +/sum/min/max/avg SQL operators the
    # CRM Opportunity / Billing Price Money migration depends on.
    ["uuid-ossp", "citext", AshMoney.AshPostgresExtension]
  end

  def min_pg_version do
    %Version{major: 14, minor: 0, patch: 0}
  end
end
