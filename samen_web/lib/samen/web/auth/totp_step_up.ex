defmodule Samen.Web.Auth.TotpStepUp do
  @moduledoc """
  ADR-035 §5 A6+A7 interaction (T100) — the SHARED 2FA step-up interstitial, so
  **no session-minting surface mints an `Identity.Session` for a `totp_enabled`
  credential without routing through the `/2fa` second factor**.

  2FA is an ACCOUNT property, not a password-flow property. The password login
  (`Samen.Web.Auth.SessionController.create/2`) AND the federated OIDC callback
  (`Samen.Web.Auth.OidcController.callback/2`) both detour a TOTP-enrolled
  credential through the SAME `:totp_pending` `AuthToken` → `/2fa`
  (`TotpChallengeLive`) → `verify_totp/2` → `finish_login` path. There is exactly
  ONE pending-token context (`:totp_pending`), ONE interstitial, ONE verify
  endpoint, and ONE `Identity.Session` mint — this module owns the ONE way that
  detour is armed and the ONE set of interstitial session keys
  `SessionController.verify_totp/2` reads back, so the entrypoints cannot drift
  into parallel 2FA paths (the T100 done-criterion: "no parallel mechanism").

  ## The generic rule (inherited by future surfaces)

  Any FUTURE session-minting surface (magic-link login, invite-acceptance
  auto-login, post-reset auto-login) is the SAME class: it MUST call
  `enrolled?/3` and, when true, `challenge/4` BEFORE minting a session — never
  `Samen.Auth.SessionCreate.create/3` directly for an enrolled credential. The
  `challenge/4` seam plus `verify_totp/2`'s shared `finish_login` is the blessed
  route.
  """

  import Plug.Conn, only: [put_session: 3, configure_session: 2]

  require Ash.Query

  alias Samen.Auth.TokenMint
  alias Samen.Web.Auth
  alias Samen.Web.Mount

  # ADR-035 §4.2 table — the `:totp_pending` context's TTL (single source of
  # truth; both the password and OIDC entrypoints mint at this TTL).
  @totp_pending_ttl_seconds 5 * 60

  # Interstitial-only session keys — pure login-flow bookkeeping carried between
  # `challenge/4` and `SessionController.verify_totp/2`. Their presence NEVER
  # authenticates anyone (only `Samen.Web.Auth.totp_pending_key/0`'s token, which
  # resolves against `AuthToken`, not `Session`). Owned HERE (not in either
  # controller) so the writer and reader share one definition.
  @pending_remember_key "samen_totp_pending_remember"
  @pending_return_key "samen_totp_pending_return_to"

  @default_return "/"

  @doc "The session key carrying the interstitial remember-me choice."
  def pending_remember_key, do: @pending_remember_key

  @doc "The session key carrying the interstitial sanitized `return_to`."
  def pending_return_key, do: @pending_return_key

  @doc "The `:totp_pending` interstitial TTL in seconds (ADR-035 §4.2)."
  def totp_pending_ttl_seconds, do: @totp_pending_ttl_seconds

  @doc """
  Whether `credential_id` requires a TOTP second factor — i.e. its
  `totp_enabled_at` is set. Read-only, `authorize?: false` (the same
  server-side, non-oracle read the interstitial peek uses); a missing/unknown
  credential is `false` (fail-closed on the caller's side: an unknown credential
  never step-ups, but it also never mints a session — the callers guard that).
  """
  @spec enrolled?(module(), String.t(), module()) :: boolean()
  def enrolled?(credential_mod, credential_id, _repo) when is_binary(credential_id) do
    credential_mod
    |> Ash.Query.filter(id == ^credential_id and not is_nil(totp_enabled_at))
    |> Ash.Query.select([:id])
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
    |> case do
      [_ | _] -> true
      [] -> false
    end
  end

  @doc """
  Arm the `/2fa` step-up for `credential_id`: mint the `:totp_pending`
  `AuthToken` (5 min), renew the session id (fixation defense at the FIRST
  privileged step), stash the remember-me/`return_to` choices, and hand back the
  conn — the CALLER redirects to its own `/2fa` path. NO `Identity.Session` row
  is created here (that happens only after `verify_totp/2` succeeds). Returns
  `{:ok, conn}` or `{:error, reason}` (a mint failure — the caller fails closed
  to its login page, never a partial session).

  `opts`: `:remember?` (boolean, default `false`), `:return_to` (a path string
  or nil — sanitized to a same-origin path here so `verify_totp/2` reads back a
  safe value).
  """
  @spec challenge(Plug.Conn.t(), Mount.t(), String.t(), keyword()) ::
          {:ok, Plug.Conn.t()} | {:error, term()}
  def challenge(conn, %Mount{} = mount, credential_id, opts \\ []) when is_binary(credential_id) do
    remember? = Keyword.get(opts, :remember?, false)
    return_to = Keyword.get(opts, :return_to)
    auth_token_mod = Mount.resource(mount, AuthToken)

    case TokenMint.mint(auth_token_mod, credential_id, :totp_pending, nil, @totp_pending_ttl_seconds) do
      {:ok, _auth_token, raw_token} ->
        conn =
          conn
          |> configure_session(renew: true)
          |> Auth.put_totp_pending_token(raw_token)
          |> put_session(@pending_remember_key, remember?)
          |> put_session(@pending_return_key, safe_return(return_to))

        {:ok, conn}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Only a same-origin absolute path (single leading "/") is honored — the SAME
  # rule `SessionController.safe_return/1` enforces (no open redirect via a
  # crafted `return_to`).
  defp safe_return("/" <> rest = path) when rest != "" do
    if String.starts_with?(path, "//"), do: @default_return, else: path
  end

  defp safe_return(_), do: @default_return
end
