defmodule Samen.Web.Auth.LoginLive do
  @moduledoc """
  A4 — full sign-in (ADR-035 §5 A4). Mounted at `GET /login` by
  `Samen.Web.Router.samen_auth_routes/1`. **Pre-actor public** (ADR-035 §6):
  no org data rendered.

  A LiveView cannot set a cookie mid-mount, so this page only VALIDATES —
  `Samen.Identity.SignIn.authenticate/3` runs here purely for the inline
  error UX (the SAME generic "invalid email or password" message for a wrong
  password AND an unknown email, no account-existence oracle). On a
  successful validation, the form's `phx-trigger-action` fires a REAL browser
  POST to `Samen.Web.Auth.SessionController.create/2`, which re-authenticates
  (never trusts the client-side check alone), mints the `Identity.Session`
  row, and writes the cookies on that real HTTP response.
  """
  use Phoenix.LiveView

  import Samen.UI

  alias Samen.Identity.SignIn
  alias Samen.Web.Mount

  @impl true
  def mount(_params, session, socket) do
    socket = Samen.Web.Live.assign_mount(socket, session)
    {:ok, load(socket)}
  end

  @doc false
  def load(socket) do
    assign(socket, form: blank_form(), error: nil, trigger_submit: false)
  end

  @impl true
  def handle_params(params, _uri, socket) do
    error = if params["error"], do: "Invalid email or password.", else: socket.assigns[:error]
    {:noreply, assign(socket, error: error)}
  end

  @impl true
  def handle_event("login", %{"login" => params}, socket) do
    mount = socket.assigns.samen_mount
    email = String.trim(params["email"] || "")
    password = params["password"] || ""

    case SignIn.authenticate(email, password, sign_in_mods(mount)) do
      {:ok, _credential} ->
        {:noreply, assign(socket, form: to_form(params, as: :login), trigger_submit: true)}

      {:error, _reason} ->
        {:noreply,
         assign(socket,
           form: to_form(params, as: :login),
           error: "Invalid email or password.",
           trigger_submit: false
         )}
    end
  end

  defp sign_in_mods(%Mount{} = mount), do: %{credential: Mount.resource(mount, Credential)}

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
          phx-submit="login"
          phx-trigger-action={@trigger_submit}
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
