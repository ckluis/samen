defmodule Samen.Web.Auth.InviteAcceptLive do
  @moduledoc """
  A5 — team invitation accept (ADR-035 §5 A5). Mounted at `GET
  /invite/:token` by `Samen.Web.Router.samen_auth_routes/1`. **Pre-actor
  public** (ADR-035 §6): no org data rendered.

  On mount, `Samen.Identity.Invite.preview/2` (non-mutating) checks the raw
  `:token` path param. When the invited email already has a `Credential`
  (email_bidx match), token possession alone is the proof — this mirrors
  `ConfirmLive`'s auto-consume-on-mount posture, and immediately runs the
  real atomic `Invite.accept/3`. When NO credential exists yet, a short
  password form collects the one missing fact (the invite already carries
  the email + org + role) — token possession is STILL the email-ownership
  proof (the minted credential is pre-verified, no separate confirm loop).

  `{:error, :expired | :revoked | :already_accepted | :invalid_token}` all
  render distinct, honest copy — unlike sign-in/reset, an invite link is not
  an account-existence oracle surface (the recipient already knows they were
  invited; distinguishing "expired" from "revoked" is a real UX kindness,
  not a leak).
  """
  use Phoenix.LiveView

  import Samen.UI

  alias Samen.Identity.Invite
  alias Samen.Web.Mount

  @impl true
  def mount(%{"token" => token}, session, socket) do
    socket = Samen.Web.Live.assign_mount(socket, session)
    mount = socket.assigns.samen_mount

    socket =
      assign(socket,
        token: token,
        form: blank_form(),
        error: nil,
        joined?: false,
        needs_registration?: false
      )

    case Invite.preview(mods(mount), token) do
      {:ok, %{needs_registration?: false}} ->
        {:ok, do_accept(socket, mount, token, nil)}

      {:ok, %{needs_registration?: true}} ->
        {:ok, assign(socket, needs_registration?: true)}

      {:error, reason} ->
        {:ok, assign(socket, error: preview_error(reason))}
    end
  end

  @impl true
  def handle_event("accept", %{"accept" => %{"password" => password}}, socket) do
    mount = socket.assigns.samen_mount
    {:noreply, do_accept(socket, mount, socket.assigns.token, password)}
  end

  defp do_accept(socket, mount, token, password) do
    opts = if password, do: [password: password], else: []

    case Invite.accept(mods(mount), token, opts) do
      {:ok, _joined} ->
        assign(socket, joined?: true, error: nil)

      {:error, :password_required} ->
        assign(socket, needs_registration?: true, error: nil)

      {:error, :weak_password} ->
        assign(socket,
          needs_registration?: true,
          error: "Password must be at least #{Samen.Auth.PasswordPolicy.min_length()} characters."
        )

      {:error, reason} ->
        assign(socket, error: preview_error(reason))
    end
  end

  defp preview_error(:expired), do: "This invitation has expired."
  defp preview_error(:revoked), do: "This invitation was revoked."
  defp preview_error(:already_accepted), do: "This invitation has already been accepted."
  defp preview_error(_), do: "This invite link is invalid."

  defp mods(%Mount{} = mount) do
    %{
      invitation: Mount.resource(mount, Invitation),
      credential: Mount.resource(mount, Credential),
      user: Mount.resource(mount, User),
      membership: Mount.resource(mount, Membership),
      repo: mount.repo
    }
  end

  defp blank_form, do: to_form(%{}, as: :accept)

  # -- render ------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div id="auth-invite-accept" class="wrap" style="max-width:420px;margin:60px auto">
      <div class="card" style="padding:28px 24px">
        <div :if={@joined?}>
          <h2 id="invite-accept-ok" style="margin:0 0 4px">You're in</h2>
          <p style="margin:0;color:var(--muted)">
            The invitation was accepted — you can sign in now.
          </p>
        </div>

        <div :if={not @joined? and @needs_registration?}>
          <h2 style="margin:0 0 4px">Set a password to join</h2>
          <p :if={@error} id="invite-accept-form-error" style="color:#B91C1C;margin:8px 0">{@error}</p>
          <.simple_form for={@form} id="invite-accept-form" phx-submit="accept">
            <.form_field field={@form[:password]} label="Password" type="password" required />
            <:actions>
              <.button type="submit" variant="primary" id="invite-accept-submit">Join</.button>
            </:actions>
          </.simple_form>
        </div>

        <div :if={not @joined? and not @needs_registration? and @error}>
          <h2 id="invite-accept-error-title" style="margin:0 0 4px">Couldn't accept this invite</h2>
          <p id="invite-accept-error" style="margin:0;color:#B91C1C">{@error}</p>
        </div>
      </div>
    </div>
    """
  end
end
