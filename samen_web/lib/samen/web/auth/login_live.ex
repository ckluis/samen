defmodule Samen.Web.Auth.LoginLive do
  @moduledoc """
  A4 — full sign-in (ADR-035 §5 A4). Mounted at `GET /login` by
  `Samen.Web.Router.samen_auth_routes/1`. **Pre-actor public** (ADR-035 §6):
  no org data rendered.

  This page NEVER authenticates. The form is a plain `POST` to
  `Samen.Web.Auth.SessionController.create/2` (a real `action` + `method="post"`,
  no `phx-submit`), which is the ONE place a password is checked: it applies the
  T103 rate limits, mints the `Identity.Session` row, writes the cookies on that
  real HTTP response, and redirects back here with `?error=<code>` on a bad
  credential or an over-limit caller. A LiveView `handle_event` that ran
  `SignIn.authenticate/3` ahead of the POST would be an unthrottled
  password-guessing oracle over the websocket (it reveals ok/error), so there is
  none; the JS-on and JS-off paths are the same request.
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
    assign(socket, form: blank_form(), error: nil)
  end

  @impl true
  def handle_params(params, _uri, socket) do
    error = if code = params["error"], do: error_copy(code), else: socket.assigns[:error]
    {:noreply, assign(socket, error: error)}
  end

  # The controller redirects with `?error=rate_limited` for an over-limit caller and
  # `?error=1` for a bad credential (one generic message — no account-existence oracle).
  defp error_copy("rate_limited"), do: "Too many sign-in attempts. Please wait a minute and try again."
  defp error_copy(_), do: "Invalid email or password."

  defp blank_form, do: to_form(%{}, as: :login)

  defp login_action(%Mount{} = mount), do: Mount.label(mount, :login_path, "/login")

  # -- render ------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div id="auth-login" class="wrap" style="max-width:420px;margin:60px auto">
      <div class="card" style="padding:28px 24px">
        <h2 style="margin:0 0 4px">Sign in</h2>

        <p :if={@error} id="login-error" style="color:#B91C1C;margin:8px 0">{@error}</p>

        <.simple_form
          for={@form}
          id="login-form"
          action={login_action(@samen_mount)}
          method="post"
        >
          <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />

          <.form_field field={@form[:email]} label="Email" type="email" required />
          <.form_field field={@form[:password]} label="Password" type="password" required />

          <div class="field" style="display:flex;align-items:center;gap:8px;margin-bottom:10px">
            <input type="checkbox" id="login-remember-me" name="login[remember_me]" value="true" />
            <label for="login-remember-me" style="font-size:13px">Remember me for 60 days</label>
          </div>

          <:actions>
            <.button type="submit" variant="primary" id="login-submit">Sign in</.button>
          </:actions>
        </.simple_form>
      </div>
    </div>
    """
  end
end
