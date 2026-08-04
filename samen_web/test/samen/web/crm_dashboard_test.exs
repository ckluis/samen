defmodule Samen.Web.CRMDashboardTest do
  @moduledoc """
  End-to-end proofs for the G8 tenant DASHBOARD (T56) — the CRM dashboard as the FIRST client
  of the generic chart/dashboard kit (`Samen.Web.Reads.aggregate_by!/3` + `time_series!/3`
  rendered through `Samen.UI.dashboard/1` + `bar_chart/1` / `pie_chart/1` / `line_chart/1`).
  Each proof is anti-tautology (a positive control anchors every guard):

    * GEOMETRY — a chart renders the RIGHT server-computed SVG geometry from a `%Series{}`: bar
      heights are proportional to the values, pie slices to the share, the line has a point per
      bucket. The exact values also appear in the accessible data table.
    * FIRST-CLIENT — the real DashboardLive renders the stat tiles + all three chart SVGs from
      seeded aggregates.
    * ORG-SCOPE (sabotage-refutable) — org B's opportunities NEVER contribute to org A's
      dashboard aggregates (and DO appear on org B's own — the refutation control).
    * NO-JS / NO-CDN — the chart geometry is inline `<svg>` in the server-rendered DOM with an
      accessible `<table>` fallback; the component source pulls NO external charting CDN/script.
    * MASKING (verified non-PII) — the aggregated Opportunity facets/measure are non-vaulted
      (anchored refutably against the vaulted `Person.full_name`), so no chart can leak a secret.
  """
  use Samen.WebTest.DataCase, async: false

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Samen.Web.CRM.DashboardLive
  alias Samen.Web.CRM.Reads
  alias Samen.Web.Mount
  alias Samen.Web.Series
  alias Samen.Web.Series.Point

  @opportunity Samen.WebTest.Crm.Opportunity
  @pipeline Samen.WebTest.Crm.Pipeline
  @person Samen.WebTest.Crm.Person

  # -- seed helpers ------------------------------------------------------------

  defp money(cents), do: Samen.Type.Money.from_cents(cents, :USD)

  defp seed_stage(org_id, name, label, order) do
    @pipeline
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org_id, name: name, label: label, stage_order: order, stage_type: "open"},
      authorize?: false
    )
    |> Ash.create!()
  end

  defp seed_opp(org_id, attrs) do
    @opportunity
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(%{org_id: org_id, name: "opp", status: :open}, attrs),
      authorize?: false
    )
    |> Ash.create!()
  end

  # -- GEOMETRY (server-computed SVG) ------------------------------------------

  test "GEOMETRY: bar heights are proportional to the values; the table mirrors them" do
    series = %Series{
      points: [%Point{key: :a, label: "Alpha", value: 10, raw: 10}, %Point{key: :b, label: "Beta", value: 5, raw: 5}],
      measure: :count,
      dimension: :status,
      total: 15
    }

    html = render_component(&Samen.UI.Chart.bar_chart/1, series: series, id: "bc")

    # Inline SVG, one rect per slice, geometry computed server-side.
    assert html =~ "<svg"
    assert html =~ ~s(data-value="10")
    assert html =~ ~s(data-value="5")
    # The value-10 bar is exactly TWICE the value-5 bar's height (proportional to the max).
    assert html =~ ~s(height="140.0")
    assert html =~ ~s(height="70.0")
    # Accessible data-table fallback carries the exact values (screen-reader legible, no JS).
    assert html =~ "chart-data"
    assert html =~ "<td>10</td>"
    assert html =~ "<td>5</td>"
    assert html =~ "Alpha"
  end

  test "GEOMETRY: a pie renders a slice per share, with percentages" do
    series = %Series{
      points: [%Point{key: :x, label: "Ex", value: 5, raw: 5}, %Point{key: :y, label: "Why", value: 5, raw: 5}],
      measure: :count,
      dimension: :status,
      total: 10
    }

    html = render_component(&Samen.UI.Chart.pie_chart/1, series: series, id: "pc")

    assert html =~ "<svg"
    # Two equal slices → 50.0% each; the arc <path>s are server-computed.
    assert html =~ "chart-slice"
    assert html =~ "50.0%"
    # Two path elements (one per slice).
    assert length(String.split(html, ~s(class="chart-slice"))) - 1 == 2
  end

  test "GEOMETRY: a line renders a point per bucket over the polyline" do
    series = %Series{
      points: [
        %Point{key: ~D[2026-01-01], label: "Jan 2026", value: 2, raw: 2},
        %Point{key: ~D[2026-02-01], label: "Feb 2026", value: 0, raw: 0},
        %Point{key: ~D[2026-03-01], label: "Mar 2026", value: 1, raw: 1}
      ],
      measure: :count,
      dimension: :bucket,
      total: 3
    }

    html = render_component(&Samen.UI.Chart.line_chart/1, series: series, id: "lc")

    assert html =~ "<polyline"
    # Three dots — one per bucket.
    assert length(String.split(html, "chart-line-dot")) - 1 == 3
    assert html =~ "Jan 2026"
  end

  # -- FIRST-CLIENT (real DashboardLive) ---------------------------------------

  defp seed_dashboard_org(prefix) do
    org_id = Ash.UUID.generate()
    open_stage = seed_stage(org_id, "#{prefix}-open", "#{prefix} Open", 0)
    won_stage = seed_stage(org_id, "#{prefix}-won", "#{prefix} Won", 1)
    today = Date.utc_today()

    for _ <- 1..3, do: seed_opp(org_id, %{status: :open, value: money(100_00), pipeline_id: open_stage.id, close_date: today})
    seed_opp(org_id, %{status: :won, value: money(500_00), pipeline_id: won_stage.id, close_date: today})
    org_id
  end

  test "FIRST-CLIENT: DashboardLive renders stat tiles + all three chart SVGs from aggregates" do
    mount = build_mount(:crm)
    org_id = seed_dashboard_org("A")

    html = render_live(DashboardLive, mount, [org_id])

    # The dashboard grid + all three chart tiles present.
    assert html =~ ~s(id="crm-dash-grid")
    assert html =~ "dash-value-by-stage"
    assert html =~ "dash-by-status"
    assert html =~ "dash-closing-over-time"
    # Inline SVG geometry (no JS needed) + the accessible table fallback.
    assert html =~ "<svg"
    assert html =~ "chart-data"
    # Stat tile: 3 open opportunities (a DB count).
    assert html =~ "Open opportunities"
    # by-status pie: the open slice's count is 3, the won slice 1 (DB counts).
    assert html =~ ~s(data-value="3")
    assert html =~ ~s(data-value="1")
    # value-by-stage bar: the open stage sums to $300 = 30000 cents (a DB Money sum).
    assert html =~ ~s(data-value="30000")
    assert html =~ ~s(data-value="50000")
  end

  # -- ORG-SCOPE (sabotage-refutable) ------------------------------------------

  test "ORG-SCOPE: org B never contributes to org A's dashboard aggregates" do
    mount = build_mount(:crm)
    org_a = seed_dashboard_org("A")

    # Org B genuinely holds 5 same-key (open) opportunities — the refutation setup.
    org_b = Ash.UUID.generate()
    b_stage = seed_stage(org_b, "B-open", "B Open", 0)
    for _ <- 1..5, do: seed_opp(org_b, %{status: :open, value: money(999_00), pipeline_id: b_stage.id, close_date: Date.utc_today()})

    a_html = render_live(DashboardLive, mount, [org_a])
    b_html = render_live(DashboardLive, mount, [org_b])

    # Reads-level: org A's by-status open count is 3 (its own), NOT 8 (3 + org B's 5).
    scope_a = Mount.scope(mount, org_a)
    a_status = Reads.opportunities_by_status(mount, scope_a)
    open = Enum.find(a_status.points, &(&1.key == :open))
    assert open.value == 3
    assert a_status.total == 4

    # DOM-level: org A shows count 3; org B's magnitude (999 dollars = 99900 cents) is absent.
    assert a_html =~ ~s(data-value="3")
    refute a_html =~ ~s(data-value="99900")
    refute a_html =~ ~s(data-value="499500")

    # Refutation control: org B's OWN dashboard shows its 5 (so the absence above is real
    # org-scoping, not a seed that never rendered anywhere).
    scope_b = Mount.scope(mount, org_b)
    b_status = Reads.opportunities_by_status(mount, scope_b)
    assert Enum.find(b_status.points, &(&1.key == :open)).value == 5
    assert b_html =~ ~s(data-value="5")
  end

  # -- NO-JS / NO-CDN ----------------------------------------------------------

  test "NO-CDN: the chart component source pulls no external CDN/script; geometry is inline SVG" do
    for path <- [
          "lib/samen/ui/chart.ex",
          "lib/samen/ui/dashboard.ex"
        ] do
      src = File.read!(path)
      refute src =~ "http://", "#{path} must not reference an external URL"
      refute src =~ "https://", "#{path} must not reference an external URL"
      refute src =~ "cdn", "#{path} must not reference a CDN"
      refute src =~ "<script", "#{path} must not embed an external script"
    end

    # And the rendered chart is self-contained inline SVG (present with JS off).
    series = %Series{points: [%Point{key: :a, label: "A", value: 1, raw: 1}], measure: :count, dimension: :status, total: 1}
    html = render_component(&Samen.UI.Chart.bar_chart/1, series: series, id: "bc")
    assert html =~ "<svg"
    refute html =~ "<script"
  end

  # -- MASKING (verified non-PII, refutable) -----------------------------------

  test "MASKING: the aggregated Opportunity facets/measure are non-vaulted (anchored vs a 🔒 field)" do
    # The refutation anchor: Person.full_name IS vault-routed — so the negatives below are a
    # real property of the aggregated fields, not a check that would pass for everything.
    assert Samen.Pii.Info.vault_routed?(@person, :full_name)

    # Every field the dashboard aggregates/labels/axes is non-vaulted → no chart can render a
    # secret as a slice, axis, tooltip, or summed value.
    refute Samen.Pii.Info.vault_routed?(@opportunity, :status)
    refute Samen.Pii.Info.vault_routed?(@opportunity, :pipeline_id)
    refute Samen.Pii.Info.vault_routed?(@opportunity, :value)
    refute Samen.Pii.Info.vault_routed?(@opportunity, :close_date)
  end
end
