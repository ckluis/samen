defmodule Samen.Web.SecureHeadersTest do
  @moduledoc """
  ARCH-11 — the framework's browser security headers: clickjacking protection (CSP
  `frame-ancestors` + `x-frame-options`), a CSP that does not break the bundled assets, the
  LiveView websocket, the UI kit's inline styles or the session-replay player's srcdoc frame.
  """
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias Samen.Web.Replay.Renderer
  alias Samen.Web.SecureHeaders

  defp run(conn \\ conn(:get, "/"), opts \\ []), do: SecureHeaders.call(conn, SecureHeaders.init(opts))
  defp csp(conn), do: conn |> get_resp_header("content-security-policy") |> List.first()

  # Parse "a 'x' y; b z" into %{"a" => ["'x'", "y"], "b" => ["z"]}.
  defp directives(policy) do
    policy
    |> String.split(";", trim: true)
    |> Map.new(fn d ->
      [name | sources] = String.split(d, ~r/\s+/, trim: true)
      {name, sources}
    end)
  end

  test "RED: a browser response forbids framing by any other origin (clickjacking) and sniffing" do
    conn = run()

    assert directives(csp(conn))["frame-ancestors"] == ["'self'"]
    assert get_resp_header(conn, "x-frame-options") == ["SAMEORIGIN"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(conn, "referrer-policy") != []
  end

  test "the policy is conservative: no script-src widening, no eval, no remote origins by default" do
    d = directives(csp(run()))

    assert d["default-src"] == ["'self'"]
    assert d["script-src"] == ["'self'"]
    assert d["object-src"] == ["'none'"]
    assert d["base-uri"] == ["'self'"]

    all = d |> Map.values() |> List.flatten()
    refute "'unsafe-eval'" in all
    refute "*" in all
    refute Enum.any?(all, &String.starts_with?(&1, "http"))
    # inline style is the ONLY inline allowance (the kit's style="" attributes)
    assert "'unsafe-inline'" in d["style-src"]
    refute "'unsafe-inline'" in d["script-src"]
  end

  test "it keeps what the shared layout needs working: same-origin scripts, styles, fonts, websocket" do
    d = directives(csp(run()))

    for directive <- ["script-src", "style-src", "font-src", "connect-src", "img-src"] do
      assert "'self'" in d[directive], "#{directive} must allow the same origin (assets + LiveView socket)"
    end
  end

  test "SESSION REPLAY: the srcdoc frame's needs are all permitted by the parent policy it inherits" do
    parent = directives(csp(run()))
    frame = directives(Renderer.csp())

    # A srcdoc document inherits the embedding page's CSP IN ADDITION to its own: every source the
    # frame grants itself must also be granted by the parent, or the frame renders unstyled.
    for {directive, sources} <- frame, directive in ["style-src", "img-src", "font-src"], source <- sources do
      allowed = parent[directive] || parent["default-src"]

      assert source in allowed,
             "replay frame needs #{directive} #{source}, but the page policy only allows #{inspect(allowed)}"
    end

    # And the frame stays inert: the parent never grants it script or frames.
    refute "'unsafe-inline'" in parent["script-src"]
  end

  test "HSTS only on https; a host-set CSP is left alone" do
    assert get_resp_header(run(), "strict-transport-security") == []

    https = run(%{conn(:get, "/") | scheme: :https})
    assert [hsts] = get_resp_header(https, "strict-transport-security")
    assert hsts =~ "max-age="

    own = conn(:get, "/") |> put_resp_header("content-security-policy", "default-src 'none'") |> run()
    assert csp(own) == "default-src 'none'"
  end

  test "a host extends the policy per directive (merged, never replaced) via opts or config" do
    d = directives(csp(run(conn(:get, "/"), csp: %{"img-src" => ["https://tiles.example.com"]})))
    assert "https://tiles.example.com" in d["img-src"]
    assert "'self'" in d["img-src"]

    prev = Application.get_env(:samen_web, SecureHeaders)
    Application.put_env(:samen_web, SecureHeaders, csp: %{"connect-src" => ["https://api.example.com"]})
    on_exit(fn -> if prev, do: Application.put_env(:samen_web, SecureHeaders, prev), else: Application.delete_env(:samen_web, SecureHeaders) end)

    d = directives(csp(run()))
    assert d["connect-src"] == ["'self'", "https://api.example.com"]
  end
end
