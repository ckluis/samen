defmodule Samen.Web.Auth.TotpEnrollController do
  @moduledoc """
  T110 — the no-JS HTTP POST fallbacks for `Samen.Web.Auth.TotpEnrollLive`
  (ADR-035 §5 A7 self-service 2FA enrollment). Since ADR-042 the LiveView client
  ships (`Samen.Web.Layouts`), so with JS these controls enhance in place and the
  socket connects; but 2FA enrollment is Class A (ADR-042 §5), so its
  controller-POST fallback is a BINDING no-JS floor. Critically for the T110
  security invariant, the confirm form's native submit was a **GET**, which would
  put the 6-digit **TOTP code** (a credential) in the URL query string. These
  actions give it a real POST endpoint so the code rides the body, never the URL.

  Unlike `AccountController` (pre-actor), enrollment is a TENANT-plane action on
  the CALLER's OWN credential, so `credential_id` is resolved from the
  authenticated SESSION here — NEVER from a client-controlled field (a hidden
  credential id would let one user enroll 2FA on another's credential). Only the
  freshly-generated enrollment secret rides the form (as a hidden field): it is
  the user's own not-yet-persisted secret, confirmed by proving possession of a
  live code — the standard TOTP-enroll round-trip.

  One-time recovery codes cannot ride a redirect URL (that is the very leak this
  task closes), so on success the codes are handed back via the Phoenix FLASH
  (a signed, single-use, same-user channel — never a URL) and `TotpEnrollLive`
  renders them once on the `?enrolled=1` landing.

  Mounted by `Samen.Web.Router.samen_settings_routes/3` ONLY under the
  `spine_totp` opt (the same gate as the GET enroll LiveView).
  """
  use Phoenix.Controller, formats: [:html]

  import Plug.Conn

  alias Samen.Scopes.Identity.Audit
  alias Samen.Scopes.Identity.Notify
  alias Samen.Web.Auth
  alias Samen.Web.Auth.Totp
  alias Samen.Web.Mount

  @doc """
  `POST /settings/security/2fa`. Params: `totp_enroll[code]` (the live 6-digit
  code, in the BODY) + `totp_secret` (the hidden base32 enrollment secret shown
  on the GET page). Verifies the code against that secret and, on success, does
  the ONE atomic enroll (secret + recovery codes + `totp_enabled_at`), fans out
  the `auth.totp_enrolled` audit + notice, hands the recovery codes to the
  `?enrolled=1` landing via flash, and redirects. On failure: `?error=1`.
  """
  def confirm(conn, params) do
    mount = conn.private.samen_mount
    path = enroll_path(conn)

    with {:ok, credential_id} <- session_credential_id(conn, mount),
         {:ok, raw_secret} <- decode_secret(params["totp_secret"]),
         code <- extract_code(params),
         {:ok, _credential, recovery_codes} <- Totp.confirm_enrollment(mods(mount), credential_id, raw_secret, code) do
      fan_out(mount, credential_id, "totp_enrolled", "Two-factor authentication was enabled on your account.")

      conn
      |> put_flash(:totp_recovery_codes, Enum.join(recovery_codes, "\n"))
      |> redirect(to: "#{path}?enrolled=1")
    else
      _ -> redirect(conn, to: "#{path}?error=1")
    end
  end

  @doc """
  `POST /settings/security/2fa/recovery_codes`. Regenerates the caller's recovery
  codes (the old set stops working) and shows the new set once via flash.
  """
  def regenerate(conn, _params) do
    mount = conn.private.samen_mount
    path = enroll_path(conn)

    with {:ok, credential_id} <- session_credential_id(conn, mount),
         {:ok, _credential, recovery_codes} <- Totp.regenerate_recovery_codes(mods(mount), credential_id) do
      fan_out(
        mount,
        credential_id,
        "recovery_codes_regenerated",
        "Your two-factor recovery codes were regenerated — the old codes no longer work."
      )

      conn
      |> put_flash(:totp_recovery_codes, Enum.join(recovery_codes, "\n"))
      |> redirect(to: "#{path}?enrolled=1&regenerated=1")
    else
      _ -> redirect(conn, to: "#{path}?error=1")
    end
  end

  @doc "`POST /settings/security/2fa/disable`. Turns 2FA off for the caller's credential."
  def disable(conn, _params) do
    mount = conn.private.samen_mount
    path = enroll_path(conn)

    with {:ok, credential_id} <- session_credential_id(conn, mount),
         {:ok, _credential} <- Totp.disable(mods(mount), credential_id) do
      fan_out(mount, credential_id, "totp_disabled", "Two-factor authentication was disabled on your account.")
      redirect(conn, to: "#{path}?disabled=1")
    else
      _ -> redirect(conn, to: "#{path}?error=1")
    end
  end

  # -- private ----------------------------------------------------------------

  # The caller's OWN credential, from the authenticated session — never a
  # client-supplied field (defense against enrolling 2FA on a foreign credential).
  defp session_credential_id(conn, mount) do
    conn = fetch_session(conn)

    case Auth.resolve_principal(get_session(conn), %{session: Mount.resource(mount, Session)}) do
      {:ok, %{credential_id: credential_id}} when is_binary(credential_id) -> {:ok, credential_id}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp decode_secret(b32) when is_binary(b32) do
    case Base.decode32(b32, padding: false) do
      {:ok, raw} -> {:ok, raw}
      _ -> :error
    end
  end

  defp decode_secret(_), do: :error

  defp extract_code(%{"totp_enroll" => %{"code" => code}}) when is_binary(code), do: code
  defp extract_code(_), do: ""

  defp mods(%Mount{} = mount) do
    %{credential: Mount.resource(mount, Credential), user: Mount.resource(mount, User), repo: mount.repo}
  end

  # Co-located audit + notify, exactly as `TotpEnrollLive.fan_out/4` does.
  defp fan_out(%Mount{} = mount, credential_id, event, body) do
    Audit.auth_event(mount.repo, event: "auth.#{event}", subject_id: credential_id, actor_id: credential_id)
    Notify.notify_credential(Mount.resource(mount, User), credential_id, event, body)
    :ok
  end

  defp enroll_path(conn), do: conn.private[:samen_totp_enroll_path] || "/settings/security/2fa"
end
