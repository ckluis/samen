defmodule PawChart.DataCase do
  @moduledoc "ExUnit case template for database-backed PawChart tests."
  use ExUnit.CaseTemplate

  using do
    quote do
      alias PawChart.Repo
      import PawChart.DataCase
    end
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(PawChart.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(PawChart.Repo, {:shared, self()})
    :ok
  end
end
