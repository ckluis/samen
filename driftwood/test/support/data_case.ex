defmodule Driftwood.DataCase do
  @moduledoc "ExUnit case template for database-backed Driftwood tests."
  use ExUnit.CaseTemplate

  using do
    quote do
      alias Driftwood.Repo
      import Driftwood.DataCase
    end
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Driftwood.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Driftwood.Repo, {:shared, self()})

    # The reviewed non_pii! rows the pii_classify gate + destruction oracle rely on.
    :ok = Driftwood.NonPiiSetup.register_all()
    :ok
  end
end
