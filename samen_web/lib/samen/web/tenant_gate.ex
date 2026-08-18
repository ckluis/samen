defmodule Samen.Web.TenantGate do
  @moduledoc """
  The env-aware ARMING resolver + the fail-secure PROD BOOT GUARD for the tenant-auth gate
  (ADR-045 §2, V-F1 Option A — a scoped amendment to ADR-031's env-blind "off by default").

  ## The one resolution point for armed-ness (`armed?/1`)

  Every reader of a host's `:auth_required?` posture resolves through THIS function, so they can
  never disagree: `Samen.Web.CurrentOrg` (the tenant `?org=` gate), `Samen.Web.AuthGate` (the
  operator conn plug), `Samen.Web.Operator.{Authz,Impersonation}`, and each host's own reference
  auth module (`DriftwoodWeb.Auth`, `PawChartWeb.Auth`, …).

    * an EXPLICIT `config <otp_app>, auth_required?: <bool>` is honoured verbatim;
    * UNSET → env-aware: ARMED (`true`) in `:prod`, DISARMED (`false`) in dev/test.

  This makes the SECURE posture the DEFAULT in production while preserving ADR-031's dev/test
  ergonomics byte-for-byte — a `mix test` / `mix phx.server` host with no `:auth_required?` set
  stays DISARMED (the query-param dogfood convenience). A shipped host (driftwood/pawchart) or a
  fresh `mix samen.gen.app` running under a RELEASE with no `:auth_required?` config comes up
  ARMED, rather than serving an open tenant plane.

  ## Prod detection (`prod?/1`) — release-safe, the `Samen.AI.resolved_env/0` precedent

  A compiled release has no `:mix` application, so `config_env()` is unavailable at boot.
  `prod?/1` mirrors the kernel's `Samen.AI.resolved_env/0`: Mix present ⇒ its `Mix.env()`; Mix
  ABSENT (a release) OR any error reading it ⇒ `:prod`. That default is fail-SECURE — an
  unknowable environment is treated as production, so the gate ARMS rather than silently opening.

  ## The boot guard (`assert_prod_armed!/1`)

  The fail-secure backstop, matching the `--deploy` `runtime.exs` `fetch_secret!` raise (ADR-024):
  a mount-bearing host that reaches a PRODUCTION boot with the tenant gate DISARMED (an operator
  who EXPLICITLY set `auth_required?: false`) REFUSES TO BOOT with a named, actionable error — a
  vaulted multi-tenant SaaS must never come up serving an open tenant plane. Dev/test NEVER raise
  (the guard is a no-op unless `prod?/1`). It is wired at the framework boot seam (the host
  `Application.start/2`, alongside the ADR-024 prod-secret raise), so it fires before the endpoint
  ever accepts a request.
  """

  @unset :__samen_auth_required_unset__

  @doc """
  Whether the tenant-auth gate is ARMED for `otp_app`. See the moduledoc: explicit config is
  honoured; UNSET falls to the env-aware default (`:prod` ⇒ armed, dev/test ⇒ disarmed). A `nil`
  otp_app (a synthetic/unit-test mount with no host) is DISARMED, matching the pre-existing
  `CurrentOrg.param_trust_disarmed?/1` treatment of a mountless socket. `env_reader` is a test-only
  seam (default `&Mix.env/0`) so a suite can prove the prod default inside a `:test` run.
  """
  @spec armed?(atom() | nil, (-> atom())) :: boolean()
  def armed?(otp_app, env_reader \\ &Mix.env/0)
  def armed?(nil, _env_reader), do: false

  def armed?(otp_app, env_reader) when is_atom(otp_app) do
    case Application.get_env(otp_app, :auth_required?, @unset) do
      @unset -> prod?(env_reader)
      nil -> prod?(env_reader)
      value -> !!value
    end
  end

  @doc """
  Whether the runtime environment is production. Release-safe (Mix absent ⇒ `:prod`); see the
  moduledoc. `env_reader` is a test-only seam (default `&Mix.env/0`).
  """
  @spec prod?((-> atom())) :: boolean()
  def prod?(env_reader \\ &Mix.env/0), do: resolved_env(env_reader) == :prod

  @doc false
  @spec resolved_env((-> atom())) :: atom()
  def resolved_env(env_reader \\ &Mix.env/0) do
    if Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0) do
      env_reader.()
    else
      :prod
    end
  rescue
    _ -> :prod
  end

  @doc """
  The FAIL-SECURE boot guard (ADR-045 §2, Option A). Raises when — and ONLY when — `otp_app` is
  booting in a PRODUCTION environment with the tenant-auth gate DISARMED (i.e. an operator
  explicitly set `auth_required?: false`). A no-op in dev/test and whenever the gate resolves
  ARMED. Call it at the top of a mount-bearing host's `Application.start/2`. `env_reader` is a
  test-only seam.
  """
  @spec assert_prod_armed!(atom(), (-> atom())) :: :ok
  def assert_prod_armed!(otp_app, env_reader \\ &Mix.env/0) when is_atom(otp_app) do
    if prod?(env_reader) and not armed?(otp_app, env_reader) do
      raise """
      #{inspect(otp_app)} refuses to boot: the tenant-auth gate is DISARMED in PRODUCTION.

      This host was started in a production environment with

          config #{inspect(otp_app)}, auth_required?: false

      explicitly set. A Samen host must NEVER serve a multi-tenant plane in prod with the gate
      disarmed — an unauthenticated `?org=<uuid>` would resolve any tenant's vaulted data in the
      clear (ADR-045 §2). The gate is ARMED BY DEFAULT in prod; the only way to reach this state
      is an explicit opt-out, which is refused.

      To fix, ARM the gate (remove the explicit `false`, or set it true):

          config #{inspect(otp_app)}, auth_required?: true

      Arming REQUIRES a real login path and an authorization seam so operators are not locked out:
        * a host login that sets the authenticated principal (`Samen.Web.Auth`), and
        * the `:identity_namespace` (or `:authorized_orgs`) seam on every tenant mount, so admin
          writes derive the caller's REAL `Identity.Membership` role instead of failing closed.

      See docs/runbooks/deploy.md ("Operator TODO" — arm the tenant-auth gate).
      """
    end

    :ok
  end
end
