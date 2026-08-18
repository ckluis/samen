defmodule DriftwoodWeb.IdentitySpineMountTest do
  @moduledoc """
  T148 — the framework IDENTITY SPINE is now MOUNTED in driftwood over `Driftwood.Operator`,
  following the generated golden router (`samen_auth_routes` + `samen_onboarding_routes`).

  Proves:
    * the pre-actor auth surfaces (signup / verify / reset / 2fa / invite) + login/logout +
      the onboarding wizard are routed (the ≈0-LOC adoption);
    * the bespoke BYO login controller was MIGRATED to the framework spine and then REMOVED
      (R9 doc-sweep) — `/login` is now the framework LoginLive, no host controller owns it;
    * the pre-actor paths are EXEMPT from the `DriftwoodWeb.Auth` prod gate (a new user can
      sign up / verify when auth is armed), while `/onboarding` and normal tenant surfaces
      stay gated (they need an actor).
  """
  use ExUnit.Case, async: false

  import Plug.Test

  @routes DriftwoodWeb.Router.__routes__()
  defp paths, do: Enum.map(@routes, & &1.path)

  test "the auth spine + onboarding + invite-accept routes are mounted (the golden-app pattern)" do
    ps = paths()

    for path <- ~w(/signup /verify/:token /reset /reset/:token /2fa /login /logout /invite/:token /onboarding) do
      assert path in ps, "expected #{path} to be mounted by the framework identity spine"
    end
  end

  test "/login is the framework LoginLive, not a bespoke controller (migrated to the identity spine)" do
    login = Enum.find(@routes, &(&1.path == "/login" and &1.verb == :get))
    assert login, "expected a GET /login route mounted by the framework identity spine"

    # The bespoke `DriftwoodWeb.AuthController` was REMOVED (R9 doc-sweep) once no route pointed
    # at it. GET /login is now served by the framework LiveView (`Samen.Web.Auth.LoginLive`) via
    # `samen_auth_routes`, so it carries LiveView metadata and its plug is `Phoenix.LiveView.Plug`
    # — never a host controller module.
    assert login.plug == Phoenix.LiveView.Plug,
           "GET /login must be the framework LoginLive (a LiveView), not a host controller"

    assert elem(login.metadata.phoenix_live_view, 0) == Samen.Web.Auth.LoginLive,
           "GET /login must resolve to the framework Samen.Web.Auth.LoginLive"
  end

  describe "DriftwoodWeb.Auth prod gate exemptions (T148)" do
    setup do
      Application.put_env(:driftwood, :auth_required?, true)
      on_exit(fn -> Application.put_env(:driftwood, :auth_required?, false) end)
      :ok
    end

    test "GREEN: the pre-actor auth surfaces are reachable unauthenticated (not redirected)" do
      for path <- ~w(/signup /reset /2fa /verify/tok123 /reset/tok123 /invite/tok123) do
        conn = conn(:get, path) |> init_test_session(%{}) |> DriftwoodWeb.Auth.call([])
        refute conn.halted, "expected #{path} to be gate-exempt when auth is armed"
      end
    end

    test "RED: /onboarding is NOT exempt (needs an actor) — unauthenticated is redirected" do
      conn = conn(:get, "/onboarding") |> init_test_session(%{}) |> DriftwoodWeb.Auth.call([])
      assert conn.halted
    end

    test "RED: a normal tenant surface is still gated" do
      conn = conn(:get, "/crm/contacts") |> init_test_session(%{}) |> DriftwoodWeb.Auth.call([])
      assert conn.halted
    end
  end
end
