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
    Samen.TestSandbox.shared!(PawChart.Repo)
    :ok
  end
end
