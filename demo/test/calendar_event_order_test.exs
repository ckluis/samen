defmodule Demo.CalendarEventOrderTest do
  @moduledoc """
  `Calendar.Event`: `ends_at` may not precede `starts_at`, on create and on update (including when only one of
  them changes, compared against the stored other).
  """
  use Demo.DataCase, async: false

  alias Demo.CalendarScope.Event
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


  # -- calendar ---------------------------------------------------------------

  describe "Calendar.Event ends_at never precedes starts_at" do
    @t0 ~U[2026-12-01 10:00:00.000000Z]

    defp mk_event(actor, org_id, attrs) do
      Event
      |> Ash.Changeset.for_create(:create, Map.merge(%{title: "e", org_id: org_id, starts_at: @t0}, attrs), actor: actor)
      |> Ash.create(actor: actor)
    end

    defp update_event(actor, event, attrs),
      do: event |> Ash.Changeset.for_update(:update, attrs, actor: actor) |> Ash.update(actor: actor)

    test "RED on create; CONTROL: the equal and later instants and a missing end are accepted" do
      org = mk_org()
      member = mk_actor(org.id, :member)

      assert {:error, %Ash.Error.Invalid{}} = mk_event(member, org.id, %{ends_at: DateTime.add(@t0, -1, :second)})
      assert {:ok, _} = mk_event(member, org.id, %{ends_at: DateTime.add(@t0, 3600, :second)})
      assert {:ok, _} = mk_event(member, org.id, %{ends_at: @t0})
      assert {:ok, _} = mk_event(member, org.id, %{})
    end

    test "RED on update, whichever one instant moves (compared against the stored other)" do
      org = mk_org()
      member = mk_actor(org.id, :member)
      {:ok, event} = mk_event(member, org.id, %{ends_at: DateTime.add(@t0, 3600, :second)})

      # only ends_at changes: before the stored start
      assert {:error, %Ash.Error.Invalid{}} = update_event(member, event, %{ends_at: DateTime.add(@t0, -60, :second)})
      # only starts_at changes: after the stored end
      assert {:error, %Ash.Error.Invalid{}} = update_event(member, event, %{starts_at: DateTime.add(@t0, 7200, :second)})
      # both change, inverted
      assert {:error, %Ash.Error.Invalid{}} =
               update_event(member, event, %{starts_at: DateTime.add(@t0, 7200, :second), ends_at: @t0})

      # CONTROL: moving both consistently, or touching neither, is accepted
      assert {:ok, moved} =
               update_event(member, event, %{
                 starts_at: DateTime.add(@t0, 7200, :second),
                 ends_at: DateTime.add(@t0, 10_800, :second)
               })

      assert DateTime.compare(moved.ends_at, moved.starts_at) == :gt
      assert {:ok, _} = update_event(member, moved, %{title: "renamed"})
    end
  end
end
