defmodule Demo.ApiHelpEndpointTest do
  @moduledoc """
  The mounted `/api/help` (`Samen.Api.Help.Endpoint`) and the error hints (`Samen.Api.Help.ErrorHints`), through the
  real top-level router and key plug: who is answered, what they are told, what is never said, and that a response
  that is not an error is not touched.
  """
  use Demo.ApiCase, async: false
  use Samen.MaskingCase

  import ExUnit.CaptureLog

  defmodule NoHints do
    @moduledoc "The API endpoint without the hint plug: the control for 'a success body is byte-identical'."
    use Plug.Builder

    plug(DemoWeb.Api.KeyAuthPlug)
    plug(DemoWeb.Api.PageLimitClamp)
    plug(DemoWeb.Api.Router)
  end

  defp help_get(path, key \\ nil, headers \\ []) do
    conn = Plug.Test.conn(:get, "/api/help" <> path)
    conn = if key, do: put_req_header(conn, "authorization", "Bearer " <> key), else: conn
    conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    DemoWeb.Router.call(conn, DemoWeb.Router.init([]))
  end

  defp header(conn, name), do: conn |> get_resp_header(name) |> List.first()

  describe "who is answered" do
    test "RED: no key is answered 401 with WWW-Authenticate: Bearer and no description; CONTROL: a key is answered 200" do
      org = mk_org("Auth")
      {raw, _} = mk_api_key(org.id, scopes: %{"crm" => ["read"]})

      for path <- ["", "/contact", "/no_such_type"] do
        conn = help_get(path)
        assert conn.status == 401
        assert header(conn, "www-authenticate") == "Bearer"
        refute conn.resp_body =~ "contact" and path == ""
        refute conn.resp_body =~ "resources"
      end

      bad = help_get("", "sk_not_a_real_key")
      assert bad.status == 401

      ok = help_get("", raw)
      assert ok.status == 200
      assert %{"resources" => [%{"type" => "contact"}]} = json(ok)
    end

    test "RED: a key with no scopes is described nothing; CONTROL: a scoped key is described its resource" do
      org = mk_org("Empty")
      {empty, _} = mk_api_key(org.id, scopes: %{})
      conn = help_get("", empty)

      assert conn.status == 200
      assert json(conn)["resources"] == []
      assert json(conn)["caller"]["scopes"] == %{}
    end

    test "only GET and HEAD are served" do
      org = mk_org("Method")
      {raw, _} = mk_api_key(org.id, scopes: %{"crm" => ["read"]})

      conn =
        Plug.Test.conn(:post, "/api/help")
        |> put_req_header("authorization", "Bearer " <> raw)
        |> then(&DemoWeb.Router.call(&1, DemoWeb.Router.init([])))

      assert conn.status == 405
      assert header(conn, "allow") == "GET, HEAD"
    end
  end

  describe "a hidden type" do
    test "RED: help for a hidden type and for an unknown type is the same 404, byte for byte; CONTROL: a visible type answers" do
      org = mk_org("Hidden")
      {raw, _} = mk_api_key(org.id, scopes: %{"crm" => ["read"]})

      hidden = help_get("/user", raw)
      unknown = help_get("/no_such_type", raw)

      assert hidden.status == 404
      assert {hidden.status, hidden.resp_body, hidden.resp_headers -- [{"x-request-id", header(hidden, "x-request-id")}]} ==
               {unknown.status, unknown.resp_body, unknown.resp_headers -- [{"x-request-id", header(unknown, "x-request-id")}]}

      refute hidden.resp_body =~ "user"
      assert help_get("/contact", raw).status == 200
    end

    test "RED: an error on a hidden resource links to /api/help, never to its type; CONTROL: a visible one links to its own" do
      org = mk_org("Link")
      {raw, _} = mk_api_key(org.id, scopes: %{"crm" => ["read"]})

      hidden = api_get("/users", raw)
      assert hidden.status == 403
      assert [%{"links" => %{"about" => "/api/help"}, "meta" => %{"help" => "/api/help"}}] = json(hidden)["errors"]
      refute hidden.resp_body =~ "/api/help/user"

      # a visible type that answers an error (an unknown id is a 404) links to its own help
      visible = api_get("/contacts/#{Ecto.UUID.generate()}", raw)
      assert visible.status == 404
      assert [%{"links" => %{"about" => "/api/help/contact"}, "meta" => %{"help" => "/api/help/contact"}}] = json(visible)["errors"]
    end
  end

  describe "error hints" do
    test "RED: an API error carries meta._hint and links.about; CONTROL: a 200 body is byte-identical with the plug" do
      org = mk_org("Hints")
      mk_contact(org.id, %{display_name: "Row"})
      {raw, _} = mk_api_key(org.id, scopes: %{"crm" => ["read"], "identity" => ["read"]})
      {narrow, _} = mk_api_key(org.id, scopes: %{"identity" => ["read"]})

      error = api_get("/contacts", narrow)
      assert error.status == 403
      assert [%{"code" => "forbidden", "meta" => %{"_hint" => hint}, "links" => %{"about" => about}}] = json(error)["errors"]
      assert hint =~ "GET /api/help lists the actions"
      assert about == "/api/help"
      assert json(error)["jsonapi"] == %{"version" => "1.0"}

      for path <- ["/contacts", "/orgs", "/users"] do
        with_hints = api_get(path, raw)
        assert with_hints.status == 200

        without =
          Plug.Test.conn(:get, "/api/v1" <> path)
          |> put_req_header("accept", "application/vnd.api+json")
          |> put_req_header("authorization", "Bearer " <> raw)
          # the host router's forward strips `/api/v1` into script_name before the endpoint sees the request
          |> then(&%{&1 | script_name: ["api", "v1"], path_info: Enum.drop(&1.path_info, 2)})
          |> NoHints.call(NoHints.init([]))

        assert without.resp_body == with_hints.resp_body
      end
    end

    test "the hint is a fixed sentence: it never carries the error's detail" do
      org = mk_org("Fixed")
      {raw, _} = mk_api_key(org.id, scopes: %{"all" => ["read"]})

      conn = api_get("/contacts?sort=ZxCanaryValue", raw)
      assert conn.status == 400
      # the underlying error does carry the value in its detail: the hint must not
      assert conn.resp_body =~ "ZxCanaryValue"
      for error <- json(conn)["errors"], do: refute(error["meta"]["_hint"] =~ "ZxCanaryValue")
      assert Enum.all?(json(conn)["errors"], &is_binary(&1["meta"]["_hint"]))
    end

    test "RED: a key with no scopes is told so; the refusal is counted per request and never logged as an error; CONTROL: a scoped key's 403 is the plain hint" do
      org = mk_org("NoScopes")
      {empty, _} = mk_api_key(org.id, scopes: %{})
      {narrow, _} = mk_api_key(org.id, scopes: %{"identity" => ["read"]})

      ref = make_ref()
      test = self()
      handler = "no-scopes-#{inspect(ref)}"
      :telemetry.attach(handler, [:samen, :api, :help, :key_has_no_scopes], fn _e, m, _meta, _c -> send(test, {ref, m}) end, nil)
      on_exit(fn -> :telemetry.detach(handler) end)

      log =
        capture_log(fn ->
          assert api_get("/contacts", empty).status == 403
          assert api_get("/contacts", empty).status == 403
        end)

      assert_received {^ref, %{count: 1}}
      assert_received {^ref, %{count: 1}}
      refute log =~ "api_key_no_scopes"
      refute log =~ "[error]"
      refute log =~ "sk_"

      [%{"meta" => %{"_hint" => hint}}] = json(api_get("/contacts", empty))["errors"]
      assert hint =~ "no scopes"
      assert_received {^ref, %{count: 1}}

      [%{"meta" => %{"_hint" => plain}}] = json(api_get("/contacts", narrow))["errors"]
      refute plain =~ "no scopes"
      refute_received {^ref, _}
    end
  end

  describe "only a key's actor is described" do
    defmodule AssignsAnActor do
      @moduledoc "A key plug stand-in that assigns an actor the way something other than the key plug would: no `:api_key`."
      @behaviour Plug
      def init(opts), do: opts
      def call(conn, _opts), do: Ash.PlugHelpers.set_actor(conn, %{plane: :operator, role: :owner, org_id: Ecto.UUID.generate()})
    end

    defmodule AssignsAKeyActor do
      @moduledoc "The control: the same actor carrying an `:api_key` map."
      @behaviour Plug
      def init(opts), do: opts

      def call(conn, _opts) do
        key = %{org_id: nil, plane: :tenant, scopes: %{"all" => ["read"]}, minter_role: :admin}
        Ash.PlugHelpers.set_actor(conn, %{plane: :tenant, role: :admin, org_id: Ecto.UUID.generate(), api_key: key})
      end
    end

    defp via(key_auth, path) do
      opts = Samen.Api.Help.Endpoint.init(router: DemoWeb.Api.Router, key_auth: key_auth)
      Samen.Api.Help.Endpoint.call(Plug.Test.conn(:get, path), opts)
    end

    test "RED: an actor that is not the key plug's answers 401 and no description; CONTROL: the same actor with a key map is described" do
      refuted = via(AssignsAnActor, "/")
      assert refuted.status == 401
      assert header(refuted, "www-authenticate") == "Bearer"
      refute refuted.resp_body =~ "resources"
      assert via(AssignsAnActor, "/contact").status == 401

      assert via(AssignsAKeyActor, "/").status == 200
    end
  end

  describe "the HTML view's content security policy" do
    test "RED: the HTML page cannot be framed, has no base and posts nowhere; CONTROL: the JSON answer has none" do
      org = mk_org("Csp")
      {raw, _} = mk_api_key(org.id, scopes: %{"crm" => ["read"]})

      csp = header(help_get("?format=html", raw), "content-security-policy")
      assert csp == "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'"
      assert header(help_get("", raw), "content-security-policy") == nil
    end
  end

  describe "private, no-store" do
    test "RED: every help response is private, no-store and varies by Authorization; CONTROL: they are present on 200, 401 and 404" do
      org = mk_org("Cache")
      {raw, _} = mk_api_key(org.id, scopes: %{"crm" => ["read"]})

      for conn <- [help_get("", raw), help_get("/contact", raw), help_get("/nope", raw), help_get(""), help_get("", raw, [{"accept", "text/html"}])] do
        assert header(conn, "cache-control") == "private, no-store"
        assert header(conn, "vary") == "Authorization, Accept"
      end
    end
  end

  describe "the HTML view, masked per plane (a contact with canary PII)" do
    @canary "zxcanary@example.com"

    setup do
      org = mk_org("Html")
      mk_contact(org.id, %{full_name: %{first: "Zxcanaryfirst", last: "L"}, emails: [@canary]})
      %{org: org}
    end

    test "GREEN: the tenant page lists the PII fields as clear and carries no canary", %{org: org} do
      {raw, _} = mk_api_key(org.id, plane: :tenant, scopes: %{"crm" => ["read"]})
      conn = help_get("/contact?format=html", raw)

      assert conn.status == 200
      assert header(conn, "content-type") =~ "text/html"
      refute conn.resp_body =~ @canary
      refute conn.resp_body =~ "Zxcanaryfirst"
      assert conn.resp_body =~ "<code>emails</code>"
      Samen.VaultTokenAssert.refute_vault_token(conn.resp_body)
    end

    test "RED: the operator page shows the mask, never a value or a vault token; JSON and HTML agree", %{org: org} do
      {raw, _} = mk_api_key(org.id, plane: :operator, scopes: %{"crm" => ["read"]})

      html = help_get("/contact", raw, [{"accept", "text/html"}])
      assert_masked_dom!(html.resp_body, [@canary, "Zxcanaryfirst"])
      assert html.resp_body =~ "omitted without a reveal grant"

      json = help_get("/contact", raw)
      refute json.resp_body =~ @canary
      assert json(json)["fields"] |> Enum.filter(& &1["pii"]) |> Enum.all?(&(&1["delivery"] == "omitted_without_grant"))
      Samen.VaultTokenAssert.refute_vault_token(json.resp_body)
    end

    test "TWIN: the DOM scan is refutable: a page with the canary injected is caught", %{org: org} do
      {raw, _} = mk_api_key(org.id, plane: :operator, scopes: %{"crm" => ["read"]})
      html = help_get("/contact?format=html", raw).resp_body
      leaked = String.replace(html, "</body>", @canary <> "</body>")

      assert_leak_detected!(leaked, @canary)
      assert_raise ExUnit.AssertionError, fn -> assert_masked_dom!(leaked, [@canary]) end
    end

    test "HTML escapes what it renders" do
      assert Samen.Api.Help.Html.render(%{"label" => "<script>x</script>", "description" => "a & b", "type" => "t", "family" => "f",
        "fields" => [], "actions" => [], "relations" => [], "links" => %{"index" => "/api/help"}}, :detail) =~ "&lt;script&gt;"
    end
  end
end
