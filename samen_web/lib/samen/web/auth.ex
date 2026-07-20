defmodule Samen.Web.Auth do
  @moduledoc """
  The framework AUTHENTICATED-PRINCIPAL session seam (F2 / ADR-031).

  Auth is HOST-OWNED (ADR-029): `samen_web` ships no password store, no login LiveView,
  no IdP. What it DOES own is the ONE session key that names "who is authenticated" and
  the read/write helpers around it — so a host's login flow (phx.gen.auth, an external
  IdP callback, or the driftwood reference verifier) has a single, framework-blessed place
  to record the signed-in user, and `Samen.Web.CurrentOrg` has a single place to read it
  when deriving the tenant actor on the prod path.

  ## The key — reused, not reinvented

  The authenticated principal lives under `"samen_current_user"` — the SAME key the
  self-serve settings surface already reads as "me" (`Samen.Web.Settings.Reads`). Before
  F2 that key was only ever set by a host in dev; F2 makes a real login the thing that
  sets it, and teaches `CurrentOrg` to GATE the tenant org against it.

  ## Session-only — never a query param

  `authenticated_user_id/1` reads ONLY the signed session (set on a real HTTP login
  response). It deliberately does NOT consult `params["user"]`: a query param is a
  dev/settings convenience, never a proof of identity. The security boundary is the
  session the host's login established, nothing a URL can spoof.
  """

  import Plug.Conn, only: [put_session: 3, delete_session: 2]

  @session_user_key "samen_current_user"
  @session_org_key "samen_current_org"

  @doc "The session key naming the authenticated principal (aligned with the settings surface)."
  def session_user_key, do: @session_user_key

  @doc """
  The authenticated user id from the SIGNED session, or `nil`. Session-only by design —
  never a query param (a param cannot prove identity). Never raises.
  """
  @spec authenticated_user_id(map() | nil) :: String.t() | nil
  def authenticated_user_id(session) when is_map(session) do
    case Map.get(session, @session_user_key) do
      v when is_binary(v) ->
        case String.trim(v) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  def authenticated_user_id(_), do: nil

  @doc "Whether the session carries an authenticated principal."
  @spec authenticated?(map() | nil) :: boolean()
  def authenticated?(session), do: authenticated_user_id(session) != nil

  @doc """
  Record the authenticated principal on the conn's session (a host login calls this on the
  successful HTTP response). Framework-generic; the host owns HOW it verified the user.
  """
  @spec put_current_user(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def put_current_user(conn, user_id) when is_binary(user_id),
    do: put_session(conn, @session_user_key, user_id)

  @doc "Clear the authenticated principal + the sticky current org (logout)."
  @spec log_out(Plug.Conn.t()) :: Plug.Conn.t()
  def log_out(conn) do
    conn
    |> delete_session(@session_user_key)
    |> delete_session(@session_org_key)
  end
end
