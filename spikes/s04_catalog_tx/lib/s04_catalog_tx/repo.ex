defmodule S04CatalogTx.Repo do
  @moduledoc false
  use AshPostgres.Repo, otp_app: :s04_catalog_tx

  @impl true
  def installed_extensions do
    ["ash-functions"]
  end

  @impl true
  def min_pg_version do
    %Version{major: 14, minor: 0, patch: 0}
  end
end
