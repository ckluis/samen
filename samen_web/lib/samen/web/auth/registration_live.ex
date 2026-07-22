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
  """
  use Phoenix.LiveView

  import Samen.UI

  alias Samen.Identity.Register
  alias Samen.Web.Mount

  @impl true
  def mount(_params, session, socket) do
    socket = Samen.Web.Live.assign_mount(socket, session)
    {:ok, load(socket)}
  end

  @doc false
  def load(socket) do
    assign(socket, form: blank_form(), flash_ok: nil, error: nil, registered?: false)
  end

  @impl true
  def handle_event("register", %{"registration" => params}, socket) do
    mount = socket.assigns.samen_mount

    attrs = %{
      org_name: trim(Map.get(params, "org_name")),
      first_name: trim(Map.get(params, "first_name")),
      last_name: trim(Map.get(params, "last_name")),
      email: trim(Map.get(params, "email")),
      password: Map.get(params, "password") || ""
    }

    case Register.register(attrs, mods(mount)) do
      {:ok, %{status: status}} when status in [:registered, :duplicate] ->
        {:noreply,
         assign(socket,
           form: blank_form(),
           error: nil,
           registered?: true,
           flash_ok: "Check your inbox to verify your email and finish setting up your account."
         )}

      {:error, :weak_password} ->
        {:noreply,
         assign(socket,
           form: to_form(params, as: :registration),
           error: "Password must be at least #{Samen.Auth.PasswordPolicy.min_length()} characters.",
           flash_ok: nil
         )}

      {:error, _reason} ->
        {:noreply,
         assign(socket,
           form: to_form(params, as: :registration),
           error: "Something went wrong. Please try again.",
           flash_ok: nil
         )}
    end
  end

  # The eight Identity resources a `use Samen.Scopes.Identity` mount materializes
  # (ADR-004: `Module.concat(namespace, Name)`) — only the five Register needs.
  defp mods(%Mount{} = mount) do
    %{
      org: Mount.resource(mount, Org),
      credential: Mount.resource(mount, Credential),
      user: Mount.resource(mount, User),
      membership: Mount.resource(mount, Membership),
      auth_token: Mount.resource(mount, AuthToken),
      repo: mount.repo
    }
  end

  defp trim(v) when is_binary(v), do: String.trim(v)
  defp trim(_), do: nil

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
          phx-submit="register"
        >
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
