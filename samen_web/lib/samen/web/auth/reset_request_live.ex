defmodule Samen.Web.Auth.ResetRequestLive do
  @moduledoc """
  A3 — Password reset request (ADR-035 §5 A3). Mounted at `GET /reset` by
  `Samen.Web.Router.samen_auth_routes/1`. **Pre-actor public** (ADR-035 §6):
  no org data rendered.

  Submitting the form calls `Samen.Identity.Reset.request/2`, which mints a
  `:password_reset` token (1h) and dispatches it via the Delivery chokepoint.
  The response is the SAME generic "check your inbox" copy whether or not the
  account exists (ADR-035 §5 A3 — no account-existence oracle, mirroring A1).
  """
  use Phoenix.LiveView

  import Samen.UI

  alias Samen.Identity.Reset
  alias Samen.Web.Mount
  alias Samen.Web.RateLimit

  @impl true
  def mount(_params, session, socket) do
    socket = Samen.Web.Live.assign_mount(socket, session)
    {:ok, load(socket)}
  end

  @doc false
  def load(socket) do
    assign(socket, form: blank_form(), flash_ok: nil, requested?: false)
  end

  @impl true
  def handle_event("request_reset", %{"reset" => %{"email" => email}}, socket) do
    mount = socket.assigns.samen_mount
    email = String.trim(email)

    # ADR-035 §4.5 / ADR-038 §6.3 — token-request brute-force control (T103): 3/15min
    # per `email_bidx` (a non-reversible HMAC, ADR-035 §4.1 — never the plaintext email).
    # Keyed on the email the caller SUPPLIED, so it bumps identically whether or not an
    # account exists (no existence oracle — the same posture as the uniform copy below).
    case reset_rate_limit(email) do
      {:error, :rate_limited} ->
        {:noreply,
         assign(socket,
           form: blank_form(),
           requested?: true,
           flash_ok: "Too many reset requests. Please wait a few minutes before trying again."
         )}

      :ok ->
        # The uniform response is the whole point (no account-existence oracle) —
        # `Reset.request/2`'s only distinguishable outcome is an honestly-blocked
        # Delivery chokepoint, which still shows the SAME generic copy (a caller
        # never renders "blocked" to a pre-actor visitor; that's an
        # operator-facing signal, not a public one).
        _ = Reset.request(email, mods(mount))

        {:noreply,
         assign(socket,
           form: blank_form(),
           requested?: true,
           flash_ok: "If that email has an account, check your inbox for a reset link."
         )}
    end
  end

  defp reset_rate_limit(email) do
    case Samen.Auth.BlindIndex.compute(email) do
      {:ok, bidx} -> RateLimit.check(:token_request_account, :email_bidx, bidx)
      _ -> :ok
    end
  end

  defp mods(%Mount{} = mount) do
    %{
      credential: Mount.resource(mount, Credential),
      auth_token: Mount.resource(mount, AuthToken),
      repo: mount.repo
    }
  end

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
          phx-submit="request_reset"
        >
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
