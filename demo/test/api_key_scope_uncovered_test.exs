defmodule Demo.ApiKeyScopeUncoveredTest do
  @moduledoc """
  The key-scope policy never authorizes anything on its own. An action that no policy the resource declares covers is
  forbidden for every actor (nobody, a signed-in person, a key scoped `all: read+write`), and a resource with the
  policy authorizer and no declared policy is deny-all. Each refusal here is paired with a control that a covered
  action is allowed for the same actor, through the real transformer and Ash's authorization path.
  """
  use ExUnit.Case, async: false

  alias Demo.ScopeFixture.{Bare, Widget}

  @org Ecto.UUID.generate()

  defp person, do: %{id: Ecto.UUID.generate(), org_id: @org, role: :admin, plane: :tenant}

  defp key(scopes),
    do: Map.put(person(), :api_key, %{scopes: scopes, org_id: @org, plane: :tenant, minter_role: :admin})

  defp actors do
    [
      {"nil", nil},
      {"a signed-in actor", person()},
      {"a key scoped all: read+write", key(%{"all" => ["read", "write"]})}
    ]
  end

  defp widget, do: Widget |> Ash.Changeset.for_create(:create, %{name: "w"}) |> Ash.create!(authorize?: false)

  defp forbidden?({:error, %Ash.Error.Forbidden{}}), do: true
  defp forbidden?(_), do: false

  describe "an action no declared policy covers" do
    test "RED: a read, create, update, destroy and generic action are each forbidden for every actor" do
      for {who, actor} <- actors() do
        record = widget()

        assert forbidden?(Ash.read(Widget, action: :read, actor: actor)), "read allowed for #{who}"

        assert forbidden?(
                 Widget |> Ash.Changeset.for_create(:create, %{name: "x"}, actor: actor) |> Ash.create()
               ),
               "create allowed for #{who}"

        assert forbidden?(
                 record |> Ash.Changeset.for_update(:update, %{name: "y"}, actor: actor) |> Ash.update()
               ),
               "update allowed for #{who}"

        assert forbidden?(record |> Ash.Changeset.for_destroy(:destroy, %{}, actor: actor) |> Ash.destroy()),
               "destroy allowed for #{who}"

        assert forbidden?(Widget |> Ash.ActionInput.for_action(:ping, %{}, actor: actor) |> Ash.run_action()),
               "generic action allowed for #{who}"

        assert {:ok, _} = Ash.get(Widget, record.id, authorize?: false), "#{who} destroyed or changed the row"
        refute Ash.can?({Widget, :read}, actor), "Ash.can? says read is allowed for #{who}"
      end
    end

    test "CONTROL: the one covered read is allowed for the same actors" do
      for {who, actor} <- actors() do
        assert {:ok, _} = Ash.read(Widget, action: :covered_read, actor: actor), "covered read refused for #{who}"
        assert Ash.can?({Widget, :covered_read}, actor), "Ash.can? refuses the covered read for #{who}"
      end
    end

    test "CONTROL: a key whose scopes do not cover even the covered read is still refused" do
      assert forbidden?(Ash.read(Widget, action: :covered_read, actor: key(%{"crm" => ["read"]})))
      assert forbidden?(Ash.read(Widget, action: :covered_read, actor: key(%{})))
    end
  end

  describe "a resource with the authorizer and no declared policy" do
    test "RED: it is deny-all for every actor" do
      for {who, actor} <- actors() do
        assert forbidden?(Ash.read(Bare, actor: actor)), "read allowed for #{who}"

        assert forbidden?(Bare |> Ash.Changeset.for_create(:create, %{name: "x"}, actor: actor) |> Ash.create()),
               "create allowed for #{who}"
      end
    end

    test "CONTROL: the resource itself is usable when authorization is off, so the refusal is the policy's" do
      assert {:ok, _} = Ash.read(Bare, authorize?: false)
      assert {:ok, _} = Bare |> Ash.Changeset.for_create(:create, %{name: "x"}) |> Ash.create(authorize?: false)
    end
  end
end
