defmodule Samen.Web.AuthGate do
  @moduledoc """
  The reusable OPERATOR control-plane auth gate PLUG (T117; ROLE-hardened T146) — the framework
  generalization of driftwood's reference `DriftwoodWeb.Auth` runtime gate, backing the generated
  router's `:require_authenticated_operator` pipeline.

  A generated app (`mix samen.gen.app`) mounts the ADR-010 operator / SaaS-company control
  plane (`samen_operator_routes` — accounts · platform billing · revenue · flags · analytics ·
  desk · webhook DLQ) whose LiveViews derive their scope from the well-known operator org id,
  NOT through `Samen.Web.CurrentOrg`. So the `:authn` seam that gates every tenant/shared mount
  (`{:app_env, otp_app, :auth_required?}`, consumed by `CurrentOrg.resolve/3`) does NOT cover
  the operator scope. Without a gate the operator control plane is reachable COLD in prod
  (P9-F1: `/operator/*` renders to any anonymous visitor).

  ## Two things it enforces (so `:require_authenticated_operator` is an honest name)

    1. AUTHENTICATION — armed in prod (`config <otp_app>, auth_required?: true`), an
       UNAUTHENTICATED request is redirected to `/login` (halt) before any operator surface
       renders; a NO-OP in dev/test (`:auth_required?` false — the query-param convenience
       identity stays), same three-way posture as `DriftwoodWeb.Auth.require_authenticated_user/2`.
    2. OPERATOR ROLE (T146) — armed in prod, an authenticated request must ALSO hold operator
       authority. The principal is resolved from the signed session and passed to the host's
       `:operator_authority` MFA (app env `config <otp_app>, :operator_authority, {mod, fun, args}`,
       the conn-level twin of the mount `:operator_authority` seam `Samen.Web.Operator.Authz`
       reads). No resolver, an error, or a non-operator return → redirect to `/login`. Deny by
       default: a host that wires NO resolver gets NO operator access in prod, never open access.

  This is conn-level DEFENSE-IN-DEPTH; the by-construction ROLE gate is the
  `{Samen.Web.Operator.Authz, :require_operator}` `on_mount` every operator route carries (which
  applies in dev too — the operator-ROLE check is NOT bypassed by `auth_required?: false` there).

  ## Options (compile-time literals — this plug is `init`'d in a router pipeline)

    * `:otp_app`    — REQUIRED. The host app whose `:auth_required?` runtime flag arms the gate
      (mirrors the `:authn` label's `{:app_env, otp_app, :auth_required?}` seam) and whose
      `:operator_authority` app-env holds the conn-level operator-role resolver MFA.
    * `:login_path` — where an unauthenticated / non-operator request is redirected (default `"/login"`).
    * `:exempt`     — request paths always allowed through even when armed (default `[]`; the
      operator scope carries no pre-actor routes, so the generated mount needs none — `/login`
      and `/healthz` live in the un-gated base scope).
  """

  @behaviour Plug

  import Plug.Conn, only: [get_session: 1, halt: 1]
  import Phoenix.Controller, only: [redirect: 2]

  alias Samen.OperatorPlane.Actor
  alias Samen.Web.Auth, as: WebAuth

  @roles Actor.roles()

  @impl Plug
  def init(opts) do
    %{
      otp_app: Keyword.fetch!(opts, :otp_app),
      login_path: Keyword.get(opts, :login_path, "/login"),
      exempt: Keyword.get(opts, :exempt, [])
    }
  end

  @impl Plug
  def call(conn, %{otp_app: otp_app, login_path: login_path, exempt: exempt}) do
    cond do
      # Dev/test AUTHENTICATION no-op; the operator-ROLE gate still applies at the mount
      # (`Samen.Web.Operator.Authz` on_mount), so this dev relaxation cannot ship the exploit.
      not auth_required?(otp_app) -> conn
      conn.request_path in exempt -> conn
      is_nil(WebAuth.authenticated_user_id(get_session(conn))) -> conn |> redirect(to: login_path) |> halt()
      operator_role(conn, otp_app) -> conn
      true -> conn |> redirect(to: login_path) |> halt()
    end
  end

  @doc "Whether the prod auth gate is armed for `otp_app` (runtime flag; false in dev/test)."
  @spec auth_required?(atom()) :: boolean()
  def auth_required?(otp_app) when is_atom(otp_app),
    do: !!Application.get_env(otp_app, :auth_required?, false)

  # T146 — resolve the authenticated principal's operator role via the host's app-env
  # `:operator_authority` MFA (called with the principal id appended). Fail CLOSED: no resolver,
  # an error, or a non-operator return → `nil` (the caller then denies).
  defp operator_role(conn, otp_app) do
    principal_id = WebAuth.authenticated_user_id(get_session(conn))

    case Application.get_env(otp_app, :operator_authority) do
      {mod, fun, args} when is_atom(mod) and is_atom(fun) and is_list(args) ->
        case apply(mod, fun, args ++ [principal_id]) do
          role when role in @roles -> role
          _ -> nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end
end
