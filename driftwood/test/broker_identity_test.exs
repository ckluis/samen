defmodule DriftwoodWeb.BrokerIdentityTest do
  @moduledoc """
  Eval 2026-11-13 verticals F02/F03/F12: the broker console names the REAL org and user (mount
  labels, like every framework screen), an unknown `?panel=` falls back to the dispatch board,
  and the roster button reports what it does (eligibility) instead of claiming a dispatch.
  """
  use Driftwood.DataCase, async: false

  alias Driftwood.DogfoodScenario
  alias DriftwoodWeb.BrokerLive

  defmodule Dir do
    def orgs, do: [{"b1112d00-0000-4000-8000-0000000000ee", "Harbor Freight Partners"}]
  end

  @org "b1112d00-0000-4000-8000-0000000000ee"

  defp mount(extra \\ %{}) do
    Samen.Web.Mount.new(:settings, Driftwood.Operator, Driftwood.Repo,
      labels: Map.merge(%{org_directory: {Dir, :orgs, []}}, extra)
    )
  end

  defp render(assigns) do
    assigns
    |> Map.put(:__changed__, %{})
    |> BrokerLive.render()
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  defp assigns(mount, panel) do
    %{
      samen_mount: mount,
      samen_acting_as: false,
      no_org: false,
      org_id: @org,
      panel: panel,
      summary: nil,
      loads: [],
      drivers: [],
      settlements: [],
      flash: %{}
    }
  end

  test "the sidebar and crumbs carry the resolved org name and the mount's user, not baked-in literals" do
    html =
      render(
        assigns(mount(%{user_name: "Priya Shah", user_role: "dispatcher", user_initials: "PS"}), "loads")
      )

    assert html =~ "Harbor Freight Partners"
    assert html =~ "Priya Shah"
    assert html =~ "PS"
    refute html =~ "Blue Ridge Logistics"
    refute html =~ "Rosa Medina"
  end

  test "without user labels the framework defaults show, never a hard-coded person" do
    html = render(assigns(mount(), "loads"))

    assert html =~ "Signed in"
    refute html =~ "Rosa Medina"
  end

  test "an unknown ?panel= falls back to the dispatch board; a known one is kept" do
    socket =
      %Phoenix.LiveView.Socket{}
      |> Phoenix.Component.assign(:samen_mount, mount())
      |> Phoenix.Component.assign(:org_id, @org)

    {:noreply, bogus} = BrokerLive.handle_params(%{"panel" => "bogus"}, "http://x/broker", socket)
    assert bogus.assigns.panel == "dashboard"

    {:noreply, known} = BrokerLive.handle_params(%{"panel" => "roster"}, "http://x/broker", socket)
    assert known.assigns.panel == "roster"

    html = render(assigns(mount(), bogus.assigns.panel))
    assert html =~ "Dispatch board"
  end

  test "the roster button reports eligibility by name and creates NO DispatchEvent (a dispatch needs a load)" do
    s = DogfoodScenario.build(lane: "IL->TX", tier: "starter", mrr_cents: 120_000)

    socket =
      %Phoenix.LiveView.Socket{}
      |> Phoenix.Component.assign(:org_id, s.org_id)
      |> then(&%{&1 | assigns: Map.put(&1.assigns, :flash, %{})})

    before_count = length(Ash.read!(Driftwood.Freight.DispatchEvent, authorize?: false))

    {:noreply, socket} = BrokerLive.handle_event("dispatch", %{"driver" => s.compliant_driver_id}, socket)

    msg = socket.assigns.flash["info"]
    assert msg =~ "eligible for dispatch"
    refute msg =~ s.compliant_driver_id
    refute msg =~ "is dispatchable"

    assert length(Ash.read!(Driftwood.Freight.DispatchEvent, authorize?: false)) == before_count

    html = render(Map.put(assigns(mount(), "roster"), :drivers, Driftwood.Reads.driver_roster(BrokerLive.broker_scope(s.org_id))))
    assert html =~ "Check eligibility"
    refute html =~ ~r/dispatch-btn[^>]*>\s*Dispatch\s*</
  end
end
