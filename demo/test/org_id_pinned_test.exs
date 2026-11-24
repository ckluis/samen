defmodule Demo.OrgIdPinnedTest do
  @moduledoc """
  A. `org_id` is immutable after create and an actor's create is bound to the actor's org, on
  every resource (`Samen.Policy.OrgIdPinned`). RED tests do the forbidden write through the real
  action + policy (an actor, `authorize?: true`) on three representative resources: CRM
  (`Demo.CrmScope.Company`), billing (`Demo.BillingScope.Customer`) and the host-written
  `Demo.Crm.Contact` (whose write policy is `always()`). Each is paired with a POSITIVE CONTROL.
  """
  use Demo.DataCase, async: false

  require Ash.Query

  alias Demo.BillingScope.Customer
  alias Demo.Crm.Contact
  alias Demo.CrmScope.Company
  alias Demo.Identity.Org

  defp mk_org(name) do
    {:ok, org} = Org |> Ash.Changeset.for_create(:create, %{name: name}) |> Ash.create(authorize?: false)
    org
  end

  defp actor(org_id, role \\ :admin),
    do: %{id: Ecto.UUID.generate(), org_id: org_id, role: role, verified?: true, kind: :tenant, plane: :tenant}

  defp seed(resource, attrs),
    do: resource |> Ash.Changeset.for_create(:create, attrs) |> Ash.create!(authorize?: false)

  defp org_of(resource, id) do
    (resource |> Ash.Query.filter(id == ^id) |> Ash.Query.select([:id, :org_id]) |> Ash.read_one!(authorize?: false)).org_id
  end

  defp assert_org_error({:error, %Ash.Error.Invalid{errors: errors}}) do
    assert Enum.any?(errors, &(Map.get(&1, :field) == :org_id))
  end

  @cases [
    {Company, %{name: "Pin Co"}, %{name: "Renamed"}},
    {Customer, %{billing_name: "Pin Customer", billing_email: "pin@billing.example"}, %{billing_name: "Renamed"}},
    {Contact, %{display_name: "Pin Contact"}, %{display_name: "Renamed"}}
  ]

  for {resource, create_attrs, update_attrs} <- @cases do
    describe "#{inspect(resource)}" do
      test "RED: an in-org actor cannot move the row into another org through :update" do
        a = mk_org("pin-a")
        b = mk_org("pin-b")
        row = seed(unquote(resource), Map.put(unquote(Macro.escape(create_attrs)), :org_id, a.id))

        result =
          row
          |> Ash.Changeset.for_update(:update, %{org_id: b.id}, actor: actor(a.id))
          |> Ash.update(actor: actor(a.id))

        assert_org_error(result)
        assert org_of(unquote(resource), row.id) == a.id
      end

      test "positive control: the same actor can still update the row's other fields" do
        a = mk_org("pin-pa")
        row = seed(unquote(resource), Map.put(unquote(Macro.escape(create_attrs)), :org_id, a.id))

        assert {:ok, _} =
                 row
                 |> Ash.Changeset.for_update(:update, unquote(Macro.escape(update_attrs)), actor: actor(a.id))
                 |> Ash.update(actor: actor(a.id))

        assert org_of(unquote(resource), row.id) == a.id
      end

      test "an actor can send the row's OWN org_id back when the record in hand has org_id loaded" do
        a = mk_org("pin-sa")
        row = seed(unquote(resource), Map.put(unquote(Macro.escape(create_attrs)), :org_id, a.id))

        loaded =
          unquote(resource)
          |> Ash.Query.filter(id == ^row.id)
          |> Ash.Query.ensure_selected([:org_id])
          |> Ash.read_one!(authorize?: false)

        assert loaded.org_id == a.id
        attrs = Map.put(unquote(Macro.escape(update_attrs)), :org_id, a.id)

        assert {:ok, _} = loaded |> Ash.Changeset.for_update(:update, attrs, actor: actor(a.id)) |> Ash.update(actor: actor(a.id))
        assert org_of(unquote(resource), row.id) == a.id
      end

      test "RED: the same org_id sent back is REFUSED when the record in hand has org_id NOT loaded (the pin cannot tell it is unchanged)" do
        a = mk_org("pin-na")
        row = seed(unquote(resource), Map.put(unquote(Macro.escape(create_attrs)), :org_id, a.id))

        unloaded = unquote(resource) |> Ash.Query.filter(id == ^row.id) |> Ash.Query.select([:id]) |> Ash.read_one!(authorize?: false)
        assert %Ash.NotLoaded{} = unloaded.org_id
        attrs = Map.put(unquote(Macro.escape(update_attrs)), :org_id, a.id)

        result = unloaded |> Ash.Changeset.for_update(:update, attrs, actor: actor(a.id)) |> Ash.update(actor: actor(a.id))

        assert_org_error(result)
        assert org_of(unquote(resource), row.id) == a.id
      end

      test "RED: an actor cannot file a row under another org's org_id" do
        a = mk_org("pin-ca")
        b = mk_org("pin-cb")
        attrs = Map.put(unquote(Macro.escape(create_attrs)), :org_id, b.id)

        result =
          unquote(resource)
          |> Ash.Changeset.for_create(:create, attrs, actor: actor(a.id))
          |> Ash.create(actor: actor(a.id))

        assert {:error, _} = result
        assert [] = unquote(resource) |> Ash.Query.filter(org_id == ^b.id) |> Ash.read!(authorize?: false)
      end

      test "positive control: an actor creates in its own org; the seed path may still set any org" do
        a = mk_org("pin-oa")
        b = mk_org("pin-ob")
        own = Map.put(unquote(Macro.escape(create_attrs)), :org_id, a.id)

        assert {:ok, row} =
                 unquote(resource)
                 |> Ash.Changeset.for_create(:create, own, actor: actor(a.id))
                 |> Ash.create(actor: actor(a.id))

        assert org_of(unquote(resource), row.id) == a.id

        seeded = seed(unquote(resource), Map.put(unquote(Macro.escape(create_attrs)), :org_id, b.id))
        assert org_of(unquote(resource), seeded.id) == b.id
      end
    end
  end

  describe "same-org FK on an update whose record has org_id NOT loaded" do
    alias Demo.CrmScope.Person

    test "RED: re-pointing a person at another org's company is refused (a NotLoaded org_id is read from the row, not skipped)" do
      a = mk_org("pin-fka")
      b = mk_org("pin-fkb")
      company_a = seed(Company, %{name: "A Co", org_id: a.id})
      company_b = seed(Company, %{name: "B Co", org_id: b.id})
      person = seed(Person, %{display_name: "P", company_id: company_a.id, org_id: a.id})

      # The normal read does not select org_id (always_select? false) -- the NotLoaded shape callers hold.
      fetched = Person |> Ash.Query.filter(id == ^person.id) |> Ash.read_one!(actor: actor(a.id))

      result =
        fetched
        |> Ash.Changeset.for_update(:update, %{company_id: company_b.id}, actor: actor(a.id))
        |> Ash.update(actor: actor(a.id))

      assert {:error, %Ash.Error.Invalid{}} = result

      # positive control: the same-org company is accepted
      other_a = seed(Company, %{name: "A2 Co", org_id: a.id})

      assert {:ok, _} =
               fetched
               |> Ash.Changeset.for_update(:update, %{company_id: other_a.id}, actor: actor(a.id))
               |> Ash.update(actor: actor(a.id))
    end
  end
end
