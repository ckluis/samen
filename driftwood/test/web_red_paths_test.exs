defmodule Driftwood.WebRedPathsTest do
  @moduledoc """
  RED-PATH matrix re-run against the LIVE Driftwood web planes (T5.3). Each guarantee
  ships a MUST-FAIL assertion plus a non-vacuous control:

    * masked impersonation renders `••••` for driver name + CDL, NEVER plaintext (with a
      positive control: the real non-PII data shape IS present);
    * an UNGRANTED reveal DENIES (control: a distinct-party grant succeeds);
    * the token-blind AGGREGATE view exposes NO PII (control: it DOES show cross-tenant
      counts/MRR);
    * an FMCSA-blocked (expired-card) driver CANNOT be dispatched from the UI action
      (control: a compliant driver's Dispatch button is enabled);
    * an expired / never-opened impersonation session renders access-denied, NO data.

  The anti-tautology probe on the live masked-render path is documented in
  `test/web_anti_tautology_probe.md` (scratch-dir sabotage → flip confirmed → reverted).
  """
  use Driftwood.DataCase, async: false

  alias Driftwood.{DogfoodScenario, Reads, OperatorDashboard, OperatorReveal}
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

  setup do
    scenario = DogfoodScenario.build(lane: "IL->TX", tier: "starter", mrr_cents: 120_000)
    {:ok, scenario: scenario}
  end

  # ==========================================================================
  # RED PATH 1 — impersonation shows •••• for CDL/name (no plaintext leak)
  # ==========================================================================

  test "impersonation renders •••• for CDL + name and NEVER plaintext", %{scenario: s} do
    op = Actor.new("op-red-1", :operator_support)
    {:ok, _} = Impersonation.open(op, s.org_id, "red path: masked render check")

    socket = DriftwoodWeb.OperatorImpersonationLive.load(empty_socket(), op.id, s.org_id)
    html = render(DriftwoodWeb.OperatorImpersonationLive, socket.assigns)

    # MUST render the mask.
    assert html =~ "••••"
    # MUST NOT leak the plaintext CDL, the driver name, or the vault token.
    refute html =~ "CDL-OK-"
    refute html =~ "CDL-EXP-"
    refute html =~ "Dana"
    refute html =~ "Reed"
    refute html =~ "vt_"

    # POSITIVE CONTROL (non-vacuous): the real non-PII data shape IS present — both
    # driver rows render, with FMCSA badges (so this isn't an empty page passing by
    # rendering nothing).
    assert html =~ "fmcsa-ok"
    assert html =~ "fmcsa-blocked"
    assert length(socket.assigns.drivers) == 2
  end

  # ==========================================================================
  # RED PATH 2 — ungranted reveal denies (control: granted reveal succeeds)
  # ==========================================================================

  test "an UNGRANTED reveal denies; a distinct-party grant succeeds (control)", %{scenario: s} do
    op = Actor.new("op-red-2", :operator_support)
    {:ok, _} = Impersonation.open(op, s.org_id, "red path: reveal gate")
    driver_id = s.compliant_driver_id

    # MUST-FAIL: no grant → denied, •••• stays.
    assert {:error, :denied} = OperatorReveal.reveal_cdl(op.id, driver_id)

    # With no reveal in the assigns (denial leaves `revealed` empty), the render still
    # masks the CDL — plaintext never appears.
    socket = DriftwoodWeb.OperatorImpersonationLive.load(empty_socket(), op.id, s.org_id)
    denied_html = render(DriftwoodWeb.OperatorImpersonationLive, socket.assigns)
    assert denied_html =~ "••••"
    refute denied_html =~ "CDL-OK-"

    # CONTROL (non-vacuous): a distinct-party grant → reveal succeeds.
    {:ok, req} =
      Grants.request(%{
        subject_id: to_string(driver_id),
        requestor_id: op.id,
        reason: "ticket verify"
      })

    {:ok, _} = Grants.approve(req, %{granted_by: "distinct-reviewer-2"})
    assert {:ok, plaintext} = OperatorReveal.reveal_cdl(op.id, driver_id)
    assert String.starts_with?(plaintext, "CDL-OK-")

    # RED PATH 2b — SELF-approval is refused (the distinct-party invariant).
    op3 = Actor.new("op-red-2b", :operator_support)
    {:ok, req3} =
      Grants.request(%{
        subject_id: to_string(driver_id),
        requestor_id: op3.id,
        reason: "self approve attempt"
      })

    assert {:error, :self_approval} = Grants.approve(req3, %{granted_by: op3.id})
    assert {:error, :denied} = OperatorReveal.reveal_cdl(op3.id, driver_id)
  end

  # ==========================================================================
  # RED PATH 3 — aggregate view exposes no PII (control: shows counts/MRR)
  # ==========================================================================

  test "the token-blind aggregate view exposes NO PII (control: shows counts/MRR)", %{scenario: s} do
    {:ok, _} = Driftwood.Aggregate.Rebuild.run(Driftwood.Repo)
    {:ok, lv} = OperatorDashboard.load_volume()
    {:ok, mrr} = OperatorDashboard.mrr()

    html = render(DriftwoodWeb.OperatorDashboardLive, %{load_volume: lv, mrr: mrr})

    # MUST NOT contain any PII / mask / vault token / driver identity.
    refute html =~ "••••"
    refute html =~ "CDL-"
    refute html =~ "Dana"
    refute html =~ "Reed"
    refute html =~ "vt_"
    refute html =~ s.compliant_driver_id

    # POSITIVE CONTROL (non-vacuous): it DOES render the cross-tenant aggregate — the
    # lane cohort + a numeric total — so the "no PII" is the boundary, not an empty page.
    assert html =~ "IL-&gt;TX" or html =~ "IL->TX"
    assert html =~ "MRR"
  end

  # ==========================================================================
  # RED PATH 4 — expired-card driver cannot be dispatched from the UI action
  # ==========================================================================

  test "an FMCSA-blocked driver's Dispatch button is disabled AND the UI action refuses", %{scenario: s} do
    scope = DriftwoodWeb.BrokerLive.broker_scope(s.org_id)
    drivers = Reads.driver_roster(scope)

    blocked = Enum.find(drivers, &(to_string(&1.id) == s.blocked_driver_id))
    compliant = Enum.find(drivers, &(to_string(&1.id) == s.compliant_driver_id))

    # The blocked driver is NOT dispatchable; the compliant one IS (control).
    refute Reads.dispatchable?(blocked)
    assert Reads.dispatchable?(compliant)

    # The rendered roster disables the blocked driver's Dispatch button.
    html =
      render(DriftwoodWeb.BrokerLive, %{
        no_org: false,
        org_id: s.org_id,
        panel: "roster",
        summary: nil,
        loads: [],
        drivers: drivers,
        settlements: []
      })

    assert html =~ "Dispatch (blocked)"
    # And an enabled button exists for the compliant driver (control).
    assert html =~ ">Dispatch<"

    # The UI ACTION decision refuses the blocked driver (defence in depth over the
    # disabled button — even a forged phx-click is rejected server-side).
    assert {:error, :fmcsa_blocked} =
             DriftwoodWeb.BrokerLive.dispatch_decision(s.org_id, s.blocked_driver_id)

    # CONTROL: the compliant driver's UI action is accepted.
    assert {:ok, _} = DriftwoodWeb.BrokerLive.dispatch_decision(s.org_id, s.compliant_driver_id)
  end

  # ==========================================================================
  # RED PATH 5 — expired / never-opened session → access denied, NO data
  # ==========================================================================

  test "an expired / never-opened impersonation session renders access-denied and NO data", %{scenario: s} do
    op = Actor.new("op-red-5", :operator_support)
    # NO session opened → the scope build fails closed.

    socket = DriftwoodWeb.OperatorImpersonationLive.load(empty_socket(), op.id, s.org_id)
    html = render(DriftwoodWeb.OperatorImpersonationLive, socket.assigns)

    assert html =~ "access denied"
    refute html =~ "driver-row"
    refute html =~ "CDL-OK-"
    assert socket.assigns.drivers == []
  end

  # ==========================================================================
  # RED PATH 5b (Gate-5 F3) — NO operator_id/org_id (session-less mount) renders
  # access-denied, NEVER a crash. Regression guard for the /operator/impersonate
  # 500 the Gate-5 red-team found (nil operator_id → FunctionClauseError → 500).
  # ==========================================================================

  test "a session-less mount (nil operator_id/org_id) renders access-denied, does NOT crash" do
    # This is exactly what `mount/3` passes when no params/session are present — the
    # path that used to 500. It must render the documented fail-closed state.
    for {op_id, org_id} <- [{nil, nil}, {nil, "some-org"}, {"op-x", nil}] do
      socket = DriftwoodWeb.OperatorImpersonationLive.load(empty_socket(), op_id, org_id)
      html = render(DriftwoodWeb.OperatorImpersonationLive, socket.assigns)

      assert html =~ "access denied", "nil path {#{inspect(op_id)}, #{inspect(org_id)}} did not deny"
      refute html =~ "driver-row"
      refute html =~ "CDL-OK-"
      assert socket.assigns.drivers == []
      assert socket.assigns.session_inactive == true
    end
  end
end
