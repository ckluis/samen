defmodule Driftwood.ApiKeyScopeMintValidationTest do
  @moduledoc """
  `Driftwood.Freight.ApiKey`'s own `:create` refuses a key whose scopes are empty or outside the grammar, as the
  identity ApiKey does. A seeded row bypasses the action. Each refusal is paired with a create that differs only in
  its scopes.
  """
  use Driftwood.ApiCase, async: false

  defp create(org_id, scopes) do
    {user_id, _} = mk_minter(org_id, :admin)

    Driftwood.Freight.ApiKey
    |> Ash.Changeset.for_create(:create, %{plane: :tenant, scopes: scopes, minter_role: :admin, minter_user_id: user_id, org_id: org_id})
    |> Ash.Changeset.force_change_attribute(:token_digest, "d-#{System.unique_integer([:positive])}")
    |> Ash.create(authorize?: false)
  end

  test "RED: the freight key's :create refuses an empty scope map; CONTROL: the same create with a scope succeeds" do
    org = mk_org()
    assert {:error, %Ash.Error.Invalid{}} = create(org, %{})
    assert {:ok, _} = create(org, %{"all" => ["read"]})
  end

  test "RED: :create refuses scope keys and values outside the grammar; CONTROL: each fixed one succeeds" do
    org = mk_org()
    refused = [%{"FREIGHT" => ["read"]}, %{"freight.driver.x" => ["read"]}, %{"freight" => ["delete"]}, %{"freight" => []}, %{"freight" => "read"}]

    for scopes <- refused, do: assert({:error, %Ash.Error.Invalid{}} = create(org, scopes), inspect(scopes))

    for scopes <- [%{"freight" => ["read"]}, %{"freight.driver" => ["read", "write"]}, %{all: [:read]}],
        do: assert({:ok, _} = create(org, scopes), inspect(scopes))
  end
end
