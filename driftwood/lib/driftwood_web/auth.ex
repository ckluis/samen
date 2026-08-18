defmodule DriftwoodWeb.Auth do
  @moduledoc """
  Driftwood's session-auth PLUG + login/logout conn helpers (F2 / ADR-031) — the reference
  wiring that proves day-1 login exists under the framework session seam.

  `Driftwood.Auth` verifies credentials; THIS module does the conn/session work: establishing
  the authenticated session on login (writing the framework `Samen.Web.Auth` principal + the
  sticky current org), clearing it on logout, and gating the prod path.

  ## The runtime gate (module plug)

  `DriftwoodWeb.Auth` is a module plug on the host `:browser` pipeline. It is a NO-OP in dev/test
  (`:auth_required?` false — the query-param convenience identity stays), and in prod it redirects
  any unauthenticated request to `/login` (the auth + health routes are exempt so there is no
  redirect loop). Defense-in-depth: even if a request slips past this conn-level gate,
  `Samen.Web.CurrentOrg` refuses to derive a tenant actor without an authenticated principal.
  """

  @behaviour Plug
  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  alias Samen.Web.Auth, as: WebAuth
  alias Samen.Web.CurrentOrg

  # Reachable WITHOUT a session (else the gate would loop, or a NEW user could never sign up /
  # verify / reset). T148: the framework IDENTITY-SPINE pre-actor surfaces (`samen_auth_routes`)
  # join `/login`/`/logout` here — they are PUBLIC by design (pre-actor, no plane/org data). The
  # token routes (`/verify/:t`, `/reset/:t`, `/invite/:t`, OIDC callback) match by PREFIX.
  # `/onboarding` is deliberately NOT exempt: it needs an actor, and a post-login session passes.
  @exempt_exact ~w(/login /logout /healthz /readyz /signup /reset /2fa)
  @exempt_prefixes ~w(/verify/ /reset/ /invite/ /auth/oidc/)

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    if exempt?(conn.request_path) do
      conn
    else
      require_authenticated_user(conn, [])
    end
  end

  # Public pre-actor paths (exact) + the token/callback families (prefix).
  defp exempt?(path) do
    path in @exempt_exact or Enum.any?(@exempt_prefixes, &String.starts_with?(path, &1))
  end

  @doc "Whether the prod auth gate is armed (env-aware via `Samen.Web.TenantGate`; false in dev/test)."
  @spec auth_required?() :: boolean()
  def auth_required?, do: Samen.Web.TenantGate.armed?(:driftwood)

  @doc """
  The gate: pass through when auth is not required (dev/test convenience) or the session already
  carries an authenticated principal; otherwise halt + redirect to `/login`.
  """
  @spec require_authenticated_user(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def require_authenticated_user(conn, _opts) do
    cond do
      not auth_required?() -> conn
      WebAuth.authenticated_user_id(get_session(conn)) -> conn
      true -> conn |> redirect(to: "/login") |> halt()
    end
  end

  @doc """
  Establish an authenticated session: record the framework principal + the sticky current org,
  and renew the session id (fixation defense). The host decided WHO this is; the seam is uniform.
  """
  @spec log_in_user(Plug.Conn.t(), String.t(), String.t() | nil) :: Plug.Conn.t()
  def log_in_user(conn, user_id, org_id) when is_binary(user_id) do
    conn
    |> WebAuth.put_current_user(user_id)
    |> maybe_put_org(org_id)
    |> configure_session(renew: true)
  end

  @doc "Clear the authenticated session (logout)."
  @spec log_out_user(Plug.Conn.t()) :: Plug.Conn.t()
  def log_out_user(conn) do
    conn
    |> WebAuth.log_out()
    |> configure_session(renew: true)
  end

  defp maybe_put_org(conn, org_id) when is_binary(org_id),
    do: put_session(conn, CurrentOrg.session_key(), org_id)

  defp maybe_put_org(conn, _), do: conn
end
