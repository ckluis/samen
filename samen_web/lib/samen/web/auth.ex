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

  import Plug.Conn, only: [put_session: 3, delete_session: 2, put_resp_cookie: 4, fetch_cookies: 2]

  alias Samen.Auth.SessionResolve

  @session_user_key "samen_current_user"
  @session_org_key "samen_current_org"

  # ADR-035 §4.3 — the framework spine's OWN session-token key, distinct from the
  # BYO-auth `samen_current_user` key above. Carries the RAW `Identity.Session`
  # token inside the signed+encrypted Phoenix session cookie.
  @session_token_key "samen_session_token"

  # The standalone remember-me cookie (§4.3): signed, http_only, secure,
  # SameSite=Lax, max-age 60 days, carrying the SAME raw token as the session
  # cookie above — one Session row, two possible carriers. Signed (not the plain
  # session store) because it lives OUTSIDE the Plug.Session cookie entirely, so
  # `resolve_principal/2` can fall back to it once the browser-session cookie is
  # gone (browser closed) without trusting an unsigned client-supplied value.
  @remember_cookie_key "samen_remember_token"
  @remember_cookie_salt "samen.web.auth.remember_me"

  # ADR-035 §5 A7 — the SIGNED (Plug session, same carrier as
  # `@session_token_key`) key holding the raw `:totp_pending` AuthToken while
  # a credential is between "password verified" and "second factor verified".
  # Distinct from `@session_token_key`: its presence does NOT authenticate
  # anyone — `Identity.Session` is created ONLY after the second factor (or a
  # recovery code) succeeds (ADR-035 §5 A7: "no half-authenticated session
  # rows exist").
  @totp_pending_key "samen_totp_pending_token"

  @doc "The session key naming the authenticated principal (aligned with the settings surface)."
  def session_user_key, do: @session_user_key

  @doc "The session key naming the framework spine's raw session token (ADR-035 §4.3)."
  def session_token_key, do: @session_token_key

  @doc "The remember-me cookie's name (ADR-035 §4.3)."
  def remember_cookie_key, do: @remember_cookie_key

  @doc "The session key naming the pending-2FA raw token (ADR-035 §5 A7)."
  def totp_pending_key, do: @totp_pending_key

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

  @doc """
  Clear the authenticated principal + the sticky current org (logout) — BOTH the
  legacy BYO-auth key and the framework spine's session-token key + remember-me
  cookie, so one `log_out/1` call is a complete logout regardless of which auth
  path signed the request in. Clearing a key/cookie that was never set is a
  harmless no-op (a BYO-auth host never had `samen_session_token` to begin
  with).
  """
  @spec log_out(Plug.Conn.t()) :: Plug.Conn.t()
  def log_out(conn) do
    conn
    |> delete_session(@session_user_key)
    |> delete_session(@session_org_key)
    |> delete_session(@session_token_key)
    |> delete_session(@totp_pending_key)
    |> clear_remember_cookie()
  end

  # ---------------------------------------------------------------------------
  # ADR-035 §5 A7 — the pending-2FA interstitial (between password verify and
  # second-factor verify; carries NO authenticated principal on its own).
  # ---------------------------------------------------------------------------

  @doc """
  Record the raw `:totp_pending` `AuthToken` on the conn's session — written
  on the SessionController's real HTTP response when a credential with 2FA
  enabled has just verified its password (`Samen.Web.Auth.SessionController.create/2`).
  """
  @spec put_totp_pending_token(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def put_totp_pending_token(conn, raw_token) when is_binary(raw_token),
    do: put_session(conn, @totp_pending_key, raw_token)

  @doc "Read the pending-2FA raw token from a session MAP, or `nil`."
  @spec fetch_totp_pending_token(map()) :: String.t() | nil
  def fetch_totp_pending_token(session) when is_map(session) do
    case Map.get(session, @totp_pending_key) do
      v when is_binary(v) -> v
      _ -> nil
    end
  end

  def fetch_totp_pending_token(_), do: nil

  @doc "Clear the pending-2FA token (consumed, expired, or abandoned)."
  @spec clear_totp_pending_token(Plug.Conn.t()) :: Plug.Conn.t()
  def clear_totp_pending_token(conn), do: delete_session(conn, @totp_pending_key)

  # ---------------------------------------------------------------------------
  # ADR-035 §4.3/§5 A4 — the framework spine's own session-token seam.
  # ---------------------------------------------------------------------------

  @doc """
  Record the RAW `Identity.Session` token on the conn's session (a real HTTP
  response — a LiveView socket cannot set a cookie mid-mount, ADR-035 §5 A4).
  This is the framework-auth counterpart to `put_current_user/2`; the two are
  independent (a host may run either path, or — during a BYO-auth → spine
  migration — both, briefly).
  """
  @spec put_session_token(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def put_session_token(conn, raw_token) when is_binary(raw_token),
    do: put_session(conn, @session_token_key, raw_token)

  @doc """
  Write the standalone remember-me cookie (ADR-035 §4.3): **signed**,
  `http_only`, `secure`, `SameSite=Lax`, max-age 60 days — carrying the SAME
  raw token the session cookie carries (one `Identity.Session` row, two
  possible carriers, one revocation). Signed with `Plug.Crypto.sign/3` against
  the endpoint's `secret_key_base` (the SAME primitive Phoenix's own cookie
  session store uses) so a tampered cookie value fails verification rather
  than resolving to someone else's forged token.
  """
  @spec write_remember_cookie(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def write_remember_cookie(%Plug.Conn{secret_key_base: secret} = conn, raw_token)
      when is_binary(secret) and is_binary(raw_token) do
    signed = Plug.Crypto.sign(secret, @remember_cookie_salt, raw_token)

    put_resp_cookie(conn, @remember_cookie_key, signed,
      http_only: true,
      secure: true,
      same_site: "Lax",
      max_age: Samen.Auth.SessionCreate.default_ttl_seconds()
    )
  end

  @doc "Clear the remember-me cookie (logout, or an explicit 'forget this device')."
  @spec clear_remember_cookie(Plug.Conn.t()) :: Plug.Conn.t()
  def clear_remember_cookie(conn), do: Plug.Conn.delete_resp_cookie(conn, @remember_cookie_key)

  @doc """
  Read + verify the remember-me cookie's raw token, or `nil`. A MISSING,
  tampered, or wrongly-signed cookie all resolve to `nil` — never raises,
  never trusts an unsigned client-supplied value.
  """
  @spec read_remember_cookie(Plug.Conn.t()) :: String.t() | nil
  def read_remember_cookie(%Plug.Conn{secret_key_base: secret} = conn) when is_binary(secret) do
    conn = fetch_cookies(conn, [])

    case Map.get(conn.req_cookies, @remember_cookie_key) do
      signed when is_binary(signed) ->
        case Plug.Crypto.verify(secret, @remember_cookie_salt, signed) do
          {:ok, raw_token} -> raw_token
          {:error, _reason} -> nil
        end

      _ ->
        nil
    end
  end

  def read_remember_cookie(_conn), do: nil

  @doc """
  Resolve the authenticated principal from a session MAP (works for both a
  `Plug.Conn`'s `get_session/1` result and a LiveView `mount/3` session param —
  ADR-035 §5 A4: `Samen.Web.Auth.Plug` + `on_mount {Samen.Web.Auth,
  :ensure_authenticated}` both call this). `mods` needs `:session` (the host's
  `Identity.Session` module).

  Resolution order:

    1. `"samen_session_token"` present → digest → live `Identity.Session` row →
       `{:ok, %{credential_id:, session_id:}}`. A revoked/expired/unknown token
       falls through to (2), it does NOT hard-fail — the caller may still be a
       legacy BYO-auth principal on a host running both paths.
    2. Fall back to the existing `"samen_current_user"` read — **ADR-031 hosts
       keep working unchanged**. `{:ok, %{user_id:}}` (a DIFFERENT identifier
       shape than (1): `user_id` is a per-org `Identity.User` id; `credential_id`
       is org-less — callers pattern-match on which key is present).
    3. Neither present/valid → `:error`.

  NOTE (scope boundary): this resolves WHICH principal is asking, not which
  ORG they are acting in — wiring the credential → per-org `User` derivation
  into `Samen.Web.CurrentOrg`'s `:authn`/`:authorized_orgs` seam (ADR-035 §5
  A4's `CurrentOrg` paragraph) is the next integration step, not done here.
  """
  @spec resolve_principal(map(), %{required(:session) => module()}) ::
          {:ok, %{credential_id: String.t(), session_id: String.t()}}
          | {:ok, %{user_id: String.t()}}
          | :error
  def resolve_principal(session, %{session: session_mod}) when is_map(session) do
    with raw when is_binary(raw) <- Map.get(session, @session_token_key),
         {:ok, row} <- SessionResolve.resolve(session_mod, raw) do
      SessionResolve.touch(session_mod, row)
      {:ok, %{credential_id: row.credential_id, session_id: row.id}}
    else
      _ -> legacy_fallback(session)
    end
  end

  def resolve_principal(_session, _mods), do: :error

  defp legacy_fallback(session) do
    case authenticated_user_id(session) do
      nil -> :error
      user_id -> {:ok, %{user_id: user_id}}
    end
  end

  @doc """
  The LiveView `on_mount` hook — `on_mount {Samen.Web.Auth, :ensure_authenticated}`
  in a host's `live_session` (ADR-035 §5 A4). Reads the LiveView session map
  ONLY (never a cookie — `Samen.Web.Auth.Plug` is the one place with real
  cookie access, and it normalizes a resurrected remember-me token back into
  the Plug session before this hook ever runs — see `Samen.Web.Auth.Plug`'s
  moduledoc). `:halt` + redirect to `/login` on failure; `:cont` with
  `samen_credential_id`/`samen_session_id` assigned (or the legacy
  `samen_current_user_id`, for a BYO-auth host) on success.
  """
  @spec on_mount(atom(), map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()} | {:halt, Phoenix.LiveView.Socket.t()}
  def on_mount(:ensure_authenticated, _params, session, socket) do
    mount = Samen.Web.Mount.from_session(session["samen_mount"] || %{})
    mods = %{session: Samen.Web.Mount.resource(mount, Session)}

    case resolve_principal(session, mods) do
      {:ok, %{credential_id: credential_id, session_id: session_id}} ->
        {:cont,
         Phoenix.Component.assign(socket,
           samen_credential_id: credential_id,
           samen_session_id: session_id
         )}

      {:ok, %{user_id: user_id}} ->
        {:cont, Phoenix.Component.assign(socket, samen_current_user_id: user_id)}

      :error ->
        {:halt, Phoenix.LiveView.redirect(socket, to: "/login")}
    end
  end
end
