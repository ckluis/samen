defmodule PawChart.McpAuthTest do
  @moduledoc """
  T142 (folded into T157) — the END-TO-END auth test for pawchart's mounted MCP endpoint
  (`samen_mcp_route`, ADR-043 §9), over the LIVE HTTP path (dispatched through
  `PawChartWeb.Endpoint` → router → the `/mcp` forward → `Samen.Web.AI.McpPlug` →
  `PawChartWeb.Api.McpKeyResolver`).

  Proves the REAL constant-time, org-scoped resolver:

    * unauth (no bearer) ⇒ 401;
    * forged bearer token ⇒ 401 (the enforcing digest lookup returns no row — the refutable
      forged-credential-REJECTION guarantee this build sabotage-pins);
    * revoked token ⇒ 401;
    * a valid per-operator token AUTHENTICATES (200, JSON-RPC ping/initialize);
    * org-scope: an org-A token can NEVER reach org-B's data — a browse over an org-A token sees
      org-A's CRM company and NOT org-B's (the MCP engine's hard `org_id ==` filter, keyed on the
      resolver's per-token org).

  NOTE on constant-time (honest disclosure, per the T84a P9 lesson): the resolver's final gate is
  `Plug.Crypto.secure_compare/2` over the stored SHA-256 digest. A "constant-time" sabotage is
  VACUOUS to refute in this harness (a forged token has no matching row, so the secure_compare
  line is never reached for it, and a timing assertion is not deterministically refutable). So the
  sabotage patch pins the REFUTABLE forged-credential REJECTION (the digest-equality enforcing
  filter), NOT the timing — see scripts/sabotages.
  """
  use PawChart.DataCase, async: false

  import Phoenix.ConnTest

  alias PawChartWeb.Api.McpKeyResolver

  @endpoint PawChartWeb.Endpoint

  @org_a "a0000000-0000-4000-8000-0000000000a1"
  @org_b "b0000000-0000-4000-8000-0000000000b1"
  @token_a "pawchart-operator-token-AAA-11112222"
  @token_b "pawchart-operator-token-BBB-33334444"

  setup do
    start_supervised!(PawChartWeb.Endpoint)

    # Mint two per-operator API tokens (stored ONLY as SHA-256 digests), one per org.
    mint_key(@org_a, @token_a)
    mint_key(@org_b, @token_b)

    # Org A owns a distinctively-named CRM company (non-PII); org B has none.
    PawChart.Crm.Company
    |> Ash.Changeset.for_create(:create, %{org_id: @org_a, name: "Aurora Referral Vets"}, authorize?: false)
    |> Ash.create!()

    :ok
  end

  defp mint_key(org_id, raw, opts \\ []) do
    Ash.Seed.seed!(PawChart.Operator.ApiKey, %{
      org_id: org_id,
      token_digest: McpKeyResolver.digest(raw),
      plane: :tenant,
      minter_role: :admin,
      revoked_at: Keyword.get(opts, :revoked_at)
    })
  end

  defp mcp_post(body, token) do
    conn =
      build_conn()
      |> Plug.Conn.put_req_header("content-type", "application/json")

    conn = if token, do: Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> token), else: conn
    post(conn, "/mcp", Jason.encode!(body))
  end

  test "unauthenticated (no bearer) ⇒ 401" do
    conn = mcp_post(%{"method" => "tools/list", "id" => 1}, nil)
    assert conn.status == 401
  end

  test "a FORGED bearer token ⇒ 401 (the enforcing digest lookup rejects it)" do
    conn = mcp_post(%{"method" => "tools/list", "id" => 1}, "totally-forged-token")
    assert conn.status == 401
  end

  test "a REVOKED token ⇒ 401" do
    mint_key(@org_a, "revoked-token-zzz", revoked_at: DateTime.utc_now())
    conn = mcp_post(%{"method" => "tools/list", "id" => 1}, "revoked-token-zzz")
    assert conn.status == 401
  end

  test "a VALID per-operator token authenticates (200, JSON-RPC ping/initialize)" do
    ping = mcp_post(%{"method" => "ping", "id" => 1}, @token_a)
    assert ping.status == 200

    init = mcp_post(%{"method" => "initialize", "id" => 2}, @token_a)
    assert init.status == 200
    assert Jason.decode!(init.resp_body)["result"]["serverInfo"]["name"] == "samen-mcp"
  end

  test "org-scope: an org-A token sees org-A's data; an org-B token can NEVER reach it" do
    browse = fn token ->
      mcp_post(
        %{
          "method" => "tools/call",
          "id" => 3,
          "params" => %{"name" => "browse", "arguments" => %{"resource" => "vca_company"}}
        },
        token
      )
    end

    a = browse.(@token_a)
    assert a.status == 200
    assert a.resp_body =~ "Aurora Referral Vets"

    b = browse.(@token_b)
    assert b.status == 200
    # org B's token, org-scoped by the resolver to org B, can NEVER see org A's company.
    refute b.resp_body =~ "Aurora Referral Vets"
  end
end
