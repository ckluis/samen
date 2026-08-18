defmodule Samen.Web.SessionOrgCsrfTest do
  @moduledoc """
  Luminary S7/S16 — the org switch is a STATE CHANGE and must not ride a forgeable GET.

  `GET /session/org/:org_id` used to write `session["samen_current_org"]` directly: an
  attacker page could flip a logged-in operator's current org with `<img
  src="/session/org/X">` (CSRF), and a link-hover prefetcher could mutate the session
  without any click. The fix: `samen_session_routes()` now binds the session write to
  `POST` (CSRF-protected by the host `:browser` pipeline's `protect_from_forgery`)
  and keeps the GET path as a STALE-SAFE landing (`SessionController.stale_get/2`)
  that redirects WITHOUT touching the session.

  Proven here through the REAL route macro over a real `protect_from_forgery`
  pipeline (the driftwood/pawchart/generated-app `:browser` shape — this suite would
  be vacuous against a pipeline without the CSRF plug):

    * **RED (the S7 attack)** — a GET to the old URL does NOT switch the org: a
      session already on org A stays on org A, an empty session stays empty; the
      viewer is bounced to the sanitized `return_to`, nothing is written.
    * **Positive control (anti-tautology)** — the POST path with a session-valid
      `_csrf_token` DOES switch the org (the write still exists; the GET test cannot
      pass because the whole endpoint went dead).
    * **CSRF control (non-vacuous protection)** — the same POST WITHOUT a token is
      REFUSED by `protect_from_forgery` and the session org stays unchanged: the
      POST conversion actually bought CSRF protection, not just a verb change.
    * **Route-shape floor** — `route_info/4` proves GET→`stale_get` / POST→
      `put_current_org`, so a regressed macro (GET bound back to the write) fails
      loudly even if dispatch semantics drift.
  """
  use ExUnit.Case, async: true

  import Plug.Test

  alias Samen.Web.CurrentOrg

  defmodule Router do
    @moduledoc false
    use Phoenix.Router
    import Samen.Web.Router

    # The REAL host shape: session + CSRF (driftwood router.ex:94, pawchart
    # router.ex:114, both generated router templates).
    pipeline :browser do
      plug(:accepts, ["html"])
      plug(:fetch_session)
      plug(:protect_from_forgery)
    end

    scope "/" do
      pipe_through(:browser)
      samen_session_routes()
    end
  end

  @org_a "11111111-0000-4000-8000-00000000000a"
  @org_b "11111111-0000-4000-8000-00000000000b"

  @session_opts Plug.Session.init(
                  store: :cookie,
                  key: "_samen_csrf_probe",
                  signing_salt: "s7-salt",
                  encryption_salt: "s7-esalt"
                )
  @parser_opts Plug.Parsers.init(parsers: [:urlencoded], pass: ["*/*"])

  # A conn as the host endpoint hands the router: parsed params + session installed.
  # `session` seeds pre-existing session state (e.g. the CURRENT org before the attack).
  defp dispatch(method, path, opts \\ []) do
    conn =
      conn(method, path, opts[:body])
      |> Map.put(:secret_key_base, String.duplicate("s", 64))
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

  # A `{masked_token, unmasked_session_value}` pair, exactly as a real request that
  # rendered the switcher form would have established them.
  defp csrf_pair do
    Plug.CSRFProtection.delete_csrf_token()
    masked = Plug.CSRFProtection.get_csrf_token()
    unmasked = Plug.CSRFProtection.dump_state()
    Plug.CSRFProtection.delete_csrf_token()
    {masked, unmasked}
  end

  test "RED (S7): a GET to /session/org/:org_id does NOT switch the org — session org unchanged" do
    # The victim's session is on org A; the attacker lures a GET for org B.
    conn = dispatch(:get, "/session/org/#{@org_b}?return_to=%2Fbilling%2Finvoices",
             session: %{CurrentOrg.session_key() => @org_a}
           )

    # Bounced to the sanitized return_to…
    assert conn.status == 302
    assert Plug.Conn.get_resp_header(conn, "location") == ["/billing/invoices"]
    # …and the session org did NOT move: still the victim's own org, never org B.
    assert Plug.Conn.get_session(conn, CurrentOrg.session_key()) == @org_a
  end

  test "RED (S7): a stale GET with NO prior session org writes nothing (prefetch is a no-op)" do
    conn = dispatch(:get, "/session/org/#{@org_b}")

    assert conn.status == 302
    assert Plug.Conn.get_session(conn, CurrentOrg.session_key()) == nil
  end

  test "POSITIVE CONTROL: the POST path with a session-valid CSRF token DOES switch the org" do
    {masked, unmasked} = csrf_pair()

    conn =
      dispatch(:post, "/session/org/#{@org_b}?return_to=%2Fbilling%2Finvoices",
        session: %{"_csrf_token" => unmasked, CurrentOrg.session_key() => @org_a},
        headers: [{"x-csrf-token", masked}]
      )

    assert conn.status == 302
    assert Plug.Conn.get_resp_header(conn, "location") == ["/billing/invoices"]
    assert Plug.Conn.get_session(conn, CurrentOrg.session_key()) == @org_b
  end

  test "CSRF CONTROL: the same POST WITHOUT a token is refused — the protection is real" do
    # The router (a plug) wraps the raise in Plug.Conn.WrapperError; the REASON is the
    # CSRF refusal (a real endpoint turns it into a 403, never a session write).
    err =
      assert_raise Plug.Conn.WrapperError, fn ->
        dispatch(:post, "/session/org/#{@org_b}",
          session: %{CurrentOrg.session_key() => @org_a}
        )
      end

    assert %Plug.CSRFProtection.InvalidCSRFTokenError{} = err.reason
  end

  test "ROUTE-SHAPE FLOOR: GET binds to stale_get, POST binds to put_current_org" do
    assert %{plug: Samen.Web.SessionController, plug_opts: :stale_get} =
             Phoenix.Router.route_info(Router, "GET", "/session/org/#{@org_b}", "host")

    assert %{plug: Samen.Web.SessionController, plug_opts: :put_current_org} =
             Phoenix.Router.route_info(Router, "POST", "/session/org/#{@org_b}", "host")
  end
end
