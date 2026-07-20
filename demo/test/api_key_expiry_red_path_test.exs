defmodule Demo.ApiKeyExpiryRedPathTest do
  @moduledoc """
  F3.4 — bounded API-key expiry, DENY-ON-READ at the auth boundary
  (`DemoWeb.Api.KeyAuthPlug`). An expired key is never resolved to an actor: the
  lookup query filters `expires_at > now`, so the request fails closed exactly like
  a revoked/unknown key (org-scope nil-org branch → zero rows / 401-ish absence).

  Anti-tautology: the SAME org + SAME plane + SAME scopes with a FUTURE expiry reads
  its data in clear (the positive control) — so "denied" is a real, refutable result,
  not a key that never worked.
  """
  use Demo.ApiCase, async: false

  defp seed_contact(org) do
    mk_contact(org.id, %{
      display_name: "Alice",
      full_name: %{first: "Alice", last: "Owner"},
      emails: ["alice@acme.com"]
    })
  end

  describe "deny-on-read" do
    test "an EXPIRED tenant key resolves NO actor — sees zero of its own org's rows" do
      org = mk_org("Acme")
      _c = seed_contact(org)

      past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)
      {raw, _key} = mk_api_key(org.id, plane: :tenant, expires_at: past)

      conn = api_get("/contacts", raw)
      # Fail closed: an expired key derives no actor, so the org-scope policy's
      # nil-org branch yields no rows (never this org's contacts in clear).
      body = json(conn)
      data = Map.get(body, "data", [])
      assert data == [], "an expired key must not resolve to an actor / read any rows"
    end

    test "the SAME key config with a FUTURE expiry reads its org's data (positive control)" do
      org = mk_org("Acme2")
      _c = seed_contact(org)

      future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

      {raw, _key} =
        mk_api_key(org.id,
          plane: :tenant,
          expires_at: future,
          scopes: %{"crm" => ["read"], "identity" => ["read"]}
        )

      conn = api_get("/contacts", raw)
      assert conn.status == 200
      %{"data" => [record | _]} = json(conn)
      assert record["attributes"]["emails"] =~ "alice@acme.com"
    end

    test "a non-expiring key (nil expiry, legacy) still reads — the gate only bites on a set, past expiry" do
      org = mk_org("Acme3")
      _c = seed_contact(org)

      {raw, _key} = mk_api_key(org.id, plane: :tenant, expires_at: nil)

      conn = api_get("/contacts", raw)
      assert conn.status == 200
      assert %{"data" => [_ | _]} = json(conn)
    end
  end
end
