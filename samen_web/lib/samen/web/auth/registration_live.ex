defmodule Samen.Web.Auth.RegistrationLive do
  @moduledoc """
  A1 — self-serve registration (ADR-035 §5 A1; spec §WS-A A1). Mounted at
  `/signup` by `Samen.Web.Router.samen_auth_routes/1`. **Pre-actor public**
  (ADR-035 §6): no org actor exists yet, so this surface renders no org data and
  is plane-less by construction.

  Submitting the form calls `Samen.Identity.Register.register/2` — the ONE
  atomic transaction creating Org + Credential + User (PII vaulted at write) +
  owner Membership + the `:email_verify` AuthToken. The response is the SAME
  generic "check your inbox" copy whether the email was fresh or already
  registered (ADR-035 §5 A1 — no account-existence oracle); a weak password is
  the one distinguishable, non-oracle-leaking rejection (it says nothing about
  whether the account exists).

  Sending the verify email through the Delivery chokepoint (A2) is a later
  task's contract — this surface mints the AuthToken row (inside the SAME
  transaction) but does not itself dispatch mail.

  ## No-JS HTTP fallback (T110)

  Since ADR-042 the LiveView client ships, so with JS this form enhances in
  place and the socket connects; but signup is Class A (ADR-042 §5), so its
  controller-POST fallback is a BINDING no-JS floor. The form therefore carries a
  REAL `action="/signup"` + `method="post"` (the `LoginLive`/`SessionController`
  precedent), so a no-JS browser POSTs to
  `Samen.Web.Auth.AccountController.register/2` — the password
  rides the POST body, never a GET query string. When JS IS connected,
  `phx-submit="register"` does a cheap inline password-length check for UX and,
  on success, arms `phx-trigger-action` to fire that SAME real POST (the
  authoritative rate-limit + `Register.register/2` mutation lives in the
  controller, the ONE enforcement point a no-JS submit also hits). Status flows
  back as NON-secret query flags (`?registered=1`, `?error=weak_password`,
  `?error=rate_limited`) read in `handle_params/3` — never a credential.
  """
  use Phoenix.LiveView

  import Samen.UI

  alias Samen.Auth.PasswordPolicy
  alias Samen.Web.Mount

  @impl true
  def mount(_params, session, socket) do
    socket = Samen.Web.Live.assign_mount(socket, session)
    {:ok, load(socket)}
  end

  @doc false
  def load(socket) do
    assign(socket, form: blank_form(), flash_ok: nil, error: nil, registered?: false, trigger_submit: false)
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_status(socket, params)}
  end

  # T110 — the controller redirects back here with a NON-secret status flag; a
  # weak-password retry is re-shown for the caller to fix (no credential is ever
  # echoed into these params).
  defp apply_status(socket, %{"registered" => "1"}) do
    assign(socket,
      registered?: true,
      error: nil,
      flash_ok: "Check your inbox to verify your email and finish setting up your account."
    )
  end

  defp apply_status(socket, %{"error" => "weak_password"}) do
    assign(socket, error: "Password must be at least #{PasswordPolicy.min_length()} characters.", flash_ok: nil)
  end

  defp apply_status(socket, %{"error" => "rate_limited"}) do
    assign(socket,
      error: "Too many sign-up attempts from your network. Please wait a few minutes and try again.",
      flash_ok: nil
    )
  end

  defp apply_status(socket, %{"error" => _}) do
    assign(socket, error: "Something went wrong. Please try again.", flash_ok: nil)
  end

  defp apply_status(socket, _params), do: socket

  @impl true
  def handle_event("register", %{"registration" => params}, socket) do
    # JS-connected path only: a cheap inline password-length check for UX, then
    # arm the real POST. The AUTHORITATIVE rate-limit + `Register.register/2`
    # (and the same weak-password rejection, re-derived server-side) run in
    # `Samen.Web.Auth.AccountController.register/2`, which a no-JS submit hits
    # directly — so this handler never mutates and never enforces on its own.
    case PasswordPolicy.validate(Map.get(params, "password") || "") do
      :ok ->
        {:noreply, assign(socket, form: to_form(params, as: :registration), error: nil, trigger_submit: true)}

      {:error, _weak} ->
        {:noreply,
         assign(socket,
           form: to_form(params, as: :registration),
           error: "Password must be at least #{PasswordPolicy.min_length()} characters.",
           flash_ok: nil,
           trigger_submit: false
         )}
    end
  end

  defp registration_action(%Mount{} = mount), do: Mount.label(mount, :signup_path, "/signup")

  defp blank_form, do: to_form(%{}, as: :registration)

  # -- render ------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div id="auth-registration" class="wrap" style="max-width:420px;margin:60px auto">
      <div class="card" style="padding:28px 24px">
        <h2 style="margin:0 0 4px">Create your account</h2>
        <p style="margin:0 0 18px;color:var(--muted)">Free to start — no card required.</p>

        <p :if={@flash_ok} id="registration-ok" style="color:#15803D;margin:8px 0">{@flash_ok}</p>
        <p :if={@error} id="registration-error" style="color:#B91C1C;margin:8px 0">{@error}</p>

        <.simple_form
          :if={not @registered?}
          for={@form}
          id="registration-form"
          action={registration_action(@samen_mount)}
          method="post"
          phx-submit="register"
          phx-trigger-action={@trigger_submit}
        >
          <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />

          <.form_field field={@form[:org_name]} label="Company / org name" required />
          <.form_field field={@form[:first_name]} label="First name" />
          <.form_field field={@form[:last_name]} label="Last name" />
          <.form_field field={@form[:email]} label="Work email" type="email" required />
          <.form_field field={@form[:password]} label="Password" type="password" required />

          <:actions>
            <.button type="submit" variant="primary" id="registration-submit">Create account</.button>
          </:actions>
        </.simple_form>
      </div>
    </div>
    """
  end
end
