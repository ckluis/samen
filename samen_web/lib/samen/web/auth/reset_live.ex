defmodule Samen.Web.Auth.ResetLive do
  @moduledoc """
  A3 — Password reset consume (ADR-035 §5 A3). Mounted at
  `GET /reset/:token` by `Samen.Web.Router.samen_auth_routes/1`. **Pre-actor
  public** (ADR-035 §6): no org data rendered.

  Submitting the new password calls `Samen.Identity.Reset.consume/3`: atomic
  single-use/expiring token consume, rehash, revoke ALL the credential's
  sessions (c3), audit. A weak password is rejected WITHOUT touching the
  token (it can be retried against the same link); an invalid/expired/
  already-used token renders the SAME generic message RegistrationLive's
  weak-password path never leaks into an account-existence oracle.
  """
  use Phoenix.LiveView

  import Samen.UI

  alias Samen.Identity.Reset
  alias Samen.Web.Mount

  @impl true
  def mount(%{"token" => token}, session, socket) do
    socket = Samen.Web.Live.assign_mount(socket, session)
    {:ok, load(socket, token)}
  end

  @doc false
  def load(socket, token) do
    assign(socket, token: token, form: blank_form(), error: nil, flash_ok: nil, reset?: false)
  end

  @impl true
  def handle_event("reset", %{"reset" => %{"password" => password}}, socket) do
    mount = socket.assigns.samen_mount

    case Reset.consume(socket.assigns.token, password, mods(mount)) do
      {:ok, _credential} ->
        {:noreply,
         assign(socket,
           form: blank_form(),
           error: nil,
           reset?: true,
           flash_ok: "Your password has been reset. Every other session was signed out — sign in again."
         )}

      {:error, :weak_password} ->
        {:noreply,
         assign(socket,
           error: "Password must be at least #{Samen.Auth.PasswordPolicy.min_length()} characters.",
           flash_ok: nil
         )}

      {:error, :invalid_token} ->
        {:noreply,
         assign(socket,
           error: "This link is invalid or has expired.",
           flash_ok: nil
         )}

      {:error, _reason} ->
        {:noreply, assign(socket, error: "Something went wrong. Please try again.", flash_ok: nil)}
    end
  end

  defp mods(%Mount{} = mount) do
    %{
      credential: Mount.resource(mount, Credential),
      auth_token: Mount.resource(mount, AuthToken),
      session: Mount.resource(mount, Session),
      # ADR-035 §5 A10 (T09) — optional notify seam (`Samen.Identity.Reset`'s
      # `mods[:user]`): wires the real `GET/PUT /reset/:token` surface to the
      # security-notice notification, in addition to the existing
      # `password_reset` audit.
      user: Mount.resource(mount, User),
      repo: mount.repo
    }
  end

  defp blank_form, do: to_form(%{}, as: :reset)

  # -- render ------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div id="auth-reset" class="wrap" style="max-width:420px;margin:60px auto">
      <div class="card" style="padding:28px 24px">
        <h2 style="margin:0 0 4px">Choose a new password</h2>

        <p :if={@flash_ok} id="reset-ok" style="color:#15803D;margin:8px 0">{@flash_ok}</p>
        <p :if={@error} id="reset-error" style="color:#B91C1C;margin:8px 0">{@error}</p>

        <.simple_form :if={not @reset?} for={@form} id="reset-form" phx-submit="reset">
          <.form_field field={@form[:password]} label="New password" type="password" required />

          <:actions>
            <.button type="submit" variant="primary" id="reset-submit">Reset password</.button>
          </:actions>
        </.simple_form>
      </div>
    </div>
    """
  end
end
