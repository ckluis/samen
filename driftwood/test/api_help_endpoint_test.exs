defmodule Driftwood.ApiHelpEndpointTest do
  @moduledoc """
  The mounted `/api/help` and the error hints on the freight host, through the real top-level router and key plug.
  """
  use Driftwood.ApiCase, async: false
  use Samen.MaskingCase

  defmodule NoHints do
    @moduledoc "The API endpoint without the hint plug: the control for 'a success body is byte-identical'."
    use Plug.Builder

    plug(DriftwoodWeb.Api.KeyAuthPlug)
    plug(Samen.Web.Api.PageLimitClamp)
    plug(DriftwoodWeb.Api.Router)
  end

  defp router_call(conn), do: DriftwoodWeb.Router.call(conn, DriftwoodWeb.Router.init([]))

  defp help_get(path, key \\ nil, headers \\ []) do
    conn = Plug.Test.conn(:get, "/api/help" <> path)
    conn = if key, do: put_req_header(conn, "authorization", "Bearer " <> key), else: conn
    router_call(Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end))
  end

  defp v1_get(path, key) do
    Plug.Test.conn(:get, "/api/v1" <> path)
    |> put_req_header("accept", "application/vnd.api+json")
    |> put_req_header("authorization", "Bearer " <> key)
    |> router_call()
  end

  defp header(conn, name), do: conn |> get_resp_header(name) |> List.first()

  test "RED: no key is answered 401 with WWW-Authenticate: Bearer; CONTROL: a key is described its driver type" do
    {raw, _} = mk_api_key(mk_org(), scopes: %{"freight" => ["read"]})

    for path <- ["", "/driver", "/nope"] do
      conn = help_get(path)
      assert conn.status == 401
      assert header(conn, "www-authenticate") == "Bearer"
      refute conn.resp_body =~ "resources"
    end

    ok = help_get("", raw)
    assert ok.status == 200
    assert [%{"type" => "driver"}] = json(ok)["resources"]
  end

  test "RED: help for a hidden type and an unknown type is the same 404, byte for byte; CONTROL: the visible type answers" do
    {other, _} = mk_api_key(mk_org(), scopes: %{"freight.dispatch_event" => ["read"]})
    {raw, _} = mk_api_key(mk_org(), scopes: %{"freight.driver" => ["read"]})

    hidden = help_get("/driver", other)
    unknown = help_get("/nope", other)
    assert hidden.status == 404
    assert {hidden.status, hidden.resp_body} == {unknown.status, unknown.resp_body}
    assert help_get("/driver", raw).status == 200
  end

  test "RED: every help response is private, no-store; CONTROL: present on 200, 401 and 404" do
    {raw, _} = mk_api_key(mk_org(), scopes: %{"freight" => ["read"]})

    for conn <- [help_get("", raw), help_get("/driver", raw), help_get("/nope", raw), help_get("")] do
      assert header(conn, "cache-control") == "private, no-store"
      assert header(conn, "vary") =~ "Authorization"
    end
  end

  test "RED: an API error carries meta._hint and links.about; CONTROL: a 200 body is byte-identical with the plug" do
    org = mk_org()
    mk_driver(org)
    {raw, _} = mk_api_key(org, scopes: %{"freight" => ["read"]})
    {narrow, _} = mk_api_key(org, scopes: %{"other" => ["read"]})

    error = v1_get("/drivers", narrow)
    assert error.status == 403
    assert [%{"meta" => %{"_hint" => hint}, "links" => %{"about" => "/api/help"}}] = json(error)["errors"]
    assert hint =~ "GET /api/help"

    with_hints = v1_get("/drivers", raw)

    without =
      Plug.Test.conn(:get, "/api/v1/drivers")
      |> put_req_header("accept", "application/vnd.api+json")
      |> put_req_header("authorization", "Bearer " <> raw)
      |> Map.merge(%{script_name: ["api", "v1"], path_info: ["drivers"]})
      |> NoHints.call(NoHints.init([]))

    assert with_hints.status == 200
    assert without.resp_body == with_hints.resp_body
  end

  test "RED: an error on a hidden driver route links to /api/help; CONTROL: a visible one links to its own help" do
    {narrow, _} = mk_api_key(mk_org(), scopes: %{"freight.dispatch_event" => ["read"]})
    {raw, _} = mk_api_key(mk_org(), scopes: %{"freight" => ["read"]})

    assert [%{"links" => %{"about" => "/api/help"}}] = json(v1_get("/drivers", narrow))["errors"]
    visible = v1_get("/drivers/#{Ecto.UUID.generate()}", raw)
    assert visible.status == 404
    assert [%{"links" => %{"about" => "/api/help/driver"}}] = json(visible)["errors"]
  end

  describe "the HTML view, masked per plane (a driver with canary PII)" do
    @canary "CDL-ZXCANARY-8812"

    test "GREEN: the tenant page carries no canary; RED: the operator page shows the mask; TWIN: the scan is refutable" do
      org = mk_org()
      mk_driver(org, %{cdl_number: @canary})
      {tenant, _} = mk_api_key(org, plane: :tenant, scopes: %{"freight" => ["read"]})
      {operator, _} = mk_api_key(org, plane: :operator, scopes: %{"freight" => ["read"]})

      refute help_get("/driver?format=html", tenant).resp_body =~ @canary

      html = help_get("/driver", operator, [{"accept", "text/html"}]).resp_body
      assert_masked_dom!(html, [@canary])

      leaked = String.replace(html, "</body>", @canary <> "</body>")
      assert_leak_detected!(leaked, @canary)
      assert_raise ExUnit.AssertionError, fn -> assert_masked_dom!(leaked, [@canary]) end
    end
  end
end
