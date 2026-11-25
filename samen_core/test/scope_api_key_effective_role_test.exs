defmodule Samen.ScopeApiKeyEffectiveRoleTest do
  @moduledoc """
  `Samen.Scope.ApiKey.effective_role/2` is the one place every key-check site decides the acting role. The
  membership must be ACTIVE and in the key's OWN org: a site that builds its actor's org from the membership
  (demo, the generated plug) must never act in an org other than the key's.
  """
  use ExUnit.Case, async: true

  alias Samen.Scope.ApiKey

  @org "6f1c5b3a-1111-4111-8111-000000000001"
  @other "6f1c5b3a-2222-4222-8222-000000000002"

  test "RED: a membership in another org (or with no/unloaded org) yields no role; CONTROL: the same org yields the capped role" do
    key = %{org_id: @org, minter_role: :admin}

    assert {:ok, :admin} = ApiKey.effective_role(key, %{org_id: @org, role: :owner, status: "active"})
    assert {:ok, :viewer} = ApiKey.effective_role(key, %{org_id: @org, role: :viewer, status: "active"})

    assert :error = ApiKey.effective_role(key, %{org_id: @other, role: :owner, status: "active"})
    assert :error = ApiKey.effective_role(key, %{role: :owner, status: "active"})
    assert :error = ApiKey.effective_role(key, %{org_id: nil, role: :owner, status: "active"})
    assert :error = ApiKey.effective_role(%{minter_role: :admin}, %{org_id: @org, role: :owner, status: "active"})
    assert :error = ApiKey.effective_role(%{key | org_id: %Ash.NotLoaded{field: :org_id, type: :attribute}}, %{org_id: @org, role: :owner, status: "active"})
  end
end
