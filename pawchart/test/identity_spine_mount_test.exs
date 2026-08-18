defmodule PawChartWeb.IdentitySpineMountTest do
  @moduledoc """
  PP-2 (Batch 5a PAWCHART-SPINE) — the framework IDENTITY SPINE is now MOUNTED in pawchart over
  `PawChart.Operator`, following the generated golden router (`samen_auth_routes` +
  `samen_onboarding_routes` + `samen_settings_routes`), MIRRORING driftwood's adoption.

  Live-reproduced gap (dogfood W4 BLOCKER-2): pawchart mounted NO identity spine at all — no
  /login, /signup, verify, reset, 2FA, invite, onboarding, or tenant Settings — so the operator
  AuthGate's `/login` redirect target 404'd and the tenant first-run journey was impossible.

  Proves:
    * the pre-actor auth surfaces (signup / verify / reset / 2fa / invite) + login/logout + the
      onboarding wizard + tenant Settings are routed (the ≈0-LOC adoption over PawChart.Operator);
    * the pre-actor paths are EXEMPT from the `PawChartWeb.Auth` prod gate (a new clinic user can
      sign up / verify when auth is armed), while `/onboarding` and normal tenant surfaces stay
      gated (they need an actor) — so the operator plane's `/login` target is a LIVE route.
  """
  use ExUnit.Case, async: false

  import Plug.Test

  @routes PawChartWeb.Router.__routes__()
  defp paths, do: Enum.map(@routes, & &1.path)

  test "the auth spine + onboarding + settings routes are mounted (the golden-app pattern)" do
    ps = paths()

    for path <-
          ~w(/signup /verify/:token /reset /reset/:token /2fa /login /logout /invite/:token /onboarding /settings /settings/api-keys /settings/security) do
      assert path in ps, "expected #{path} to be mounted by the framework identity spine"
    end
  end

  test "the session-write endpoint is mounted (sticky current org for switcher + Open account)" do
    assert "/session/org/:org_id" in paths()
  end

  test "/login is the FRAMEWORK LoginLive (not a dead route) — the AuthGate redirect target resolves" do
    login = Enum.find(@routes, &(&1.path == "/login" and &1.verb == :get))
    assert login
    assert login.plug == Phoenix.LiveView.Plug
    assert match?({Samen.Web.Auth.LoginLive, _, _, _}, login.metadata.phoenix_live_view)
  end

  describe "PawChartWeb.Auth prod gate exemptions (PP-2)" do
    setup do
      Application.put_env(:pawchart, :auth_required?, true)
      on_exit(fn -> Application.put_env(:pawchart, :auth_required?, false) end)
      :ok
    end

    test "GREEN: the pre-actor auth surfaces are reachable unauthenticated (not redirected)" do
      for path <- ~w(/signup /reset /2fa /verify/tok123 /reset/tok123 /invite/tok123) do
        conn = conn(:get, path) |> init_test_session(%{}) |> PawChartWeb.Auth.call([])
        refute conn.halted, "expected #{path} to be gate-exempt when auth is armed"
      end
    end

    test "RED: /onboarding is NOT exempt (needs an actor) — unauthenticated is redirected" do
      conn = conn(:get, "/onboarding") |> init_test_session(%{}) |> PawChartWeb.Auth.call([])
      assert conn.halted
    end

    test "RED: a normal tenant surface is still gated when armed" do
      conn = conn(:get, "/crm/contacts") |> init_test_session(%{}) |> PawChartWeb.Auth.call([])
      assert conn.halted
    end

    test "dev/test: the gate is a no-op when auth is not required" do
      Application.put_env(:pawchart, :auth_required?, false)
      conn = conn(:get, "/crm/contacts") |> init_test_session(%{}) |> PawChartWeb.Auth.call([])
      refute conn.halted
    end
  end
end
