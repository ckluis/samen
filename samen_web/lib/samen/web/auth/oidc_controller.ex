defmodule Samen.Web.Auth.OidcController do
  @moduledoc """
  A6 — the OIDC request + callback endpoints (ADR-035 §5 A6). Mounted ONLY when a
  host passes `oidc:` to `Samen.Web.Router.samen_auth_routes/1`; an app that does
  not enable OIDC has none of these routes (the module-absent contract).

  A plain Phoenix controller (not a LiveView) because the whole flow is
  cookie/session writes on real HTTP responses — the stashed `state`/`nonce` on
  the request leg, the minted `Identity.Session` token on the callback leg (the
  SAME reason `Samen.Web.Auth.SessionController` is a controller).

    * `GET /auth/oidc/:provider`          → `request/2` — redirect to the IdP,
      stashing `state`/`nonce` in the signed session. Unconfigured provider →
      fail-honest (redirect to login with `?error=oidc_not_configured`, never a
      fabricated redirect).
    * `GET /auth/oidc/:provider/callback` → `callback/2` — validate `state`,
      exchange the code (via `Samen.Web.Auth.Oidc`), then
      `Samen.Identity.OidcLink.link_or_provision/3` resolves/links/provisions the
      Credential and `Samen.Auth.SessionCreate` mints the session.

  `private:` carries the host `%Samen.Web.Mount{}` (built once at router-compile
  time) + the OIDC provider config, so this controller never hardcodes a host
  module (the `SessionController` precedent).
  """
  use Phoenix.Controller, formats: [:html]

  import Plug.Conn

  alias Samen.Auth.DeviceLabel
  alias Samen.Auth.SessionCreate
  alias Samen.Identity.OidcLink
  alias Samen.Scopes.Identity.Audit
  alias Samen.Scopes.Identity.Notify
  alias Samen.Web.Auth
  alias Samen.Web.Auth.Oidc
  alias Samen.Web.Auth.TotpStepUp
  alias Samen.Web.Mount

  @session_params_key "samen_oidc_session_params"
  @default_return "/"

  @doc "`GET /auth/oidc/:provider` — redirect to the IdP (fail-honest if unconfigured)."
  def request(conn, %{"provider" => provider}) do
    config = oidc_config(conn)

    case Oidc.authorize_url(provider, config) do
      {:ok, url, session_params} ->
        conn
        |> put_session(@session_params_key, stringify(session_params))
        |> redirect(external: url)

      {:error, _reason} ->
        redirect(conn, to: "#{login_path(conn)}?error=oidc_not_configured")
    end
  end

  @doc """
  `GET /auth/oidc/:provider/callback` — validate `state`, link/provision the
  credential, then EITHER mint the session (no 2FA) OR detour through `/2fa`.

  ADR-035 §5 A6+A7 (T100): 2FA is an ACCOUNT property, not a password-flow
  property. If the resolved credential has `totp_enabled_at` set, the federated
  leg mints **no** `Identity.Session` — it arms the SAME `:totp_pending`
  interstitial the password path uses (`Samen.Web.Auth.TotpStepUp.challenge/4`)
  and redirects to `/2fa`, where `SessionController.verify_totp/2` verifies the
  second factor and performs the sole session mint via `finish_login`. An
  attacker who compromised the linked IdP account but lacks the TOTP code gets a
  pending token that authenticates nobody (it resolves against `AuthToken`, not
  `Session`), never a usable/elevatable session.
  """
  def callback(conn, %{"provider" => provider} = params) do
    config = oidc_config(conn)
    session_params = get_session(conn, @session_params_key) || %{}

    with {:ok, claims} <- Oidc.handle_callback(provider, params, session_params, config),
         {:ok, result} <-
           OidcLink.link_or_provision(claims, oidc_link_mods(conn), signup: signup?(conn, provider)) do
      audit_link(conn, result)

      conn
      |> delete_session(@session_params_key)
      |> finish_or_step_up(result.credential_id)
    else
      {:error, reason} ->
        redirect(conn, to: "#{login_path(conn)}?error=#{error_code(reason)}")
    end
  end

  # -- private -----------------------------------------------------------------

  # ADR-035 §5 A6+A7 (T100) — the account-property fork. A credential with
  # `totp_enabled_at` set NEVER mints a Session on the federated leg: it detours
  # through the shared `:totp_pending` → `/2fa` step-up. A non-TOTP credential
  # mints immediately (the pre-T100 path, unchanged control).
  defp finish_or_step_up(conn, credential_id) do
    mount = conn.private.samen_mount

    if TotpStepUp.enrolled?(Mount.resource(mount, Credential), credential_id, mount.repo) do
      case TotpStepUp.challenge(conn, mount, credential_id, return_to: @default_return) do
        {:ok, conn} -> redirect(conn, to: totp_path(conn))
        {:error, _reason} -> redirect(conn, to: "#{login_path(conn)}?error=oidc_failed")
      end
    else
      finish_login(conn, credential_id)
    end
  end

  # The no-2FA path: mint the real `Identity.Session` and write the session
  # token on the HTTP response (unchanged from the pre-T100 direct mint).
  defp finish_login(conn, credential_id) do
    case SessionCreate.create(session_create_mods(conn), credential_id, device_label: device_label(conn)) do
      {:ok, _session, raw_token} ->
        conn
        |> configure_session(renew: true)
        |> Auth.put_session_token(raw_token)
        |> redirect(to: @default_return)

      {:error, reason} ->
        redirect(conn, to: "#{login_path(conn)}?error=#{error_code(reason)}")
    end
  end

  defp audit_link(conn, %{status: status, credential_id: credential_id})
       when status in [:linked, :provisioned] do
    mount = conn.private.samen_mount

    # T09 addendum: the T06-era call omitted subject_id/actor_id (a nil-subject
    # aud_event row is unfindable via Samen.AuditEvent.for_subject/2, the
    # standard lookup every OTHER A10 audit call in this codebase supports) —
    # filled in here, additively, alongside the notify half below. No existing
    # test asserted on the prior (subject-less) shape.
    Audit.auth_event(mount.repo,
      event: "auth.sso_linked",
      subject_id: credential_id,
      actor_id: credential_id,
      detail: to_string(status)
    )

    notify_link(mount, credential_id)
  end

  defp audit_link(_conn, _result), do: :ok

  # ADR-035 §5 A10 (T09) — `auth.sso_linked`'s notify half (security notice),
  # co-located with the existing audit call above (the `TotpEnrollLive.fan_out/4`
  # precedent). Best-effort (`Notify.notify_credential/4` never raises); the
  # provider/uid never appear in the body (token-blind — INV-1).
  defp notify_link(mount, credential_id) do
    Notify.notify_credential(
      Mount.resource(mount, User),
      credential_id,
      "sso_linked",
      "A new sign-in method was linked to your account."
    )
  end

  defp oidc_config(conn), do: conn.private[:samen_oidc_config]

  defp signup?(conn, provider) do
    conn
    |> oidc_config()
    |> provider_signup(provider)
  end

  defp provider_signup(nil, _provider), do: false

  defp provider_signup(config, provider) do
    key = provider_atom(provider)
    providers = config[:providers] || config

    pcfg =
      cond do
        is_map(providers) -> Map.get(providers, key) || Map.get(providers, to_string(key))
        is_list(providers) -> Keyword.get(providers, key)
        true -> nil
      end

    case pcfg do
      nil -> false
      %{} = m -> !!Map.get(m, :signup)
      kw when is_list(kw) -> !!Keyword.get(kw, :signup)
      _ -> false
    end
  end

  defp provider_atom(p) when is_atom(p), do: p
  defp provider_atom(p) when is_binary(p), do: String.to_existing_atom(p)

  defp oidc_link_mods(conn) do
    mount = conn.private.samen_mount

    %{
      org: Mount.resource(mount, Org),
      credential: Mount.resource(mount, Credential),
      user: Mount.resource(mount, User),
      membership: Mount.resource(mount, Membership),
      user_identity: Mount.resource(mount, UserIdentity),
      repo: mount.repo
    }
  end

  defp session_create_mods(conn) do
    mount = conn.private.samen_mount

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

  defp login_path(conn), do: conn.private[:samen_login_path] || "/login"

  defp totp_path(conn), do: conn.private[:samen_totp_path] || "/2fa"

  # A bounded error code for the login redirect — never leaks WHY beyond a coarse
  # class (no account-existence oracle; `:no_account` and a strategy failure both
  # land the user on login with a generic marker).
  defp error_code(:invalid_state), do: "oidc_state"
  defp error_code(:not_configured), do: "oidc_not_configured"
  defp error_code(:no_account), do: "oidc_no_account"
  # ADR-035 §5 A6 — an unverified IdP email that matched an existing account was
  # refused (the takeover control): a generic marker, no account-existence oracle.
  defp error_code(:email_unverified), do: "oidc_email_unverified"
  defp error_code(_), do: "oidc_failed"

  defp stringify(%{} = m), do: Map.new(m, fn {k, v} -> {to_string(k), v} end)
  defp stringify(other), do: other
end
