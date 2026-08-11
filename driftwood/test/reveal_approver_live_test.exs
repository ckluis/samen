defmodule Driftwood.RevealApproverLiveTest do
  @moduledoc """
  PP-13 — the tenant reveal-APPROVER surface (`Samen.Web.Settings.RevealApprovalsLive`)
  walked END-TO-END on the live freight app, closing the deferred request → approve → unmask
  lifecycle: an operator files a reveal REQUEST from the impersonation console; a DISTINCT
  tenant ADMIN approves it on the approver surface, minting the grant; the operator then
  unmasks the driver's vaulted CDL. Without an approval the reveal still denies (mask holds).

  Proofs (each red pairs with a positive control):

    * ORG-SCOPE — a different org's admin sees NONE of this org's pending reveal requests.
    * MASKING — the approver surface renders the operator / subject / field / reason, but
      NEVER the plaintext CDL value nor a `vt_*` token.
    * APPROVE completes the lifecycle — after the admin approves, the operator's `reveal_cdl/2`
      succeeds, AND the approve-moment ("Reveal granted") shows on the tenant's SecurityLive
      ledger (the B6 residual close — approve-audit on the tenant chain).
    * DISTINCT-PARTY / ROLE — a non-admin MEMBER cannot approve (no grant minted); an admin can.
    * DENY — a denial issues no grant (the reveal still denies) and drops the request off the
      pending queue.
  """
  use Driftwood.DataCase, async: false

  alias Driftwood.DogfoodScenario
  alias Driftwood.OperatorReveal
  alias Samen.Reveal.Grants
  alias Samen.Web.Mount
  alias Samen.Web.Plane
  alias Samen.Web.Settings.RevealApprovalsLive
  alias Samen.Web.Settings.SecurityLive

  alias Driftwood.Operator.Membership
  alias Driftwood.Operator.User

  defp settings_mount, do: Mount.new(:settings, Driftwood.Operator, Driftwood.Repo, plane: Plane.tenant())

  defp seed_member!(org_id, role) do
    user =
      User
      |> Ash.Changeset.for_create(:create, %{
        org_id: org_id,
        handle: "approver-#{role}-#{System.unique_integer([:positive])}"
      })
      |> Ash.create!(authorize?: false)

    Membership
    |> Ash.Changeset.for_create(:create, %{org_id: org_id, user_id: user.id, role: role})
    |> Ash.create!(authorize?: false)

    user
  end

  # Drive the approver LiveView through its real load + handle_event, the operator_reveal
  # test pattern (no Endpoint boot).
  defp approver_socket(mount, org_id, user_id) do
    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, mount)
    |> Phoenix.Component.assign(:samen_acting_as, false)
    |> RevealApprovalsLive.load(org_id, user_id)
  end

  setup do
    scenario = DogfoodScenario.build(lane: "IL->TX", tier: "starter", mrr_cents: 120_000)
    {:ok, scenario: scenario}
  end

  test "END-TO-END: operator requests → admin approves → operator unmasks; ledger shows the grant", %{scenario: s} do
    org_id = s.org_id
    driver_id = to_string(s.compliant_driver_id)
    operator_id = "op-approve-e2e"
    admin = seed_member!(org_id, :admin)

    # 1. Operator files the reveal request (the console's request entry point).
    {:ok, req} = OperatorReveal.request_reveal(operator_id, driver_id, "ticket 4242: verify CDL", org_id)

    # 2. The approver surface (admin) shows the pending request — MASKING: operator + subject +
    #    reason are shown, but never the plaintext CDL value nor a vault token.
    pending_html = render_framework(RevealApprovalsLive, settings_mount(), [org_id, admin.id])
    assert pending_html =~ "reveal-approvals-table"
    assert pending_html =~ operator_id
    assert pending_html =~ driver_id
    assert pending_html =~ "ticket 4242"
    assert pending_html =~ "approve-btn-#{req.id}"
    refute pending_html =~ "vt_"
    refute pending_html =~ "CDL-OK", "the requested plaintext CDL value must NEVER render on the approver surface"

    # RED leg: before approval the reveal denies — the mask holds.
    assert {:error, _} = OperatorReveal.reveal_cdl(operator_id, driver_id)

    # 3. The admin approves via the surface's real handle_event.
    socket = approver_socket(settings_mount(), org_id, admin.id)
    assert socket.assigns.can_approve?
    {:noreply, socket} = RevealApprovalsLive.handle_event("approve", %{"request" => req.id}, socket)
    assert socket.assigns.decision_notice =~ "approved"

    # 4. POSITIVE: the operator can now unmask the CDL — the lifecycle completes.
    assert {:ok, plaintext} = OperatorReveal.reveal_cdl(operator_id, driver_id)
    assert is_binary(plaintext)
    # And, for the masking proof, the ACTUAL plaintext never appeared on the approver surface.
    refute pending_html =~ plaintext

    # 5. The approve-moment is on the tenant's SecurityLive reveal ledger (B6 residual closed).
    ledger = render_framework(SecurityLive, settings_mount(), [org_id, nil])
    assert ledger =~ "Reveal granted"
    assert ledger =~ operator_id

    # The request dropped off the pending queue (approval transitioned pending -> approved).
    assert Grants.pending_for_org(org_id, repo: Driftwood.Repo) == []
  end

  test "ORG-SCOPE: a different org's admin sees NONE of this org's pending reveal requests", %{scenario: s} do
    other = DogfoodScenario.build(lane: "OH->GA", tier: "starter", mrr_cents: 130_000)
    operator_id = "op-scope-e2e"
    driver_id = to_string(s.compliant_driver_id)

    {:ok, _req} = OperatorReveal.request_reveal(operator_id, driver_id, "ticket 71: A-side", s.org_id)

    other_admin = seed_member!(other.org_id, :admin)
    html = render_framework(RevealApprovalsLive, settings_mount(), [other.org_id, other_admin.id])

    # The other org's approver sees an empty queue — never org A's operator/subject.
    assert html =~ "reveal-approvals-empty"
    refute html =~ operator_id
    refute html =~ driver_id
  end

  test "DISTINCT-PARTY / ROLE: a non-admin MEMBER cannot approve; an admin can (positive control)", %{scenario: s} do
    org_id = s.org_id
    driver_id = to_string(s.compliant_driver_id)
    operator_id = "op-role-e2e"
    member = seed_member!(org_id, :member)
    admin = seed_member!(org_id, :admin)

    {:ok, req} = OperatorReveal.request_reveal(operator_id, driver_id, "ticket 55: role gate", org_id)

    # RED: a MEMBER cannot approve — the gate refuses and NO grant is minted.
    member_socket = approver_socket(settings_mount(), org_id, member.id)
    refute member_socket.assigns.can_approve?
    {:noreply, member_socket} = RevealApprovalsLive.handle_event("approve", %{"request" => req.id}, member_socket)
    assert member_socket.assigns.decision_notice =~ "admin"
    assert {:error, _} = OperatorReveal.reveal_cdl(operator_id, driver_id), "member's refused approve mints no grant"

    # POSITIVE: an ADMIN approves the SAME request → the operator can unmask.
    admin_socket = approver_socket(settings_mount(), org_id, admin.id)
    {:noreply, _admin_socket} = RevealApprovalsLive.handle_event("approve", %{"request" => req.id}, admin_socket)
    assert {:ok, _plaintext} = OperatorReveal.reveal_cdl(operator_id, driver_id)
  end

  test "DENY: an admin denial mints no grant and drops the request off pending", %{scenario: s} do
    org_id = s.org_id
    driver_id = to_string(s.compliant_driver_id)
    operator_id = "op-deny-e2e"
    admin = seed_member!(org_id, :admin)

    {:ok, req} = OperatorReveal.request_reveal(operator_id, driver_id, "ticket 60: deny", org_id)
    assert [_] = Grants.pending_for_org(org_id, repo: Driftwood.Repo)

    socket = approver_socket(settings_mount(), org_id, admin.id)
    {:noreply, socket} = RevealApprovalsLive.handle_event("deny", %{"request" => req.id}, socket)
    assert socket.assigns.decision_notice =~ "denied"

    # No grant → the reveal still denies (mask holds); the request left the pending queue.
    assert {:error, _} = OperatorReveal.reveal_cdl(operator_id, driver_id)
    assert Grants.pending_for_org(org_id, repo: Driftwood.Repo) == []
  end
end
