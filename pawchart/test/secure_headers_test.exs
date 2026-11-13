defmodule PawChartWeb.SecureHeadersTest do
  @moduledoc """
  ARCH-11 — PawChart's browser pipeline inherits the framework's secure headers
  (`Samen.Web.SecureHeaders`) at 0 authored LOC beyond the one `plug` line, and its session cookie
  is `Secure` in prod only.
  """
  use PawChart.DataCase, async: false

  import Phoenix.ConnTest

  @endpoint PawChartWeb.Endpoint
  @config Path.expand("../config/config.exs", __DIR__)

  setup do
    start_supervised!(PawChartWeb.Endpoint)
    :ok
  end

  test "a public browser page carries the CSP (frame-ancestors 'self') and x-frame-options" do
    conn = get(build_conn(), "/signup")

    assert html_response(conn, 200)
    [csp] = Plug.Conn.get_resp_header(conn, "content-security-policy")
    assert csp =~ "frame-ancestors 'self'"
    assert csp =~ "script-src 'self'"
    assert Plug.Conn.get_resp_header(conn, "x-frame-options") == ["SAMEORIGIN"]
    assert Plug.Conn.get_resp_header(conn, "x-content-type-options") == ["nosniff"]
  end

  test "the session cookie is Secure in prod and not in dev/test (plain http)" do
    prod = Config.Reader.read!(@config, env: :prod, target: :host)
    dev = Config.Reader.read!(@config, env: :dev, target: :host)

    assert get_in(prod, [:pawchart, :secure_session_cookie]) == true
    refute get_in(dev, [:pawchart, :secure_session_cookie])
  end
end
