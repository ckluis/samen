defmodule Samen.Web.Auth.TotpChallengeLive do
  @moduledoc """
  A7 — the second-factor interstitial (ADR-035 §5 A7). Mounted at `GET /2fa`
  by `Samen.Web.Router.samen_auth_routes/1`. **Pre-actor public** (ADR-035
  §6): reached only after `SessionController.create/2` finds
  `Credential.totp_enabled_at` set on the password-verified credential — no
  `Identity.Session` row exists yet ("no half-authenticated session rows
  exist").

  Like `LoginLive`, this page never verifies the code itself. Verifying is
  STATEFUL (the `totp_last_verified_at` anti-replay watermark; the
  single-use recovery-code consume) — checking it twice, once for an inline
  LiveView preview and once for real, would BURN the first attempt and fail
  the real one. So the form always arms `phx-trigger-action` on submit, and
  `Samen.Web.Auth.SessionController.verify_totp/2` is the ONE place a code is
  actually checked, on a real HTTP response (a LiveView cannot set a cookie
  mid-mount).
  """
  use Phoenix.LiveView

  import Samen.UI

  alias Samen.Web.Auth
  alias Samen.Web.Mount

  @impl true
  def mount(_params, session, socket) do
    socket = Samen.Web.Live.assign_mount(socket, session)
    {:ok, load(socket, session)}
  end

  @doc false
  def load(socket, session) do
    pending? = is_binary(Auth.fetch_totp_pending_token(session))
    assign(socket, form: blank_form(), error: nil, trigger_submit: false, pending?: pending?)
  end

  @impl true
  def handle_params(params, _uri, socket) do
    error = if params["error"], do: "Invalid or expired code.", else: socket.assigns[:error]
    {:noreply, assign(socket, error: error)}
  end

  @impl true
  def handle_event("verify", %{"totp" => params}, socket) do
    {:noreply, assign(socket, form: to_form(params, as: :totp), trigger_submit: true)}
  end

  defp blank_form, do: to_form(%{}, as: :totp)

  defp totp_action(%Mount{} = mount), do: Mount.label(mount, :totp_path, "/2fa")

  # -- render ------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div id="auth-totp-challenge" class="wrap" style="max-width:420px;margin:60px auto">
      <div class="card" style="padding:28px 24px">
        <h2 style="margin:0 0 4px">Two-factor verification</h2>
        <p style="margin:0 0 12px;color:var(--muted)">
          Enter the 6-digit code from your authenticator app, or a recovery code.
        </p>

        <p :if={@error} id="totp-error" style="color:#B91C1C;margin:8px 0">{@error}</p>
        <p :if={not @pending?} id="totp-no-pending" style="color:#B91C1C;margin:8px 0">
          No pending sign-in — please sign in again.
        </p>

        <.simple_form
          for={@form}
          id="totp-form"
          action={totp_action(@samen_mount)}
          method="post"
          phx-submit="verify"
          phx-trigger-action={@trigger_submit}
        >
          <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />

          <.form_field field={@form[:code]} label="Code" type="text" required autocomplete="one-time-code" />

          <:actions>
            <.button type="submit" variant="primary" id="totp-submit">Verify</.button>
          </:actions>
        </.simple_form>
      </div>
    </div>
    """
  end
end
