defmodule Demo.ApiHelpTest do
  @moduledoc """
  `Samen.Api.Help`: what THIS caller can do over the JSON:API, derived from the same policies that enforce access.

  Every refusal is paired with a control that the same description lists the thing for a caller who may use it,
  and the masking proofs scan the whole body for seeded canaries (PII values, a vault token): the description is
  schema, never a row value.
  """
  use Demo.ApiCase, async: false
  use Samen.MaskingCase

  @router DemoWeb.Api.Router
  @fixture Demo.ScopeFixture.Router
  @roles [:owner, :admin, :member, :viewer]
  @planes [:tenant, :operator]

  # the actor the real key plug built for this key (the plug leaves it on the conn, whatever the answer was)
  defp actor(raw), do: api_get("/orgs", raw).private.samen_api_actor

  defp mk_gadget(name) do
    Demo.ScopeFixture.Gadget |> Ash.Changeset.for_create(:create, %{name: name}) |> Ash.create!(authorize?: false)
  end

  defp types(help), do: Enum.map(help["resources"], & &1["type"])
  defp actions_of(help, type), do: Enum.find(help["resources"], &(&1["type"] == type))["actions"]

  describe "the index" do
    test "RED: help omits a resource the key cannot use; CONTROL: the crm key lists it, and only it" do
      org = mk_org("Index")
      {crm, _} = mk_api_key(org.id, scopes: %{"crm" => ["read"]})
      {identity, _} = mk_api_key(org.id, scopes: %{"identity" => ["read"]})

      crm_help = Samen.Api.Help.index(actor(crm), @router)
      assert types(crm_help) == ["contact"]
      assert actions_of(crm_help, "contact") == ["api_read"]
      assert crm_help["caller"] == %{"plane" => "tenant", "role" => "admin", "scopes" => %{"crm" => ["read"]}}
      assert crm_help["api"] == %{"base" => "/api/v1", "media_type" => "application/vnd.api+json"}

      identity_help = Samen.Api.Help.index(actor(identity), @router)
      assert types(identity_help) == ["membership", "org", "user"]
      refute "contact" in types(identity_help)
    end

    test "RED: a key with no scopes lists nothing; CONTROL: an all-scoped key lists every type" do
      org = mk_org("Nothing")
      {empty, _} = mk_api_key(org.id, scopes: %{})
      {all, _} = mk_api_key(org.id, scopes: %{"all" => ["read"]})

      assert Samen.Api.Help.index(actor(empty), @router)["resources"] == []
      assert types(Samen.Api.Help.index(actor(all), @router)) == ["contact", "membership", "org", "user"]
    end

    test "a bare actor with no key and no policy-allowing role lists nothing" do
      assert Samen.Api.Help.index(nil, @router)["resources"] == []
    end
  end

  describe "an action the key cannot run (fixture domain with an admin-only destroy)" do
    test "RED: help omits the destroy for a read-only key and a viewer-minted key; CONTROL: the admin writer lists it" do
      org = mk_org("Actions")
      {read_only, _} = mk_api_key(org.id, minter_role: :admin, scopes: %{"fixture" => ["read"]})
      {viewer, _} = mk_api_key(org.id, minter_role: :viewer, scopes: %{"fixture" => ["read", "write"]})
      {writer, _} = mk_api_key(org.id, minter_role: :admin, scopes: %{"fixture" => ["read", "write"]})

      names = fn raw ->
        {:ok, detail} = Samen.Api.Help.resource(actor(raw), @fixture, "gadget", prefix: "/fx")
        detail["actions"] |> Enum.map(&{&1["name"], &1["class"], &1["method"]}) |> Enum.sort()
      end

      assert names.(read_only) == [{"read", "read", "GET"}, {"read", "read", "GET"}]
      assert names.(viewer) == [{"read", "read", "GET"}, {"read", "read", "GET"}]

      assert names.(writer) ==
               [{"destroy", "write", "DELETE"}, {"read", "read", "GET"}, {"read", "read", "GET"}]
    end

    test "an action lists its route, path, scope and required args; a writable field is not read_only" do
      org = mk_org("Detail")
      {writer, _} = mk_api_key(org.id, minter_role: :admin, scopes: %{"fixture" => ["read", "write"]})
      {:ok, detail} = Samen.Api.Help.resource(actor(writer), @fixture, "gadget", prefix: "/fx")

      destroy = Enum.find(detail["actions"], &(&1["name"] == "destroy"))
      assert %{"route" => "delete", "path" => "/fx/gadgets/:id", "scope" => "fixture:write", "required_args" => []} = destroy
      assert detail["family"] == "fixture"
      assert detail["links"] == %{"self" => "/api/help/gadget", "index" => "/api/help"}
    end
  end

  describe "a hidden resource" do
    test "RED: help for a hidden resource is indistinguishable from an unknown one; CONTROL: a visible one answers" do
      org = mk_org("Hidden")
      {crm, _} = mk_api_key(org.id, scopes: %{"crm" => ["read"]})
      actor = actor(crm)

      hidden = Samen.Api.Help.resource(actor, @router, "user")
      unknown = Samen.Api.Help.resource(actor, @router, "no_such_type")
      assert hidden == :not_found
      assert hidden == unknown

      assert {:ok, %{"type" => "contact"}} = Samen.Api.Help.resource(actor, @router, "contact")
    end
  end

  describe "relations" do
    test "RED: a relation whose target the key cannot use is not listed; CONTROL: a key that lists both has it" do
      org = mk_org("Relations")
      {part_only, _} = mk_api_key(org.id, scopes: %{"fixture.part" => ["read"]})
      {both, _} = mk_api_key(org.id, scopes: %{"fixture" => ["read"]})

      {:ok, narrow} = Samen.Api.Help.resource(actor(part_only), @fixture, "part", prefix: "/fx")
      assert narrow["relations"] == []
      refute Jason.encode!(narrow) =~ ~s("target":"gadget")
      assert types(Samen.Api.Help.index(actor(part_only), @fixture)) == ["part"]

      {:ok, wide} = Samen.Api.Help.resource(actor(both), @fixture, "part", prefix: "/fx")
      assert wide["relations"] == [%{"name" => "gadget", "kind" => "belongs_to", "field" => "gadget_id", "target" => "gadget"}]
    end
  end

  describe "masking per plane (a contact with canary PII)" do
    @canary_first "Zxcanaryfirst"
    @canary_email "zxcanary@example.com"
    @canary_dob "1971-02-03"

    setup do
      org = mk_org("Masking")

      mk_contact(org.id, %{
        display_name: "ZxCanaryDisplay",
        full_name: %{first: @canary_first, last: "Zxcanarylast"},
        emails: [@canary_email],
        dob: ~D[1971-02-03]
      })

      %{org: org}
    end

    defp pii_delivery(help_detail) do
      for f <- help_detail["fields"], f["pii"], into: %{}, do: {f["name"], f["delivery"]}
    end

    defp assert_no_canary(body) do
      for canary <- [@canary_first, "Zxcanarylast", @canary_email, @canary_dob, "ZxCanaryDisplay"] do
        refute body =~ canary, "help leaked the canary #{inspect(canary)}"
      end

      Samen.VaultTokenAssert.refute_vault_token(body, "a vault token leaked into help")
    end

    test "POSITIVE CONTROL: the tenant API resolves the canary in clear", %{org: org} do
      {raw, _} = mk_api_key(org.id, plane: :tenant, scopes: %{"crm" => ["read"]})
      body = api_get("/contacts", raw).resp_body
      assert body =~ @canary_first
      assert body =~ @canary_email
    end

    test "GREEN: tenant help describes the PII fields as clear, by name, with no canary", %{org: org} do
      {raw, _} = mk_api_key(org.id, plane: :tenant, scopes: %{"crm" => ["read"]})
      {:ok, detail} = Samen.Api.Help.resource(actor(raw), @router, "contact")

      assert pii_delivery(detail) == %{"dob" => "clear", "emails" => "clear", "full_name" => "clear"}
      assert Enum.find(detail["fields"], &(&1["name"] == "display_name"))["pii"] == false
      assert_no_canary(Jason.encode!(detail))
      assert_no_canary(Jason.encode!(Samen.Api.Help.index(actor(raw), @router)))
    end

    test "RED: operator-key help says the PII fields are omitted without a grant, and carries no canary", %{org: org} do
      {raw, _} = mk_api_key(org.id, plane: :operator, scopes: %{"crm" => ["read"]})
      {:ok, detail} = Samen.Api.Help.resource(actor(raw), @router, "contact")

      assert pii_delivery(detail) ==
               %{"dob" => "omitted_without_grant", "emails" => "omitted_without_grant", "full_name" => "omitted_without_grant"}

      assert Enum.find(detail["fields"], &(&1["name"] == "display_name"))["delivery"] == "clear"
      body = Jason.encode!(detail)
      assert_no_canary(body)
      assert_no_canary(Jason.encode!(Samen.Api.Help.index(actor(raw), @router)))
    end

    test "TWIN: the canary scan is refutable: a body with an injected canary is caught", %{org: org} do
      {raw, _} = mk_api_key(org.id, plane: :tenant, scopes: %{"crm" => ["read"]})
      {:ok, detail} = Samen.Api.Help.resource(actor(raw), @router, "contact")
      leaked = Jason.encode!(Map.put(detail, "leak", @canary_email))

      assert_leak_detected!(leaked, @canary_email)
      assert_raise ExUnit.AssertionError, fn -> assert_no_canary(leaked) end
    end
  end

  describe "guards" do
    test "(b) an all-scoped admin key's help types are exactly the contract types that have routes" do
      org = mk_org("Contract")
      {raw, _} = mk_api_key(org.id, minter_role: :owner, scopes: %{"all" => ["read", "write"]})

      contract = "api_contract.v1.json" |> File.read!() |> Jason.decode!()
      contract_types = for r <- contract["resources"], r["routes"] != [], do: r["type"]

      assert contract_types != []
      assert types(Samen.Api.Help.index(actor(raw), @router)) == Enum.sort(contract_types)
    end

    test "(c) help lists an action iff a real request is not refused (role x plane x scope set x route)" do
      org = mk_org("Matrix")
      ids = ids_by_type(org)

      sets = fn family, type -> [%{"all" => ["read"]}, %{family => ["read"]}, %{"#{family}.#{type}" => ["read"]}, %{}] end
      checked = for role <- @roles, plane <- @planes, scopes <- sets.("crm", "contact") ++ sets.("identity", "org") do
        {raw, _} = mk_api_key(org.id, minter_role: role, plane: plane, scopes: scopes)
        actor = actor(raw)
        index = Samen.Api.Help.index(actor, @router)

        for type <- ["contact", "org", "user", "membership"], path <- [{"/" <> plural(type), :index}, {"/" <> plural(type) <> "/:id", :get}] do
          {route, kind} = path
          url = String.replace(route, ":id", ids[type])
          real = api_get(url, raw)

          listed? =
            case Samen.Api.Help.resource(actor, @router, type) do
              {:ok, detail} -> Enum.any?(detail["actions"], &(&1["route"] == to_string(kind)))
              :not_found -> false
            end

          assert listed? == (real.status != 403),
                 "role=#{role} plane=#{plane} scopes=#{inspect(scopes)} #{url}: help lists=#{listed?}, request answered #{real.status}"

          assert (type in types(index)) or not listed?
          listed?
        end
      end

      answers = List.flatten(checked)
      assert length(answers) == length(@roles) * length(@planes) * 8 * 8
      # not vacuous: the matrix saw a listed route and an unlisted one
      assert true in answers and false in answers
    end

    test "(c) the same iff holds for a write route (fixture domain, role x scope set)" do
      org = mk_org("MatrixWrite")

      for role <- @roles, scopes <- [%{"all" => ["read", "write"]}, %{"fixture" => ["read", "write"]}, %{"fixture.gadget" => ["read"]}, %{"fixture" => ["write"]}, %{}] do
        {raw, _} = mk_api_key(org.id, minter_role: role, plane: :tenant, scopes: scopes)
        gadget = mk_gadget("g")
        actor = Plug.Test.conn(:get, "/gadgets") |> put_req_header("authorization", "Bearer " <> raw) |> Demo.ScopeFixture.Endpoint.call([]) |> then(& &1.private.samen_api_actor)

        listed? =
          case Samen.Api.Help.resource(actor, @fixture, "gadget", prefix: "/fx") do
            {:ok, detail} -> Enum.any?(detail["actions"], &(&1["name"] == "destroy"))
            :not_found -> false
          end

        status =
          Plug.Test.conn(:delete, "/gadgets/#{gadget.id}")
          |> put_req_header("accept", "application/vnd.api+json")
          |> put_req_header("authorization", "Bearer " <> raw)
          |> Demo.ScopeFixture.Endpoint.call([])
          |> Map.fetch!(:status)

        assert listed? == (status != 403), "role=#{role} scopes=#{inspect(scopes)}: help lists destroy=#{listed?}, request answered #{status}"
      end
    end
  end

  defp plural("contact"), do: "contacts"
  defp plural("org"), do: "orgs"
  defp plural("user"), do: "users"
  defp plural("membership"), do: "memberships"

  defp ids_by_type(org) do
    user = mk_user(org.id, "matrix-user")
    mbr = mk_membership(org.id, user.id, :member)
    contact = mk_contact(org.id, %{display_name: "Row"})
    %{"contact" => contact.id, "org" => org.id, "user" => user.id, "membership" => mbr.id}
  end
end
