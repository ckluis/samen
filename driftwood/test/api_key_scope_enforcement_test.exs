defmodule Driftwood.ApiKeyScopeEnforcementTest do
  @moduledoc """
  An API key's declared scopes are enforced on every freight API request: the grammar is `"all"`, `"<family>"` or
  `"<family>.<type>"` (here `freight` / `freight.driver`), and a key with no scopes authorizes nothing. Each refusal
  is paired with a control: the same org, a key whose scopes cover the call, reads the driver.
  """
  use Driftwood.ApiCase, async: false

  defp names(conn), do: conn |> json() |> Map.fetch!("data") |> Enum.map(& &1["id"])

  test "RED: a key scoped to another family is refused /api/v1/drivers; CONTROL: freight:read reads them" do
    org = mk_org()
    driver = mk_driver(org)

    {narrow, _} = mk_api_key(org, scopes: %{"identity" => ["read"]})
    {wide, _} = mk_api_key(org, scopes: %{"freight" => ["read"]})

    refused = api_get("/drivers", narrow)
    assert refused.status == 403
    refute refused.resp_body =~ driver.id

    allowed = api_get("/drivers", wide)
    assert allowed.status == 200
    assert names(allowed) == [driver.id]
  end

  test "RED: a key with no declared scopes authorizes nothing on the API; CONTROL: the same org reads with scopes" do
    org = mk_org()
    driver = mk_driver(org)

    {empty, _} = mk_api_key(org, scopes: %{})
    {scoped, _} = mk_api_key(org, scopes: %{"freight" => ["read"]})

    refused = api_get("/drivers", empty)
    assert refused.status == 403
    refute refused.resp_body =~ driver.id
    assert api_get("/drivers/#{driver.id}", empty).status == 403

    assert api_get("/drivers", scoped).status == 200
    assert api_get("/drivers/#{driver.id}", scoped).status == 200
  end

  test "the grammar: all, family and family.type each grant; another type and a write-only scope do not" do
    org = mk_org()
    mk_driver(org)

    for scopes <- [%{"all" => ["read"]}, %{all: [:read]}, %{"freight" => ["read"]}, %{"freight.driver" => ["read"]}] do
      {raw, _} = mk_api_key(org, scopes: scopes)
      assert api_get("/drivers", raw).status == 200, "#{inspect(scopes)} should read drivers"
    end

    for scopes <- [%{"freight.dispatch_event" => ["read"]}, %{"freight" => ["write"]}, %{"driver" => ["read"]}] do
      {raw, _} = mk_api_key(org, scopes: scopes)
      assert api_get("/drivers", raw).status == 403, "#{inspect(scopes)} must not read drivers"
    end
  end
end
