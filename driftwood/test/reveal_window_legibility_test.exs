defmodule Driftwood.RevealWindowLegibilityTest do
  @moduledoc """
  R-P6 (persona-6 findings P6-F1/F2/F3): the privileged reveal window must be LEGIBLE
  while open, and the reveal control's label must be HONEST about the grant's TRUE scope.

  These probe the live `DriftwoodWeb.OperatorImpersonationLive` render (the same
  `mod.render(assigns)` path persona-6 walked), driving both the granted (window OPEN) and
  ungranted (masked-only) states.

    * P6-F2 (legibility): a window that is open shows WHO approved (`granted_by`), WHEN it
      expires, and a live countdown — not a `display:none` span.
    * P6-F1 (honest scope): a reveal grant is SUBJECT-WIDE, so the control says "Reveal
      driver record" and the banner declares the FULL subject record (name + CDL) is
      unmasked — never a field-narrow "Reveal CDL" that hides the name exposure.
    * P6-F3 (indicator reflects state): the granted subject's row reads "revealed", not a
      "Reveal" affordance, regardless of click vs. passive grant-gated resolution.

  Enforcement is unchanged — this is a UI/legibility + copy fix over the already-correct
  reveal gate (see `web_red_paths_test.exs` for the masking + gate red paths).
  """
  use Driftwood.DataCase, async: false

  alias Driftwood.DogfoodScenario
  alias Samen.OperatorPlane.Actor
  alias Samen.Impersonation
  alias Samen.Reveal.Grants

  defp render(mod, assigns) do
    assigns
    |> Map.put(:__changed__, %{})
    |> mod.render()
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  defp empty_socket, do: %Phoenix.LiveView.Socket{}

  # Persist a rendered DOM snapshot as R-P6 evidence when SAMEN_EVIDENCE=1.
  @evidence_dir Path.expand("../../_orch/tasks/T35/work", __DIR__)
  defp dump_evidence(name, html) do
    if System.get_env("SAMEN_EVIDENCE") == "1" do
      File.mkdir_p!(@evidence_dir)
      File.write!(Path.join(@evidence_dir, name), html)
    end

    :ok
  end

  setup do
    scenario = DogfoodScenario.build(lane: "IL->TX", tier: "starter", mrr_cents: 120_000)
    {:ok, scenario: scenario}
  end

  # ==========================================================================
  # UNGRANTED (control): no window banner, masked, HONEST subject-wide label.
  # ==========================================================================

  test "ungranted operator: no reveal-window banner, masked roster, honest subject-wide label",
       %{scenario: s} do
    op = Actor.new("op-legible-0", :operator_support)
    {:ok, _} = Impersonation.open(op, s.org_id, "R-P6: ungranted legibility control")

    socket = DriftwoodWeb.OperatorImpersonationLive.load(empty_socket(), op.id, s.org_id)
    html = render(DriftwoodWeb.OperatorImpersonationLive, socket.assigns)

    # No open window ⇒ no banner, and the roster is masked.
    assert socket.assigns.reveal_windows == []
    refute html =~ "reveal-window-open"
    refute html =~ "Privileged reveal window OPEN"
    assert html =~ "••••"

    # The control is HONEST about scope: subject-wide "Reveal driver record", never the
    # field-narrow "Reveal CDL" that misrepresents a subject-wide grant (P6-F1).
    assert html =~ "Reveal driver record"
    refute html =~ "Reveal CDL"

    dump_evidence("rp6-reveal-window-BEFORE-ungranted.html", html)
  end

  # ==========================================================================
  # GRANTED: window OPEN ⇒ approver + expiry + countdown VISIBLE; row "revealed".
  # ==========================================================================

  test "granted operator: reveal window is legible (approver, expiry, countdown) and honest",
       %{scenario: s} do
    op = Actor.new("op-legible-1", :operator_support)
    {:ok, _} = Impersonation.open(op, s.org_id, "R-P6: granted legibility")
    driver_id = to_string(s.compliant_driver_id)
    approver = "distinct-reviewer-p6"

    {:ok, req} =
      Grants.request(%{subject_id: driver_id, requestor_id: op.id, reason: "R-P6 ticket verify"})

    {:ok, _grant} = Grants.approve(req, %{granted_by: approver, window_minutes: 15})

    socket = DriftwoodWeb.OperatorImpersonationLive.load(empty_socket(), op.id, s.org_id)
    html = render(DriftwoodWeb.OperatorImpersonationLive, socket.assigns)

    # The window is recognized as OPEN for this subject.
    assert [w] = socket.assigns.reveal_windows
    assert w.subject_id == driver_id
    assert w.granted_by == approver

    # P6-F2: the banner is VISIBLE and names WHO approved + WHEN it expires + a countdown.
    assert html =~ "reveal-window-open"
    assert html =~ "Privileged reveal window OPEN"
    assert html =~ "approved by"
    assert html =~ approver
    assert html =~ "expires"
    assert html =~ "left"

    # P6-F1 (honest scope): the banner declares the FULL subject record is unmasked
    # (name + CDL), i.e. subject-wide — not a field-narrow "CDL only" claim.
    assert html =~ "FULL subject record"
    assert html =~ "subject-wide"

    # P6-F3 (indicator reflects state): the granted subject's row reads "revealed", not a
    # "Reveal" affordance — label and resolved scope AGREE.
    assert html =~ "revealed · record open"

    dump_evidence("rp6-reveal-window-AFTER-granted.html", html)
  end

  # ==========================================================================
  # SANITY: the countdown counts DOWN as the clock advances (not a static string).
  # ==========================================================================

  test "reveal-window countdown reflects the advancing clock", %{scenario: s} do
    op = Actor.new("op-legible-2", :operator_support)
    {:ok, _} = Impersonation.open(op, s.org_id, "R-P6: countdown")
    driver_id = to_string(s.compliant_driver_id)

    {:ok, req} =
      Grants.request(%{subject_id: driver_id, requestor_id: op.id, reason: "R-P6 countdown"})

    {:ok, _} = Grants.approve(req, %{granted_by: "reviewer-cd", window_minutes: 15})

    socket = DriftwoodWeb.OperatorImpersonationLive.load(empty_socket(), op.id, s.org_id)
    [w] = socket.assigns.reveal_windows

    early = %{socket.assigns | now: DateTime.add(w.expires_at, -600, :second)}
    late = %{socket.assigns | now: DateTime.add(w.expires_at, -60, :second)}

    early_html = render(DriftwoodWeb.OperatorImpersonationLive, early)
    late_html = render(DriftwoodWeb.OperatorImpersonationLive, late)

    assert early_html =~ "10m 0s left"
    assert late_html =~ "1m 0s left"
  end
end
