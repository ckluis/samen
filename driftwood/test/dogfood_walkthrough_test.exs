defmodule Driftwood.DogfoodWalkthroughTest do
  @moduledoc """
  The scripted end-to-end DOGFOOD walkthrough (T5.3 clause (c)) — drives the WHOLE
  Driftwood story with assertions, and renders the LIVE LiveViews' HEEx:

    1. create a brokerage tenant → add carriers/shippers/drivers/loads;
    2. DISPATCH the compliant driver (FMCSA gate passes);
    3. SETTLE (the reshaped two-sided money: linehaul − advances − factoring − claims);
    4. rebuild the tenant rollup + the cross-tenant aggregate;
    5. the broker DASHBOARD renders the rollup-backed summary (never a raw scan);
    6. the broker ROSTER + operator IMPERSONATION render driver PII as `••••`;
    7. an operator opens MASKED impersonation and sees the REAL roster/load board (••••);
    8. a distinct-party REVEAL grant unmasks ONE driver's CDL end-to-end;
    9. the token-blind AGGREGATE view shows cross-tenant load volume / MRR with NO PII.

  The human-followable version is `docs/driftwood-dogfood.md` (drives the same steps
  against the running server).
  """
  use Driftwood.DataCase, async: false

  alias Driftwood.{DogfoodScenario, Reads, BrokerRollup, OperatorDashboard, OperatorReveal}
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

  # ==========================================================================

  test "full dogfood: create → dispatch → settle → rollup → dashboard → impersonate masked → reveal one → aggregate" do
    # --- 1-4. Build the fleet (two orgs so the aggregate has >1 tenant/cohort) ---
    %{orgs: [a, _b]} = DogfoodScenario.build_fleet(Driftwood.Repo)

    # A dispatch and a settlement exist for org A (the scenario dispatched the
    # compliant driver onto load1 and created one settlement).
    assert is_binary(a.dispatch_id)
    assert is_binary(a.settlement_id)

    # --- 5. Broker DASHBOARD reads the rollup-backed summary (never raw scans) ---
    summary = BrokerRollup.summary(a.org_id)
    assert summary.settlements.settlement_count == 1
    # net_payable from the SQL rollup == the Context reshape to the cent:
    # gross 520000 - advances 50000 - factoring trunc(520000*300/10000)=15600 - claims 5000 = 449400
    assert summary.settlements.net_payable_cents == 449_400

    dash_html =
      render(DriftwoodWeb.BrokerLive, %{
        no_org: false,
        org_id: a.org_id,
        panel: "dashboard",
        summary: summary,
        loads: [],
        drivers: [],
        settlements: []
      })

    assert dash_html =~ "rollup-backed"
    assert dash_html =~ "net payable"

    # --- 6. Broker ROSTER reads its OWN drivers' PII in CLEAR (F2 tenant-owner rule) ---
    # The doc's two-key-classes tenant-as-owner posture (§external-surface :707): a
    # tenant reads its OWN org's PII in clear per its own RBAC, with NO operator reveal
    # grant. `broker_scope/1` carries `plane: :tenant`; `driver_roster/1` threads it
    # through `Samen.Api.PiiResolution.resolve/4`, which unmasks the driver's own CDL +
    # name. (This fixes the Gate-5 F2 fail-safe over-masking — the broker used to see
    # ••••.) The OPERATOR plane still masks (step 7).
    broker_scope = DriftwoodWeb.BrokerLive.broker_scope(a.org_id)
    drivers = Reads.driver_roster(broker_scope)
    assert length(drivers) == 2

    roster_html =
      render(DriftwoodWeb.BrokerLive, %{
        no_org: false,
        org_id: a.org_id,
        panel: "roster",
        summary: nil,
        loads: [],
        drivers: drivers,
        settlements: []
      })

    # The broker sees its OWN drivers' CDL number + name in CLEAR (no reveal grant).
    assert roster_html =~ "CDL-OK-"
    assert roster_html =~ "Dana"
    # The vault token itself NEVER renders (plaintext came through the decrypt
    # chokepoint, not the raw token).
    refute roster_html =~ "vt_"
    # FMCSA badges: one OK (compliant), one BLOCKED (expired medical).
    assert roster_html =~ "OK"
    assert roster_html =~ "BLOCKED"

    # --- 7. Operator opens MASKED impersonation and sees the REAL roster (••••) ---
    op = Actor.new("op-walkthrough-1", :operator_support)
    {:ok, _session} = Impersonation.open(op, a.org_id, "ticket #7781: dispatch dispute")

    imp_socket = DriftwoodWeb.OperatorImpersonationLive.load(empty_socket(), op.id, a.org_id)
    imp_html = render(DriftwoodWeb.OperatorImpersonationLive, imp_socket.assigns)

    # Real data shape present (both driver rows), PII masked, plaintext absent.
    assert imp_html =~ "••••"
    refute imp_html =~ "CDL-OK-"
    refute imp_html =~ "CDL-EXP-"
    refute imp_html =~ "Dana"
    refute imp_html =~ "vt_"
    # Accountability line.
    assert imp_html =~ "ticket #7781: dispatch dispute"
    assert imp_html =~ "PII is masked"

    # --- 8. A distinct-party REVEAL grant unmasks ONE driver's CDL end-to-end ---
    driver_id = a.compliant_driver_id

    # Before any grant: reveal DENIES (•••• stays).
    assert {:error, :denied} = OperatorReveal.reveal_cdl(op.id, driver_id)

    {:ok, req} =
      Grants.request(%{
        subject_id: to_string(driver_id),
        requestor_id: op.id,
        reason: "ticket #7781 — verify CDL against carrier packet"
      })

    {:ok, _grant} = Grants.approve(req, %{granted_by: "compliance-lead-9"})

    # After the distinct-party grant: reveal SUCCEEDS with the real plaintext.
    assert {:ok, plaintext} = OperatorReveal.reveal_cdl(op.id, driver_id)
    assert String.starts_with?(plaintext, "CDL-OK-")

    # The impersonation view, driven through its reveal handler, now shows that ONE
    # driver's plaintext while the OTHER driver stays masked.
    {:noreply, revealed_socket} =
      DriftwoodWeb.OperatorImpersonationLive.handle_event(
        "reveal",
        %{"driver" => to_string(driver_id)},
        imp_socket
      )

    revealed_html = render(DriftwoodWeb.OperatorImpersonationLive, revealed_socket.assigns)
    assert revealed_html =~ plaintext
    # The other (blocked) driver's CDL is still masked.
    assert revealed_html =~ "••••"

    # --- 9. The token-blind AGGREGATE view shows cross-tenant volume/MRR, NO PII ---
    {:ok, lv} = OperatorDashboard.load_volume()
    {:ok, mrr} = OperatorDashboard.mrr()

    # Cross-tenant: TX->CA lane spans BOTH orgs (tenant_count 2); MRR sums both.
    lane = Enum.find(lv.by_lane, &(&1.lane == "TX->CA"))
    assert lane.tenant_count == 2
    assert mrr.total_cents == 550_000

    # ADR-009: the aggregate view is the FRAMEWORK Samen.Web.Operator.AggregateLive,
    # mounted over Driftwood's token-blind projection (the `Driftwood.OperatorAggregate`
    # loader on the mount labels — the same mount DriftwoodWeb.Router builds).
    agg_mount =
      Samen.Web.Mount.new(
        :aggregate,
        Driftwood.Aggregate,
        Driftwood.Repo,
        plane: Samen.Web.Plane.operator("driftwood-operator", nil),
        labels: %{
          operator_title: "Portfolio",
          operator_workspace: "Driftwood Ops",
          aggregate_loader: {Driftwood.OperatorAggregate, :load, []}
        }
      )

    agg_socket =
      empty_socket()
      |> Phoenix.Component.assign(:samen_mount, agg_mount)
      |> Samen.Web.Operator.AggregateLive.load()

    agg_html = render(Samen.Web.Operator.AggregateLive, agg_socket.assigns)

    assert agg_html =~ "TX-&gt;CA" or agg_html =~ "TX->CA"
    assert agg_html =~ "$5500.00"
    # No PII anywhere on the aggregate plane.
    refute agg_html =~ "••••"
    refute agg_html =~ "CDL-"
    refute agg_html =~ "Dana"
    refute agg_html =~ plaintext
  end

  # The gate requires: the /broker tenant console sidebar must expose all three
  # inherited universal scopes (CRM, Billing, Support) so the "freight 20% +
  # inherited 80%" thesis is legible in navigation — reachable WITHOUT typing URLs.
  test "the /broker tenant console sidebar exposes CRM, Billing, AND Support (thesis in nav)" do
    org = "b1112d00-0000-4000-8000-000000000001"

    html =
      render(DriftwoodWeb.BrokerLive, %{
        no_org: false,
        org_id: org,
        panel: "dashboard",
        summary: nil,
        loads: [],
        drivers: [],
        settlements: []
      })

    # The three inherited module groups are present in the broker sidebar…
    assert html =~ "CRM"
    assert html =~ "Billing"
    assert html =~ "Support"
    # …and each is reachable via a real href (no dead links).
    assert html =~ ~s(href="/crm/companies?org=#{org}")
    assert html =~ ~s(href="/crm/contacts?org=#{org}")
    assert html =~ ~s(href="/crm/pipeline?org=#{org}")
    assert html =~ ~s(href="/billing?org=#{org}")
    assert html =~ ~s(href="/billing/invoices?org=#{org}")
    assert html =~ ~s(href="/billing/plans?org=#{org}")
    assert html =~ ~s(href="/support?org=#{org}")
    # The freight vertical (the 20%) is still present alongside the inherited 80%.
    # (`&` is HTML-escaped to `&amp;` in the rendered href.)
    assert html =~ "Operations"
    assert html =~ ~s(href="/broker?panel=loads&amp;org=#{org}")
  end
end
