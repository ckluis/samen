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

  ## No-JS HTTP fallback (T110)

  The invite `:token` is legitimately PART of the URL path, but a joining
  member's PASSWORD must never be. The needs-registration password form carries
  a REAL `action="/invite/:token"` + `method="post"` so a no-JS browser POSTs
  the password in the BODY to `Samen.Web.Auth.AccountController.accept_invite/2`
  (the authoritative `Invite.accept/3` site). On the JS path, `phx-submit` does
  a cheap inline password-length check for UX, then arms `phx-trigger-action`
  to fire that SAME POST. The zero-credential auto-accept path (an existing
  credential — token possession alone) still runs on GET-mount unchanged.
  Status returns as `?joined=1` / `?error=weak_password` / `?error=<terminal>`,
  honored by `mount/3` BEFORE re-running `preview/2` (which, post-accept, would
  otherwise report `already_accepted`).
  """
  use Phoenix.LiveView

  import Samen.UI

  alias Samen.Auth.PasswordPolicy
  alias Samen.Identity.Invite
  alias Samen.Web.Mount

  @impl true
  def mount(%{"token" => token} = params, session, socket) do
    socket = Samen.Web.Live.assign_mount(socket, session)
    mount = socket.assigns.samen_mount

    socket =
      assign(socket,
        token: token,
        form: blank_form(),
        error: nil,
        joined?: false,
        needs_registration?: false,
        trigger_submit: false
      )

    # T110 — the controller redirects back here with a NON-secret status flag
    # after a no-JS POST accept. Honor it BEFORE `preview/2`: a just-consumed
    # token would otherwise preview as `already_accepted` and mask the success.
    cond do
      params["joined"] == "1" ->
        {:ok, assign(socket, joined?: true)}

      params["error"] == "weak_password" ->
        {:ok,
         assign(socket,
           needs_registration?: true,
           error: "Password must be at least #{PasswordPolicy.min_length()} characters."
         )}

      is_binary(params["error"]) ->
        {:ok, assign(socket, error: error_code_message(params["error"]))}

      true ->
        preview_mount(socket, mount, token)
    end
  end

  defp preview_mount(socket, mount, token) do
    case Invite.preview(mods(mount), token) do
      {:ok, %{needs_registration?: false}} ->
        # Zero-credential auto-accept (token possession IS the proof) — the ONE
        # mutating GET-mount path, architecturally identical to ConfirmLive's
        # consume-on-mount (its own moduledoc says so). T126: run the atomic
        # `Invite.accept/3` EXACTLY ONCE on the dead render, then REDIRECT to the
        # `?joined=1` / `?error=` status flag. The dead render's 302 stops any
        # socket from connecting to `/invite/:token`, so the connected re-mount
        # never re-accepts the now-consumed invite into a FALSE
        # "already accepted" (the T49 dogfood re-walk regression, same root cause
        # as ConfirmLive). The redirect target is read by the flag-first `mount/3`
        # cond above (`joined?`/`error`) — inert under its own double-mount.
        auto_accept(socket, mount, token)

      {:ok, %{needs_registration?: true}} ->
        # preview/2 is NON-mutating — the needs-registration form render (and the
        # terminal-error render below) re-derive identically on the connected
        # re-mount, so only the mutating auto-accept branch needed the guard.
        {:ok, assign(socket, needs_registration?: true)}

      {:error, reason} ->
        {:ok, assign(socket, error: preview_error(reason))}
    end
  end

  # The auto-accept (existing-credential) path only — runs the single-use
  # `Invite.accept/3` once, then redirects to the status flag. A form-bearing
  # accept still goes through `Samen.Web.Auth.AccountController.accept_invite/2`.
  defp auto_accept(socket, mount, token) do
    case Invite.accept(mods(mount), token, []) do
      {:ok, _joined} ->
        {:ok, redirect(socket, to: "#{invite_action(mount, token)}?joined=1")}

      {:error, :password_required} ->
        # A credential vanished between preview and accept — fall back to the
        # password form (non-mutating render, double-mount safe).
        {:ok, assign(socket, needs_registration?: true, error: nil)}

      {:error, reason} ->
        {:ok, redirect(socket, to: "#{invite_action(mount, token)}?error=#{invite_error_flag(reason)}")}
    end
  end

  # The `?error=<code>` flags the flag-first `mount/3` cond honors via
  # `error_code_message/1` — same vocabulary `AccountController.accept_invite/2`
  # redirects with, so the no-JS POST path and this GET-mount path converge.
  defp invite_error_flag(:expired), do: "expired"
  defp invite_error_flag(:revoked), do: "revoked"
  defp invite_error_flag(:already_accepted), do: "already_accepted"
  defp invite_error_flag(_), do: "invalid"

  @impl true
  def handle_event("accept", %{"accept" => %{"password" => password}} = params, socket) do
    # JS-connected path: inline password-length check for UX, then arm the real
    # POST. The authoritative `Invite.accept/3` runs in
    # `Samen.Web.Auth.AccountController.accept_invite/2`, which a no-JS submit hits.
    case PasswordPolicy.validate(password) do
      :ok ->
        {:noreply, assign(socket, form: to_form(params["accept"], as: :accept), error: nil, trigger_submit: true)}

      {:error, _weak} ->
        {:noreply,
         assign(socket,
           needs_registration?: true,
           error: "Password must be at least #{PasswordPolicy.min_length()} characters.",
           trigger_submit: false
         )}
    end
  end

  defp preview_error(:expired), do: "This invitation has expired."
  defp preview_error(:revoked), do: "This invitation was revoked."
  defp preview_error(:already_accepted), do: "This invitation has already been accepted."
  defp preview_error(_), do: "This invite link is invalid."

  # The `?error=<code>` flags `AccountController.accept_invite/2` redirects with.
  defp error_code_message("expired"), do: preview_error(:expired)
  defp error_code_message("revoked"), do: preview_error(:revoked)
  defp error_code_message("already_accepted"), do: preview_error(:already_accepted)
  defp error_code_message(_), do: preview_error(:invalid_token)

  defp invite_action(%Mount{} = mount, token), do: "#{Mount.label(mount, :invite_path, "/invite")}/#{token}"

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
          <.simple_form
            for={@form}
            id="invite-accept-form"
            action={invite_action(@samen_mount, @token)}
            method="post"
            phx-submit="accept"
            phx-trigger-action={@trigger_submit}
          >
            <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />

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
