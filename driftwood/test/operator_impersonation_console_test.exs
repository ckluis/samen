defmodule Driftwood.OperatorImpersonationConsoleTest do
  @moduledoc """
  T150 (driftwood side) — the freight-shaped operator impersonation console
  (`DriftwoodWeb.OperatorImpersonationLive`) now carries the OPEN-SESSION-WITH-REASON
  affordance (F2) and resolves the target tenant to a NAME (F3).

    * DENIED (no session) — the console renders the access-denied state AND the
      `open_session` form (before T150 nothing called `Samen.Impersonation.open/3`, so this
      surface was permanently unreachable). It names the tenant, not a raw UUID.
    * OPEN (F2) — submitting the form with a reason opens a real session via `open/3`; the
      roster then renders masked and the access is recorded in the tenant's ledger.
    * NAME (F3) — with a session, the banner + crumbs name the resolved tenant
      (\"Blue Ridge Logistics\"), the human-legible \"whose house am I in\".
  """
  use Driftwood.DataCase, async: false

  alias Samen.Impersonation
  alias Samen.OperatorPlane.Actor

  # A directory-resolvable tenant (Driftwood.OperatorSeeds seeds slug == tenant_org_id + name).
  @tenant_org_id "b1112d00-0000-4000-8000-000000000001"
  @tenant_name "Blue Ridge Logistics"
  @operator_id "op-console-1"

  defp render(assigns) do
    assigns
    |> Map.put(:__changed__, %{})
    |> DriftwoodWeb.OperatorImpersonationLive.render()
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  defp empty_socket, do: %Phoenix.LiveView.Socket{}

  setup do
    Driftwood.OperatorSeeds.seed()
    :ok
  end

  test "DENIED with no session: renders the open-session affordance and names the tenant (F2/F3)" do
    socket = DriftwoodWeb.OperatorImpersonationLive.load(empty_socket(), @operator_id, @tenant_org_id)
    assert socket.assigns.session_inactive

    html = render(socket.assigns)
    assert html =~ "no active impersonation session"
    assert html =~ "open-session-form"
    assert html =~ ~s(phx-submit="open_session")
    # F3 — the denied state names the tenant, not only the raw UUID.
    assert html =~ @tenant_name
  end

  test "OPEN (F2): the open_session form opens a real session with a reason; roster then renders MASKED" do
    denied =
      empty_socket()
      |> DriftwoodWeb.OperatorImpersonationLive.load(@operator_id, @tenant_org_id)
      |> Phoenix.Component.assign(:samen_operator_role, :operator_admin)

    {:noreply, opened} =
      DriftwoodWeb.OperatorImpersonationLive.handle_event(
        "open_session",
        %{"reason" => "ticket #9001: driver dispute"},
        denied
      )

    refute opened.assigns.session_inactive
    assert render(opened.assigns) =~ "••••"

    # Recorded in the tenant's ledger (who / why).
    ledger = Impersonation.list_for_org(@tenant_org_id)
    assert Enum.any?(ledger, &(&1.operator_id == @operator_id and &1.reason == "ticket #9001: driver dispute" and &1.active?))
  end

  test "F3: with an active session the banner + crumbs name the resolved tenant, not a raw UUID" do
    {:ok, _session} = Impersonation.open(Actor.new(@operator_id, :operator_support), @tenant_org_id, "ticket #1: verify roster")

    socket = DriftwoodWeb.OperatorImpersonationLive.load(empty_socket(), @operator_id, @tenant_org_id)
    html = render(socket.assigns)

    assert html =~ @tenant_name
    assert html =~ "Impersonating brokerage"
  end
end
