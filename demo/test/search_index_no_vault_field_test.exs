defmodule Demo.SearchIndexNoVaultFieldTest do
  @moduledoc """
  `Primitives.SearchIndex` create never ran `SearchIndexGuard`, so a vault-routed field could be registered;
  the write is refused by the same guard now (create and update), through a real admin and on the system path.
  """
  use Demo.DataCase, async: false

  alias Demo.Identity.{Org, User}
  alias Demo.PrimitivesScope.SearchIndex

  defp mk_org do
    {:ok, org} =
      Org |> Ash.Changeset.for_create(:create, %{name: "r5-#{:rand.uniform(999_999)}"}) |> Ash.create(authorize?: false)

    org
  end

  defp mk_actor(org_id, role) do
    {:ok, user} =
      User
      |> Ash.Changeset.for_create(:create, %{
        handle: "r5-#{:rand.uniform(999_999)}",
        org_id: org_id,
        full_name: %{first: "R", last: "5"},
        emails: ["r5#{:rand.uniform(999_999)}@example.com"]
      })
      |> Ash.create(authorize?: false)

    Samen.Scope.new(%{id: user.id, org_id: org_id, role: role}).actor
  end


  # -- search index -----------------------------------------------------------

  describe "Primitives.SearchIndex registers no vault-routed field" do
    defp register(actor, org_id, resource_name, field_name, extra \\ []) do
      attrs = %{
        resource_name: resource_name,
        field_name: field_name,
        vector_column: "x_search_vector",
        org_id: org_id
      }

      SearchIndex
      |> Ash.Changeset.for_create(:create, attrs, actor: actor)
      |> Ash.create([actor: actor] ++ extra)
    end

    test "RED: an admin registering a vault-routed field is refused; CONTROL: a non-PII field is accepted" do
      org = mk_org()
      admin = mk_actor(org.id, :admin)

      assert {:error, _} = register(admin, org.id, "Demo.PrimitivesScope.Notification", "rendered_body")
      assert {:ok, _} = register(admin, org.id, "Demo.PrimitivesScope.File", "filename")
    end

    test "RED: the system path (authorize?: false) is held to the same guard" do
      org = mk_org()
      assert {:error, _} = register(nil, org.id, "Demo.PrimitivesScope.Notification", "rendered_body", authorize?: false)
    end

    test "RED: a resource the guard cannot read is refused (fail honest), not passed" do
      org = mk_org()
      admin = mk_actor(org.id, :admin)

      assert {:error, _} = register(admin, org.id, "Demo.NoSuch.Resource", "filename")
      assert {:error, _} = register(admin, org.id, "Elixir.String", "filename")
    end

    test "RED: an update cannot repoint a clean row at a vault-routed field" do
      org = mk_org()
      admin = mk_actor(org.id, :admin)
      {:ok, row} = register(admin, org.id, "Demo.PrimitivesScope.File", "filename")

      assert {:error, _} =
               row
               |> Ash.Changeset.for_update(
                 :update,
                 %{resource_name: "Demo.PrimitivesScope.Notification", field_name: "rendered_body"},
                 actor: admin
               )
               |> Ash.update(actor: admin)
    end
  end

end
