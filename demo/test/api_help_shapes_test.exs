defmodule Demo.ApiHelpShapesTest do
  @moduledoc """
  `Samen.Api.Help` over fixture resources that each have one shape the description must get right: a filter policy
  (listed, `conditional`), a strict policy over a filter (not listed), a check that raises (not listed, reported
  once), a related route to a destination the caller may not read (not listed), an attribute that is not public
  (not shown), and a check that counts its evaluations (an error hint asks about one resource only).
  """
  use Demo.ApiCase, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  @router Demo.HelpFixture.Router

  defp fx_get(path, raw) do
    Plug.Test.conn(:get, path)
    |> put_req_header("accept", "application/vnd.api+json")
    |> put_req_header("authorization", "Bearer " <> raw)
    |> Demo.HelpFixture.Endpoint.call([])
  end

  defp fx_actor(raw), do: fx_get("/filtered", raw).private.samen_api_actor

  defp key(role, scopes \\ %{"helpfx" => ["read", "write"]}) do
    org = mk_org("Shapes #{System.unique_integer([:positive])}")
    {raw, _} = mk_api_key(org.id, minter_role: role, scopes: scopes)
    raw
  end

  defp types(help), do: Enum.map(help["resources"], & &1["type"])

  defp action(detail, name, route), do: Enum.find(detail["actions"], &(&1["name"] == name and &1["route"] == route))

  describe "an action the policies allow only for some records" do
    test "RED: a filter-policy read and a write that loads through it are listed with conditional: true; CONTROL: an unfiltered read is not conditional" do
      actor = fx_actor(key(:admin))

      {:ok, filtered} = Samen.Api.Help.resource(actor, @router, "filtered")
      assert %{"conditional" => true, "class" => "read"} = action(filtered, "read", "index")
      assert %{"conditional" => true, "class" => "write", "scope" => %{"helpfx.filtered" => ["read", "write"]}} = action(filtered, "update", "patch")

      {:ok, holder} = Samen.Api.Help.resource(actor, @router, "holder")
      assert %{"conditional" => false} = action(holder, "read", "index")
    end

    test "RED: a write that Ash can only decide with the record is listed as conditional; CONTROL: a filter on a write that Ash refuses without it is not listed" do
      actor = fx_actor(key(:admin))

      {:ok, runtime} = Samen.Api.Help.resource(actor, @router, "runtime")
      assert %{"conditional" => true, "class" => "write"} = action(runtime, "update", "patch")
      assert %{"conditional" => false} = action(runtime, "read", "index")
    end

    test "RED: a write whose policy needs the row is not listed (the read is); a strict policy over a filter lists nothing" do
      actor = fx_actor(key(:admin))

      {:ok, row_write} = Samen.Api.Help.resource(actor, @router, "row_write")
      assert action(row_write, "read", "index")
      assert action(row_write, "update", "patch") == nil

      index = Samen.Api.Help.index(actor, @router)
      refute "strict_only" in types(index)
      assert Samen.Api.Help.resource(actor, @router, "strict_only") == :not_found
      assert "filtered" in types(index)
    end
  end

  describe "a question that raises" do
    test "RED: the resource is omitted and the failure is reported once, value-free; CONTROL: the others are listed" do
      actor = fx_actor(key(:admin))

      log = capture_log(fn -> send(self(), {:index, Samen.Api.Help.index(actor, @router)}) end)
      assert_received {:index, index}

      refute "raiser" in types(index)
      assert "holder" in types(index)
      assert length(Regex.scan(~r/read=api_help_can/, log)) == 1
      refute log =~ "help fixture check raised"
      assert Samen.Api.Help.resource(actor, @router, "raiser") == :not_found
    end
  end

  describe "a route to a relationship" do
    test "RED: a related route to a destination the caller may not read is not listed; CONTROL: an owner, who may read it, has it with both scopes" do
      {:ok, admin_view} = Samen.Api.Help.resource(fx_actor(key(:admin)), @router, "holder")
      refute Enum.any?(admin_view["actions"], &(&1["route"] == "get_related"))
      assert Enum.any?(admin_view["actions"], &(&1["route"] == "index"))

      {:ok, owner_view} = Samen.Api.Help.resource(fx_actor(key(:owner)), @router, "holder")
      related = Enum.find(owner_view["actions"], &(&1["route"] == "get_related"))
      assert related["scope"] == %{"helpfx.holder" => ["read"], "helpfx.sealed" => ["read"]}
      assert related["also_granted_by"] == ["helpfx", "all"]
    end

    test "RED: a key scoped to the holder only does not see the related route to a destination it cannot read" do
      # the owner role may read `Sealed`, but the key's scopes do not cover it
      {:ok, view} = Samen.Api.Help.resource(fx_actor(key(:owner, %{"helpfx.holder" => ["read"]})), @router, "holder")
      refute Enum.any?(view["actions"], &(&1["route"] == "get_related"))
    end
  end

  describe "an attribute that is not public" do
    test "RED: show_fields naming a non-public attribute does not show it; CONTROL: the public ones are shown" do
      # AshJsonApi's verifier only warns about this; the resource still compiles, so the description must not trust it.
      capture_io(:stderr, fn ->
        Code.compile_string("""
        defmodule Demo.HelpShapes.Domain do
          use Ash.Domain, validate_config_inclusion?: false, extensions: [AshJsonApi.Domain]
          resources do
            resource(Demo.HelpShapes.Shown)
          end
          def samen_api_family, do: "shapes"
        end

        defmodule Demo.HelpShapes.Shown do
          use Ash.Resource,
            domain: Demo.HelpShapes.Domain,
            data_layer: Ash.DataLayer.Ets,
            authorizers: [Ash.Policy.Authorizer],
            extensions: [Demo.HelpFixture.Ext, AshJsonApi.Resource]

          json_api do
            type("shown")
            show_fields([:id, :name, :secret_note])
            routes do
              base("/shown")
              index(:read)
            end
          end

          attributes do
            uuid_primary_key(:id)
            attribute(:name, :string, public?: true)
            attribute(:secret_note, :string, public?: false)
          end

          actions do
            defaults([:read])
          end

          policies do
            policy action_type(:read) do
              authorize_if(always())
            end
          end
        end

        defmodule Demo.HelpShapes.Router do
          use AshJsonApi.Router, domains: [Demo.HelpShapes.Domain], prefix: "/shapes"
        end
        """)
      end)

      actor = %{plane: :tenant, role: :admin, org_id: Ecto.UUID.generate(), api_key: %{scopes: %{"all" => ["read"]}, plane: :tenant, minter_role: :admin, org_id: nil}}
      {:ok, detail} = Samen.Api.Help.resource(actor, Demo.HelpShapes.Router, "shown")

      assert Enum.map(detail["fields"], & &1["name"]) == ["id", "name"]
    end
  end

  describe "an error hint asks about the resource the request addressed only" do
    test "RED: an error on one type does not evaluate another type's policies; CONTROL: the addressed type is evaluated" do
      raw = key(:admin)

      Demo.HelpFixture.Counted.reset()
      error = fx_get("/holders/#{Ecto.UUID.generate()}", raw)
      assert error.status == 404
      assert [%{"links" => %{"about" => "/api/help/holder"}}] = json(error)["errors"]
      assert Demo.HelpFixture.Counted.count() == 0

      Demo.HelpFixture.Counted.reset()
      addressed = fx_get("/tallies/#{Ecto.UUID.generate()}", raw)
      assert [%{"links" => %{"about" => "/api/help/tally"}}] = json(addressed)["errors"]
      assert Demo.HelpFixture.Counted.count() > 0
    end
  end

  describe "an error that already has a meta or links that is not a map" do
    defp hint_body(error) do
      opts = Samen.Api.Help.ErrorHints.init(router: Demo.ScopeFixture.Router)

      Plug.Test.conn(:get, "/anything")
      |> Samen.Api.Help.ErrorHints.call(opts)
      |> put_resp_content_type("application/vnd.api+json")
      |> send_resp(404, Jason.encode!(%{"errors" => [error]}))
      |> Map.fetch!(:resp_body)
      |> Jason.decode!()
      |> Map.fetch!("errors")
      |> hd()
    end

    test "RED: a non-map meta and a non-map links are left as they are; CONTROL: a map meta is merged, an absent one is added" do
      untouched = hint_body(%{"code" => "not_found", "meta" => "free text", "links" => ["a"]})
      assert untouched["meta"] == "free text"
      assert untouched["links"] == ["a"]

      merged = hint_body(%{"code" => "not_found", "meta" => %{"keep" => 1}, "links" => %{"about" => "/mine"}})
      assert merged["meta"]["keep"] == 1
      assert is_binary(merged["meta"]["_hint"])
      assert merged["links"]["about"] == "/mine"

      added = hint_body(%{"code" => "not_found"})
      assert is_binary(added["meta"]["_hint"])
      assert added["links"]["about"] == "/api/help"
    end
  end
end
