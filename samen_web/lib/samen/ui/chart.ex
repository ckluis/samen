defmodule Samen.UI.Chart do
  @moduledoc """
  The GENERIC chart renderers (G8, T56) — the framework renderers for a `%Samen.Web.Series{}`
  (the value `Samen.Web.Reads.aggregate_by!/3` and `time_series!/3` return). Three lenses over
  the SAME aggregate carrier: `bar_chart/1` (a breakdown), `pie_chart/1` (a share-of-total), and
  `line_chart/1` (a time series). Each is framework-level, holds NO vertical logic, and is
  parameterized only by an optional value `:format` fun — so the CRM dashboard (first client),
  a support ticket-volume tile, or any aggregate reuses them at ≈0 authored LOC.

  ## No-JS floor — server-computed inline SVG + a table fallback (ADR-042/T113)

  ALL geometry is computed SERVER-SIDE in this component and emitted as inline `<svg>` elements
  (bar `<rect>` heights, the line `<polyline points>`, pie `<path>` arcs) — the whole chart is
  present in the server-rendered DOM with JS OFF. There is NO external charting library and NO
  CDN (`CLAUDE.md`): the SVG is self-contained HEEx. Every chart ALSO renders an accessible
  `<table>` (visually hidden by default via `sr-only`, or shown with `show_table`) carrying the
  exact label/value of every slice — so a screen reader or a no-SVG client still gets the data.
  JS (tooltips, live refresh, animation) is progressive enhancement only.

  ## Masking / aggregate-leak posture (dumb renderer, INV-1)

  A chart never inspects a vault field: the DIMENSION (a `%Point{}` label/axis/legend) is
  guaranteed a NON-VAULTED facet because `aggregate_by!/3` / `time_series!/3` REFUSE a
  vault-routed group/date field (`MaskedGroupKeyError`) and a vault-routed SUM/AVG measure
  (`MaskedMeasureError`) — so no plaintext or vault token can reach a label, axis, tooltip, or a
  summed value. The renderer has no "reveal" branch; it draws numbers and non-secret labels.
  """
  use Phoenix.Component

  alias Samen.Web.Series

  # A bounded categorical palette (mid-tones legible on light AND dark) for pie/bar slices,
  # cycled by index. Self-contained — no external theme dependency for the SVG fills.
  @palette ~w(#3b82f6 #10b981 #f59e0b #ef4444 #8b5cf6 #06b6d4 #ec4899 #84cc16 #f97316 #6366f1 #14b8a6 #a855f7)

  # SVG canvas geometry (a fixed viewBox; the container scales it responsively via CSS width).
  @w 320
  @h 180
  @pad_x 8
  @pad_top 12
  @pad_bottom 28

  @doc """
  Render a `%Samen.Web.Series{}` as a vertical BAR chart (a breakdown). Bar heights are
  server-computed from each slice `value` relative to the series max, emitted as inline SVG
  `<rect>`s. An accessible data `<table>` mirrors the values.

    * `:series` (required) — a `%Samen.Web.Series{}`.
    * `:id` — DOM id (default `"bar-chart"`).
    * `:title` — an optional caption above the chart.
    * `:format` — a 1-arg fun `%Series.Point{} -> iodata` formatting a value (default the number).
    * `:show_table` — render the data table visibly (default `false` = screen-reader only).
  """
  attr :series, :any, required: true, doc: "a %Samen.Web.Series{}"
  attr :id, :string, default: "bar-chart"
  attr :title, :string, default: nil
  attr :format, :any, default: nil
  attr :show_table, :boolean, default: false

  def bar_chart(assigns) do
    assigns =
      assigns
      |> assign_new(:fmt, fn -> assigns.format || (&default_format/1) end)
      |> assign_canvas()
      |> then(fn a -> assign(a, :bars, bar_geometry(a.series)) end)

    ~H"""
    <figure id={@id} class="chart chart-bar">
      <figcaption :if={@title} class="chart-title">{@title}</figcaption>
      <%= if @bars == [] do %>
        <p class="chart-empty">No data</p>
      <% else %>
        <svg class="chart-svg" viewBox={@vb} role="img" aria-label={@title || "Bar chart"} preserveAspectRatio="xMidYMid meet">
          <line class="chart-axis" x1={@axis_x1} y1={@axis_y} x2={@axis_x2} y2={@axis_y} />
          <%= for {bar, i} <- Enum.with_index(@bars) do %>
            <rect
              class="chart-bar-rect"
              x={bar.x}
              y={bar.y}
              width={bar.width}
              height={bar.height}
              fill={palette(i)}
              data-key={to_string(bar.key)}
              data-value={bar.value}
            >
              <title>{@fmt.(bar.point)}</title>
            </rect>
            <text class="chart-xlabel" x={bar.cx} y={@label_y} text-anchor="middle">{short(bar.label)}</text>
          <% end %>
        </svg>
      <% end %>
      <.data_table series={@series} fmt={@fmt} id={@id} show={@show_table} />
    </figure>
    """
  end

  @doc """
  Render a `%Samen.Web.Series{}` as a LINE chart (a time series). The polyline points are
  server-computed from each bucket `value` relative to the series max, emitted as an inline SVG
  `<polyline>` + `<circle>` markers. An accessible data `<table>` mirrors the values.

  Same attrs as `bar_chart/1` (`:series`, `:id`, `:title`, `:format`, `:show_table`).
  """
  attr :series, :any, required: true
  attr :id, :string, default: "line-chart"
  attr :title, :string, default: nil
  attr :format, :any, default: nil
  attr :show_table, :boolean, default: false

  def line_chart(assigns) do
    assigns =
      assigns
      |> assign_new(:fmt, fn -> assigns.format || (&default_format/1) end)
      |> assign_canvas()
      |> then(fn a -> assign(a, :dots, line_geometry(a.series)) end)

    ~H"""
    <figure id={@id} class="chart chart-line">
      <figcaption :if={@title} class="chart-title">{@title}</figcaption>
      <%= if @dots == [] do %>
        <p class="chart-empty">No data</p>
      <% else %>
        <svg class="chart-svg" viewBox={@vb} role="img" aria-label={@title || "Line chart"} preserveAspectRatio="xMidYMid meet">
          <line class="chart-axis" x1={@axis_x1} y1={@axis_y} x2={@axis_x2} y2={@axis_y} />
          <polyline class="chart-line-path" fill="none" stroke={palette(0)} stroke-width="2" points={polyline_points(@dots)} />
          <%= for dot <- @dots do %>
            <circle class="chart-line-dot" cx={dot.cx} cy={dot.cy} r="3" fill={palette(0)} data-key={to_string(dot.key)} data-value={dot.value}>
              <title>{@fmt.(dot.point)}</title>
            </circle>
            <text class="chart-xlabel" x={dot.cx} y={@label_y} text-anchor="middle">{short(dot.label)}</text>
          <% end %>
        </svg>
      <% end %>
      <.data_table series={@series} fmt={@fmt} id={@id} show={@show_table} />
    </figure>
    """
  end

  @doc """
  Render a `%Samen.Web.Series{}` as a PIE (donut) chart (a share-of-total). Each slice's arc is
  server-computed from its `value` as a fraction of the series total, emitted as inline SVG
  `<path>` arcs, with a legend and an accessible data `<table>`.

  Same attrs as `bar_chart/1`, plus:

    * `:donut` — render as a donut (a center hole) rather than a full pie (default `true`).
  """
  attr :series, :any, required: true
  attr :id, :string, default: "pie-chart"
  attr :title, :string, default: nil
  attr :format, :any, default: nil
  attr :show_table, :boolean, default: false
  attr :donut, :boolean, default: true

  def pie_chart(assigns) do
    assigns =
      assigns
      |> assign_new(:fmt, fn -> assigns.format || (&default_format/1) end)
      |> then(fn a -> assign(a, :slices, pie_geometry(a.series)) end)

    ~H"""
    <figure id={@id} class="chart chart-pie">
      <figcaption :if={@title} class="chart-title">{@title}</figcaption>
      <%= if @slices == [] do %>
        <p class="chart-empty">No data</p>
      <% else %>
        <div class="chart-pie-wrap">
          <svg class="chart-svg-pie" viewBox="0 0 100 100" role="img" aria-label={@title || "Pie chart"} preserveAspectRatio="xMidYMid meet">
            <%= for {slice, i} <- Enum.with_index(@slices) do %>
              <path class="chart-slice" d={slice.d} fill={palette(i)} data-key={to_string(slice.key)} data-value={slice.value}>
                <title>{@fmt.(slice.point)} ({slice.pct}%)</title>
              </path>
            <% end %>
            <circle :if={@donut} cx="50" cy="50" r="22" class="chart-donut-hole" />
          </svg>
          <ul class="chart-legend">
            <%= for {slice, i} <- Enum.with_index(@slices) do %>
              <li class="chart-legend-item">
                <span class="chart-swatch" style={"background:#{palette(i)}"} aria-hidden="true"></span>
                <span class="chart-legend-label">{short(slice.label)}</span>
                <span class="chart-legend-val">{@fmt.(slice.point)} · {slice.pct}%</span>
              </li>
            <% end %>
          </ul>
        </div>
      <% end %>
      <.data_table series={@series} fmt={@fmt} id={@id} show={@show_table} />
    </figure>
    """
  end

  # -- the accessible data-table fallback (always in the DOM) -------------------

  attr :series, :any, required: true
  attr :fmt, :any, required: true
  attr :id, :string, required: true
  attr :show, :boolean, default: false

  defp data_table(assigns) do
    ~H"""
    <table class={["chart-data", !@show && "sr-only"]} id={"#{@id}-table"}>
      <caption>Chart data</caption>
      <thead>
        <tr>
          <th scope="col">Category</th>
          <th scope="col">Value</th>
        </tr>
      </thead>
      <tbody>
        <tr :for={p <- @series.points}>
          <th scope="row">{p.label}</th>
          <td>{@fmt.(p)}</td>
        </tr>
      </tbody>
    </table>
    """
  end

  # -- geometry (all server-computed; the no-JS floor) -------------------------

  @doc false
  # `[%{key,label,value,point,x,y,width,height,cx}]` — one bar per slice, height ∝ value/max.
  def bar_geometry(%Series{points: []}), do: []

  def bar_geometry(%Series{points: points} = series) do
    max = max(Series.max_value(series), 1)
    n = length(points)
    plot_w = @w - 2 * @pad_x
    plot_h = @h - @pad_top - @pad_bottom
    slot = plot_w / n
    bw = Float.round(slot * 0.62, 2)

    points
    |> Enum.with_index()
    |> Enum.map(fn {p, i} ->
      cx = @pad_x + slot * (i + 0.5)
      h = Float.round(p.value / max * plot_h, 2)
      y = Float.round(@h - @pad_bottom - h, 2)

      %{
        key: p.key,
        label: p.label,
        value: p.value,
        point: p,
        x: Float.round(cx - bw / 2, 2),
        y: y,
        width: bw,
        height: h,
        cx: Float.round(cx, 2)
      }
    end)
  end

  @doc false
  # `[%{key,label,value,point,cx,cy}]` — one dot per bucket, cy ∝ value/max (inverted).
  def line_geometry(%Series{points: []}), do: []
  def line_geometry(%Series{} = s), do: line_geometry_n(s)

  defp line_geometry_n(%Series{points: points} = series) do
    max = max(Series.max_value(series), 1)
    n = length(points)
    plot_w = @w - 2 * @pad_x
    plot_h = @h - @pad_top - @pad_bottom
    step = if n > 1, do: plot_w / (n - 1), else: 0

    points
    |> Enum.with_index()
    |> Enum.map(fn {p, i} ->
      cx = if n > 1, do: @pad_x + step * i, else: @pad_x + plot_w / 2
      cy = @h - @pad_bottom - p.value / max * plot_h

      %{key: p.key, label: p.label, value: p.value, point: p, cx: Float.round(cx, 2), cy: Float.round(cy, 2)}
    end)
  end

  defp polyline_points(dots), do: Enum.map_join(dots, " ", fn d -> "#{d.cx},#{d.cy}" end)

  @doc false
  # `[%{key,label,value,point,d,pct}]` — one arc per slice, angle ∝ value/total. A single
  # non-zero slice becomes a full circle (a degenerate arc path can't draw 100%).
  def pie_geometry(%Series{points: []}), do: []

  def pie_geometry(%Series{points: points}) do
    total = points |> Enum.map(& &1.value) |> Enum.sum()

    if total <= 0 do
      []
    else
      {slices, _acc} =
        Enum.map_reduce(points, 0.0, fn p, acc ->
          frac = p.value / total
          d = arc_path(acc, acc + frac)
          pct = Float.round(frac * 100, 1)
          {%{key: p.key, label: p.label, value: p.value, point: p, d: d, pct: pct}, acc + frac}
        end)

      slices
    end
  end

  # An SVG arc path for [start_frac, end_frac) of a unit circle (r=40, centered at 50,50). A
  # full-circle fraction (a lone slice) is drawn as two half-arcs (a single arc can't close 360°).
  defp arc_path(start_frac, end_frac) do
    cond do
      end_frac - start_frac >= 1.0 - 1.0e-9 ->
        # Full circle: two semicircle arcs (top then bottom) back to start.
        "M 50 10 A 40 40 0 1 1 50 90 A 40 40 0 1 1 50 10 Z"

      true ->
        large = if end_frac - start_frac > 0.5, do: 1, else: 0
        {x1, y1} = point_on_circle(start_frac)
        {x2, y2} = point_on_circle(end_frac)
        "M 50 50 L #{x1} #{y1} A 40 40 0 #{large} 1 #{x2} #{y2} Z"
    end
  end

  # A point on the r=40 circle at `frac` of the way around, starting at 12 o'clock, clockwise.
  defp point_on_circle(frac) do
    angle = frac * 2 * :math.pi() - :math.pi() / 2
    x = 50 + 40 * :math.cos(angle)
    y = 50 + 40 * :math.sin(angle)
    {Float.round(x, 2), Float.round(y, 2)}
  end

  # -- helpers -----------------------------------------------------------------

  # The fixed SVG canvas dims + derived axis coordinates, as ASSIGNS (a HEEx `@w` reads
  # assigns, not a module attribute — so the canvas geometry must be assigned, not inlined).
  defp assign_canvas(assigns) do
    assign(assigns,
      vb: "0 0 #{@w} #{@h}",
      axis_x1: @pad_x,
      axis_x2: @w - @pad_x,
      axis_y: @h - @pad_bottom,
      label_y: @h - @pad_bottom + 14
    )
  end

  defp palette(i), do: Enum.at(@palette, rem(i, length(@palette)))

  # Default value display: an integer count, or the numeric value verbatim.
  defp default_format(%Series.Point{value: v}) when is_float(v) do
    :erlang.float_to_binary(v, decimals: 2)
  end

  defp default_format(%Series.Point{value: v}), do: to_string(v)

  # Truncate a long axis/legend label so it never overflows the tick.
  defp short(nil), do: "—"

  defp short(label) do
    s = to_string(label)
    if String.length(s) > 12, do: String.slice(s, 0, 11) <> "…", else: s
  end
end
