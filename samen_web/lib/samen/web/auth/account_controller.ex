defmodule Samen.Web.Auth.AccountController do
  @moduledoc """
  ADR-035 §5 A1/A3/A5 — the framework's PRE-ACTOR account-mutation endpoints,
  the no-JS HTTP fallbacks for the identity-spine LiveViews.

  Since ADR-042 the platform DOES ship a LiveView client (`Samen.Web.Layouts`),
  so with JS these forms are enhanced-in-place and the socket connects. But this
  auth/first-run/recovery spine is **Class A** (ADR-042 §5): its controller-POST
  fallback is a BINDING no-JS floor — with JavaScript disabled or broken a user
  MUST still be able to sign up, get in, and recover the account, so every
  `phx-submit` form here also carries a real HTML submit that POSTs to these
  actions. `Samen.Web.Auth.LoginLive` + `Samen.Web.Auth.SessionController`
  already solve this for A4 sign-in — the form carries a REAL `action` +
  `method="post"` so a no-JS browser POSTs it natively, and the controller
  re-runs the mutation server-side (never trusting a client-only check). This
  controller extends that SAME precedent to the pre-actor identity surfaces the
  `SessionController` pattern was never applied to:

    * `POST /signup`         → `register/2`      — `Samen.Identity.Register.register/2` (A1)
    * `POST /reset`          → `request_reset/2`  — `Samen.Identity.Reset.request/2` (A3)
    * `POST /reset/:token`   → `reset/2`          — `Samen.Identity.Reset.consume/3` (A3)
    * `POST /invite/:token`  → `accept_invite/2`  — `Samen.Identity.Invite.accept/3` (A5)

  Mounted by `Samen.Web.Router.samen_auth_routes/1`; each route's `private:`
  carries the host's `%Samen.Web.Mount{}` (built once at router-compile time)
  plus the surface paths, so the controller never hardcodes a host module —
  the same per-host parameterization `SessionController` uses.

  ## Security invariant (T110) — no credential in a URL, ever

  Every credential/token BODY value (`registration[password]`, the new/reset
  password, the invite password) rides the POST **body**, never a query string.
  This controller only ever `redirect/2`s to a path plus NON-secret status
  flags (`?registered=1`, `?error=weak_password`, `?reset=1`, `?joined=1`),
  never echoing a password/token into the redirect target. Verify/reset/invite
  tokens that are PART of the URL path (`/reset/:token`, `/invite/:token`) are
  how the token *arrives* — legitimate, unchanged here.

  ## Rate limiting lives HERE (the real enforcement point)

  A no-JS POST hits this controller directly, bypassing the LiveView entirely,
  so the ADR-038 §6.3 brute-force limits (`:registration_ip`,
  `:token_request_account`) are enforced HERE — the authoritative site — not
  only in the LiveView's inline-validation `handle_event`. The LiveViews keep a
  cheap password-length pre-check purely for the JS-connected inline UX.

  ## No account-existence oracle (ADR-035 §5 A1/A3)

  Registration and reset-request return the SAME generic outcome whether or not
  the email already exists — `register/2` redirects to `?registered=1` for both
  a fresh signup AND a duplicate (`Register.register/2`'s `:registered` and
  `:duplicate` collapse to one `{:ok, _}` shape); `request_reset/2` always
  redirects to `?requested=1`. A weak password is the one non-oracle-leaking
  distinguishable rejection.
  """
  use Phoenix.Controller, formats: [:html]

  import Plug.Conn

  alias Samen.Identity.Invite
  alias Samen.Identity.Register
  alias Samen.Identity.Reset
  alias Samen.Web.Mount
  alias Samen.Web.RateLimit

  # -- A1 registration --------------------------------------------------------

  @doc """
  `POST /signup`. Params: `registration[org_name|first_name|last_name|email|password]`.
  Enforces the `:registration_ip` limit (5/hr per IP, ADR-038 §6.3) HERE — the
  no-JS path never runs the LiveView's guard — then the atomic A1 transaction.
  Redirects to the signup page with a NON-secret status flag: `?registered=1`
  (fresh OR duplicate — no oracle), `?error=weak_password`, `?error=rate_limited`,
  or `?error=1`. The password never leaves the POST body.
  """
  def register(conn, %{"registration" => params}) do
    mount = conn.private.samen_mount
    path = signup_path(conn)

    case RateLimit.check(:registration_ip, :ip, remote_ip(conn)) do
      {:error, :rate_limited} ->
        redirect(conn, to: "#{path}?error=rate_limited")

      :ok ->
        attrs = %{
          org_name: trim(params["org_name"]),
          first_name: trim(params["first_name"]),
          last_name: trim(params["last_name"]),
          email: trim(params["email"]),
          password: params["password"] || ""
        }

        case Register.register(attrs, register_mods(mount)) do
          {:ok, %{status: status}} when status in [:registered, :duplicate] ->
            redirect(conn, to: "#{path}?registered=1")

          {:error, :weak_password} ->
            redirect(conn, to: "#{path}?error=weak_password")

          {:error, _reason} ->
            redirect(conn, to: "#{path}?error=1")
        end
    end
  end

  def register(conn, _params), do: redirect(conn, to: "#{signup_path(conn)}?error=1")

  # -- A3 password reset ------------------------------------------------------

  @doc """
  `POST /reset`. Params: `reset[email]`. Enforces the `:token_request_account`
  limit (3/15min per `email_bidx`) HERE, then mints+dispatches the reset token
  via `Reset.request/2`. ALWAYS redirects to `?requested=1` — the uniform
  no-oracle outcome whether or not the account exists (the email is never
  echoed to the URL).
  """
  def request_reset(conn, %{"reset" => %{"email" => email}}) do
    path = reset_path(conn)
    mount = conn.private.samen_mount
    email = trim(email)

    case reset_rate_limit(email) do
      {:error, :rate_limited} ->
        # `?throttled=1` is NOT an account-existence oracle: the limiter keys on
        # the SUPPLIED `email_bidx` and fires identically whether or not that
        # email has an account (same posture as the uniform copy). It only tells
        # the caller "you've asked too often" — the SAME signal the pre-T110
        # LiveView already surfaced.
        redirect(conn, to: "#{path}?throttled=1")

      :ok ->
        _ = Reset.request(email, reset_request_mods(mount))
        redirect(conn, to: "#{path}?requested=1")
    end
  end

  def request_reset(conn, _params), do: redirect(conn, to: "#{reset_path(conn)}?requested=1")

  @doc """
  `POST /reset/:token`. Params: `reset[password]` (the NEW password, in the
  body) plus the reset `:token` in the URL path (how the link arrives — a path
  token, not a query-string credential). Runs the atomic A3 consume
  (`Reset.consume/3`: rehash, revoke every session, audit). Redirects to
  `/reset/:token` with a status flag: `?reset=1`, `?error=weak_password`,
  `?error=invalid_token`, or `?error=1`. The new password never leaves the body.
  """
  def reset(conn, %{"token" => token, "reset" => %{"password" => password}}) do
    mount = conn.private.samen_mount
    base = "#{reset_path(conn)}/#{token}"

    case Reset.consume(token, password, reset_mods(mount)) do
      {:ok, _credential} ->
        redirect(conn, to: "#{base}?reset=1")

      {:error, :weak_password} ->
        redirect(conn, to: "#{base}?error=weak_password")

      {:error, :invalid_token} ->
        redirect(conn, to: "#{base}?error=invalid_token")

      {:error, _reason} ->
        redirect(conn, to: "#{base}?error=1")
    end
  end

  def reset(conn, %{"token" => token}), do: redirect(conn, to: "#{reset_path(conn)}/#{token}?error=1")

  # -- A5 invitation accept ---------------------------------------------------

  @doc """
  `POST /invite/:token`. Params: `accept[password]` (the new member's password,
  in the body) plus the invite `:token` in the URL path. Runs the atomic A5
  accept (`Invite.accept/3` — mints the pre-verified credential + membership).
  Redirects to `/invite/:token` with a status flag: `?joined=1`,
  `?error=weak_password` (also the `:password_required` case — the form is
  re-shown), or `?error=<terminal>` for expired/revoked/already-accepted. The
  password never leaves the body.
  """
  def accept_invite(conn, %{"token" => token, "accept" => %{"password" => password}}) do
    mount = conn.private.samen_mount
    base = "#{invite_path(conn)}/#{token}"

    case Invite.accept(invite_mods(mount), token, password: password) do
      {:ok, _joined} ->
        redirect(conn, to: "#{base}?joined=1")

      {:error, reason} when reason in [:weak_password, :password_required] ->
        redirect(conn, to: "#{base}?error=weak_password")

      {:error, reason} ->
        redirect(conn, to: "#{base}?error=#{invite_error_code(reason)}")
    end
  end

  def accept_invite(conn, %{"token" => token}), do: redirect(conn, to: "#{invite_path(conn)}/#{token}?error=1")

  # -- private: mods (mirror the LiveViews' own `mods/1`) ----------------------

  defp register_mods(%Mount{} = mount) do
    %{
      org: Mount.resource(mount, Org),
      credential: Mount.resource(mount, Credential),
      user: Mount.resource(mount, User),
      membership: Mount.resource(mount, Membership),
      auth_token: Mount.resource(mount, AuthToken),
      repo: mount.repo
    }
  end

  defp reset_request_mods(%Mount{} = mount) do
    %{
      credential: Mount.resource(mount, Credential),
      auth_token: Mount.resource(mount, AuthToken),
      repo: mount.repo
    }
  end

  defp reset_mods(%Mount{} = mount) do
    %{
      credential: Mount.resource(mount, Credential),
      auth_token: Mount.resource(mount, AuthToken),
      session: Mount.resource(mount, Session),
      user: Mount.resource(mount, User),
      repo: mount.repo
    }
  end

  defp invite_mods(%Mount{} = mount) do
    %{
      invitation: Mount.resource(mount, Invitation),
      credential: Mount.resource(mount, Credential),
      user: Mount.resource(mount, User),
      membership: Mount.resource(mount, Membership),
      repo: mount.repo
    }
  end

  # -- private ----------------------------------------------------------------

  defp reset_rate_limit(email) do
    case Samen.Auth.BlindIndex.compute(email) do
      {:ok, bidx} -> RateLimit.check(:token_request_account, :email_bidx, bidx)
      _ -> :ok
    end
  end

  defp invite_error_code(:expired), do: "expired"
  defp invite_error_code(:revoked), do: "revoked"
  defp invite_error_code(:already_accepted), do: "already_accepted"
  defp invite_error_code(_), do: "invalid"

  defp signup_path(conn), do: conn.private[:samen_signup_path] || "/signup"
  defp reset_path(conn), do: conn.private[:samen_reset_path] || "/reset"
  defp invite_path(conn), do: conn.private[:samen_invite_path] || "/invite"

  defp remote_ip(%Plug.Conn{remote_ip: ip}) when is_tuple(ip), do: ip |> :inet.ntoa() |> to_string()
  defp remote_ip(_), do: "unknown"

  defp trim(v) when is_binary(v), do: String.trim(v)
  defp trim(_), do: nil
end
