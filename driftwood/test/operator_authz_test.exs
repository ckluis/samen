defmodule Driftwood.OperatorAuthzTest do
  @moduledoc """
  T146 (SECURITY-HIGH, dogfood W3-E1) — the operator control plane now enforces operator ROLE,
  not just authentication. This reproduces the verifier's LIVE exploit against the REAL
  `DriftwoodWeb.Endpoint` router (the same path the verifier used) and proves it is CLOSED.

  THE EXPLOIT (pre-T146, prod `auth_required?: true`): a plain authenticated TENANT user hitting
  `/operator/accounts` got a `200` rendering ANOTHER tenant's admin email
  (`marlene.okafor@blueridge.example`) + org (`Gulf Stream Carriers`) + MRR in the CLEAR, because
  the operator mount had NO operator-role authorization — it authenticated only, and
  `Samen.Web.Operator.scope/1` fabricated the actor from the MOUNT, never the session principal.

  Paired proofs (anti-tautology, `Samen.RedPath` discipline):
    * RED (the closed exploit) — an authenticated TENANT-user session GET `/operator/accounts`
      (and `/operator/billing`) is REFUSED (302 → `/login`) and renders NONE of the cross-tenant
      email/org/MRR. Plus the anonymous case (refused by the conn-level auth gate).
    * POSITIVE CONTROL — a genuine OPERATOR principal (in the operator roster) reaches the
      operator console and DOES see the (legitimately operator-visible) cross-tenant book — so the
      gate is not blanket-denying.

  Sabotage twin: `scripts/sabotages/56-t146-operator-plane-role-authz-bypass.patch` defeats the
  operator-role check; the RED tests below then fail (the tenant user renders the cross-tenant
  PII again) while the POSITIVE CONTROL stays green.
  """
  use Driftwood.DataCase, async: false

  import Phoenix.ConnTest
  import Plug.Conn, only: [get_resp_header: 2]

  @endpoint DriftwoodWeb.Endpoint

  # A plain TENANT user — authenticated, but NOT in the operator roster (NOT an operator).
  @tenant_user "11111111-0000-4000-8000-0000000000t9"
  # A genuine OPERATOR principal — provisioned in the operator roster.
  @operator_user "0f000000-0000-4000-8000-000000000op1"

  # The cross-tenant PII/MRR the exploit leaked (seeded by Driftwood.OperatorSeeds).
  @leaked_email "marlene.okafor@blueridge.example"
  @leaked_org "Gulf Stream Carriers"

  setup do
    start_supervised!(DriftwoodWeb.Endpoint)

    prev_required = Application.get_env(:driftwood, :auth_required?)
    prev_roster = Application.get_env(:driftwood, :operator_roster)

    # PROD posture: the gate is ARMED (the exact configuration the exploit was reproduced under).
    Application.put_env(:driftwood, :auth_required?, true)
    # The genuine operator's authority (a production deploy provisions this / swaps it for real
    # operator Membership rows — see Driftwood.Auth.operator_role/2).
    Application.put_env(:driftwood, :operator_roster, %{@operator_user => :operator_admin})

    # Seed the operator book of business so the leaked PII/MRR is actually present to leak.
    Driftwood.OperatorSeeds.seed()

    on_exit(fn ->
      restore(:auth_required?, prev_required)
      restore(:operator_roster, prev_roster)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:driftwood, key)
  defp restore(key, val), do: Application.put_env(:driftwood, key, val)

  defp session_conn(user_id) do
    build_conn() |> init_test_session(%{"samen_current_user" => user_id})
  end

  # ==========================================================================
  # RED — the closed exploit (a tenant user is refused + sees NO cross-tenant data)
  # ==========================================================================

  describe "prod (armed): a plain TENANT user is REFUSED the operator control plane" do
    test "RED: tenant-user GET /operator/accounts is redirected to /login, renders no cross-tenant PII/MRR" do
      conn = get(session_conn(@tenant_user), "/operator/accounts")

      # Refused (fail-closed redirect), NOT a 200 rendering the operator console.
      assert conn.status == 302
      assert get_resp_header(conn, "location") == ["/login"]

      # And crucially: NONE of the cross-tenant admin email / org / MRR leaked into the body.
      body = response(conn, 302)
      refute body =~ @leaked_email
      refute body =~ @leaked_org
      refute body =~ "Platform MRR"
    end

    test "RED: tenant-user GET /operator/billing is likewise refused" do
      conn = get(session_conn(@tenant_user), "/operator/billing")

      assert conn.status == 302
      assert get_resp_header(conn, "location") == ["/login"]
      refute response(conn, 302) =~ @leaked_email
    end

    test "RED: an ANONYMOUS request to the operator plane is refused" do
      conn = get(build_conn() |> init_test_session(%{}), "/operator/accounts")

      assert conn.status == 302
      assert get_resp_header(conn, "location") == ["/login"]
      refute response(conn, 302) =~ @leaked_email
    end
  end

  # ==========================================================================
  # RED (T146 round 2) — the THREE operator surfaces mounted OUTSIDE samen_operator_routes/2
  # (aggregate · impersonate · desk-chat) are now gated too. Before the operator-authz pipeline
  # these piped bare :browser (authentication only) and a tenant user reached them.
  # ==========================================================================

  describe "prod (armed): operator surfaces OUTSIDE the operator macro are refused to a tenant" do
    test "RED: tenant-user GET /operator/aggregate is refused, renders no operator-confidential aggregates" do
      conn = get(session_conn(@tenant_user), "/operator/aggregate")

      assert conn.status == 302
      assert get_resp_header(conn, "location") == ["/login"]

      # The real leak this closes: operator-confidential cross-tenant revenue/volume aggregates.
      body = response(conn, 302)
      refute body =~ "Platform MRR"
      refute body =~ "Portfolio"
      refute body =~ @leaked_org
    end

    test "RED: tenant-user GET /operator/impersonate is refused" do
      conn = get(session_conn(@tenant_user), "/operator/impersonate")

      assert conn.status == 302
      assert get_resp_header(conn, "location") == ["/login"]
    end

    test "RED: tenant-user GET /operator/desk-chat is refused" do
      conn = get(session_conn(@tenant_user), "/operator/desk-chat")

      assert conn.status == 302
      assert get_resp_header(conn, "location") == ["/login"]
    end

    test "RED: an ANONYMOUS request to each outside-the-macro operator surface is refused" do
      for path <- ["/operator/aggregate", "/operator/impersonate", "/operator/desk-chat"] do
        conn = get(build_conn() |> init_test_session(%{}), path)
        assert conn.status == 302, "#{path} must refuse anonymous"
        assert get_resp_header(conn, "location") == ["/login"]
      end
    end
  end

  # ==========================================================================
  # POSITIVE CONTROL — a genuine operator DOES reach the console (not blanket-deny)
  # ==========================================================================

  describe "prod (armed): a genuine OPERATOR principal reaches the operator console" do
    test "CONTROL: operator-user GET /operator/accounts renders the cross-tenant book (email + org + MRR)" do
      conn = get(session_conn(@operator_user), "/operator/accounts")

      assert conn.status == 200
      body = response(conn, 200)

      # The legitimately operator-visible cross-tenant book of business is present.
      assert body =~ @leaked_org
      assert body =~ "Platform MRR"
      # The tenant-admin email is CLEAR on the operator's own book (population (1), ADR-010 §5).
      assert body =~ @leaked_email
    end

    test "CONTROL: operator-user reaches the aggregate + impersonate + desk-chat surfaces (not refused)" do
      # Each outside-the-macro operator surface is REACHABLE for a genuine operator — the gate is
      # role-selective, not blanket-deny. (Not asserting a 200 body for impersonate/desk-chat,
      # which render deny-on-read / empty without a `?org=` target — the point is they are NOT
      # bounced to /login by the operator gate.)
      for path <- ["/operator/aggregate", "/operator/impersonate", "/operator/desk-chat"] do
        conn = get(session_conn(@operator_user), path)
        refute get_resp_header(conn, "location") == ["/login"], "#{path} must NOT refuse a genuine operator"
      end

      # The aggregate specifically renders (200) for an operator — the operator-confidential
      # portfolio surface a tenant is refused.
      conn = get(session_conn(@operator_user), "/operator/aggregate")
      assert conn.status == 200
    end
  end

  # ==========================================================================
  # LIVE-NAV authz (T146 round 3) — the conn pipeline gates only the HTTP dead-render; the
  # `on_mount` hook is what gates a WEBSOCKET mount reached via `live_redirect` within a shared
  # live_session. Router/live_session introspection is DISPOSITIVE per Phoenix semantics: an
  # operator LiveView in a named live_session carrying `require_operator` cannot be mounted
  # (HTTP or socket) by a non-operator; one sharing the tenant `:default` session can.
  # (No socket-nav LiveViewTest here: it needs the optional `lazy_html` dep, deliberately NOT
  # added inside a security fix; the introspection below is the dispositive proof.)
  # ==========================================================================

  describe "live-nav authz: every operator LiveView's live_session carries require_operator on_mount" do
    # {live_session_name, extra_opts} for the route at `path`, or nil if not a live route.
    defp live_session_for(path) do
      Enum.find_value(DriftwoodWeb.Router.__routes__(), fn r ->
        case r.metadata[:phoenix_live_view] do
          {_view, _action, _opts, %{name: name, extra: extra}} when r.path == path ->
            {name, extra}

          _ ->
            nil
        end
      end)
    end

    defp operator_live_routes do
      for r <- DriftwoodWeb.Router.__routes__(),
          plv = r.metadata[:phoenix_live_view],
          match?({_, _, _, %{name: _, extra: _}}, plv),
          String.starts_with?(r.path, "/operator/"),
          do: {r.path, elem(plv, 3)}
    end

    test "/operator/impersonate is in its OWN named operator live_session (NOT :default) carrying require_operator on_mount" do
      {name, extra} = live_session_for("/operator/impersonate")

      refute name == :default,
             "impersonate in the SHARED :default session — a tenant /broker socket could live_redirect in"

      assert name == :driftwood_operator_impersonate
      assert inspect(extra[:on_mount]) =~ "Samen.Web.Operator.Authz"
      assert inspect(extra[:on_mount]) =~ "require_operator"
    end

    test "EVERY /operator/* live route is in a live_session carrying the require_operator on_mount" do
      routes = operator_live_routes()
      assert routes != [], "no operator live routes found — router introspection changed"

      for {path, %{name: name, extra: extra}} <- routes do
        refute name == :default,
               "#{path} is in the SHARED :default live_session (tenant-reachable via live-nav)"

        assert inspect(extra[:on_mount]) =~ "require_operator",
               "#{path} live_session #{inspect(name)} does NOT carry the require_operator on_mount"
      end
    end

    test "NO operator live route shares the tenant /broker live_session" do
      {broker_session, _} = live_session_for("/broker")

      shared =
        for {path, %{name: name}} <- operator_live_routes(), name == broker_session, do: path

      assert shared == [],
             "operator routes share /broker's live_session (live-nav bypass): #{inspect(shared)}"
    end
  end
end
