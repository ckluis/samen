defmodule PawChart.DataCase do
  @moduledoc "ExUnit case template for database-backed PawChart tests."
  use ExUnit.CaseTemplate

  using do
    quote do
      alias PawChart.Repo
      import PawChart.DataCase
    end
  end

  @doc "A fixed-member tenant scope over `org_id`: a SYSTEM context for seeding and reading in tests (a page acts as the person)."
  def clinic_scope(org_id) do
    %Samen.Scope{actor: %{id: "clinic:#{org_id}", org_id: org_id, role: :member, kind: :tenant, plane: :tenant}}
  end

  setup do
    Samen.TestSandbox.shared!(PawChart.Repo)
    :ok
  end
end
