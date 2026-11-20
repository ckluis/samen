defmodule Demo.SupportTicketBreachedNotNullTest do
  @moduledoc """
  `Support.Ticket.breached` is a NOT NULL column (`stk_breached boolean NOT NULL DEFAULT false`), so the resource must not
  accept a NULL for it: an Ash write with `breached: nil` used to pass validation and die at the database
  (`verify.indexes` printed "`allow_nil? true` but the database column is NOT NULL" for every host). The attribute is
  `allow_nil?: false` (its `default: false` still fills an omitted value), so the refusal is an Ash validation error that
  names the field.
  """
  use Demo.DataCase, async: false

  alias Demo.Identity.Org
  alias Demo.SupportScope.Ticket

  defp mk_org do
    {:ok, org} = Org |> Ash.Changeset.for_create(:create, %{name: "breached-nn"}) |> Ash.create(authorize?: false)
    org
  end

  defp create(attrs), do: Ticket |> Ash.Changeset.for_create(:create, attrs) |> Ash.create(authorize?: false)

  test "control: an omitted or an explicit false `breached` is written as false" do
    org = mk_org()

    assert {:ok, %{breached: false}} = create(%{subject: "a", org_id: org.id})
    assert {:ok, %{breached: false}} = create(%{subject: "b", org_id: org.id, breached: false})
    assert {:ok, %{breached: true}} = create(%{subject: "c", org_id: org.id, breached: true})
  end

  test "RED: an explicit nil `breached` is refused by validation naming the field, not by the database" do
    org = mk_org()

    assert {:error, %Ash.Error.Invalid{errors: errors}} = create(%{subject: "d", org_id: org.id, breached: nil})
    assert Enum.any?(errors, &(Map.get(&1, :field) == :breached))
    refute Ash.Resource.Info.attribute(Ticket, :breached).allow_nil?
  end
end
