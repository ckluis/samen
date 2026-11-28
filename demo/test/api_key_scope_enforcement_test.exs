defmodule Demo.ApiKeyScopeEnforcementTest do
  @moduledoc """
  An API key's declared scopes are enforced on every request, through the real router and key plug.

  The grammar: `"all"`, `"<family>"` or `"<family>.<type>"` mapped to `["read"]`, `["write"]` or both. A key
  acts with the LOWER of its scopes and its role: both must allow. An empty scope map authorizes nothing.
  Every refusal here is paired with a control that the same key reads or writes when its scopes cover the call.
  """
  use Demo.ApiCase, async: false

  defp get_fx(path, key) do
    Plug.Test.conn(:get, path)
    |> put_req_header("accept", "application/vnd.api+json")
    |> put_req_header("authorization", "Bearer " <> key)
    |> Demo.ScopeFixture.Endpoint.call(Demo.ScopeFixture.Endpoint.init([]))
  end

  defp delete_fx(path, key) do
    Plug.Test.conn(:delete, path)
    |> put_req_header("accept", "application/vnd.api+json")
    |> put_req_header("authorization", "Bearer " <> key)
    |> Demo.ScopeFixture.Endpoint.call(Demo.ScopeFixture.Endpoint.init([]))
  end

  defp mk_gadget(name) do
    Demo.ScopeFixture.Gadget |> Ash.Changeset.for_create(:create, %{name: name}) |> Ash.create!(authorize?: false)
  end

  defp exists?(gadget), do: match?({:ok, %{}}, Ash.get(Demo.ScopeFixture.Gadget, gadget.id, authorize?: false))

  defp ids(conn), do: conn |> json() |> Map.fetch!("data") |> Enum.map(& &1["attributes"]["display_name"])

  test "RED: a key scoped identity:read is refused /api/v1/contacts; CONTROL: crm:read reads them" do
    org = mk_org("Scoped")
    mk_contact(org.id, %{display_name: "Visible"})

    {narrow, _} = mk_api_key(org.id, scopes: %{"identity" => ["read"]})
    {wide, _} = mk_api_key(org.id, scopes: %{"crm" => ["read"]})

    refused = api_get("/contacts", narrow)
    assert refused.status == 403
    refute refused.resp_body =~ "Visible"

    allowed = api_get("/contacts", wide)
    assert allowed.status == 200
    assert ids(allowed) == ["Visible"]
  end

  test "RED: a key with no declared scopes authorizes nothing on the API; CONTROL: the same org reads with scopes" do
    org = mk_org("Empty")
    mk_contact(org.id, %{display_name: "Hidden"})

    {empty, _} = mk_api_key(org.id, scopes: %{})
    {scoped, _} = mk_api_key(org.id, scopes: %{"crm" => ["read"]})

    for path <- ["/contacts", "/orgs", "/users", "/memberships"] do
      conn = api_get(path, empty)
      assert conn.status == 403, "#{path} answered #{conn.status} to a key with no scopes"
      refute conn.resp_body =~ "Hidden"
    end

    assert api_get("/contacts", scoped).status == 200
  end

  test "the grammar: all, family and family.type each grant; another type, a write-only scope and a malformed scope do not" do
    org = mk_org("Grammar")
    mk_contact(org.id, %{display_name: "Row"})

    granted = [
      %{"all" => ["read"]},
      %{all: [:read]},
      %{"crm" => ["read"]},
      %{crm: [:read]},
      %{"crm.contact" => ["read"]},
      %{"crm" => ["write"], "crm.contact" => ["read"]}
    ]

    for scopes <- granted do
      {raw, _} = mk_api_key(org.id, scopes: scopes)
      assert api_get("/contacts", raw).status == 200, "#{inspect(scopes)} should read contacts"
    end

    refused = [
      %{"crm.company" => ["read"]},
      %{"crm" => ["write"]},
      %{"contact" => ["read"]},
      %{"crm" => "read"},
      %{"crm" => ["delete"]}
    ]

    for scopes <- refused do
      {raw, _} = mk_api_key(org.id, scopes: scopes)
      assert api_get("/contacts", raw).status == 403, "#{inspect(scopes)} must not read contacts"
    end
  end

  describe "a write route (fixture domain with a role-gated destroy and a bypass)" do
    test "RED: a viewer-minted key with fixture:write still cannot write; CONTROL: an admin-minted key can" do
      org = mk_org("Writes")
      {viewer, _} = mk_api_key(org.id, minter_role: :viewer, scopes: %{"fixture" => ["read", "write"]})
      {admin, _} = mk_api_key(org.id, minter_role: :admin, scopes: %{"fixture" => ["read", "write"]})
      kept = mk_gadget("kept")
      gone = mk_gadget("gone")

      # the viewer-minted key holds the scope but not the role: the role half refuses it (a destroy first reads the
      # row, so a writing key carries the read scope as well)
      assert delete_fx("/gadgets/#{kept.id}", viewer).status == 403
      assert exists?(kept)

      assert delete_fx("/gadgets/#{gone.id}", admin).status in [200, 204]
      refute exists?(gone)
    end

    test "RED: the scope policy precedes a bypass; CONTROL: the same role writes once its scope says write" do
      org = mk_org("Bypass")
      {read_only, _} = mk_api_key(org.id, plane: :operator, minter_role: :admin, scopes: %{"fixture" => ["read"]})
      {writer, _} = mk_api_key(org.id, plane: :operator, minter_role: :admin, scopes: %{"fixture.gadget" => ["read", "write"]})
      kept = mk_gadget("kept")
      gone = mk_gadget("gone")

      # the fixture's `bypass` authorizes every operator-plane actor; only the scope policy ahead of it says no
      assert delete_fx("/gadgets/#{kept.id}", read_only).status == 403
      assert exists?(kept)

      assert delete_fx("/gadgets/#{gone.id}", writer).status in [200, 204]
      refute exists?(gone)
    end

    test "RED: a scope on another family does not reach the fixture; the domain's declared family is used" do
      org = mk_org("Family")
      {crm_only, _} = mk_api_key(org.id, scopes: %{"crm" => ["read", "write"]})
      {fixture, _} = mk_api_key(org.id, scopes: %{"fixture" => ["read"]})

      assert get_fx("/gadgets", crm_only).status == 403
      assert get_fx("/gadgets", fixture).status == 200
    end
  end

  test "a non-key actor is not subject to the scope policy" do
    org = mk_org("Person")
    mk_contact(org.id, %{display_name: "Seen"})

    person = %{id: Ecto.UUID.generate(), org_id: org.id, role: :admin, plane: :tenant}
    assert {:ok, [%{display_name: "Seen"}]} = Ash.read(Demo.Crm.Contact, actor: person)
    key_actor = Map.put(person, :api_key, %{scopes: %{}, org_id: org.id, plane: :tenant, minter_role: :admin})
    assert {:error, _} = Ash.read(Demo.Crm.Contact, actor: key_actor)
  end
end
