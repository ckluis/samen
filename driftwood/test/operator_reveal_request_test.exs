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

  # ==========================================================================
  # PP-12 — the reveal handler is bound to the ACTIVE impersonation session's ORG SCOPE:
  # a client-supplied `driver_id` for a subject OUTSIDE the opened tenant is refused, even
  # when the operator holds a VALID second-party grant for that subject. This is the
  # defense-in-depth the console lacked (the grant still gates; this adds the session/org
  # scope on top so a reveal cannot execute outside the session that frames it). The scope
  # guard is the ONLY thing that changes the outcome here (the grant is live), so the RED
  # leg genuinely flips when the guard is removed. SABOTAGE-PINNED.
  # ==========================================================================

  # A bare test socket has no flash; the scope-denied path calls `put_flash`, so seed it.
  defp with_flash(socket), do: %{socket | assigns: Map.put(socket.assigns, :flash, %{})}

  test "PP-12: a reveal for a subject OUTSIDE the active session's org is refused even WITH a valid grant; in-scope it succeeds" do
    org_a = DogfoodScenario.build(lane: "IL->TX", tier: "starter", mrr_cents: 120_000)
    org_b = DogfoodScenario.build(lane: "OH->GA", tier: "starter", mrr_cents: 130_000)

    op = Actor.new("op-scope-12", :operator_support)
    driver_b = to_string(org_b.compliant_driver_id)

    # A live, distinct-party-approved grant for (operator, driver_b): the reveal itself IS
    # authorized. Absent the scope guard, the operator could unmask driver_b from ANY session.
    {:ok, req} =
      Grants.request(%{subject_id: driver_b, requestor_id: op.id, reason: "ticket #71: verify CDL", repo: Repo})

    {:ok, _grant} = Grants.approve(req, %{granted_by: "distinct-approver-12", repo: Repo})
    assert {:ok, _} = Driftwood.OperatorReveal.reveal_cdl(op.id, driver_b), "the grant is live"

    # The operator opens a session over org_A — NOT driver_b's org.
    {:ok, _} = Impersonation.open(op, org_a.org_id, "ticket #71: A-side support")
    socket_a = DriftwoodWeb.OperatorImpersonationLive.load(empty_socket(), op.id, org_a.org_id) |> with_flash()
    assert socket_a.assigns.impersonating

    # RED — a `phx-value-driver` naming driver_b (foreign to org_A) is REFUSED by the scope
    # guard. Nothing is unmasked, even though the grant would authorize the decrypt.
    {:noreply, refused} =
      DriftwoodWeb.OperatorImpersonationLive.handle_event("reveal", %{"driver" => driver_b}, socket_a)

    assert refused.assigns.revealed == %{},
           "a reveal for a subject outside the session's org scope must unmask NOTHING"

    assert Phoenix.Flash.get(refused.assigns.flash, :error) =~ "scope"

    # POSITIVE CONTROL (anti-tautology) — from a session over org_B (driver_b IS in scope)
    # the SAME grant unmasks. Proves the RED refusal is the scope guard, not a dead reveal.
    {:ok, _} = Impersonation.open(op, org_b.org_id, "ticket #71: B-side support")
    socket_b = DriftwoodWeb.OperatorImpersonationLive.load(empty_socket(), op.id, org_b.org_id) |> with_flash()

    {:noreply, ok} =
      DriftwoodWeb.OperatorImpersonationLive.handle_event("reveal", %{"driver" => driver_b}, socket_b)

    assert map_size(ok.assigns.revealed) == 1,
           "an in-scope reveal under a valid grant unmasks the subject"
  end
end
