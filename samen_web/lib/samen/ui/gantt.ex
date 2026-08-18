defmodule Samen.UI.Gantt do
  @moduledoc """
  The GENERIC timeline / Gantt view — the framework renderer for a `%Samen.Web.Board{}` whose
  lanes (groups) hold records POSITIONED as horizontal BARS along a time axis by a
  `start_field`..`end_field` range (the value `Samen.Web.Reads.timeline_window!/3` returns). It
  lays each lane out as a row: a lane header + a track on which each row is a bar whose LEFT and
  WIDTH are computed SERVER-SIDE (inline `%` styles) from where its start..end falls in the
  `[range_start, range_end)` window.

  This is the horizontal analogue of `Samen.UI.calendar/1` (a distinct view from the existing
  VERTICAL activity rail `Samen.UI.timeline/1`, `Samen.UI.Object.timeline/1`, which it sits "on
  top of" per spec G3). Both `calendar/1` and `gantt/1` are framework-level, hold NO vertical
  logic, and are parameterized by a renderer slot — here the required `:bar` slot (`:let={row}`) —
  so the Work Tasks Gantt (T53, first client), a projects Gantt, or any start/end resource reuses
  it at ≈0 authored LOC. The vertical part (which resource, which start/end fields, which lanes)
  is thin wiring in the calling LiveView (`Samen.Web.Work.TimelineLive`).

  ## Bar positioning (server-rendered, no JS needed for layout)

  Each bar's `left`/`width` are percentages of the window span computed IN THIS COMPONENT and
  emitted as an inline `style`, so the full Gantt layout is present in the server-rendered DOM.
  JS (horizontal scroll, zoom, drag-to-reschedule) is progressive enhancement only. A bar whose
  `end_field` is NULL/absent (or ends before it starts) renders as a zero-width POINT marker (CSS
  `min-width`), never an infinite bar. Bars extending past a window edge are clamped to `0%`/`100%`.

  ## Masking posture (dumb renderer, same as the rest of the kit)

  The Gantt never inspects, coerces, or stringifies a bar's LABEL fields: each bar is whatever the
  `:bar` slot renders from a row the CALLER already plane-resolved through
  `Samen.Api.PiiResolution`. A `%Samen.Masked{}` field renders `••••` through the shared
  `Phoenix.HTML.Safe` impl — the Gantt has no "show plaintext" branch. The POSITIONING fields
  (start/end) are always a non-vaulted temporal facet: `timeline_window!/3` REFUSES a vault-routed
  axis field (`Samen.Web.Reads.MaskedGroupKeyError`), so no secret ever drives a bar's position.

  ## No-JS floor (progressive enhancement, ADR-042/T113)

  The lanes, every bar (with its computed position), the axis ticks, and every per-lane count/`+N
  more` are always in the server-rendered DOM. Window navigation is a pair of real `<a href>`
  links carrying the window param (`prev_href`/`next_href`), so a JS-off client navigates windows
  by ordinary GET.
  """
  use Phoenix.Component

  @month_abbr ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  @doc """
  Render a `%Samen.Web.Board{}` (lanes) as a horizontal timeline / Gantt over a window.

    * `:board` (required) — a `%Samen.Web.Board{}` whose groups are lanes
      (`Samen.Web.Reads.timeline_window!/3` output).
    * `:range_start` / `:range_end` (required) — the window (`Date` or `DateTime`; `range_end`
      EXCLUSIVE). Bars are positioned relative to this span.
    * `:start_field` (required) — the row attribute holding a bar's START (a `Date`/`DateTime`).
    * `:end_field` — the row attribute holding a bar's END (nil → every bar is a point at start;
      a row whose end value is nil is likewise a point).
    * `:id` — the DOM id of the container (default `"gantt"`).
    * `:window_label` — the header title (e.g. `"Mar 1 – Mar 28, 2026"`).
    * `:today` — a `Date`/`DateTime` to mark with a "now" line (default none; only drawn if in
      the window).
    * `:prev_href` / `:next_href` — real navigation URLs for the previous/next window (the no-JS
      floor; when `nil` the arrow renders as an inert span).
    * `:tick_count` — number of axis tick labels (default `7`, clamped `2..24`).
    * `:empty_text` — text for a lane with zero bars (default `"—"`).
    * `:bar` (required slot, `:let={row}`) — renders ONE bar's content from a lane's row.
    * `:lane_header` (optional slot, `:let={group}`) — renders a lane's header (default: label + count).
  """
  attr :id, :string, default: "gantt"
  attr :board, :any, required: true, doc: "a %Samen.Web.Board{} whose groups are lanes"
  attr :range_start, :any, required: true
  attr :range_end, :any, required: true
  attr :start_field, :atom, required: true
  attr :end_field, :atom, default: nil
  attr :window_label, :string, default: nil
  attr :today, :any, default: nil
  attr :prev_href, :string, default: nil
  attr :next_href, :string, default: nil
  attr :tick_count, :integer, default: 7
  attr :empty_text, :string, default: "—"
  slot :bar, required: true, doc: "renders one bar's content from a lane's row (:let={row})"
  slot :lane_header, doc: "renders a lane header (:let={group}); default is label + count"

  def gantt(assigns) do
    assigns =
      assigns
      |> assign(:lanes, lanes(assigns.board))
      |> assign(:ticks, ticks(assigns.range_start, assigns.range_end, assigns.tick_count))
      |> assign(:now_pos, now_pos(assigns.today, assigns.range_start, assigns.range_end))

    ~H"""
    <div id={@id} class="gantt" role="grid" aria-label={@window_label}>
      <header class="gantt-h">
        <.nav_arrow href={@prev_href} label="Previous window" glyph="‹" id={"#{@id}-prev"} />
        <h2 class="gantt-title" id={"#{@id}-title"}>{@window_label}</h2>
        <.nav_arrow href={@next_href} label="Next window" glyph="›" id={"#{@id}-next"} />
      </header>

      <div class="gantt-axis" role="row">
        <div class="gantt-axis-h" aria-hidden="true"></div>
        <div class="gantt-axis-track">
          <span
            :for={tick <- @ticks}
            class="gantt-tick"
            role="columnheader"
            style={"left:#{tick.pos}%"}
          >
            {tick.label}
          </span>
        </div>
      </div>

      <div class="gantt-lanes">
        <div :for={lane <- @lanes} class="gantt-lane" role="row" id={"#{@id}-lane-#{lane_id(lane)}"}>
          <div class="gantt-lane-h" role="rowheader">
            <%= if @lane_header != [] do %>
              {render_slot(@lane_header, lane)}
            <% else %>
              <span class="gantt-lane-label">{lane_label(lane)}</span>
              <span :if={lane_count(lane) > 0} class="gantt-lane-n">{lane_count(lane)}</span>
            <% end %>
          </div>

          <div class="gantt-lane-track">
            <span :if={@now_pos} class="gantt-now" style={"left:#{@now_pos}%"} aria-hidden="true"></span>

            <%= for row <- lane.rows do %>
              <% geo = bar_geometry(row, @start_field, @end_field, @range_start, @range_end) %>
              <article
                class={["gantt-bar", geo.point? && "gantt-bar-point"]}
                style={"left:#{geo.left}%;width:#{geo.width}%"}
                data-row-id={Map.get(row, :id)}
              >
                <div class="gantt-bar-in">{render_slot(@bar, row)}</div>
              </article>
            <% end %>

            <p :if={lane.rows == []} class="gantt-lane-empty">{@empty_text}</p>

            <span :if={overflow(lane) > 0} class="gantt-more">+{overflow(lane)} more</span>
          </div>
        </div>

        <p :if={@lanes == []} class="gantt-empty">{@empty_text}</p>
      </div>
    </div>
    """
  end

  attr :href, :string, default: nil
  attr :label, :string, required: true
  attr :glyph, :string, required: true
  attr :id, :string, required: true

  defp nav_arrow(%{href: href} = assigns) when is_binary(href) do
    ~H"""
    <a href={@href} class="gantt-nav" id={@id} rel="nofollow" aria-label={@label}>{@glyph}</a>
    """
  end

  defp nav_arrow(assigns) do
    ~H"""
    <span class="gantt-nav gantt-nav-off" id={@id} aria-hidden="true">{@glyph}</span>
    """
  end

  # -- geometry (server-computed positions) ------------------------------------

  @doc """
  The `%{left, width, point?}` geometry (percentages of the window span) for ONE row's bar —
  exposed so the client mount and tests can assert deterministic positions. `left`/`width` are
  clamped to `[0, 100]`; a NULL/absent end (or an end at/before start) yields a zero-width POINT.
  """
  def bar_geometry(row, start_field, end_field, range_start, range_end) do
    start_val = Map.get(row, start_field)
    end_val = if end_field, do: Map.get(row, end_field)
    effective_end = end_val || start_val

    left = frac(start_val, range_start, range_end)
    right = frac(effective_end, range_start, range_end)
    width = max(right - left, 0.0)

    %{
      left: pct(left),
      width: pct(width),
      point?: width == 0.0
    }
  end

  # Clamped fraction 0..1 of `value` across [range_start, range_end). A non-temporal or nil value
  # (should never occur — the read refuses vaulted axes and filters NULL starts) clamps to 0.0
  # rather than crash the render (dumb, fail-safe renderer).
  defp frac(nil, _s, _e), do: 0.0

  defp frac(value, range_start, range_end) do
    total = span_seconds(range_start, range_end)

    if total <= 0 do
      0.0
    else
      value
      |> offset_seconds(range_start)
      |> then(fn off -> off / total end)
      |> clamp01()
    end
  rescue
    _ -> 0.0
  end

  defp clamp01(x) when x < 0.0, do: 0.0
  defp clamp01(x) when x > 1.0, do: 1.0
  defp clamp01(x), do: x

  defp pct(fraction), do: Float.round(fraction * 100, 4)

  # Distance in seconds between two temporal points (Date counted as whole days × 86400).
  defp span_seconds(%Date{} = s, %Date{} = e), do: Date.diff(e, s) * 86_400
  defp span_seconds(%DateTime{} = s, %DateTime{} = e), do: DateTime.diff(e, s, :second)
  defp span_seconds(%NaiveDateTime{} = s, %NaiveDateTime{} = e), do: NaiveDateTime.diff(e, s, :second)

  defp offset_seconds(%Date{} = v, %Date{} = s), do: Date.diff(v, s) * 86_400
  defp offset_seconds(%DateTime{} = v, %DateTime{} = s), do: DateTime.diff(v, s, :second)
  defp offset_seconds(%NaiveDateTime{} = v, %NaiveDateTime{} = s), do: NaiveDateTime.diff(v, s, :second)
  # Mixed/other → let frac's rescue clamp it to 0.0.
  defp offset_seconds(v, s), do: raise(ArgumentError, "incomparable timeline points #{inspect({v, s})}")

  # -- axis ticks --------------------------------------------------------------

  defp ticks(range_start, range_end, tick_count) do
    n = tick_count |> max(2) |> min(24)
    total = span_seconds(range_start, range_end)

    for i <- 0..(n - 1) do
      f = i / (n - 1)
      at = add_seconds(range_start, round(f * total))
      %{pos: Float.round(f * 100, 4), label: tick_label(at)}
    end
  end

  defp now_pos(nil, _s, _e), do: nil

  defp now_pos(today, range_start, range_end) do
    f = frac(today, range_start, range_end)
    # Only draw the marker when `today` is strictly inside the window (0 < f < 1).
    if f > 0.0 and f < 1.0, do: Float.round(f * 100, 4)
  end

  defp add_seconds(%Date{} = s, secs), do: Date.add(s, div(secs, 86_400))
  defp add_seconds(%DateTime{} = s, secs), do: DateTime.add(s, secs, :second)
  defp add_seconds(%NaiveDateTime{} = s, secs), do: NaiveDateTime.add(s, secs, :second)

  defp tick_label(%Date{month: m, day: d}), do: "#{Enum.at(@month_abbr, m - 1)} #{d}"
  defp tick_label(%DateTime{month: m, day: d}), do: "#{Enum.at(@month_abbr, m - 1)} #{d}"
  defp tick_label(%NaiveDateTime{month: m, day: d}), do: "#{Enum.at(@month_abbr, m - 1)} #{d}"

  # -- lane helpers ------------------------------------------------------------

  defp lanes(%{groups: groups}) when is_list(groups), do: groups
  defp lanes(_), do: []

  defp lane_label(%{label: label}) when not is_nil(label), do: to_string(label)
  defp lane_label(%{key: nil}), do: "All"
  defp lane_label(%{key: key}), do: to_string(key)
  defp lane_label(_), do: ""

  defp lane_count(%{count: count}) when is_integer(count), do: count
  defp lane_count(%{rows: rows}) when is_list(rows), do: length(rows)
  defp lane_count(_), do: 0

  defp lane_id(%{key: nil}), do: "all"
  defp lane_id(%{key: key}), do: key |> to_string() |> String.replace(~r/[^a-zA-Z0-9_-]/, "-")
  defp lane_id(_), do: "lane"

  defp overflow(%{has_more: false}), do: 0
  defp overflow(%{count: count, rows: rows}) when is_integer(count), do: max(count - length(rows), 0)
  defp overflow(_), do: 0
end
