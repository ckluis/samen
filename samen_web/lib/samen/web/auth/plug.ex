defmodule Samen.Web.Auth.Plug do
  @moduledoc """
  ADR-035 §5 A4 — the browser-pipeline half of principal resolution. Runs on
  every dead-render request BEFORE any LiveView mounts, so it is the ONE place
  with real cookie access: if the Plug session already carries
  `"samen_session_token"`, it leaves it alone; if not, it tries the remember-me
  cookie and, on a successful resolve, WRITES the token into the Plug session
  — so the subsequent `live_session`'s session map (and therefore the
  `on_mount {Samen.Web.Auth, :ensure_authenticated}` hook, which only ever
  reads a plain session map, never a cookie) sees it too. A missing/invalid/
  revoked/expired token on both carriers is NOT a hard failure here — the
  request simply proceeds unauthenticated; enforcement (redirect to login)
  is the `on_mount` hook's job, mirroring `Samen.Web.CurrentOrg`'s existing
  "resolve, don't enforce" plug/on_mount split.

  Mount this in the host's `:browser` pipeline, per-Identity-mount:

      plug Samen.Web.Auth.Plug, namespace: MyApp.Identity, repo: MyApp.Repo
  """
  import Plug.Conn

  alias Samen.Auth.SessionResolve
  alias Samen.Web.Auth

  @behaviour Plug

  @impl true
  def init(opts) do
    namespace = Keyword.fetch!(opts, :namespace)
    session_mod = Module.concat(namespace, Session)
    [session_mod: session_mod]
  end

  @impl true
  def call(conn, session_mod: session_mod) do
    conn = fetch_session(conn)

    case get_session(conn, Auth.session_token_key()) do
      raw when is_binary(raw) ->
        conn

      _ ->
        resurrect_from_remember_cookie(conn, session_mod)
    end
  end

  defp resurrect_from_remember_cookie(conn, session_mod) do
    case Auth.read_remember_cookie(conn) do
      raw when is_binary(raw) ->
        case SessionResolve.resolve(session_mod, raw) do
          {:ok, _session} -> Auth.put_session_token(conn, raw)
          :error -> conn
        end

      nil ->
        conn
    end
  end
end
