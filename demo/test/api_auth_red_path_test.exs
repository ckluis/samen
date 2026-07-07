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
      |> Ash.Changeset.for_update(:update, %{revoked_at: DateTime.utc_now()})
      |> Ash.update(authorize?: false)

    # AFTER revocation the same key resolves no actor → zero rows.
    conn = api_get("/contacts", raw)
    assert conn.status in [200, 401, 403]

    if conn.status == 200 do
      assert %{"data" => []} = json(conn)
    end

    refute conn.resp_body =~ "Guarded"
  end
end
