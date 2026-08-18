defmodule Samen.UI.GanttComponentTest do
  @moduledoc """
  Unit proofs for the GENERIC timeline/Gantt renderer (`Samen.UI.gantt/1`, T53/WS-G) — the
  reusable renderer the Work Tasks timeline (and later any start/end resource) consumes. These
  test the FRAMEWORK component in isolation from any vertical, against a hand-built
  `%Samen.Web.Board{}` of lanes over a fixed window:

    * LAYOUT — each row is a bar whose `left`/`width` are SERVER-computed `%` of the window span
      (deterministic positions), so the whole Gantt is in the no-JS DOM.
    * POINT — a NULL/absent end renders a zero-width POINT marker (never an infinite bar).
    * LANES — one row per lane, header label + exact count; a `+N more` overflow when capped.
    * AXIS + NOW — tick labels are positioned across the window; a `today` inside the window
      draws a "now" marker.
    * NO-JS NAV — prev/next are real `<a href>` links (inert spans when no href).
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Samen.Web.Board

  # A 30-day window so day offsets map to clean percentages (Date span = 30 days).
  @ws ~D[2026-03-01]
  @we ~D[2026-03-31]

  defp bar_slot do
    [%{inner_block: fn _changed, row -> Phoenix.HTML.raw(~s(<b class="nm">#{row.title}</b>)) end}]
  end

  defp sample_board do
    %Board{
      group_field: :status,
      per_group_limit: 2,
      max_groups: 50,
      groups: [
        %Board.Group{
          key: :pending,
          label: "Pending",
          # FIRST-HALF: 03-01 → 03-16  =>  left 0%, width 50%
          # SECOND-HALF: 03-16 → 03-31 =>  left 50%, width 50%
          rows: [
            %{id: 1, title: "FIRST-HALF", start: ~D[2026-03-01], finish: ~D[2026-03-16]},
            %{id: 2, title: "SECOND-HALF", start: ~D[2026-03-16], finish: ~D[2026-03-31]}
          ],
          count: 5,
          has_more: true,
          next_cursor: {2}
        },
        %Board.Group{
          key: :in_progress,
          label: "In progress",
          # POINT: nil end => zero-width marker at 03-10 (left 30%)
          rows: [%{id: 3, title: "POINTY", start: ~D[2026-03-10], finish: nil}],
          count: 1,
          has_more: false
        },
        %Board.Group{key: :done, label: "Done", rows: [], count: 0, has_more: false}
      ]
    }
  end

  defp render(assigns) do
    render_component(
      &Samen.UI.gantt/1,
      Map.merge(
        %{
          id: "g",
          board: sample_board(),
          range_start: @ws,
          range_end: @we,
          start_field: :start,
          end_field: :finish,
          window_label: "Mar 1 – Mar 30, 2026",
          bar: bar_slot()
        },
        assigns
      )
    )
  end

  test "LAYOUT: bars are positioned with server-computed left/width % of the window" do
    html = render(%{})

    # A bar over the first half: left 0%, width 50% (deterministic, from the fixture dates).
    assert html =~ "left:0.0%;width:50.0%"
    # A bar over the second half: left 50%, width 50%.
    assert html =~ "left:50.0%;width:50.0%"
    # The bar content comes through the :bar slot.
    assert html =~ "FIRST-HALF"
    assert html =~ "SECOND-HALF"
  end

  test "bar_geometry/5 computes clamped fractions and flags a point" do
    row = %{id: 9, start: ~D[2026-03-16], finish: ~D[2026-03-31]}
    geo = Samen.UI.Gantt.bar_geometry(row, :start, :finish, @ws, @we)
    assert geo.left == 50.0
    assert geo.width == 50.0
    refute geo.point?

    # A bar extending past the window edge is clamped to 100%, never beyond.
    over = %{id: 10, start: ~D[2026-03-16], finish: ~D[2026-06-01]}
    assert Samen.UI.Gantt.bar_geometry(over, :start, :finish, @ws, @we).width == 50.0

    # A nil end is a zero-width point (never an infinite bar).
    point = %{id: 11, start: ~D[2026-03-10], finish: nil}
    pg = Samen.UI.Gantt.bar_geometry(point, :start, :finish, @ws, @we)
    assert pg.point?
    assert pg.width == 0.0
    assert pg.left == 30.0
  end

  test "POINT: a nil end renders a zero-width point marker, not an infinite bar" do
    html = render(%{})
    assert html =~ "gantt-bar-point"
    # The point sits at 03-10 = 30% and has width 0 (min-width via CSS, never 100%).
    assert html =~ "left:30.0%;width:0.0%"
    assert html =~ "POINTY"
  end

  test "LANES: one row per lane, header label + exact count, +N more when capped" do
    html = render(%{})

    assert html =~ ~s(id="g-lane-pending")
    assert html =~ ~s(id="g-lane-in_progress")
    assert html =~ ~s(id="g-lane-done")
    assert html =~ "Pending"
    assert html =~ "In progress"
    # Exact count from the group (5), not length(rows) (2) …
    assert html =~ ~s(class="gantt-lane-n">5<)
    # … and the "+N more" overflow (5 total − 2 shown = 3) in the server-rendered DOM.
    assert html =~ "+3 more"
    # An empty lane renders its placeholder text, not a bar.
    assert html =~ "gantt-lane-empty"
  end

  test "AXIS + NOW: tick labels span the window; a today inside draws a now marker" do
    html = render(%{today: ~D[2026-03-16]})

    # Axis ticks are positioned (first at 0%, last at 100%) with month/day labels.
    assert html =~ ~s(class="gantt-tick")
    assert html =~ "Mar 1"
    assert html =~ "left:0.0%"
    assert html =~ "left:100.0%"
    # today = 03-16 = 50% of a 30-day window → a "now" marker at 50%.
    assert html =~ ~s(class="gantt-now")
    assert html =~ "left:50.0%"
  end

  test "NO-JS NAV: prev/next are real links when hrefs given, inert spans otherwise" do
    linked = render(%{prev_href: "?from=2026-02-01", next_href: "?from=2026-04-01"})
    assert linked =~ ~s(<a href="?from=2026-02-01")
    assert linked =~ ~s(<a href="?from=2026-04-01")
    assert linked =~ ~s(class="gantt-nav")

    inert = render(%{prev_href: nil, next_href: nil})
    assert inert =~ "gantt-nav-off"
  end

  test "custom lane_header slot overrides the default header" do
    html =
      render_component(&Samen.UI.gantt/1, %{
        id: "g",
        board: sample_board(),
        range_start: @ws,
        range_end: @we,
        start_field: :start,
        end_field: :finish,
        window_label: "W",
        bar: bar_slot(),
        lane_header: [%{inner_block: fn _c, group -> Phoenix.HTML.raw(~s(<i class="lh">#{group.label}!</i>)) end}]
      })

    assert html =~ ~s(<i class="lh">Pending!</i>)
  end
end
