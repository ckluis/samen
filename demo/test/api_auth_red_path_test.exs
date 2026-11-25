defmodule Demo.ApiAuthRedPathTest do
  @moduledoc """
  T3.11 — the api_key auth boundary fails closed. A request with no key, an unknown
  key, or a revoked key carries NO actor; the org-scope read policy then sees a
  nil-org actor and returns zero rows (the tenant boundary never opens by omission).

  Anti-tautology: a VALID key on the same request returns the row — so the empty
  results below are the auth gate, not an empty dataset.
  """
  use Demo.ApiCase, async: false

  setup do
    org = mk_org("Acme")
    _c = mk_contact(org.id, %{display_name: "Guarded"})
    {:ok, org: org}
  end

  test "no bearer key → zero rows (fail closed)", %{org: _org} do
    conn = api_get("/contacts", nil)
    # Either an empty 200 (org-scope filter → no rows) or a 4xx — both are "no data".
    assert conn.status in [200, 401, 403]

    if conn.status == 200 do
      assert %{"data" => []} = json(conn)
    end

    refute conn.resp_body =~ "Guarded"
  end

  test "unknown key → zero rows (fail closed)" do
    conn = api_get("/contacts", "sk_this_key_was_never_minted")
    assert conn.status in [200, 401, 403]

    if conn.status == 200 do
      assert %{"data" => []} = json(conn)
    end

    refute conn.resp_body =~ "Guarded"
  end

  test "revoked key → zero rows (fail closed)", %{org: org} do
    {raw, key} = mk_api_key(org.id, plane: :tenant)

    # Positive control: BEFORE revocation the key reads the row.
    conn_ok = api_get("/contacts", raw)
    assert conn_ok.status == 200
    assert conn_ok.resp_body =~ "Guarded"

    # Revoke the key.
    {:ok, _} =
      key
      |> Ash.Changeset.for_update(:revoke, %{})
      |> Ash.update(authorize?: false)

    # AFTER revocation the same key resolves no actor → zero rows.
    conn = api_get("/contacts", raw)
    assert conn.status in [200, 401, 403]

    if conn.status == 200 do
      assert %{"data" => []} = json(conn)
    end

    refute conn.resp_body =~ "Guarded"
  end

  test "a key row with a nil minter_role resolves no actor (never `role: nil` through an OrgScope-only read)", %{org: org} do
    {raw, key} = mk_api_key(org.id, plane: :tenant)
    assert api_get("/contacts", raw).resp_body =~ "Guarded"

    key
    |> Ash.Changeset.for_update(:mark_used, %{}, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:minter_role, nil)
    |> Ash.update!(authorize?: false)

    conn = api_get("/contacts", raw)
    assert conn.status in [200, 401, 403]
    refute conn.resp_body =~ "Guarded"
  end

  defp actor_for(raw) do
    Plug.Test.conn(:get, "/contacts")
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> raw)
    |> DemoWeb.Api.KeyAuthPlug.call(DemoWeb.Api.KeyAuthPlug.init([]))
    |> then(& &1.private[:samen_api_actor])
  end

  defp membership_of(key), do: Ash.get!(Demo.Identity.Membership, key.membership_id, authorize?: false)

  test "RED: an owner-rank key whose minter was demoted acts with the membership's CURRENT role", %{org: org} do
    {raw, key} = mk_api_key(org.id, minter_role: :owner)
    assert %{role: :owner} = actor_for(raw)

    membership_of(key) |> Ash.Changeset.for_update(:update, %{role: :viewer}, authorize?: false) |> Ash.update!()

    assert %{role: :viewer, api_key: %{minter_role: :viewer}} = actor_for(raw)
  end

  test "RED: a key whose minter's membership was suspended (a removal is refused by the FK while keys exist) authenticates no more", %{org: org} do
    {raw1, key1} = mk_api_key(org.id, minter_role: :admin)
    assert actor_for(raw1)

    membership_of(key1) |> Ash.Changeset.for_update(:update, %{status: "suspended"}, authorize?: false) |> Ash.update!()
    refute actor_for(raw1)
    refute api_get("/contacts", raw1).resp_body =~ "Guarded"
  end
  test "RED: a key whose membership row names a DIFFERENT org than the key authenticates no actor; CONTROL: the same key before the move acts in its own org", %{org: org} do
    other = mk_org("Other")
    {raw, key} = mk_api_key(org.id, minter_role: :admin)
    assert %{org_id: org_id} = actor_for(raw)
    assert to_string(org_id) == to_string(org.id)

    # a rewritten membership (seeded past the policy: Membership :update no longer accepts org_id)
    membership_of(key)
    |> Ash.Changeset.for_update(:update, %{}, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:org_id, other.id)
    |> Ash.update!()

    refute actor_for(raw)
    refute api_get("/contacts", raw).resp_body =~ "Guarded"
  end
end
