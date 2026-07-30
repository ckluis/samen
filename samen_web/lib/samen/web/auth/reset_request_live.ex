defmodule Samen.Web.Auth.ResetRequestLive do
  @moduledoc """
  A3 — Password reset request (ADR-035 §5 A3). Mounted at `GET /reset` by
  `Samen.Web.Router.samen_auth_routes/1`. **Pre-actor public** (ADR-035 §6):
  no org data rendered.

  Submitting the form calls `Samen.Identity.Reset.request/2`, which mints a
  `:password_reset` token (1h) and dispatches it via the Delivery chokepoint.
  The response is the SAME generic "check your inbox" copy whether or not the
  account exists (ADR-035 §5 A3 — no account-existence oracle, mirroring A1).

  ## No-JS HTTP fallback (T110)

  The form carries a REAL `action="/reset"` + `method="post"` so a no-JS
  browser POSTs to `Samen.Web.Auth.AccountController.request_reset/2` (the
  authoritative rate-limit + `Reset.request/2` site). On the JS path,
  `phx-submit` arms `phx-trigger-action` to fire that SAME POST. The controller
  always redirects to `?requested=1` (the uniform, no-oracle outcome), read in
  `handle_params/3` — the email is never echoed into the URL.
  """
  use Phoenix.LiveView

  import Samen.UI

  alias Samen.Web.Mount

  @impl true
  def mount(_params, session, socket) do
    socket = Samen.Web.Live.assign_mount(socket, session)
    {:ok, load(socket)}
  end

  @doc false
  def load(socket) do
    assign(socket, form: blank_form(), flash_ok: nil, requested?: false, trigger_submit: false)
  end

  @impl true
  def handle_params(%{"requested" => "1"}, _uri, socket) do
    {:noreply,
     assign(socket, requested?: true, flash_ok: "If that email has an account, check your inbox for a reset link.")}
  end

  def handle_params(%{"throttled" => "1"}, _uri, socket) do
    {:noreply,
     assign(socket,
       requested?: true,
       flash_ok: "Too many reset requests. Please wait a few minutes before trying again."
     )}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("request_reset", %{"reset" => %{"email" => _email}} = params, socket) do
    # JS-connected path: arm the real POST. The authoritative rate-limit +
    # `Reset.request/2` (uniform no-oracle outcome) run in
    # `Samen.Web.Auth.AccountController.request_reset/2`, which a no-JS submit
    # hits directly — this handler never mutates.
    {:noreply, assign(socket, form: to_form(params["reset"] || %{}, as: :reset), trigger_submit: true)}
  end

  defp reset_action(%Mount{} = mount), do: Mount.label(mount, :reset_path, "/reset")

  defp blank_form, do: to_form(%{}, as: :reset)

  # -- render ------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div id="auth-reset-request" class="wrap" style="max-width:420px;margin:60px auto">
      <div class="card" style="padding:28px 24px">
        <h2 style="margin:0 0 4px">Reset your password</h2>
        <p style="margin:0 0 18px;color:var(--muted)">
          Enter your account email — we'll send a reset link.
        </p>

        <p :if={@flash_ok} id="reset-request-ok" style="color:#15803D;margin:8px 0">{@flash_ok}</p>

        <.simple_form
          :if={not @requested?}
          for={@form}
          id="reset-request-form"
          action={reset_action(@samen_mount)}
          method="post"
          phx-submit="request_reset"
          phx-trigger-action={@trigger_submit}
        >
          <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />

          <.form_field field={@form[:email]} label="Email" type="email" required />

          <:actions>
            <.button type="submit" variant="primary" id="reset-request-submit">Send reset link</.button>
          </:actions>
        </.simple_form>
      </div>
    </div>
    """
  end
end
