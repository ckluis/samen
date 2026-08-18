defmodule Samen.Web.Auth.ConfirmLive do
  @moduledoc """
  A2 — Email verification consume loop (ADR-035 §5 A2). Mounted at
  `GET /verify/:token` by `Samen.Web.Router.samen_auth_routes/1`. **Pre-actor
  public** (ADR-035 §6): no org data rendered.

  On the disconnected (dead) render mount, consumes the raw `:token` path param
  through `Samen.Identity.Confirm.consume/2` — a single atomic, single-use,
  expiring token consume (`Samen.Auth.TokenConsume`) that sets
  `Credential.verified_at` on success — and then **redirects** to a NON-secret
  `?verified=1` / `?error=invalid_token` status flag. `{:error, :invalid_token}`
  renders the SAME generic "this link is invalid or has expired" copy whether
  the token was never real, already consumed, or expired — no distinguishing
  oracle.

  ## Double-mount guard (T126, ADR-042)

  Since ADR-042 the platform ships a real LiveSocket client, so a `live(...)`
  route mounts TWICE in a browser: the disconnected (dead) HTTP render, then the
  connected socket join. A naive consume-on-EVERY-mount consumed the token on the
  dead render (success) and RE-consumed the now-spent token on the connected
  mount (`{:error, :invalid_token}`) — the connected render is authoritative, so
  a real user saw a FALSE "Couldn't verify this link" even though the account WAS
  verified server-side (the T49 dogfood re-walk regression).

  The fix mirrors the T110 controller-POST paths (`AccountController`): the
  mutating consume runs EXACTLY ONCE on the dead render, then `redirect/2`s to a
  `?verified=1` / `?error=invalid_token` status flag. Because the dead render
  returns a 302, no socket ever connects to `/verify/:token`, so the connected
  re-mount never fires a second consume. The redirect target's own dead+connected
  double-mount is inert — it only READS the flag (`verified?/error` clauses
  below). Single-use is UNWEAKENED: a genuine second click is a separate request
  whose consume legitimately fails → `?error=invalid_token`. No-JS is unbroken:
  the dead render still consumes and the 302 + status render both work without a
  socket.
  """
  use Phoenix.LiveView

  alias Samen.Identity.Confirm
  alias Samen.Web.Mount

  # Status-flag render clauses (the redirect target) — flag-first so
  # `/verify/:token?verified=1` reads the flag and NEVER re-runs the consume.
  @impl true
  def mount(%{"verified" => "1"}, session, socket) do
    socket = Samen.Web.Live.assign_mount(socket, session)
    {:ok, assign(socket, verified?: true, error: nil)}
  end

  def mount(%{"error" => code}, session, socket) do
    socket = Samen.Web.Live.assign_mount(socket, session)
    {:ok, assign(socket, verified?: false, error: consume_error_code(code))}
  end

  def mount(%{"token" => token}, session, socket) do
    socket = Samen.Web.Live.assign_mount(socket, session)
    mount = socket.assigns.samen_mount

    # The ONE mutating consume, on the dead render only, then redirect to the
    # status flag (see moduledoc "Double-mount guard").
    flag =
      case Confirm.consume(token, mods(mount)) do
        {:ok, _} -> "verified=1"
        {:error, :invalid_token} -> "error=invalid_token"
      end

    {:ok, redirect(socket, to: "#{verify_action(mount, token)}?#{flag}")}
  end

  # Generic, no-oracle copy — an absent, expired, wrong-context, or
  # already-consumed token all collapse to the SAME message.
  defp consume_error_code(_code), do: "This link is invalid or has expired."

  defp verify_action(%Mount{} = mount, token), do: "#{Mount.label(mount, :verify_path, "/verify")}/#{token}"

  defp mods(%Mount{} = mount) do
    %{
      credential: Mount.resource(mount, Credential),
      auth_token: Mount.resource(mount, AuthToken),
      # ADR-035 §5 A10 (T09) — optional notify seam (`Samen.Identity.Confirm`'s
      # `mods[:user]`): wires the real `GET /verify/:token` surface to the
      # welcome notification, in addition to the existing `email_verified` audit.
      user: Mount.resource(mount, User),
      repo: mount.repo
    }
  end

  # -- render ------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div id="auth-confirm" class="wrap" style="max-width:420px;margin:60px auto">
      <div class="card" style="padding:28px 24px">
        <h2 :if={@verified?} id="confirm-ok" style="margin:0 0 4px">Email verified</h2>
        <p :if={@verified?} style="margin:0;color:var(--muted)">
          Your email address is confirmed — you're all set.
        </p>

        <h2 :if={not @verified?} id="confirm-error-title" style="margin:0 0 4px">
          Couldn't verify this link
        </h2>
        <p :if={not @verified?} id="confirm-error" style="margin:0;color:#B91C1C">{@error}</p>
      </div>
    </div>
    """
  end
end
