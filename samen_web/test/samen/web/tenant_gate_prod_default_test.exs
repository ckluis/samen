defmodule Samen.Web.TenantGateProdDefaultTest do
  @moduledoc """
  ADR-045 §2 (V-F1, Option A) — the PROD-ARMING default + the fail-secure BOOT GUARD.

  This is the coverage gap ADR-045 §2 named: there was NO test asserting that a production
  environment ARMS the tenant-auth gate by default. `Samen.Web.TenantGate` now owns the env-aware
  arming resolution + the boot refusal; this suite proves all three postures the ADR requires:

    * (a) a PROD-like config resolves ARMED — and, when armed, a real tenant surface DENIES an
      unauthenticated dead-render request (the exact `handle_params`-on-dead-render vector B-SEC
      closed), with the DISARMED convenience as the anti-tautology positive control;
    * (b) the BOOT GUARD RAISES when a prod environment is configured with the gate DISARMED
      (an explicit `auth_required?: false`), and stays silent when armed / unset-in-prod;
    * (c) dev/test resolve DISARMED by default (the ADR-031 dogfood ergonomics, byte-identical) —
      an UNSET flag is disarmed in dev/test and armed ONLY in prod.

  The env is injected via `TenantGate`'s test-only `env_reader` seam so the prod default is
  provable inside a `:test` run (the same seam `Samen.AI.resolved_env/1` established), never by
  mutating the real `Mix.env/0`.
  """
  use Samen.WebTest.DataCase, async: false

  import Phoenix.ConnTest

  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount
  alias Samen.Web.TenantGate
  alias Samen.WebTest.SecurityHost

  @endpoint Samen.WebTest.SecurityEndpoint

  # A throwaway app whose `:auth_required?` this suite owns — never poisons a real host.
  @app :samen_web_tenant_gate_test_app

  # Injected env readers (the `TenantGate` test-only seam). Functions, not module attrs,
  # because an anonymous fun cannot be escaped into a module attribute.
  defp prod, do: fn -> :prod end
  defp dev, do: fn -> :dev end
  defp test_env, do: fn -> :test end

  setup do
    prev_app = Application.get_env(@app, :auth_required?)
    prev_sec = Application.get_env(SecurityHost.otp_app(), :auth_required?)

    on_exit(fn ->
      restore(@app, prev_app)
      restore(SecurityHost.otp_app(), prev_sec)
    end)

    :ok
  end

  defp restore(app, nil), do: Application.delete_env(app, :auth_required?)
  defp restore(app, v), do: Application.put_env(app, :auth_required?, v)

  # ==========================================================================
  # (c) + (a-unit) — `armed?/2`: explicit honoured; UNSET is env-aware (prod arms).
  # ==========================================================================

  describe "TenantGate.armed?/2 — the env-aware default (ADR-045 §2)" do
    test "UNSET flag: ARMED in :prod, DISARMED in dev/test (the coverage gap the ADR named)" do
      Application.delete_env(@app, :auth_required?)

      assert TenantGate.armed?(@app, prod()), "prod must ARM the gate by default when unset"
      refute TenantGate.armed?(@app, dev()), "dev must stay DISARMED by default (ADR-031 ergonomics)"
      refute TenantGate.armed?(@app, test_env()), "test must stay DISARMED by default (ADR-031 ergonomics)"
    end

    test "an EXPLICIT operator choice is honoured verbatim in every env" do
      Application.put_env(@app, :auth_required?, false)
      refute TenantGate.armed?(@app, prod()), "an explicit false disarms even in prod"
      refute TenantGate.armed?(@app, dev())

      Application.put_env(@app, :auth_required?, true)
      assert TenantGate.armed?(@app, prod())
      assert TenantGate.armed?(@app, dev()), "an explicit true arms even in dev"
    end

    test "a nil otp_app (a synthetic/mountless socket) is DISARMED" do
      refute TenantGate.armed?(nil, prod())
    end

    test "prod?/1 detects the injected env; resolved_env passes Mix's value through when Mix is loaded" do
      assert TenantGate.prod?(prod())
      refute TenantGate.prod?(dev())
      # Mix IS loaded during `mix test`, so the reader value is returned verbatim.
      assert TenantGate.resolved_env(prod()) == :prod
      assert TenantGate.resolved_env(test_env()) == :test
    end
  end

  # ==========================================================================
  # (b) — the fail-secure BOOT GUARD refuses a disarmed prod host.
  # ==========================================================================

  describe "TenantGate.assert_prod_armed!/2 — the boot refusal (ADR-045 §2, Option A)" do
    test "RAISES in prod when the gate is explicitly DISARMED, naming the config key" do
      Application.put_env(@app, :auth_required?, false)

      err =
        assert_raise RuntimeError, fn ->
          TenantGate.assert_prod_armed!(@app, prod())
        end

      assert err.message =~ "refuses to boot"
      assert err.message =~ "auth_required?"
      assert err.message =~ Atom.to_string(@app)
    end

    test "does NOT raise in prod when armed (explicit true) or when UNSET (armed by default)" do
      Application.put_env(@app, :auth_required?, true)
      assert TenantGate.assert_prod_armed!(@app, prod()) == :ok

      Application.delete_env(@app, :auth_required?)
      assert TenantGate.assert_prod_armed!(@app, prod()) == :ok,
             "unset-in-prod is ARMED by default, so the guard must not raise"
    end

    test "NEVER raises in dev/test, even when disarmed (dev ergonomics preserved)" do
      Application.put_env(@app, :auth_required?, false)
      assert TenantGate.assert_prod_armed!(@app, dev()) == :ok
      assert TenantGate.assert_prod_armed!(@app, test_env()) == :ok

      Application.delete_env(@app, :auth_required?)
      assert TenantGate.assert_prod_armed!(@app, dev()) == :ok
      assert TenantGate.assert_prod_armed!(@app, test_env()) == :ok
    end
  end

  # ==========================================================================
  # (a) — when the gate resolves ARMED, a real tenant surface DENIES an
  # unauthenticated dead render; the DISARMED posture serves it (anti-tautology).
  # ==========================================================================

  describe "an ARMED tenant surface denies the unauthenticated dead render (a)" do
    setup do
      org_id = Ash.UUID.generate()

      Samen.WebTest.Crm.Person
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org_id,
          display_name: "GATE PROBE CONTACT",
          job_title: "Dispatcher",
          full_name: %Samen.Type.FullName{first: "Prodesther", last: "Armington"}
        },
        authorize?: false
      )
      |> Ash.create!()

      %{org_id: org_id}
    end

    test "ARMED (the prod posture): the dead-render GET is REFUSED, no PII, no vt_ token", ctx do
      # This is what a prod config resolves to (config_env() == :prod → true, or the framework
      # env-aware default). The armed surface halts at the on_mount before handle_params runs.
      SecurityHost.arm!()

      conn = get(build_conn(), "/crm/contacts?org=#{ctx.org_id}")

      assert conn.status == 302, "an armed unauthenticated tenant dead render must not render"
      assert redirected_to(conn) == "/login"

      body = response(conn, 302)
      refute body =~ "Armington"
      refute body =~ "GATE PROBE CONTACT"
      refute body =~ "vt_"
    end

    test "POSITIVE CONTROL — DISARMED (dev/dogfood) serves the SAME request (ergonomics kept)", ctx do
      SecurityHost.disarm!()

      # The clean anti-tautology flip: the SAME unauthenticated dead render that ARMED refused
      # with a 302 is SERVED here with a 200 (never a redirect to /login) — the sanctioned
      # ADR-031 query-param convenience. The requested org is trusted and threaded into the page
      # (its nav hrefs carry `?org=<org_id>`), proving `?org=` resolved as identity while disarmed.
      html =
        build_conn()
        |> get("/crm/contacts?org=#{ctx.org_id}")
        |> html_response(200)

      assert html =~ ctx.org_id, "the disarmed dev convenience must resolve the requested ?org="
    end

    test "the resolver agrees: UNSET flag disarmed in :test trusts ?org=; the ARMED gate does not", ctx do
      mount =
        Mount.new(:crm, Samen.WebTest.Crm, Samen.WebTest.Repo,
          labels: %{authn: {:app_env, SecurityHost.otp_app(), :auth_required?}}
        )

      # DISARMED (the suite runs in :test; flag false) → the dev `?org=` convenience resolves.
      SecurityHost.disarm!()
      assert CurrentOrg.resolve(mount, %{"org" => ctx.org_id}, %{}) == ctx.org_id

      # ARMED → `?org=` is never trusted as identity; an unauthenticated caller gets NO actor.
      SecurityHost.arm!()
      assert CurrentOrg.resolve(mount, %{"org" => ctx.org_id}, %{}) == nil
    end
  end
end
