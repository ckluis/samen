defmodule PawChart.OperatorAuthzTest do
  @moduledoc """
  T157 — the second-vertical operator-plane adoption proof, pawchart side. Validates:

    * the REAL operator ROSTER (not the framework dev fallback): under a PROD-armed gate
      (`auth_required?: true`, so the dev convenience is OFF), a principal IN the configured
      `:operator_roster` is admitted with its role and one ABSENT is refused (`nil`) — and the
      per-product isolation holds (`operator_role(:other, _)` is `nil`);
    * the framework operator VIEWS WORK for pawchart's (vet) data shape: the in-roster operator
      reaches `/operator/accounts` · `/operator/billing` · `/operator/revenue` (200) and the
      dead render carries pawchart's seeded clinic accounts;
    * the GATE closes: a plain TENANT user (authenticated, NOT in the roster) and an ANONYMOUS
      request are REFUSED (302 → /login) and see NONE of the cross-tenant clinic PII/MRR.

  Mirrors `driftwood/test/operator_authz_test.exs` — same framework `Samen.Web.AuthGate` +
  `Samen.Web.Operator.Authz` mechanism, pawchart's `PawChart.Auth.operator_role/2` roster seam.
  """
  use PawChart.DataCase, async: false

  import Phoenix.ConnTest
  import Plug.Conn, only: [get_resp_header: 2]

  @endpoint PawChartWeb.Endpoint

  # A genuine OPERATOR principal — provisioned in the operator roster below.
  @operator_user "0f000000-0000-4000-8000-000000000op1"
  # A plain TENANT user — authenticated, but ABSENT from the roster (NOT an operator).
  @tenant_user "11111111-0000-4000-8000-0000000000t9"

  # Seeded pawchart operator book of business (PawChart.OperatorSeeds).
  @clinic_name "Happy Paws Clinic"
  @leaked_admin_email "dana.mendez@happypaws.example"

  setup do
    start_supervised!(PawChartWeb.Endpoint)

    prev_required = Application.get_env(:pawchart, :auth_required?)
    prev_roster = Application.get_env(:pawchart, :operator_roster)

    # PROD posture: the gate is ARMED — the dev-fallback operator_admin grant is OFF, so the
    # ONLY authority is the roster (the T157 "real roster, not dev fallback" requirement).
    Application.put_env(:pawchart, :auth_required?, true)
    Application.put_env(:pawchart, :operator_roster, %{@operator_user => :operator_support})

    PawChart.OperatorSeeds.seed()

    on_exit(fn ->
      restore(:auth_required?, prev_required)
      restore(:operator_roster, prev_roster)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:pawchart, key)
  defp restore(key, val), do: Application.put_env(:pawchart, key, val)

  defp session_conn(user_id) do
    build_conn() |> init_test_session(%{"samen_current_user" => user_id})
  end

  describe "the REAL roster resolver (not the dev fallback)" do
    test "armed prod: a roster principal → its role; an absent principal → nil (refused)" do
      # auth_required? is true in setup, so the dev-only :operator_admin grant is disarmed —
      # the roster is the ONLY authority.
      assert PawChart.Auth.operator_role(:pawchart, @operator_user) == :operator_support
      assert PawChart.Auth.operator_role(:pawchart, @tenant_user) == nil
      assert PawChart.Auth.operator_role(:pawchart, nil) == nil
    end

    test "per-product isolation: a pawchart role confers NOTHING on another product scope" do
      assert PawChart.Auth.operator_role(:some_other_app, @operator_user) == nil
    end
  end

  describe "GREEN: the in-roster operator reaches the framework views over pawchart's data" do
    test "GET /operator/accounts renders pawchart's seeded clinic accounts" do
      conn = get(session_conn(@operator_user), "/operator/accounts")

      body = html_response(conn, 200)
      assert body =~ @clinic_name
    end

    test "GET /operator/billing and /operator/revenue are reachable (200)" do
      assert html_response(get(session_conn(@operator_user), "/operator/billing"), 200)
      assert html_response(get(session_conn(@operator_user), "/operator/revenue"), 200)
    end
  end

  describe "RED: the gate closes for a tenant / anonymous request" do
    test "a plain TENANT user is redirected to /login, sees no cross-tenant clinic PII/MRR" do
      conn = get(session_conn(@tenant_user), "/operator/accounts")

      assert conn.status == 302
      assert get_resp_header(conn, "location") == ["/login"]

      body = response(conn, 302)
      refute body =~ @clinic_name
      refute body =~ @leaked_admin_email
    end

    test "the /operator/billing surface is likewise refused to a tenant" do
      conn = get(session_conn(@tenant_user), "/operator/billing")

      assert conn.status == 302
      assert get_resp_header(conn, "location") == ["/login"]
      refute response(conn, 302) =~ @clinic_name
    end

    test "an ANONYMOUS request to the operator plane is refused" do
      conn = get(build_conn() |> init_test_session(%{}), "/operator/accounts")

      assert conn.status == 302
      assert get_resp_header(conn, "location") == ["/login"]
      refute response(conn, 302) =~ @clinic_name
    end
  end
end
