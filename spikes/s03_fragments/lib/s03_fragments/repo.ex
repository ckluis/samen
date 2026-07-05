defmodule S03Fragments.Repo do
  @moduledoc false
  use AshPostgres.Repo, otp_app: :s03_fragments

  @impl true
  def installed_extensions do
    ["ash-functions"]
  end

  @impl true
  def min_pg_version do
    %Version{major: 14, minor: 0, patch: 0}
  end
end
