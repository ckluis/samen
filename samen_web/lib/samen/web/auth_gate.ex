defmodule Samen.Web.AuthGate do
  @moduledoc """
  The reusable OPERATOR-plane authentication gate PLUG (T117 / ADR-031) — the framework
  generalization of driftwood's reference `DriftwoodWeb.Auth` runtime gate.

  A generated app (`mix samen.gen.app`) mounts the ADR-010 operator / SaaS-company control
  plane (`samen_operator_routes` — accounts · platform billing · revenue · flags · analytics ·
  desk · webhook DLQ) whose LiveViews derive their scope from the well-known operator org id,
  NOT through `Samen.Web.CurrentOrg`. So the `:authn` seam that gates every tenant/shared mount
  (`{:app_env, otp_app, :auth_required?}`, consumed by `CurrentOrg.resolve/3`) does NOT cover
  the operator scope. Without a conn-level gate the operator control plane is reachable COLD in
  prod (P9-F1: `/operator/*` renders to any anonymous visitor). This plug closes that hole.

  ## The runtime gate

  A module plug the generated router pipes the operator scope through (a dedicated
  `:require_authenticated_operator` pipeline, riding AFTER `:browser` so the session is already
  fetched). It is a NO-OP in dev/test (`:auth_required?` false — the query-param convenience
  identity stays) and, in prod (`config <otp_app>, auth_required?: true`), it redirects any
  UNAUTHENTICATED request to `/login` (halt), before any operator surface renders. Same three-way
  gate as `DriftwoodWeb.Auth.require_authenticated_user/2`; defense-in-depth alongside the
  `CurrentOrg` actor gate that already covers the tenant mounts.

  ## Options (compile-time literals — this plug is `init`'d in a router pipeline)

    * `:otp_app`    — REQUIRED. The host app whose `:auth_required?` runtime flag arms the gate
      (mirrors the `:authn` label's `{:app_env, otp_app, :auth_required?}` seam).
    * `:login_path` — where an unauthenticated request is redirected (default `"/login"`).
    * `:exempt`     — request paths always allowed through even when armed (default `[]`; the
      operator scope carries no pre-actor routes, so the generated mount needs none — `/login`
      and `/healthz` live in the un-gated base scope).
  """

  @behaviour Plug

  import Plug.Conn, only: [get_session: 1, halt: 1]
  import Phoenix.Controller, only: [redirect: 2]

  alias Samen.Web.Auth, as: WebAuth

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
      not auth_required?(otp_app) -> conn
      conn.request_path in exempt -> conn
      WebAuth.authenticated_user_id(get_session(conn)) -> conn
      true -> conn |> redirect(to: login_path) |> halt()
    end
  end

  @doc "Whether the prod auth gate is armed for `otp_app` (runtime flag; false in dev/test)."
  @spec auth_required?(atom()) :: boolean()
  def auth_required?(otp_app) when is_atom(otp_app),
    do: !!Application.get_env(otp_app, :auth_required?, false)
end
