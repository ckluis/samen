defmodule Driftwood.FreightApiKeyAuthzTest do
  @moduledoc """
  `Driftwood.Freight.ApiKey` shares the Identity ApiKey escalation guards: an admin cannot mint
  a key acting as `:owner`, and revocation is one-way through `:revoke` (no generic update).
  Each RED is paired with the legitimate path.
  """
  use Driftwood.ApiCase, async: false

  defp scope(org_id, role),
    do: %Samen.Scope{actor: %{id: "u-1", org_id: org_id, role: role, verified?: true, kind: :tenant, plane: :tenant}}

  defp create(org_id, role, minter_role) do
    s = scope(org_id, role)

    Driftwood.Freight.ApiKey
    |> Ash.Changeset.for_create(:create, %{org_id: org_id, minter_role: minter_role, scopes: %{}}, scope: s)
    |> Ash.Changeset.force_change_attribute(:token_digest, "d-#{System.unique_integer([:positive])}")
    |> Ash.create(scope: s)
  end

  test "RED: an admin cannot mint an owner-role key; CONTROL: admin-at-admin and owner-at-owner mint" do
    org = mk_org()
    assert {:error, _} = create(org, :admin, :owner)
    assert {:ok, _} = create(org, :admin, :admin)
    assert {:ok, _} = create(org, :owner, :owner)
  end

  test "RED: no generic update (role/revocation cannot be rewritten); CONTROL: :revoke is one-way and idempotent" do
    org = mk_org()
    {:ok, key} = create(org, :admin, :admin)
    s = scope(org, :admin)

    assert_raise ArgumentError, fn -> Ash.Changeset.for_update(key, :update, %{minter_role: :owner}, scope: s) end

    assert {:ok, revoked} = key |> Ash.Changeset.for_update(:revoke, %{}, scope: s) |> Ash.update(scope: s)
    assert %DateTime{} = revoked.revoked_at
    assert {:ok, again} = revoked |> Ash.Changeset.for_update(:revoke, %{}, scope: s) |> Ash.update(scope: s)
    assert again.revoked_at == revoked.revoked_at
  end
end
