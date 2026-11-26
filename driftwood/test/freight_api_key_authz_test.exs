defmodule Driftwood.FreightApiKeyAuthzTest do
  @moduledoc """
  `Driftwood.Freight.ApiKey` shares the Identity ApiKey escalation guards: an admin cannot mint
  a key acting as `:owner`, and revocation is one-way through `:revoke` (no generic update).
  Each RED is paired with the legitimate path.
  """
  use Driftwood.ApiCase, async: false

  require Ash.Query

  # A REAL minter: a `Driftwood.Operator.User` holding an active `role` membership in the org. A key minted by an
  # actor attributed to anything else is refused at create (it could never authenticate).
  defp scope(org_id, role) do
    {user_id, _mbr} = mk_minter(org_id, role)
    scope_for(org_id, role, user_id)
  end

  defp scope_for(org_id, role, user_id),
    do: %Samen.Scope{actor: %{id: user_id, org_id: org_id, role: role, verified?: true, kind: :tenant, plane: :tenant}}

  defp create(org_id, role, minter_role), do: create_with(scope(org_id, role), org_id, minter_role)

  defp create_as(org_id, role, user_id), do: create_with(scope_for(org_id, role, user_id), org_id, role)

  defp create_with(s, org_id, minter_role) do

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

  test "RED: a key is never minted by an actor that is not a UUID with an ACTIVE membership in the key's org (it would be dead on arrival); CONTROL: a real minter mints" do
    org = mk_org()
    other = mk_org()
    {outsider, _} = mk_minter(other, :admin)
    {suspended, mbr} = mk_minter(org, :admin)

    mbr
    |> Ash.Changeset.for_update(:update, %{status: "suspended"}, authorize?: false)
    |> Ash.update!()

    for {label, id} <- [
          {"fixture id", "u-1"},
          {"opaque id", "user-7"},
          {"a UUID with no membership at all", Ash.UUID.generate()},
          {"a user of ANOTHER org", outsider},
          {"a suspended membership", suspended}
        ] do
      # WHICH check refused: the minter-membership one (a role-ceiling or pin refusal would be a
      # different error and must not satisfy this).
      assert {:error, %Ash.Error.Invalid{errors: errors}} = create_as(org, :admin, id),
             "#{label} must not mint a key"

      assert Enum.any?(errors, fn e ->
               Map.get(e, :field) == :minter_user_id and
                 (Map.get(e, :message) || "") =~ "active membership in this org"
             end),
             "#{label}: expected the minter-membership check to refuse, got: #{inspect(errors)}"
    end

    assert Ash.count!(Driftwood.Freight.ApiKey, authorize?: false) == 0

    {real, _} = mk_minter(org, :admin)
    assert {:ok, key} = create_as(org, :admin, real)
    assert key.minter_user_id == real
    # and the minted key authenticates (the use-time check agrees with the create-time one)
    assert {:ok, %{role: :admin}} = Samen.Scope.ApiKey.membership_for_user(Driftwood.Operator.Membership, org, real)
  end

  test "RED: the minter is checked against the org the key is CREATED in, not the org it was built with; CONTROL: a minter of the final org mints" do
    org_a = mk_org()
    org_b = mk_org()
    {minter_a, _} = mk_minter(org_a, :admin)
    s = scope_for(org_a, :admin, minter_a)

    build = fn ->
      Driftwood.Freight.ApiKey
      |> Ash.Changeset.for_create(:create, %{org_id: org_a, minter_role: :admin, scopes: %{}}, scope: s)
      |> Ash.Changeset.force_change_attribute(:token_digest, "d-#{System.unique_integer([:positive])}")
    end

    # built for org A (the minter IS a member there), then moved to org B before the create runs
    assert {:error, %Ash.Error.Invalid{errors: errors}} =
             build.() |> Ash.Changeset.force_change_attribute(:org_id, org_b) |> Ash.create(authorize?: false)

    assert Enum.any?(errors, fn e ->
             Map.get(e, :field) == :minter_user_id and (Map.get(e, :message) || "") =~ "active membership in this org"
           end),
           "expected the minter-membership check against the FINAL org, got: #{inspect(errors)}"

    assert Ash.count!(Driftwood.Freight.ApiKey, authorize?: false) == 0

    # CONTROL: the same move is fine when the minter really is a member of the final org
    {minter_b, _} = mk_minter(org_b, :admin)
    sb = scope_for(org_a, :admin, minter_b)

    assert {:ok, key} =
             Driftwood.Freight.ApiKey
             |> Ash.Changeset.for_create(:create, %{org_id: org_a, minter_role: :admin, scopes: %{}}, scope: sb)
             |> Ash.Changeset.force_change_attribute(:token_digest, "d-#{System.unique_integer([:positive])}")
             |> Ash.Changeset.force_change_attribute(:org_id, org_b)
             |> Ash.create(authorize?: false)

    assert Driftwood.Freight.ApiKey
           |> Ash.Query.filter(id == ^key.id and org_id == ^org_b)
           |> Ash.count!(authorize?: false) == 1
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

  test "RED: a member/viewer cannot revoke or mint a Freight key; CONTROL: an admin revokes" do
    org = mk_org()
    {_raw, key} = mk_api_key(org, minter_role: :admin)

    for role <- [:member, :viewer] do
      s = scope(org, role)
      assert {:error, _} = key |> Ash.Changeset.for_update(:revoke, %{}, scope: s) |> Ash.update(scope: s)
      assert {:error, _} = create(org, role, role)
    end

    assert is_nil(Ash.get!(Driftwood.Freight.ApiKey, key.id, authorize?: false).revoked_at)
    s = scope(org, :admin)
    assert {:ok, %{revoked_at: %DateTime{}}} = key |> Ash.Changeset.for_update(:revoke, %{}, scope: s) |> Ash.update(scope: s)
  end

  test "RED: a key row with a nil minter_role resolves no actor; CONTROL: the same key with a role reads" do
    org = mk_org()
    {raw, key} = mk_api_key(org, minter_role: :admin, scopes: %{"freight" => ["read"]})
    mk_driver(org, %{full_name: %{first: "Guarded", last: "Driver"}})
    assert api_get("/drivers", raw).resp_body =~ "Guarded"

    # a legacy / seeded row: `Ash.Seed` writes what no action would accept
    Ash.Seed.update!(key, %{minter_role: nil})

    conn = api_get("/drivers", raw)
    assert conn.status in [200, 401, 403]
    refute conn.resp_body =~ "Guarded"
  end

  test "RED: an admin cannot attribute a key to another user (minter_user_id is the actor's); CONTROL: a system path may" do
    org = mk_org()
    s = scope(org, :admin)

    {:ok, key} =
      Driftwood.Freight.ApiKey
      |> Ash.Changeset.for_create(
        :create,
        %{org_id: org, minter_role: :admin, scopes: %{}, minter_user_id: "the-owners-user-id"},
        scope: s
      )
      |> Ash.Changeset.force_change_attribute(:token_digest, "d-#{System.unique_integer([:positive])}")
      |> Ash.create(scope: s)

    assert key.minter_user_id == s.actor.id
    refute key.minter_user_id == "the-owners-user-id"

    {_raw, seeded} = mk_api_key(org, minter_role: :admin)
    assert {:ok, _} = Ecto.UUID.cast(seeded.minter_user_id)
  end

  describe "the key's rank follows its minter's CURRENT membership" do
    defp reads?(raw), do: api_get("/drivers", raw).resp_body =~ "Guarded"

    defp set_membership(_org, user_id, attrs) do
      mbr =
        Driftwood.Operator.Membership
        |> Ash.read!(authorize?: false)
        |> Enum.find(&(&1.user_id == user_id))

      mbr |> Ash.Changeset.for_update(:update, attrs, authorize?: false) |> Ash.update!()
    end

    defp actor_for(raw) do
      conn =
        Plug.Test.conn(:get, "/drivers")
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> raw)
        |> DriftwoodWeb.Api.KeyAuthPlug.call(DriftwoodWeb.Api.KeyAuthPlug.init([]))

      conn.private[:samen_api_actor]
    end

    setup do
      org = mk_org()
      mk_driver(org, %{full_name: %{first: "Guarded", last: "Driver"}})
      {:ok, org: org}
    end

    test "RED: a removed minter's key stops authenticating; CONTROL: it read while the membership existed", %{org: org} do
      {raw, key} = mk_api_key(org, minter_role: :admin)
      assert reads?(raw)

      Driftwood.Operator.Membership
      |> Ash.read!(authorize?: false)
      |> Enum.find(&(&1.user_id == key.minter_user_id))
      |> Ash.destroy!(authorize?: false)

      refute reads?(raw)
    end

    test "RED: a suspended minter's key stops authenticating", %{org: org} do
      {raw, key} = mk_api_key(org, minter_role: :admin)
      assert reads?(raw)
      set_membership(org, key.minter_user_id, %{status: "suspended"})
      refute reads?(raw)
    end

    test "RED: an owner-rank key whose minter was demoted to viewer no longer acts as owner", %{org: org} do
      {raw, key} = mk_api_key(org, minter_role: :owner)
      {raw_owner_control, _} = mk_api_key(org, minter_role: :owner)
      assert reads?(raw)
      assert %{role: :owner} = actor_for(raw)
      set_membership(org, key.minter_user_id, %{role: :viewer})
      assert %{role: :viewer} = actor_for(raw)
      assert %{role: :owner} = actor_for(raw_owner_control)
    end

    test "RED: a key with no minter user id resolves no actor", %{org: org} do
      {raw, key} = mk_api_key(org, minter_role: :admin)
      assert reads?(raw)

      Ash.Seed.update!(key, %{minter_user_id: nil})

      refute reads?(raw)
    end
  end

  test "RED: revoking a row read WITHOUT revoked_at still revokes it; the original instant survives a second revoke" do
    org = mk_org()
    {_raw, key} = mk_api_key(org, minter_role: :admin)
    s = scope(org, :admin)
    partial = fn -> Driftwood.Freight.ApiKey |> Ash.Query.filter(id == ^key.id) |> Ash.Query.select([:id, :org_id]) |> Ash.read_one!(authorize?: false) end

    assert %Ash.NotLoaded{} = partial.().revoked_at
    assert {:ok, _} = partial.() |> Ash.Changeset.for_update(:revoke, %{}, scope: s) |> Ash.update(scope: s)
    first = Ash.get!(Driftwood.Freight.ApiKey, key.id, authorize?: false).revoked_at
    assert %DateTime{} = first
    refute is_nil(Driftwood.Freight.ApiKey |> Ash.Query.filter(id == ^key.id and not is_nil(revoked_at)) |> Ash.read_one!(authorize?: false))

    assert {:ok, _} = partial.() |> Ash.Changeset.for_update(:revoke, %{}, scope: s) |> Ash.update(scope: s)
    assert Ash.get!(Driftwood.Freight.ApiKey, key.id, authorize?: false).revoked_at == first
  end
end
