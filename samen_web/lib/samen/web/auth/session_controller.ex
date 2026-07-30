defmodule Samen.Web.Auth.SessionController do
  @moduledoc """
  ADR-035 §5 A4 — the framework's session-WRITE endpoints. A LiveView cannot
  set a cookie mid-mount (the SAME rule `Samen.Web.SessionController`'s
  moduledoc documents for the current-org write), so every state-changing act
  in the session lifecycle — sign-in, sign-out, and Settings/Security's
  individual/revoke-others controls — goes through a plain Phoenix controller
  so the cookie writes happen on a real HTTP response.

  Mounted by `Samen.Web.Router.samen_auth_routes/1`; each route's `private:`
  carries the host's `%Samen.Web.Mount{}` (built once at router-compile time,
  the same struct `samen_module_routes` bakes into a `live_session`) so this
  controller never hardcodes a host module.

    * `POST /login`   → `create/2` — `Samen.Identity.SignIn.authenticate/3`.
      A credential WITHOUT 2FA mints the `Identity.Session` row immediately
      (the pre-A7 path, unchanged). A credential WITH 2FA enabled
      (ADR-035 §5 A7) instead mints a `:totp_pending` `AuthToken` (5 min),
      carries it + the `remember_me`/`return_to` choices in the signed Plug
      session, and redirects to `/2fa` — **no `Identity.Session` row exists
      yet** ("no half-authenticated session rows exist").
    * `POST /2fa`     → `verify_totp/2` — consumes the `:totp_pending`
      interstitial: verifies a 6-digit TOTP code OR a recovery code, THEN
      (only on success) consumes the pending token and mints the real
      `Identity.Session` row via the SAME `finish_login/4` the password-only
      path uses.
    * `GET /logout`   → `delete/2` — revokes the CURRENT session row + clears
      both cookies (`Samen.Web.Auth.log_out/1`).
    * `POST .../sessions/:id/revoke`         → `revoke/2` — one session,
      scoped to the caller's OWN credential (defense in depth).
    * `POST .../sessions/revoke_others`      → `revoke_others/2` — every
      OTHER live session (keeps the caller's own current session alive).

  `return_to` is sanitized the same way `Samen.Web.SessionController` already
  does (same-origin absolute path only — no open redirect).

  ## A10 fan-out — `auth.recovery_code_used` (T09, ADR-035 §5 A10)

  A successful `/2fa` verify via a RECOVERY code (never a TOTP code — the
  distinction `verify_second_factor/2`'s `method` return already makes for
  the c3 "revoke other sessions" rule) audits `auth.recovery_code_used`
  (`Samen.Scopes.Identity.Audit`) and dispatches a security-notice
  notification (`Samen.Scopes.Identity.Notify`) BEFORE `finish_login/4` mints
  the real session — closing the fourth kind T07 explicitly deferred
  (`_orch/tasks/T07/status.json`: "auth.totp_enrolled/disabled/
  recovery_code_used/recovery_codes_regenerated ... are not wired").

  ## A10 fan-out — the login-family kinds (T101, ADR-035 §5 A10)

  T09's six named categories left the login-family rows OWNERLESS
  (`_orch/verify/T09-verdict.json` scope_table row 8). This task wires the
  remaining five, reusing the SAME `Audit.auth_event` / `Notify.notify_credential`
  seam T09 established (never a parallel mechanism), landing in the `aud_event`
  append-only tier (never the `AuditChain` hash-chain — that tier stays
  untouched). Every row sets `subject_id` (the T09 `sso_linked` lesson — an
  audit row with no `subject_id` is unfindable via `Samen.AuditEvent.for_subject/2`).

  **Notify policy, read directly off the ADR-035 §5 A10 table (not
  reinterpreted):**

    * `auth.login` — audit always; **no notify** (the ADR row's Notification
      column is `—`). Audited once, in `finish_login/4`, the ONE place a real
      session is minted — covers the password-only path AND the post-2FA path
      identically.
    * `auth.login_failed` — audit always; **no notify** (ADR: `—`). Also a
      deliberate product choice independent of the ADR: notifying on every
      failed attempt would be both noise (one bad keystroke = an alert) and an
      account-enumeration amplifier (an attacker probing emails could use
      "did a notification fire" as an oracle). Audited on a wrong password
      (`create/2`) and on a wrong second factor once a pending login is
      already resolved to a real credential (`verify_totp/2`) — token-blind:
      the default `Audit.auth_event/2` detail is the fixed string
      `"identity.auth.login_failed"`, never the attempted email; `subject_id`
      is set ONLY when the email's blind index resolves to a real credential
      (a read, never a vault write — an unknown email adds no row anywhere
      beyond the audit line itself, so INV-1's no-account-oracle discipline
      holds at audit time too).
    * `auth.logout` — audit always; **no notify**. The ADR marks the
      logout/session_revoked/sessions_revoked_all trio `✓ on
      revoke-by-another-session` — logout is the credential's OWN current
      session ending itself, never "another session" acting on it, so it
      falls outside that notify condition.
    * `auth.session_revoked` (Settings/Security's per-row revoke, `revoke/2`)
      and `auth.sessions_revoked_all` (Settings/Security's "revoke all other
      sessions", `revoke_others/2`) — audit always; **notify** (the ADR's
      `revoke-by-another-session` condition IS exactly these two controls: the
      caller's CURRENT session revoking a DIFFERENT session/all other
      sessions). Security-notice class, fixed copy, `Notify.notify_credential/6`
      to the credential owner — the same "a security-relevant thing happened
      to your account" pattern `auth.recovery_code_used` above already uses.
  """
  use Phoenix.Controller, formats: [:html]

  import Plug.Conn

  require Ash.Query

  alias Samen.Auth.DeviceLabel
  alias Samen.Auth.SessionCreate
  alias Samen.Auth.SessionRevoke
  alias Samen.Auth.TokenConsume
  alias Samen.Auth.TokenMint
  alias Samen.Identity.SignIn
  alias Samen.Scopes.Identity.Audit
  alias Samen.Scopes.Identity.Notify
  alias Samen.Web.Auth
  alias Samen.Web.Auth.Totp
  alias Samen.Web.Auth.TotpStepUp
  alias Samen.Web.Mount
  alias Samen.Web.RateLimit

  @default_return "/"

  # Interstitial-only session keys (never authenticate anyone on their own — see
  # `Samen.Web.Auth.totp_pending_key/0`'s moduledoc note). Owned by
  # `Samen.Web.Auth.TotpStepUp` (T100) so the password AND OIDC step-up
  # entrypoints share ONE definition; read back here in `verify_totp/2`.
  @pending_remember_key TotpStepUp.pending_remember_key()
  @pending_return_key TotpStepUp.pending_return_key()

  @doc """
  `POST /login`. Params: `login[email]`, `login[password]`,
  `login[remember_me]` ("true"/"on"/"1"), optional `return_to`. On success
  with 2FA DISABLED: renews the session id (fixation defense), writes the
  session token, writes the remember-me cookie iff requested, redirects to a
  sanitized `return_to`. On success with 2FA ENABLED (ADR-035 §5 A7): mints a
  `:totp_pending` token, stashes the choices, redirects to `/2fa` — no
  `Identity.Session` row yet. On failure (bad credentials, or the
  credential's timing-parity dummy-verify branch): redirects back to the
  login page with `?error=1` — the SAME generic outcome for "no such
  account" and "wrong password" (no oracle, mirroring `Samen.Identity.SignIn`'s
  own discipline).
  """
  def create(conn, %{"login" => login_params} = params) do
    mount = conn.private.samen_mount
    email = trim(login_params["email"])
    password = login_params["password"] || ""
    remember? = login_params["remember_me"] in ["true", "on", "1"]

    # ADR-035 §4.5 / ADR-038 §6.3 — the brute-force / enumeration control (T103).
    # Two INDEPENDENT keys: per-IP (100/hr) AND per-account bidx (10/min). The check
    # runs BEFORE authenticate and is CONSTANT-SHAPE for a known vs unknown account
    # (an `email_bidx` HMAC + two counter bumps, identical either way), so it adds no
    # enumeration timing signal on top of `SignIn.authenticate/3`'s own dummy-verify
    # parity (ADR-035 §4.4). Over-limit → a generic 429, the same for any caller.
    case rate_limit_signin(conn, mount, email) do
      :ok ->
        case SignIn.authenticate(email, password, sign_in_mods(mount)) do
          {:ok, %{totp_enabled_at: enabled_at} = credential} when not is_nil(enabled_at) ->
            start_totp_challenge(conn, mount, credential, remember?, params["return_to"])

          {:ok, credential} ->
            finish_login(conn, mount, credential.id, remember?, params["return_to"])

          _ ->
            audit_login_failed(mount, email)
            redirect(conn, to: "#{login_path(conn)}?error=1")
        end

      {:error, :rate_limited} ->
        rate_limited(conn)
    end
  end

  @doc """
  `POST /2fa`. Params: `code` (or `totp[code]`) — a 6-digit TOTP code, or a
  recovery code (dispatched by shape, `Samen.Web.Auth.Totp.totp_shaped?/1`).

  Order matters (mirrors `Samen.Identity.Reset.consume/3`'s "a doomed request
  never burns the single-use token" discipline): the second factor is
  verified FIRST; the `:totp_pending` token is consumed ONLY after a correct
  code, so a wrong guess never burns the interstitial (the caller can retry
  within its 5-minute window, bounded separately by the §4.5 TOTP-verify rate
  limit). A recovery-code success additionally revokes every OTHER live
  session for the credential (ADR-035 §5 A7 / c3 — "recovery-use revokes
  other sessions"; there is no "current" session yet to except, unlike A3's
  reset). On any failure: redirects to `/2fa?error=1`, mints NO session.
  """
  def verify_totp(conn, params) do
    mount = conn.private.samen_mount
    conn = fetch_session(conn)
    code = extract_code(params)

    with raw when is_binary(raw) <- get_session(conn, Auth.totp_pending_key()),
         digest <- TokenMint.digest(raw),
         {:ok, credential_id} <- peek_pending(mount, digest) do
      complete_second_factor(conn, mount, credential_id, digest, code)
    else
      _ -> redirect(conn, to: "#{totp_path(conn)}?error=1")
    end
  end

  # Split out of `verify_totp/2` so a resolved `credential_id` stays in scope
  # on the failure path too (T101, ADR-035 §5 A10) — a WRONG code against an
  # already-identified pending login is `auth.login_failed`, subject_id set;
  # an unresolved/expired/missing pending token (handled by the caller's
  # `with`/`else` above, before this function is ever reached) never had a
  # credential to key on, so it is not audited as a login attempt at all —
  # nothing was attempted against a real account there, only a stale
  # interstitial.
  defp complete_second_factor(conn, mount, credential_id, digest, code) do
    # ADR-035 §4.5 / ADR-038 §6.3 — TOTP-verify brute-force control (T103): 5/min per
    # credential id (a UUID, non-PII). Keyed on the ALREADY-resolved pending credential,
    # so a stale/absent interstitial (handled by `verify_totp/2` before this is reached)
    # is never charged against a real account's budget. Over-limit → generic 429.
    case RateLimit.check(:totp_verify_credential, :credential, to_string(credential_id)) do
      {:error, :rate_limited} ->
        rate_limited(conn)

      :ok ->
        complete_second_factor_verified(conn, mount, credential_id, digest, code)
    end
  end

  defp complete_second_factor_verified(conn, mount, credential_id, digest, code) do
    with {:ok, method} <- verify_second_factor(mount, credential_id, code),
         {:ok, _consumed} <- TokenConsume.consume_once(Mount.resource(mount, AuthToken), digest, :totp_pending) do
      if method == :recovery do
        SessionRevoke.revoke_all(Mount.resource(mount, Session), credential_id)

        # ADR-035 §5 A10 (T09) — audit + notify, co-located exactly as
        # `Samen.Web.Auth.TotpEnrollLive.fan_out/4` does for the sibling
        # totp_* kinds. Unconditional audit (token-only); best-effort notify.
        Audit.auth_event(mount.repo, event: "auth.recovery_code_used", subject_id: credential_id, actor_id: credential_id)

        Notify.notify_credential(
          Mount.resource(mount, User),
          credential_id,
          "recovery_code_used",
          "A recovery code was used to sign in to your account. If this wasn't you, secure your account immediately."
        )
      end

      remember? = get_session(conn, @pending_remember_key) == true
      return_to = get_session(conn, @pending_return_key)

      finish_login(conn, mount, credential_id, remember?, return_to)
    else
      _ ->
        # ADR-035 §5 taxonomy / ADR-038 §6.4 (T103) — BOUNDED audit: bump the bidx/
        # credential-keyed failure counter every attempt, but append the `aud_event`
        # row only on the window EDGE (first failure), so a wrong-code brute force
        # against one credential does NOT grow the audit partition per attempt. The
        # detail stays the fixed token-blind string (T101), subject_id set.
        if login_failed_edge?(:credential, to_string(credential_id)) do
          Audit.auth_event(mount.repo, event: "auth.login_failed", subject_id: credential_id, actor_id: credential_id)
        end

        # ADR-038 §6.4 (T109) — durable bump for the credential-keyed axis, same
        # cadence as the ETS counter above, independent of the O(windows)-bounded
        # audit-edge decision (see `Samen.Identity.LoginFailure`'s moduledoc).
        Samen.Identity.LoginFailure.bump!(
          Mount.resource(mount, LoginFailure),
          :credential,
          to_string(credential_id),
          login_failed_window_seconds()
        )

        redirect(conn, to: "#{totp_path(conn)}?error=1")
    end
  end

  @doc """
  `GET /logout`. Revokes the CURRENT `Identity.Session` row (if any resolved
  — a stale/already-revoked session logs out cleanly regardless) and clears
  both the session key and the remember-me cookie (`Samen.Web.Auth.log_out/1`).
  """
  def delete(conn, params) do
    mount = conn.private.samen_mount
    session_mod = Mount.resource(mount, Session)

    conn = fetch_session(conn)

    case Auth.resolve_principal(get_session(conn), %{session: session_mod}) do
      {:ok, %{credential_id: credential_id, session_id: session_id}} ->
        _ = SessionRevoke.revoke_one(session_mod, session_id, credential_id)

        # ADR-035 §5 A10 (T101) — self-initiated logout: audit always, no
        # notify (this is the credential's OWN current session ending
        # itself, not "revoke-by-another-session" — see moduledoc).
        Audit.auth_event(mount.repo, event: "auth.logout", subject_id: credential_id, actor_id: credential_id)

      _ ->
        :ok
    end

    conn
    |> Auth.log_out()
    |> configure_session(renew: true)
    |> redirect(to: safe_return(params["return_to"]))
  end

  @doc """
  `POST /settings/security/sessions/:id/revoke` — revoke exactly ONE session,
  scoped to the CALLER's own credential (`Samen.Auth.SessionRevoke.revoke_one/3`
  refuses a foreign session id). Unauthenticated → redirected to login rather
  than revoking anything.
  """
  def revoke(conn, %{"id" => session_id} = params) do
    mount = conn.private.samen_mount
    session_mod = Mount.resource(mount, Session)
    conn = fetch_session(conn)

    case Auth.resolve_principal(get_session(conn), %{session: session_mod}) do
      {:ok, %{credential_id: credential_id}} ->
        case SessionRevoke.revoke_one(session_mod, session_id, credential_id) do
          {:ok, :revoked} ->
            # ADR-035 §5 A10 (T101) — this control is, by construction, the
            # caller's CURRENT session revoking a (typically different)
            # session in the list: the ADR's "revoke-by-another-session"
            # notify condition. Audit always; notify the credential owner.
            Audit.auth_event(mount.repo, event: "auth.session_revoked", subject_id: credential_id, actor_id: credential_id)

            Notify.notify_credential(
              Mount.resource(mount, User),
              credential_id,
              "session_revoked",
              "A session was signed out on your account. If this wasn't you, secure your account immediately."
            )

          {:error, :not_found} ->
            :ok
        end

        redirect(conn, to: safe_return(params["return_to"]))

      _ ->
        redirect(conn, to: login_path(conn))
    end
  end

  @doc """
  `POST /settings/security/sessions/revoke_others` — revoke every OTHER live
  session for the caller's credential; the session making THIS request stays
  live (the c3 "revoke all other sessions" control — distinct from A3's
  reset-time revoke-ALL-including-current).
  """
  def revoke_others(conn, params) do
    mount = conn.private.samen_mount
    session_mod = Mount.resource(mount, Session)
    conn = fetch_session(conn)

    case Auth.resolve_principal(get_session(conn), %{session: session_mod}) do
      {:ok, %{credential_id: credential_id, session_id: session_id}} ->
        :ok = SessionRevoke.revoke_others(session_mod, credential_id, session_id)

        # ADR-035 §5 A10 (T101) — the caller's CURRENT session revoking every
        # OTHER session: also "revoke-by-another-session". Audit always;
        # notify the credential owner (the classic mass-signout security
        # notice).
        Audit.auth_event(mount.repo, event: "auth.sessions_revoked_all", subject_id: credential_id, actor_id: credential_id)

        Notify.notify_credential(
          Mount.resource(mount, User),
          credential_id,
          "sessions_revoked_all",
          "All other sessions were signed out on your account. If this wasn't you, secure your account immediately."
        )

        redirect(conn, to: safe_return(params["return_to"]))

      _ ->
        redirect(conn, to: login_path(conn))
    end
  end

  # -- private: ADR-035 §5 A7 2FA-interstitial helpers -----------------------

  # Password verified, 2FA enabled: arm the SHARED `:totp_pending` → `/2fa`
  # step-up (`Samen.Web.Auth.TotpStepUp.challenge/4` — the SAME mechanism the
  # OIDC callback uses, T100), then redirect to `/2fa`. The step-up renews the
  # session id (fixation defense at the FIRST privileged step, not just the
  # last) — `finish_login/4` renews again at the real sign-in.
  defp start_totp_challenge(conn, mount, credential, remember?, return_to) do
    case TotpStepUp.challenge(conn, mount, credential.id, remember?: remember?, return_to: return_to) do
      {:ok, conn} -> redirect(conn, to: totp_path(conn))
      {:error, _reason} -> redirect(conn, to: "#{login_path(conn)}?error=1")
    end
  end

  # The ONE place a real `Identity.Session` row is minted — called by BOTH the
  # no-2FA password path and the post-2FA-verify path, so the cookie-writing
  # + fixation-defense discipline is identical either way.
  defp finish_login(conn, mount, credential_id, remember?, return_to) do
    case SessionCreate.create(session_create_mods(mount), credential_id, device_label: device_label(conn)) do
      {:ok, _session, raw_token} ->
        # ADR-035 §5 A10 (T101) — every real login, password-only OR
        # post-2FA, mints its session HERE; auditing once at this single
        # chokepoint covers both without duplicating the call at each
        # caller. Audit always; NO notify (the ADR row's Notification column
        # is `—` for `auth.login`).
        Audit.auth_event(mount.repo, event: "auth.login", subject_id: credential_id, actor_id: credential_id)

        # ADR-038 §6.4 (T109) — "successful login -> reset": clear the durable
        # brute-force signal for BOTH key axes now that a real session minted.
        reset_login_failures(mount, credential_id)

        conn
        |> configure_session(renew: true)
        |> Auth.put_session_token(raw_token)
        |> maybe_remember(remember?, raw_token)
        |> Auth.clear_totp_pending_token()
        |> delete_session(@pending_remember_key)
        |> delete_session(@pending_return_key)
        |> redirect(to: safe_return(return_to))

      {:error, _reason} ->
        redirect(conn, to: "#{login_path(conn)}?error=1")
    end
  end

  # ADR-035 §5 A10 (T101) — `auth.login_failed` on the `create/2` password
  # path. `SignIn.authenticate/3` deliberately returns the SAME generic
  # `{:error, :invalid_credentials}` for "no such account" and "wrong
  # password" (no oracle) and never a credential id, so this does its OWN
  # read-only blind-index lookup purely for audit `subject_id` — NEVER for
  # the authentication decision itself, which already happened. It runs
  # unconditionally on the failure path (same cost whether the email is
  # known or not, so it adds no NEW timing signal beyond what
  # `SignIn.authenticate/3`'s own timing-parity dummy-verify already pays
  # symmetrically). A known email sets `subject_id` (findable via
  # `Samen.AuditEvent.for_subject/2` — the T09 `sso_linked` lesson); an
  # unknown email leaves it `nil` — a READ, never a vault write, so INV-1's
  # "failed attempts against unknown identifiers must not vault-write
  # anything new" holds. The audit `detail` is left at `Audit.auth_event/2`'s
  # own default (`"identity.auth.login_failed"`, a fixed string) — never the
  # attempted email — token-blind by construction either way.
  #
  # ADR-035 §5 taxonomy / ADR-038 §6.4 (T103) — BOUNDED replacement for the former
  # per-attempt row: every failed attempt bumps a bidx-keyed FAILURE counter (non-PII —
  # the `email_bidx` HMAC, never the plaintext email), but an `aud_event` row is appended
  # only on the window EDGE (the first failure of the window). So N ≫ limit brute-force
  # attempts against one account produce O(windows) audit rows, not O(N) — the audit
  # partition no longer grows unboundedly under brute force. The edge row keeps the
  # token-blind default detail (T101's per-kind findability holds: subject_id is still set
  # when the email resolves, so the row is findable via `Samen.AuditEvent.for_subject/2`).
  defp audit_login_failed(mount, email) do
    bidx = login_failed_bidx(email)
    edge? = login_failed_edge?(:email_bidx, bidx)

    # ADR-038 §6.4 (T109) — durable bump: every failed attempt (the SAME cadence
    # as the ETS counter above), independent of the O(windows)-bounded audit-edge
    # decision — the durable count tracks every attempt exactly like T103's ETS
    # counter does, so it survives a restart (see `Samen.Identity.LoginFailure`'s
    # moduledoc). `bidx` is the non-reversible HMAC even for an unresolvable
    # email (never the plaintext), so this adds no new PII surface.
    Samen.Identity.LoginFailure.bump!(
      Mount.resource(mount, LoginFailure),
      :email_bidx,
      bidx,
      login_failed_window_seconds()
    )

    case lookup_credential_id_for_audit(mount, email) do
      {:ok, credential_id} ->
        if edge?,
          do: Audit.auth_event(mount.repo, event: "auth.login_failed", subject_id: credential_id, actor_id: credential_id)

      :error ->
        if edge?, do: Audit.auth_event(mount.repo, event: "auth.login_failed")
    end
  end

  # ADR-038 §6.4 (T109) — "successful login -> reset": clears BOTH durable key
  # axes for this credential (the password-path `email_bidx` key AND the
  # 2FA-path `credential` key) the instant a real session mints. Independent of
  # T103's ETS behavior (which merely lets a window lapse) — a genuine login
  # always fully clears the durable brute-force signal.
  defp reset_login_failures(mount, credential_id) do
    login_failure_mod = Mount.resource(mount, LoginFailure)
    Samen.Identity.LoginFailure.reset!(login_failure_mod, :credential, to_string(credential_id))

    case lookup_email_bidx(mount, credential_id) do
      {:ok, bidx} -> Samen.Identity.LoginFailure.reset!(login_failure_mod, :email_bidx, bidx)
      :error -> :ok
    end
  end

  defp lookup_email_bidx(mount, credential_id) do
    Mount.resource(mount, Credential)
    |> Ash.Query.filter(id == ^credential_id)
    |> Ash.Query.select([:email_bidx])
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
    |> case do
      [%{email_bidx: bidx}] -> {:ok, bidx}
      _ -> :error
    end
  end

  # The bounded audit-edge counter's own window (900s / 15min, `login_failed_audit`
  # in `Samen.Web.RateLimit`'s `@default_limits`) doubles as the durable resource's
  # window — ONE source of truth, never a duplicated literal.
  defp login_failed_window_seconds do
    {_limit, window_ms} = RateLimit.limit_for(:login_failed_audit)
    div(window_ms, 1000)
  end

  # The `email_bidx` (ADR-035 §4.1) is the non-PII failure-counter key; an email that
  # cannot produce a bidx falls back to a fixed non-PII sentinel (still bounded).
  defp login_failed_bidx(email) do
    case Samen.Auth.BlindIndex.compute(email) do
      {:ok, bidx} -> bidx
      _ -> "unknown"
    end
  end

  # A window EDGE = the FIRST failure of the window for this key: the failure counter's
  # new value is 1. Bumps every attempt (so the bidx-keyed counter tracks the burst);
  # returns true only on the edge, gating the bounded `aud_event` append.
  defp login_failed_edge?(kind, value), do: RateLimit.bump(:login_failed_audit, kind, value) == 1

  defp lookup_credential_id_for_audit(mount, email) do
    with {:ok, bidx} <- Samen.Auth.BlindIndex.compute(email) do
      Mount.resource(mount, Credential)
      |> Ash.Query.filter(email_bidx == ^bidx)
      |> Ash.Query.select([:id])
      |> Ash.Query.limit(1)
      |> Ash.read!(authorize?: false)
      |> case do
        [%{id: id}] -> {:ok, id}
        _ -> :error
      end
    else
      _ -> :error
    end
  end

  # Read-only lookup of the credential a PENDING (unconsumed, unexpired)
  # `:totp_pending` token names — deliberately NOT `TokenConsume.consume_once/3`
  # here: consuming happens only AFTER the code verifies (see `verify_totp/2`'s
  # moduledoc — a wrong guess must not burn the token).
  defp peek_pending(mount, digest) do
    now = DateTime.utc_now()

    Mount.resource(mount, AuthToken)
    |> Ash.Query.filter(
      token_digest == ^digest and context == :totp_pending and is_nil(consumed_at) and expires_at > ^now
    )
    |> Ash.Query.select([:id, :credential_id])
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
    |> case do
      [%{credential_id: credential_id}] -> {:ok, credential_id}
      _ -> :error
    end
  end

  # Dispatch by shape (Totp.totp_shaped?/1): a 6-digit input tries the TOTP
  # path, anything else tries a recovery code. Returns `{:ok, :totp |
  # :recovery}` on success (the method the caller needs to know, ONLY to
  # decide the recovery-triggered "revoke other sessions" c3 rule) or
  # `:error` — the SAME generic outcome for a wrong TOTP code, an
  # already-used/unknown recovery code, or an unenrolled credential (no
  # oracle on why the second factor failed).
  defp verify_second_factor(mount, credential_id, code) do
    mods = totp_mods(mount)

    result =
      if Totp.totp_shaped?(code) do
        with {:ok, _} <- Totp.verify_login_code(mods, credential_id, code), do: {:ok, :totp}
      else
        with {:ok, _} <- Totp.verify_recovery_code(mods, credential_id, code), do: {:ok, :recovery}
      end

    case result do
      {:ok, method} -> {:ok, method}
      _ -> :error
    end
  end

  defp totp_mods(%Mount{} = mount), do: %{credential: Mount.resource(mount, Credential), repo: mount.repo}

  defp extract_code(%{"code" => code}) when is_binary(code), do: code
  defp extract_code(%{"totp" => %{"code" => code}}) when is_binary(code), do: code
  defp extract_code(_), do: ""

  defp totp_path(conn), do: conn.private[:samen_totp_path] || "/2fa"

  # -- private -------------------------------------------------------------

  defp sign_in_mods(%Mount{} = mount), do: %{credential: Mount.resource(mount, Credential)}

  defp session_create_mods(%Mount{} = mount) do
    %{
      session: Mount.resource(mount, Session),
      org: Mount.resource(mount, Org),
      membership: Mount.resource(mount, Membership),
      user: Mount.resource(mount, User)
    }
  end

  defp device_label(conn) do
    conn
    |> get_req_header("user-agent")
    |> List.first()
    |> DeviceLabel.from_user_agent()
  end

  defp maybe_remember(conn, true, raw_token), do: Auth.write_remember_cookie(conn, raw_token)
  defp maybe_remember(conn, _false, _raw_token), do: conn

  defp login_path(conn), do: conn.private[:samen_login_path] || "/login"

  # ADR-035 §4.5 / ADR-038 §6.3 — sign-in rate limit: per-IP (100/hr) THEN per-account
  # bidx (10/min), both independent. Per-IP first so an account-rotating attacker from
  # one IP is caught by the IP budget; a resolvable email is additionally caught per
  # account when an IP-rotating attacker hammers ONE account. Both counters increment on
  # every attempt regardless of whether the account exists (no existence oracle).
  defp rate_limit_signin(conn, mount, email) do
    with :ok <- RateLimit.check(:signin_ip, :ip, remote_ip(conn)) do
      signin_account_check(mount, email)
    end
  end

  # Constant-shape by construction: `email_bidx` is computed for ANY well-formed email
  # (known or not), so the per-account bucket is bumped identically. A malformed email
  # that cannot produce a bidx skips the account axis (still covered by the per-IP axis)
  # — that is an email-VALIDITY branch, never an account-EXISTENCE branch.
  defp signin_account_check(mount, email) do
    case Samen.Auth.BlindIndex.compute(email) do
      {:ok, bidx} ->
        with :ok <- RateLimit.check(:signin_account, :email_bidx, bidx) do
          durable_signin_check(mount, bidx)
        end

      _ ->
        :ok
    end
  end

  # ADR-038 §6.4 (T109) — the restart-survival re-check, ADDITIONAL to (never in
  # place of) the ETS check above. `Samen.Web.RateLimit`'s ETS table is wiped by a
  # node restart, which alone would silently hand a still-locked-out attacker a
  # fresh budget; this durable re-check refuses the SAME `email_bidx` key while
  # its durable window is still live and already at/over the SAME `:signin_account`
  # limit, so the lockout survives a restart. This can only make the gate STRICTER
  # than the ETS check alone (it runs strictly after an `:ok` from RateLimit.check),
  # never weaker — T103's rate-limiting policy is never loosened.
  defp durable_signin_check(mount, bidx) do
    {limit, _window_ms} = RateLimit.limit_for(:signin_account)
    window_seconds = login_failed_window_seconds()

    if Samen.Identity.LoginFailure.over_limit?(
         Mount.resource(mount, LoginFailure),
         :email_bidx,
         bidx,
         limit,
         window_seconds
       ) do
      {:error, :rate_limited}
    else
      :ok
    end
  end

  defp remote_ip(%Plug.Conn{remote_ip: ip}) when is_tuple(ip), do: ip |> :inet.ntoa() |> to_string()
  defp remote_ip(_), do: "unknown"

  # The over-limit response (ADR-035 §4.5 "429 or interstitial"): a bare 429, identical
  # for every caller — carries no account/enumeration signal.
  defp rate_limited(conn) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(429, "rate_limited")
    |> halt()
  end

  defp trim(v) when is_binary(v), do: String.trim(v)
  defp trim(_), do: ""

  # Only a same-origin absolute path (starts with a single "/") is honored — the
  # SAME rule `Samen.Web.SessionController.put_current_org/2` enforces (no
  # open-redirect via a crafted `return_to`).
  defp safe_return("/" <> rest = path) when rest != "" do
    if String.starts_with?(path, "//"), do: @default_return, else: path
  end

  defp safe_return(_), do: @default_return
end
