defmodule Driftwood.OperatorRevealRequestTest do
  @moduledoc """
  T149 B5 — the operator impersonation console now offers a "Request reveal" affordance that
  opens the REQUEST side of the EXISTING reveal-grant lifecycle (`Samen.Reveal.Grants.request/1`)
  — the console previously only had a "Reveal driver record" button that flashed "denied — no
  active second-party grant" with no path to actually OBTAIN one.

  Proofs (each red pairs with a positive control):

    * AFFORDANCE — with an active session but NO grant, the roster offers BOTH the reveal button
      AND the new "Request reveal" button (the entry point that was missing).
    * REQUEST OPENS A LIFECYCLE — invoking it files a real `RevealRequest` for (driver, operator)
      and shows a notice naming the DISTINCT-approver + time-boxed-window facts.
    * GRANTS NOTHING (red) — the request does NOT itself unmask: `reveal_cdl/2` still denies after
      the request (a distinct second party must approve first). Positive control: after a DISTINCT
      party approves, the same reveal succeeds.
  """
  use Driftwood.DataCase, async: false

  alias Driftwood.DogfoodScenario
  alias Samen.OperatorPlane.Actor
  alias Samen.Impersonation
  alias Samen.Reveal.Grants
  alias Samen.Reveal.RevealRequest

  import Ecto.Query, only: [from: 2]

  defp render(assigns) do
    assigns
    |> Map.put(:__changed__, %{})
    |> DriftwoodWeb.OperatorImpersonationLive.render()
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  defp empty_socket, do: %Phoenix.LiveView.Socket{}

  setup do
    scenario = DogfoodScenario.build(lane: "IL->TX", tier: "starter", mrr_cents: 120_000)
    {:ok, scenario: scenario}
  end

  test "AFFORDANCE: an active session with NO grant offers both Reveal and Request-reveal", %{scenario: s} do
    op = Actor.new("op-req-0", :operator_support)
    {:ok, _} = Impersonation.open(op, s.org_id, "B5: request affordance")

    socket = DriftwoodWeb.OperatorImpersonationLive.load(empty_socket(), op.id, s.org_id)
    html = render(socket.assigns)

    assert socket.assigns.reveal_windows == []
    assert html =~ "Reveal driver record"
    assert html =~ "request-reveal-btn"
    assert html =~ "Request reveal"
  end

  test "REQUEST: request_reveal files a RevealRequest and shows the distinct-approver / time-bound notice", %{scenario: s} do
    op = Actor.new("op-req-1", :operator_support)
    {:ok, _} = Impersonation.open(op, s.org_id, "B5: request opens lifecycle")
    driver_id = to_string(s.compliant_driver_id)

    socket = DriftwoodWeb.OperatorImpersonationLive.load(empty_socket(), op.id, s.org_id)
    {:noreply, socket} = DriftwoodWeb.OperatorImpersonationLive.handle_event("request_reveal", %{"driver" => driver_id}, socket)

    # A real RevealRequest row now exists for (driver, operator).
    assert Repo.exists?(
             from(r in RevealRequest, where: r.subject_id == ^driver_id and r.requestor_id == ^op.id)
           )

    # The notice names the accountability facts (distinct approver + time-boxed window).
    notice = socket.assigns.request_notice
    assert notice =~ "DISTINCT"
    assert notice =~ "#{Grants.default_window_minutes()} minutes"

    html = render(socket.assigns)
    assert html =~ "reveal-request-notice"
  end

  test "GRANTS NOTHING (red) + positive control: request alone does not unmask; a distinct approval does", %{scenario: s} do
    op = Actor.new("op-req-2", :operator_support)
    {:ok, _} = Impersonation.open(op, s.org_id, "B5: request grants nothing")
    driver_id = to_string(s.compliant_driver_id)

    # The console's request entry point files the request (same call the LiveView handler makes).
    {:ok, req} = Driftwood.OperatorReveal.request_reveal(op.id, driver_id, "ticket #55: verify CDL")

    # RED: the request alone grants nothing — the reveal still denies (no distinct approval yet).
    assert {:error, _} = Driftwood.OperatorReveal.reveal_cdl(op.id, driver_id)

    # POSITIVE CONTROL: a DISTINCT party approves the request → the reveal now succeeds.
    {:ok, _grant} = Grants.approve(req, %{granted_by: "distinct-approver-b5", window_minutes: 15})
    assert {:ok, plaintext} = Driftwood.OperatorReveal.reveal_cdl(op.id, driver_id)
    assert is_binary(plaintext)
  end
end
