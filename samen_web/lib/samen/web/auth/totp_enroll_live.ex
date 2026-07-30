defmodule Samen.Web.Auth.TotpEnrollLive do
  @moduledoc """
  A7 — TOTP enrollment (ADR-035 §5 A7). Tenant-plane, self-service ("enroll
  MY OWN 2FA"): a fresh secret is generated on mount and shown once as a
  QR-ready `otpauth://` URI + the plain secret (for manual entry), but is
  **never persisted** until the user proves possession by entering a valid
  code — `Samen.Web.Auth.Totp.confirm_enrollment/4` verifies the code against
  the FRESH secret and then, in ONE atomic write
  (`Samen.Identity.Totp.enroll/4`), sets the secret + a freshly-generated
  recovery-code set + `totp_enabled_at` together. There is no window where a
  secret exists on the row but 2FA isn't really live ("no half-enrolled
  lockouts").

  Pure LiveView (no cookie write needed — enrollment does not change WHO is
  signed in, unlike `SessionController`'s login/2fa-verify endpoints), so
  every event is handled entirely in `handle_event/3`, mirroring
  `Samen.Web.Auth.ResetLive`'s shape rather than `LoginLive`'s
  `phx-trigger-action` pattern.

  `credential_id` comes from `on_mount {Samen.Web.Auth, :ensure_authenticated}`
  (`socket.assigns.samen_credential_id`) when mounted behind the framework
  spine's auth, with a `params["credential_id"]` override for direct/test
  mounts — the SAME "explicit override, else session-derived" shape
  `Samen.Web.Settings.Reads.current_user_id/3` already uses elsewhere in this
  library.

  ## A10 fan-out (T09, ADR-035 §5 A10)

  Every state-changing event here (confirm/enroll, regenerate recovery
  codes, disable) audits its `auth.totp_*` event kind
  (`Samen.Scopes.Identity.Audit.auth_event/2`, the `api_key_event`
  precedent) AND dispatches a token-blind security-notice notification
  (`Samen.Scopes.Identity.Notify`) — closing the gap T07 explicitly deferred
  (`_orch/tasks/T07/status.json` caveats: "auth.totp_enrolled/disabled/
  recovery_code_used/recovery_codes_regenerated audit+notification events...
  are not wired"). `auth.recovery_code_used` (the fourth named kind) is
  wired at its OWN real call site — `Samen.Web.Auth.SessionController.
  verify_totp/2`, the `/2fa` recovery-code login path — not here (enrollment
  never consumes a recovery code).
  """
  use Phoenix.LiveView

  import Samen.UI

  alias Samen.Scopes.Identity.Audit
  alias Samen.Scopes.Identity.Notify
  alias Samen.Web.Auth.Totp
  alias Samen.Web.Mount

  @impl true
  def mount(params, session, socket) do
    socket = Samen.Web.Live.assign_mount(socket, session)
    {:ok, load(socket, params)}
  end

  @doc false
  def load(socket, params) do
    credential_id = params["credential_id"] || socket.assigns[:samen_credential_id]
    mount = socket.assigns.samen_mount

    cond do
      # T110 — the no-JS POST confirm/regenerate redirected back here after
      # enrolling; render the "enabled" state and the ONE-TIME recovery codes
      # (handed over via flash — never a URL). `?error=1` re-shows the setup form
      # with the generic failure copy; `?disabled=1` (and the default) show setup.
      params["enrolled"] == "1" ->
        assign(socket,
          credential_id: credential_id,
          raw_secret: nil,
          provisioning_uri: nil,
          confirm_form: to_form(%{}, as: :totp_enroll),
          error: nil,
          enrolled?: true,
          recovery_codes: flash_recovery_codes(socket)
        )

      true ->
        error = if params["error"] == "1", do: "That code didn't verify — try the current code from your app.", else: nil
        setup(socket, credential_id, mount, error)
    end
  end

  defp setup(socket, credential_id, mount, error) do
    raw_secret = Totp.generate_secret()

    assign(socket,
      credential_id: credential_id,
      raw_secret: raw_secret,
      provisioning_uri: Totp.provisioning_uri(raw_secret, enroll_label(credential_id), issuer(mount)),
      confirm_form: to_form(%{}, as: :totp_enroll),
      error: error,
      enrolled?: false,
      recovery_codes: nil
    )
  end

  # One-time recovery codes handed over by `TotpEnrollController` via flash (a
  # signed, same-user, single-use channel — never a URL). Read defensively: a
  # directly-constructed test socket carries no `:flash` assign.
  defp flash_recovery_codes(socket) do
    with %{} = flash <- socket.assigns[:flash],
         joined when is_binary(joined) and joined != "" <- Phoenix.Flash.get(flash, :totp_recovery_codes) do
      String.split(joined, "\n")
    else
      _ -> nil
    end
  end

  @impl true
  def handle_event("confirm", %{"totp_enroll" => %{"code" => code}}, socket) do
    mount = socket.assigns.samen_mount

    case Totp.confirm_enrollment(mods(mount), socket.assigns.credential_id, socket.assigns.raw_secret, code) do
      {:ok, _credential, recovery_codes} ->
        fan_out(mount, socket.assigns.credential_id, "totp_enrolled", "Two-factor authentication was enabled on your account.")
        {:noreply, assign(socket, enrolled?: true, recovery_codes: recovery_codes, error: nil)}

      {:error, _reason} ->
        {:noreply, assign(socket, error: "That code didn't verify — try the current code from your app.")}
    end
  end

  @impl true
  def handle_event("regenerate_recovery_codes", _params, socket) do
    mount = socket.assigns.samen_mount

    case Totp.regenerate_recovery_codes(mods(mount), socket.assigns.credential_id) do
      {:ok, _credential, recovery_codes} ->
        fan_out(
          mount,
          socket.assigns.credential_id,
          "recovery_codes_regenerated",
          "Your two-factor recovery codes were regenerated — the old codes no longer work."
        )

        {:noreply, assign(socket, recovery_codes: recovery_codes, error: nil)}

      {:error, _reason} ->
        {:noreply, assign(socket, error: "Could not regenerate recovery codes.")}
    end
  end

  @impl true
  def handle_event("disable", _params, socket) do
    mount = socket.assigns.samen_mount

    case Totp.disable(mods(mount), socket.assigns.credential_id) do
      {:ok, _credential} ->
        fan_out(mount, socket.assigns.credential_id, "totp_disabled", "Two-factor authentication was disabled on your account.")

      _ ->
        :ok
    end

    {:noreply, load(socket, %{"credential_id" => socket.assigns.credential_id})}
  end

  defp mods(%Mount{} = mount) do
    %{
      credential: Mount.resource(mount, Credential),
      # ADR-035 §5 A10 (T09) — notify seam: resolves the credential's
      # {org_id, user_id} for the security-notice notification.
      user: Mount.resource(mount, User),
      repo: mount.repo
    }
  end

  # ADR-035 §5 A10 (T09) — audit + notify, co-located exactly as
  # `Samen.Web.Auth.OidcController.audit_link/2` already does for
  # `auth.sso_linked`: the audit write is unconditional (token-only, cannot
  # fail this surface's success path); the notify half is best-effort
  # (`Samen.Scopes.Identity.Notify` never raises).
  defp fan_out(%Mount{} = mount, credential_id, event, body) do
    Audit.auth_event(mount.repo, event: "auth.#{event}", subject_id: credential_id, actor_id: credential_id)
    Notify.notify_credential(Mount.resource(mount, User), credential_id, event, body)
    :ok
  end

  # T110 — the real `<form action=>` for the no-JS enroll POST, built off the
  # settings mount path (host-overridable) so it matches the paired POST route.
  defp enroll_action(%Mount{} = mount), do: "#{Mount.label(mount, :settings_path, "/settings")}/security/2fa"

  defp enroll_label(nil), do: "Samen"
  defp enroll_label(credential_id), do: "Samen:#{credential_id}"

  defp issuer(%Mount{} = mount), do: Mount.label(mount, :totp_issuer, "Samen")

  # -- render ------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div id="auth-totp-enroll" class="wrap" style="max-width:480px;margin:60px auto">
      <div class="card" style="padding:28px 24px">
        <h2 style="margin:0 0 4px">Two-factor authentication</h2>

        <p :if={@error} id="totp-enroll-error" style="color:#B91C1C;margin:8px 0">{@error}</p>

        <div :if={not @enrolled?} id="totp-enroll-setup">
          <p style="color:var(--muted)">
            Scan this in your authenticator app, or enter the secret manually.
          </p>
          <p id="totp-enroll-uri" style="word-break:break-all;font-family:monospace;font-size:12px">
            {@provisioning_uri}
          </p>
          <p id="totp-enroll-secret" style="font-family:monospace">{@raw_secret |> Base.encode32(padding: false)}</p>

          <.simple_form
            for={@confirm_form}
            id="totp-enroll-confirm-form"
            action={enroll_action(@samen_mount)}
            method="post"
            phx-submit="confirm"
          >
            <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
            <input type="hidden" name="totp_secret" value={Base.encode32(@raw_secret, padding: false)} />
            <.form_field field={@confirm_form[:code]} label="Enter the current code to confirm" type="text" required />
            <:actions>
              <.button type="submit" variant="primary" id="totp-enroll-confirm">Confirm and enable</.button>
            </:actions>
          </.simple_form>
        </div>

        <div :if={@enrolled?} id="totp-enroll-done">
          <p id="totp-enroll-success">Two-factor authentication is enabled.</p>

          <div :if={@recovery_codes} id="totp-recovery-codes">
            <p style="color:var(--muted)">
              Save these recovery codes somewhere safe — each works ONCE, and this is the only
              time they're shown.
            </p>
            <ul>
              <li :for={{code, i} <- Enum.with_index(@recovery_codes)} id={"recovery-code-#{i}"} style="font-family:monospace">
                {code}
              </li>
            </ul>
          </div>

          <form action={"#{enroll_action(@samen_mount)}/recovery_codes"} method="post" phx-submit="regenerate_recovery_codes" style="display:inline">
            <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
            <button type="submit" id="totp-regenerate-codes" class="btn">Regenerate recovery codes</button>
          </form>
          <form action={"#{enroll_action(@samen_mount)}/disable"} method="post" phx-submit="disable" style="display:inline">
            <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
            <button type="submit" id="totp-disable" class="btn">Disable two-factor authentication</button>
          </form>
        </div>
      </div>
    </div>
    """
  end
end
