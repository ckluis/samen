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

  # The key is bound to a real, ACTIVE membership (the resolver caps the acting role by it and refuses a
  # key whose minter is gone or suspended); `:membership_role` / `:membership_status` shape that membership.
  defp mint_key(org_id, raw, opts \\ []) do
    user =
      PawChart.Operator.User
      |> Ash.Changeset.for_create(:create, %{org_id: org_id, handle: "u-#{System.unique_integer([:positive])}"})
      |> Ash.create!(authorize?: false)

    membership =
      PawChart.Operator.Membership
      |> Ash.Changeset.for_create(:create, %{
        org_id: org_id,
        user_id: user.id,
        role: Keyword.get(opts, :membership_role, :admin),
        status: Keyword.get(opts, :membership_status, "active")
      })
      |> Ash.create!(authorize?: false)

    key =
      PawChart.Operator.ApiKey
      |> Ash.Changeset.for_create(:create, %{
        org_id: org_id,
        membership_id: membership.id,
        plane: :tenant,
        minter_role: Keyword.get(opts, :minter_role, :admin),
        expires_at: Keyword.get(opts, :expires_at)
      })
      |> Ash.Changeset.force_change_attribute(:token_digest, McpKeyResolver.digest(raw))
      |> Ash.create!(authorize?: false)

    # born live and clamped by the resource; the helper then shapes the legacy/expired/revoked rows the tests need
    key
    |> Ash.Changeset.for_update(:mark_used, %{}, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:revoked_at, Keyword.get(opts, :revoked_at))
    |> Ash.Changeset.force_change_attribute(:expires_at, Keyword.get(opts, :expires_at))
    |> Ash.update!(authorize?: false)
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

  test "an EXPIRED token ⇒ 401 (deny-on-read; the same shared lookup every host uses)" do
    past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
    mint_key(@org_a, "expired-token-yyy", expires_at: past)
    assert mcp_post(%{"method" => "tools/list", "id" => 1}, "expired-token-yyy").status == 401

    # control: the same token shape with a FUTURE expiry authenticates
    future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)
    mint_key(@org_a, "future-token-yyy", expires_at: future)
    assert mcp_post(%{"method" => "ping", "id" => 1}, "future-token-yyy").status == 200
  end

  test "a key with NO minter_role ⇒ 401 (fail closed; it must not be promoted to :member)" do
    # control: the same key with a role (and an active membership) authenticates
    row = mint_key(@org_a, "roleless-token-www")
    assert mcp_post(%{"method" => "ping", "id" => 1}, "roleless-token-www").status == 200

    row
    |> Ash.Changeset.for_update(:mark_used, %{}, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:minter_role, nil)
    |> Ash.update!(authorize?: false)

    assert mcp_post(%{"method" => "ping", "id" => 1}, "roleless-token-www").status == 401
  end

  test "RED: a key whose minter's membership is suspended ⇒ 401; CONTROL: an active one authenticates" do
    mint_key(@org_a, "active-minter-token", membership_status: "active")
    mint_key(@org_a, "suspended-minter-token", membership_status: "suspended")

    assert mcp_post(%{"method" => "ping", "id" => 1}, "active-minter-token").status == 200
    assert mcp_post(%{"method" => "ping", "id" => 1}, "suspended-minter-token").status == 401
  end

  test "RED: an owner-rank key whose minter was demoted resolves with the membership's CURRENT role" do
    mint_key(@org_a, "demoted-owner-token", minter_role: :owner, membership_role: :viewer)
    mint_key(@org_a, "owner-token", minter_role: :owner, membership_role: :owner)

    assert {:ok, %Samen.Scope{actor: %{role: :viewer}}} = McpKeyResolver.resolve_scope("demoted-owner-token")
    assert {:ok, %Samen.Scope{actor: %{role: :owner}}} = McpKeyResolver.resolve_scope("owner-token")
  end

  test "RED: a key that RESOLVES but whose membership read FAILS is 503 + Retry-After, reported once, not 401; CONTROL: healthy = 200" do
    mint_key(@org_a, "membership-outage-token")
    assert mcp_post(%{"method" => "ping", "id" => 1}, "membership-outage-token").status == 200

    table = AshPostgres.DataLayer.Info.table(PawChart.Operator.Membership)
    Ecto.Adapters.SQL.query!(PawChart.Repo, "ALTER TABLE #{table} RENAME TO #{table}_broken", [])

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        send(self(), {:resolved, McpKeyResolver.resolve_scope("membership-outage-token")})
        send(self(), {:conn, mcp_post(%{"method" => "ping", "id" => 1}, "membership-outage-token")})
      end)

    assert_received {:resolved, {:error, :unavailable}}
    assert_received {:conn, conn}
    assert conn.status == 503
    assert [retry] = Plug.Conn.get_resp_header(conn, "retry-after")
    assert String.to_integer(retry) > 0
    # two requests above (resolver + plug) = two reports, each once, under the membership name only
    assert length(Regex.scan(~r/read=pawchart_mcp_key_membership_load/, log)) == 2
    refute log =~ "read=pawchart_mcp_key_lookup"
    refute log =~ "membership-outage-token"
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
