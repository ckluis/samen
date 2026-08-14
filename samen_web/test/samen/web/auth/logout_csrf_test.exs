defmodule Samen.Web.Auth.LogoutCsrfTest do
  @moduledoc """
  Verifier R6 — `GET /logout` was a state-changing GET: it REVOKED the current
  `Identity.Session` row, wrote an `auth.logout` audit event, and renewed the
  session — the exact CSRF-forgeable/prefetch-triggerable class S7 closed for the
  org switch. An attacker page's `<img src="/logout">` (or a link-hover
  prefetcher) could end a signed-in viewer's session with no click and no token.

  The fix (same shape as S7): `samen_auth_routes()` binds the logout WRITE to
  `POST /logout` (CSRF-protected by the host `:browser` pipeline's
  `protect_from_forgery`) and keeps `GET /logout` as a stale-safe landing
  (`SessionController.stale_logout_get/2`) that redirects WITHOUT revoking,
  auditing, clearing cookies, or renewing.

  Proven through the REAL `samen_auth_routes` macro over a real
  `protect_from_forgery` pipeline, against REAL `Identity.Session` + `aud_event`
  rows:

    * **RED (the R6 attack)** — a GET to `/logout` with a live session leaves the
      session row ALIVE (still resolvable by token), writes NO `auth.logout`
      audit event, and keeps the session cookie's principal intact.
    * **Positive control (anti-tautology)** — the POST path with a session-valid
      `_csrf_token` revokes the row (token no longer resolves) AND writes the
      `identity.auth.logout` audit event: the logout write still exists, so the
      RED test cannot pass because the endpoint went dead.
    * **CSRF control (non-vacuous protection)** — the same POST WITHOUT a token
      is refused by `protect_from_forgery` and the session row stays alive.
    * **Route-shape floor** — GET→`stale_logout_get` / POST→`delete`, so a
      regressed macro (GET bound back to the write) fails loudly.
  """
  use Samen.WebTest.DataCase, async: false

  import Plug.Test

  alias Samen.Auth.SessionCreate
  alias Samen.Auth.SessionResolve
  alias Samen.AuditEvent
  alias Samen.Identity.Register
  alias Samen.WebTest.Operator.AuthToken
  alias Samen.WebTest.Operator.Credential
  alias Samen.WebTest.Operator.Membership
  alias Samen.WebTest.Operator.Org
  alias Samen.WebTest.Operator.Session
  alias Samen.WebTest.Operator.User

  defmodule Router do
    @moduledoc false
    use Phoenix.Router
    import Phoenix.LiveView.Router
    import Samen.Web.Router

    # The REAL host shape: session + CSRF (driftwood/pawchart routers, both
    # generated router templates).
    pipeline :browser do
      plug(:accepts, ["html"])
      plug(:fetch_session)
      plug(:protect_from_forgery)
    end

    scope "/" do
      pipe_through(:browser)
      samen_auth_routes(namespace: Samen.WebTest.Operator, repo: Samen.WebTest.Repo)
    end
  end

  @secret_key_base String.duplicate("r", 64)
  @session_opts Plug.Session.init(
                  store: :cookie,
                  key: "_samen_logout_probe",
                  signing_salt: "r6-salt",
                  encryption_salt: "r6-esalt"
                )
  @parser_opts Plug.Parsers.init(parsers: [:urlencoded], pass: ["*/*"])

  defp register_mods,
    do: %{org: Org, credential: Credential, user: User, membership: Membership, auth_token: AuthToken, repo: Repo}

  defp session_create_mods, do: %{session: Session, org: Org, membership: Membership, user: User}

  defp register! do
    attrs = %{
      org_name: "LogoutCsrf Co #{System.unique_integer([:positive])}",
      first_name: "Ada",
      last_name: "Lovelace",
      email: "logoutcsrf-#{System.unique_integer([:positive])}@example.test",
      password: "correct horse battery staple"
    }

    {:ok, result} = Register.register(attrs, register_mods())
    result
  end

  # A signed-in viewer: a REAL minted Identity.Session row, its raw token in the
  # Plug session — exactly what `Auth.resolve_principal/2` reads.
  defp signed_in!(credential_id) do
    {:ok, _session, raw} = SessionCreate.create(session_create_mods(), credential_id)
    raw
  end

  defp dispatch(method, path, opts) do
    conn =
      conn(method, path, opts[:body])
      |> Map.put(:secret_key_base, @secret_key_base)
      |> then(fn conn ->
        Enum.reduce(opts[:headers] || [], conn, fn {k, v}, c -> Plug.Conn.put_req_header(c, k, v) end)
      end)
      |> Plug.Parsers.call(@parser_opts)
      |> Plug.Session.call(@session_opts)
      |> Plug.Conn.fetch_session()
      |> then(fn conn ->
        Enum.reduce(opts[:session] || %{}, conn, fn {k, v}, c -> Plug.Conn.put_session(c, k, v) end)
      end)

    Router.call(conn, Router.init([]))
  end

  # A `{masked_token, unmasked_session_value}` pair, exactly as a real request
  # that rendered a logout form would have established them.
  defp csrf_pair do
    Plug.CSRFProtection.delete_csrf_token()
    masked = Plug.CSRFProtection.get_csrf_token()
    unmasked = Plug.CSRFProtection.dump_state()
    Plug.CSRFProtection.delete_csrf_token()
    {masked, unmasked}
  end

  defp session_alive?(raw), do: match?({:ok, _}, SessionResolve.resolve(Session, raw))

  defp logout_audited?(credential_id) do
    Repo
    |> AuditEvent.for_subject(credential_id)
    |> Enum.any?(&(&1.detail == "identity.auth.logout"))
  end

  test "RED (R6): a GET to /logout does NOT log out — session row alive, no audit event, principal intact" do
    result = register!()
    raw = signed_in!(result.credential.id)

    conn =
      dispatch(:get, "/logout", session: %{Samen.Web.Auth.session_token_key() => raw})

    # Bounced (stale-safe landing)…
    assert conn.status == 302
    # …but NOTHING was logged out: the session row still resolves,
    assert session_alive?(raw)
    # no auth.logout audit event was written,
    refute logout_audited?(result.credential.id)
    # and the viewer's principal is still in the (un-renewed, un-cleared) session.
    assert Plug.Conn.get_session(conn, Samen.Web.Auth.session_token_key()) == raw
  end

  test "POSITIVE CONTROL: the POST path with a session-valid CSRF token revokes AND audits" do
    result = register!()
    raw = signed_in!(result.credential.id)
    {masked, unmasked} = csrf_pair()

    conn =
      dispatch(:post, "/logout",
        session: %{"_csrf_token" => unmasked, Samen.Web.Auth.session_token_key() => raw},
        headers: [{"x-csrf-token", masked}]
      )

    assert conn.status == 302
    refute session_alive?(raw)
    assert logout_audited?(result.credential.id)
  end

  test "CSRF CONTROL: the same POST WITHOUT a token is refused — session row stays alive" do
    result = register!()
    raw = signed_in!(result.credential.id)

    err =
      assert_raise Plug.Conn.WrapperError, fn ->
        dispatch(:post, "/logout", session: %{Samen.Web.Auth.session_token_key() => raw})
      end

    assert %Plug.CSRFProtection.InvalidCSRFTokenError{} = err.reason
    assert session_alive?(raw)
    refute logout_audited?(result.credential.id)
  end

  test "ROUTE-SHAPE FLOOR: GET binds to stale_logout_get, POST binds to delete" do
    assert %{plug: Samen.Web.Auth.SessionController, plug_opts: :stale_logout_get} =
             Phoenix.Router.route_info(Router, "GET", "/logout", "host")

    assert %{plug: Samen.Web.Auth.SessionController, plug_opts: :delete} =
             Phoenix.Router.route_info(Router, "POST", "/logout", "host")
  end
end
