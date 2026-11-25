defmodule Demo.AnalyticsAppendSystemOnlyTest do
  @moduledoc """
  `Analytics.ProductEvent :append` is the system door `Samen.Analytics.track/1` uses, with the gates (registered
  event, catalogued prop keys, no PII-shaped `entity_ref` or value) in `track/1`. An admin's direct `:append` skipped every
  gate; no actor may run it.
  """
  use Demo.DataCase, async: false

  require Ash.Query

  alias Demo.Analytics.ProductEvent
  alias Demo.Identity.{Org, User}

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


  # -- analytics --------------------------------------------------------------

  describe "Analytics.ProductEvent :append" do
    defp append(actor, org_id, attrs) do
      ProductEvent
      |> Ash.Changeset.for_create(
        :append,
        Map.merge(
          %{org_id: org_id, event_name: :"record.created", occurred_at: DateTime.utc_now() |> DateTime.truncate(:second)},
          attrs
        ),
        actor: actor
      )
      |> Ash.create(actor: actor)
    end

    test "RED: an admin cannot append directly, however clean or dirty the row" do
      org = mk_org()
      admin = mk_actor(org.id, :admin)

      for attrs <- [%{}, %{entity_ref: "alice@example.com"}, %{props: %{"free text" => "Alice Smith 555-0100"}}] do
        assert {:error, %Ash.Error.Forbidden{}} = append(admin, org.id, attrs)
      end

      org_id = org.id
      assert [] = Ash.read!(Ash.Query.filter(ProductEvent, org_id == ^org_id), authorize?: false)
    end

    test "POSITIVE: track/1 (the one door) still writes, and refuses the PII-shaped entity_ref the direct path used to take" do
      org = mk_org()

      assert {:ok, _} =
               Samen.Analytics.track(%{org_id: org.id, event_name: "record.created", entity_ref: "rec-1", props: %{"resource" => "crm.contact"}})

      assert {:error, :pii_rejected} =
               Samen.Analytics.track(%{org_id: org.id, event_name: "record.created", entity_ref: "alice@example.com"})
    end
  end

end
