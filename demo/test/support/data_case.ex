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
    Samen.TestSandbox.shared!(Demo.Repo)
    :ok
  end
end
