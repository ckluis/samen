defmodule Demo.DataCase do
  @moduledoc "ExUnit case template for database-backed demo tests."
  use ExUnit.CaseTemplate

  using do
    quote do
      alias Demo.Repo
      import Demo.DataCase
    end
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Demo.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Demo.Repo, {:shared, self()})
    :ok
  end
end
