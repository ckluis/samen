defmodule Samen.Web.TenantActorSharedTest do
  @moduledoc """
  The shared pieces every converted tenant LiveView uses (and every LiveView still to be converted will):
  the denied / unavailable component (`Samen.Web.TenantActor.Components.actor_refused/1`) and the shared
  `handle_event` guard (`TenantActor.refuse_events/1`). `TenantActor.assign_actor/2` is proven in
  `tenant_role_surfaces_test.exs` against real memberships.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias Samen.Web.TenantActor.Components

  defmodule GuardedLive do
    @moduledoc false
    require Samen.Web.TenantActor

    Samen.Web.TenantActor.refuse_events()

    def handle_event("ping", _params, socket), do: {:noreply, Map.put(socket, :pinged, true)}
  end

  defmodule SomeEventsGuardedLive do
    @moduledoc false
    require Samen.Web.TenantActor

    Samen.Web.TenantActor.refuse_events(["save"])

    def handle_event("save", _params, socket), do: {:noreply, Map.put(socket, :saved, true)}
    def handle_event("retry", _params, socket), do: {:noreply, Map.put(socket, :retried, true)}
  end

  defp socket(assigns), do: %{assigns: assigns}

  describe "actor_refused/1" do
    test "denied: the no-access card, with the noun the surface names, and no data" do
      html = rendered_to_string(Components.actor_refused(%{state: :denied, title: "Contacts", nothing: "there are no contacts to show"}))

      assert html =~ ~s(id="actor-denied")
      assert html =~ "No access"
      assert html =~ "Your account holds no active membership in this workspace, so there are no contacts to show."
      refute html =~ "actor-unavailable"
    end

    test "unavailable: the error card, never the empty state" do
      html = rendered_to_string(Components.actor_refused(%{state: :unavailable, title: "Companies", nothing: "there are no companies to show"}))

      assert html =~ ~s(id="actor-unavailable")
      assert html =~ "Companies unavailable"
      assert html =~ "Nothing is shown rather than a wrong list."
      refute html =~ "actor-denied"
      refute html =~ "no active membership"
    end
  end

  describe "refuse_events/0 (every event)" do
    test "a socket with no acting scope, or a refused actor_state, no-ops every event" do
      assert {:noreply, s} = GuardedLive.handle_event("ping", %{}, socket(%{acting_scope: nil, actor_state: :denied}))
      refute Map.has_key?(s, :pinged)
      assert {:noreply, s} = GuardedLive.handle_event("ping", %{}, socket(%{acting_scope: nil, actor_state: :ok}))
      refute Map.has_key?(s, :pinged)
      assert {:noreply, s} = GuardedLive.handle_event("ping", %{}, socket(%{acting_scope: %{}, actor_state: :unavailable}))
      refute Map.has_key?(s, :pinged)
    end

    test "positive control: an acting socket reaches the view's own clause" do
      assert {:noreply, %{pinged: true}} = GuardedLive.handle_event("ping", %{}, %{assigns: %{acting_scope: %{}, actor_state: :ok}} |> Map.put(:x, 1))
    end
  end

  describe "refuse_events/1 (named events)" do
    test "a refused actor_state no-ops the named events only" do
      refused = socket(%{actor_state: :denied})
      assert {:noreply, s} = SomeEventsGuardedLive.handle_event("save", %{}, refused)
      refute Map.has_key?(s, :saved)
      # the unnamed event still reaches the view (a retry must work from the unavailable state)
      assert {:noreply, %{retried: true}} = SomeEventsGuardedLive.handle_event("retry", %{}, socket(%{actor_state: :unavailable}))
    end

    test "positive control: an :ok actor_state reaches the named event" do
      assert {:noreply, %{saved: true}} = SomeEventsGuardedLive.handle_event("save", %{}, socket(%{actor_state: :ok}))
    end
  end
end
