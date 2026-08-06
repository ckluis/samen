defmodule Samen.Web.AuthGateTest do
  @moduledoc """
  T117 (P9-F1 fix) — the OPERATOR control-plane prod auth gate (`Samen.Web.AuthGate`), the
  framework generalization of driftwood's `DriftwoodWeb.Auth`. The generated router pipes the
  operator scope through a `:require_authenticated_operator` pipeline over this plug, so a
  deployed prod app no longer exposes `/operator/*` (accounts · platform billing · webhook DLQ ·
  flags · …) to anonymous visitors.

  Paired red/control per `Samen.RedPath` (anti-tautology):
    * RED (anon)     — armed prod, ANONYMOUS `/operator/accounts` → 302 redirect to `/login` + halted.
    * RED (non-op)   — armed prod, an AUTHENTICATED TENANT user (no operator role) → 302 + halted
      (T146: the plug now enforces operator ROLE, not just authentication).
    * CONTROL — armed prod, AUTHENTICATED OPERATOR (host `:operator_authority` returns a role) →
      passes through untouched (proves the RED assertions can fail; a gate that halted everyone
      would be a tautology).
    * dev/test no-op — disarmed, anonymous passes (the sanctioned query-param convenience posture).

  SABOTAGE-REFUTABLE: neutralize `AuthGate.call/2` (e.g. make it always return `conn`) and the RED
  tests fail (no 302, no `location` header) while the CONTROL stays green — the pre-fix ungated
  shape is exactly what this asserts against. Mirrors `driftwood/test/auth_prodpath_test.exs`.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn, only: [get_resp_header: 2]

  alias Samen.Web.AuthGate

  # This test app-env namespace stands in for a generated app's otp_app; the gate reads
  # `Application.get_env(otp_app, :auth_required?, false)` exactly as it does in prod.
  @otp_app :samen_web
  @opts AuthGate.init(otp_app: @otp_app)

  @operator_user "operator-user-1"
  @tenant_user "tenant-user-9"

  # A host `:operator_authority` resolver: the single seeded operator user holds
  # `:operator_admin`; everyone else (a tenant user, anonymous nil) is NOT an operator.
  def resolve_operator_role(@operator_user), do: :operator_admin
  def resolve_operator_role(_), do: nil

  setup do
    prev = Application.get_env(@otp_app, :auth_required?)
    prev_authority = Application.get_env(@otp_app, :operator_authority)

    Application.put_env(@otp_app, :operator_authority, {__MODULE__, :resolve_operator_role, []})

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(@otp_app, :auth_required?)
        val -> Application.put_env(@otp_app, :auth_required?, val)
      end

      case prev_authority do
        nil -> Application.delete_env(@otp_app, :operator_authority)
        val -> Application.put_env(@otp_app, :operator_authority, val)
      end
    end)

    :ok
  end

  defp arm!, do: Application.put_env(@otp_app, :auth_required?, true)

  # A representative operator control-plane route (accounts list).
  defp operator_conn(session), do: conn(:get, "/operator/accounts") |> init_test_session(session)

  describe "prod (armed): the operator control plane requires an authenticated operator" do
    test "RED — an ANONYMOUS /operator/accounts request is redirected to /login and halted" do
      arm!()

      conn = operator_conn(%{}) |> AuthGate.call(@opts)

      assert conn.halted, "an anonymous operator request must be halted in prod"
      assert conn.status == 302
      assert get_resp_header(conn, "location") == ["/login"]
    end

    test "RED (T146) — an AUTHENTICATED TENANT user without operator role is redirected + halted" do
      arm!()

      # A real authenticated principal (the SAME session seam a host login writes) — but the
      # host `:operator_authority` resolver returns nil for a tenant user: NOT an operator.
      conn =
        operator_conn(%{})
        |> Samen.Web.Auth.put_current_user(@tenant_user)
        |> AuthGate.call(@opts)

      assert conn.halted, "an authenticated tenant user must NOT reach the operator plane"
      assert conn.status == 302
      assert get_resp_header(conn, "location") == ["/login"]
    end

    test "CONTROL — an AUTHENTICATED operator passes through (not halted, no redirect)" do
      arm!()

      conn =
        operator_conn(%{})
        # The real session seam a host login writes (`Samen.Web.Auth.put_current_user/2`),
        # the SAME key `authenticated_user_id/1` + `CurrentOrg` read — never a query param.
        # The host `:operator_authority` resolver returns `:operator_admin` for this principal.
        |> Samen.Web.Auth.put_current_user(@operator_user)
        |> AuthGate.call(@opts)

      refute conn.halted
      assert get_resp_header(conn, "location") == []
    end
  end

  describe "dev/test (disarmed): the sanctioned no-op stays active" do
    test "an anonymous request passes through when :auth_required? is false" do
      # No arm!/0 — the default disarmed posture (query-param convenience identity stays).
      conn = operator_conn(%{}) |> AuthGate.call(@opts)

      refute conn.halted
      assert get_resp_header(conn, "location") == []
    end
  end

  describe "auth_required?/1" do
    test "reflects the runtime app-env flag (false in dev/test, true when armed)" do
      refute AuthGate.auth_required?(@otp_app)
      arm!()
      assert AuthGate.auth_required?(@otp_app)
    end
  end
end
