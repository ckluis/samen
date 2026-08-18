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

  ## No-JS HTTP fallback (T110)

  The reset `:token` is legitimately PART of the URL path (`/reset/:token` —
  that's how the link arrives), but the NEW PASSWORD must never be. The form
  carries a REAL `action="/reset/:token"` + `method="post"` so a no-JS browser
  POSTs the password in the BODY to `Samen.Web.Auth.AccountController.reset/2`
  (never a GET query string). On the JS path, `phx-submit` does a cheap inline
  password-length check for UX, then arms `phx-trigger-action` to fire that
  SAME POST — the authoritative `Reset.consume/3` mutation lives in the
  controller. Status returns as `?reset=1` / `?error=weak_password` /
  `?error=invalid_token`, read in `handle_params/3`.
  """
  use Phoenix.LiveView

  import Samen.UI

  alias Samen.Auth.PasswordPolicy
  alias Samen.Web.Mount

  @impl true
  def mount(%{"token" => token}, session, socket) do
    socket = Samen.Web.Live.assign_mount(socket, session)
    {:ok, load(socket, token)}
  end

  @doc false
  def load(socket, token) do
    assign(socket, token: token, form: blank_form(), error: nil, flash_ok: nil, reset?: false, trigger_submit: false)
  end

  @impl true
  def handle_params(%{"reset" => "1"}, _uri, socket) do
    {:noreply,
     assign(socket,
       reset?: true,
       error: nil,
       flash_ok: "Your password has been reset. Every other session was signed out — sign in again."
     )}
  end

  def handle_params(%{"error" => "weak_password"}, _uri, socket) do
    {:noreply, assign(socket, error: "Password must be at least #{PasswordPolicy.min_length()} characters.")}
  end

  def handle_params(%{"error" => "invalid_token"}, _uri, socket) do
    {:noreply, assign(socket, error: "This link is invalid or has expired.")}
  end

  def handle_params(%{"error" => _}, _uri, socket) do
    {:noreply, assign(socket, error: "Something went wrong. Please try again.")}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("reset", %{"reset" => %{"password" => password}} = params, socket) do
    # JS-connected path: inline password-length check for UX, then arm the real
    # POST. The authoritative `Reset.consume/3` runs in
    # `Samen.Web.Auth.AccountController.reset/2`, which a no-JS submit hits.
    case PasswordPolicy.validate(password) do
      :ok ->
        {:noreply, assign(socket, form: to_form(params["reset"], as: :reset), error: nil, trigger_submit: true)}

      {:error, _weak} ->
        {:noreply,
         assign(socket,
           error: "Password must be at least #{PasswordPolicy.min_length()} characters.",
           flash_ok: nil,
           trigger_submit: false
         )}
    end
  end

  defp reset_action(%Mount{} = mount, token), do: "#{Mount.label(mount, :reset_path, "/reset")}/#{token}"

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

        <.simple_form
          :if={not @reset?}
          for={@form}
          id="reset-form"
          action={reset_action(@samen_mount, @token)}
          method="post"
          phx-submit="reset"
          phx-trigger-action={@trigger_submit}
        >
          <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />

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
