defmodule Driftwood.ApiHelpTest do
  @moduledoc """
  `Samen.Api.Help` on the freight host: what THIS caller can do over the JSON:API, from the same policies that
  enforce it. Refusals are paired with controls; the masking proofs scan the whole body for seeded canaries.
  """
  use Driftwood.ApiCase, async: false
  use Samen.MaskingCase

  @router DriftwoodWeb.Api.Router
  @roles [:owner, :admin, :member, :viewer]
  @planes [:tenant, :operator]

  defp actor(raw), do: api_get("/drivers", raw).private.samen_api_actor
  defp types(help), do: Enum.map(help["resources"], & &1["type"])

  test "RED: help omits a type the key cannot use; CONTROL: the family and type keys list the driver" do
    org = mk_org()
    {family, _} = mk_api_key(org, scopes: %{"freight" => ["read"]})
    {one, _} = mk_api_key(org, scopes: %{"freight.driver" => ["read"]})
    {other, _} = mk_api_key(org, scopes: %{"freight.dispatch_event" => ["read"]})
    {none, _} = mk_api_key(org, scopes: %{})

    assert types(Samen.Api.Help.index(actor(family), @router)) == ["driver"]
    assert types(Samen.Api.Help.index(actor(one), @router)) == ["driver"]
    assert Samen.Api.Help.index(actor(other), @router)["resources"] == []
    assert Samen.Api.Help.index(actor(none), @router)["resources"] == []
  end

  test "RED: help for a hidden type is indistinguishable from an unknown one; CONTROL: the visible type answers" do
    org = mk_org()
    {other, _} = mk_api_key(org, scopes: %{"freight.dispatch_event" => ["read"]})
    {one, _} = mk_api_key(org, scopes: %{"freight.driver" => ["read"]})

    hidden = Samen.Api.Help.resource(actor(other), @router, "driver")
    assert hidden == :not_found
    assert hidden == Samen.Api.Help.resource(actor(other), @router, "nope")
    assert {:ok, %{"type" => "driver"}} = Samen.Api.Help.resource(actor(one), @router, "driver")
  end

  describe "masking per plane (a driver with canary PII)" do
    @canary_cdl "CDL-ZXCANARY-4471"
    @canary_name "Zxcanaryfirst"

    setup do
      org = mk_org()
      mk_driver(org, %{cdl_number: @canary_cdl, full_name: %{first: @canary_name, last: "Zxcanarylast"}})
      %{org: org}
    end

    defp assert_no_canary(body) do
      for canary <- [@canary_cdl, @canary_name, "Zxcanarylast"], do: refute(body =~ canary, "help leaked #{canary}")
      Samen.VaultTokenAssert.refute_vault_token(body, "a vault token leaked into help")
    end

    defp pii_delivery(detail), do: for(f <- detail["fields"], f["pii"], into: %{}, do: {f["name"], f["delivery"]})

    test "POSITIVE CONTROL + GREEN: the tenant API resolves the canary in clear; tenant help says clear, with no canary", %{org: org} do
      {raw, _} = mk_api_key(org, plane: :tenant, scopes: %{"freight" => ["read"]})
      assert api_get("/drivers", raw).resp_body =~ @canary_cdl

      {:ok, detail} = Samen.Api.Help.resource(actor(raw), @router, "driver")
      assert pii_delivery(detail) == %{"cdl_number" => "clear", "full_name" => "clear"}
      assert_no_canary(Jason.encode!(detail))
      assert_no_canary(Jason.encode!(Samen.Api.Help.index(actor(raw), @router)))
    end

    test "RED: operator-key help says omitted_without_grant and carries no canary; TWIN: the scan catches an injected one", %{org: org} do
      {raw, _} = mk_api_key(org, plane: :operator, scopes: %{"freight" => ["read"]})
      {:ok, detail} = Samen.Api.Help.resource(actor(raw), @router, "driver")

      assert pii_delivery(detail) == %{"cdl_number" => "omitted_without_grant", "full_name" => "omitted_without_grant"}
      assert_no_canary(Jason.encode!(detail))

      leaked = Jason.encode!(Map.put(detail, "leak", @canary_cdl))
      assert_leak_detected!(leaked, @canary_cdl)
      assert_raise ExUnit.AssertionError, fn -> assert_no_canary(leaked) end
    end
  end

  describe "guards" do
    test "(b) an all-scoped owner key's help types are exactly the contract types that have routes" do
      {raw, _} = mk_api_key(mk_org(), minter_role: :owner, scopes: %{"all" => ["read", "write"]})
      contract = "api_contract.v1.json" |> File.read!() |> Jason.decode!()
      contract_types = for r <- contract["resources"], r["routes"] != [], do: r["type"]

      assert contract_types != []
      assert types(Samen.Api.Help.index(actor(raw), @router)) == Enum.sort(contract_types)
    end

    test "(c) help lists a route iff a real request is not refused (role x plane x scope set x route)" do
      org = mk_org()
      id = Ecto.UUID.generate()
      sets = [%{"all" => ["read"]}, %{"freight" => ["read"]}, %{"freight.driver" => ["read"]}, %{"freight.dispatch_event" => ["read"]}, %{}]

      answers =
        for role <- @roles, plane <- @planes, scopes <- sets, type <- ["driver"], kind <- [:index, :get] do
          {raw, _} = mk_api_key(org, minter_role: role, plane: plane, scopes: scopes)
          actor = actor(raw)
          base = "/drivers"
          real = api_get(if(kind == :index, do: base, else: base <> "/" <> id), raw)

          listed? =
            case Samen.Api.Help.resource(actor, @router, type) do
              {:ok, detail} -> Enum.any?(detail["actions"], &(&1["route"] == to_string(kind)))
              :not_found -> false
            end

          assert listed? == (real.status != 403),
                 "role=#{role} plane=#{plane} scopes=#{inspect(scopes)} #{type}/#{kind}: help lists=#{listed?}, request answered #{real.status}"

          listed?
        end

      assert length(answers) == length(@roles) * length(@planes) * 5 * 2
      assert true in answers and false in answers
    end
  end
end
