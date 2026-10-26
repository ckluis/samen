defmodule Samen.UI.DataMap do
  @moduledoc """
  The data-map ERD (issue #97) — one domain of a `Samen.DataMap` drawn as server-computed
  inline SVG, the `Samen.UI.Chart` idiom: `erd_layout/2` is pure geometry, `erd/1` emits
  `<rect>`/`<path>`/`<text>` and plain `<a>` links. No client JS and no hook, so the page
  renders complete with JS off (ADR-042 Class B by construction).

  ## Layout

  Tables are ranked parent-above-child along their DECLARED edges (a `belongs_to` points
  child → parent), ordered inside a rank by the barycentre of their parents, and wrapped at
  `@per_row` boxes so a wide rank stays readable. Tables from OTHER domains that an edge
  reaches are drawn as dashed stubs linking to that domain's page — the cross-domain seams
  are the architecture, so they are never dropped.

  Edges use ERD crow's-foot ends: the child (foreign-key) end is "many", the parent end
  "one"; a `has_one` is one-to-one; a `many_to_many` is dashed with its join named.

  ## Metadata only

  Everything drawn is catalog metadata — names, types, `pii` flags. There is no value on
  this surface to mask; a PII field shows its NAME and a lock, never a sample.
  """
  use Phoenix.Component

  @box_w 232
  @head_h 46
  @field_h 19
  @foot_h 24
  @stub_h 42
  @col_gap 56
  @row_gap 88
  @pad 28
  @per_row 4
  @max_fields 12

  @doc """
  Render one domain's ERD.

    * `:map` (required) — a `Samen.DataMap.build/1` result.
    * `:domain` (required) — the domain slug to draw.
    * `:base_path` — the map's route prefix; stub boxes link to `base_path/<domain>`.
  """
  attr :map, :map, required: true
  attr :domain, :string, required: true
  attr :base_path, :string, default: "/operator/data-map"
  attr :id, :string, default: "data-map-erd"

  def erd(assigns) do
    # The box metrics travel as assigns: inside ~H, `@name` reads an assign, not the
    # module attribute.
    assigns =
      assign(assigns,
        g: erd_layout(assigns.map, assigns.domain),
        head_h: @head_h,
        field_h: @field_h,
        foot_h: @foot_h
      )

    ~H"""
    <div class="dmap-scroll">
      <svg
        id={@id}
        class="dmap-svg"
        viewBox={"0 0 #{@g.width} #{@g.height}"}
        style={"--dmap-w:#{@g.width}px;min-width:#{min(@g.width, 760)}px;max-width:#{@g.width}px"}
        role="img"
        aria-label={"Entity relationship diagram: #{length(@g.nodes)} tables, #{length(@g.edges)} relationships"}
        font-family="Inter, -apple-system, sans-serif"
      >
        <defs>
          <%!-- Crow's-foot ends. Each marker sits on the box edge and reads outward along the
               path, so a start marker and an end marker need mirrored shapes. --%>
          <marker id={"#{@id}-many-s"} viewBox="0 0 14 14" refX="1" refY="7" markerWidth="14" markerHeight="14" orient="auto" markerUnits="userSpaceOnUse">
            <path d="M1 1 L13 7 M1 7 L13 7 M1 13 L13 7" class="dmap-mark" />
          </marker>
          <marker id={"#{@id}-many-e"} viewBox="0 0 14 14" refX="13" refY="7" markerWidth="14" markerHeight="14" orient="auto" markerUnits="userSpaceOnUse">
            <path d="M13 1 L1 7 M13 7 L1 7 M13 13 L1 7" class="dmap-mark" />
          </marker>
          <marker id={"#{@id}-one-s"} viewBox="0 0 14 14" refX="1" refY="7" markerWidth="14" markerHeight="14" orient="auto" markerUnits="userSpaceOnUse">
            <path d="M3 2 L3 12 M7 2 L7 12" class="dmap-mark" />
          </marker>
          <marker id={"#{@id}-one-e"} viewBox="0 0 14 14" refX="13" refY="7" markerWidth="14" markerHeight="14" orient="auto" markerUnits="userSpaceOnUse">
            <path d="M7 2 L7 12 M11 2 L11 12" class="dmap-mark" />
          </marker>
        </defs>

        <g class="dmap-edges">
          <g :for={e <- @g.edges} class={"dmap-edge dmap-edge-#{e.type}"}>
            <path
              d={e.d}
              marker-start={"url(##{@id}-#{if e.type == :has_one, do: "one", else: "many"}-s)"}
              marker-end={"url(##{@id}-#{if e.type == :many_to_many, do: "many", else: "one"}-e)"}
            />
            <text x={e.lx} y={e.ly} class="dmap-edge-label" text-anchor={e.anchor}>{e.label}</text>
          </g>
        </g>

        <g :for={n <- @g.nodes} class={"dmap-node dmap-n-#{n.kind}"} data-resource={n.resource}>
          <%= if n.kind == :stub do %>
            <a href={"#{@base_path}/#{n.domain}"}>
              <rect x={n.x} y={n.y} width={n.w} height={n.h} rx="10" class="dmap-stub-box" />
              <text x={n.x + 14} y={n.y + 18} class="dmap-stub-name">{n.name}</text>
              <text x={n.x + 14} y={n.y + 33} class="dmap-stub-dom">in {n.domain_name} →</text>
            </a>
          <% else %>
            <rect x={n.x} y={n.y} width={n.w} height={n.h} rx="10" class="dmap-box" />
            <path d={head_path(n)} class={"dmap-head dmap-head-#{n.layer}"} />
            <text x={n.x + 14} y={n.y + 20} class="dmap-name">{n.name}</text>
            <text x={n.x + 14} y={n.y + 36} class="dmap-table">{n.table_name}</text>
            <g :if={n.anchor}>
              <rect x={n.x + n.w - 70} y={n.y + 10} width="58" height="17" rx="8.5" class="dmap-chip" />
              <text x={n.x + n.w - 41} y={n.y + 22} text-anchor="middle" class="dmap-chip-t">any object</text>
            </g>
            <g :for={{f, i} <- Enum.with_index(n.fields)} class={field_class(f)}>
              <rect :if={f.pii} x={n.x + 1} y={n.y + @head_h + i * @field_h} width={n.w - 2} height={@field_h} class="dmap-pii-row" />
              <text x={n.x + 14} y={n.y + @head_h + i * @field_h + 13} class="dmap-fname">{if f.pii, do: "🔒 ", else: ""}{clip(f.name, 22)}</text>
              <text x={n.x + n.w - 12} y={n.y + @head_h + i * @field_h + 13} text-anchor="end" class="dmap-ftype">{field_type(f)}</text>
            </g>
            <text :if={n.more > 0} x={n.x + 14} y={n.y + @head_h + length(n.fields) * @field_h + 13} class="dmap-more">+ {n.more} more fields</text>
            <line x1={n.x} x2={n.x + n.w} y1={n.y + n.h - @foot_h} y2={n.y + n.h - @foot_h} class="dmap-rule" />
            <text x={n.x + 14} y={n.y + n.h - 8} class={if n.org_scoped, do: "dmap-foot", else: "dmap-foot dmap-global"}>
              {if n.org_scoped, do: "id · org_id · timestamps", else: "global · no org_id"}
            </text>
          <% end %>
        </g>
      </svg>
    </div>
    """
  end

  defp head_path(n) do
    r = 10

    "M#{n.x} #{n.y + @head_h} V#{n.y + r} Q#{n.x} #{n.y} #{n.x + r} #{n.y} " <>
      "H#{n.x + n.w - r} Q#{n.x + n.w} #{n.y} #{n.x + n.w} #{n.y + r} V#{n.y + @head_h} Z"
  end

  defp field_class(%{pii: true}), do: "dmap-field dmap-field-pii"
  defp field_class(%{references: ref}) when is_binary(ref), do: "dmap-field dmap-field-fk"
  defp field_class(_), do: "dmap-field"

  defp field_type(%{references: ref}) when is_binary(ref),
    do: "→ " <> (ref |> String.split(".") |> List.last())

  defp field_type(%{type: type}), do: clip(type, 14)

  defp clip(s, n) do
    if String.length(s) > n, do: String.slice(s, 0, n - 1) <> "…", else: s
  end

  # ---------------------------------------------------------------------------
  # Geometry (pure)

  @doc """
  The ERD geometry for `slug` in `map`: `%{width, height, nodes, edges}` where each node
  carries `{x, y, w, h}` and each edge a ready-to-draw cubic path `d` plus a label anchor.
  Deterministic: the same map always yields byte-identical geometry.
  """
  def erd_layout(%{tables: tables, edges: all_edges} = map, slug) do
    own =
      case Samen.DataMap.domain(map, slug) do
        nil -> []
        d -> d.tables
      end

    own_set = MapSet.new(own)

    edges =
      Enum.filter(all_edges, fn e ->
        (e.from in own_set or e.to in own_set) and Map.has_key?(tables, e.from) and
          Map.has_key?(tables, e.to)
      end)

    stubs =
      edges
      |> Enum.flat_map(&[&1.from, &1.to])
      |> Enum.reject(&(&1 in own_set))
      |> Enum.uniq()
      |> Enum.sort()

    ids = own ++ stubs
    parents = parents_of(ids, edges)
    linked = edges |> Enum.flat_map(&[&1.from, &1.to]) |> MapSet.new()

    # Tables with no declared edge go to a band of their own below the graph, so no edge
    # is routed through a box it has nothing to do with.
    ranks =
      ids
      |> Enum.filter(&(&1 in linked))
      |> rank_all(parents)
      |> then(fn ranks ->
        lonely = 1 + Enum.max(Map.values(ranks), fn -> -1 end)
        Enum.reduce(ids, ranks, &Map.put_new(&2, &1, lonely))
      end)

    nodes = Map.new(ids, &{&1, node(tables[&1], &1 in own_set, map)})
    placed = place(ids, ranks, parents, nodes)

    width =
      placed
      |> Map.values()
      |> Enum.map(&(&1.x + &1.w))
      |> Enum.max(fn -> 0 end)
      |> Kernel.+(@pad)

    height =
      placed
      |> Map.values()
      |> Enum.map(&(&1.y + &1.h))
      |> Enum.max(fn -> 0 end)
      |> Kernel.+(@pad)

    %{
      width: max(width, 2 * @pad + @box_w),
      height: max(height, 2 * @pad + @stub_h),
      nodes: ids |> Enum.map(&placed[&1]) |> Enum.sort_by(&{&1.y, &1.x}),
      edges: route(edges, placed)
    }
  end

  defp node(t, own?, map) do
    if own? do
      shown = Enum.reject(t.fields, & &1.universal)
      fields = Enum.take(shown, @max_fields)
      more = length(shown) - length(fields)
      body = length(fields) * @field_h + if(more > 0, do: @field_h, else: 0)

      %{
        kind: :table,
        resource: t.resource,
        name: t.name,
        table_name: t.table_name,
        layer: t.layer,
        anchor: t.anchor,
        org_scoped: t.org_scoped,
        domain: t.domain,
        fields: fields,
        more: more,
        w: @box_w,
        h: @head_h + body + 6 + @foot_h
      }
    else
      dom = Samen.DataMap.domain(map, t.domain)

      %{
        kind: :stub,
        resource: t.resource,
        name: t.name,
        domain: t.domain,
        domain_name: (dom && dom.name) || t.domain,
        w: @box_w,
        h: @stub_h
      }
    end
  end

  defp parents_of(ids, edges) do
    set = MapSet.new(ids)

    Map.new(ids, fn id ->
      ps =
        for e <- edges, e.from == id, e.to != id, e.to in set, uniq: true, do: e.to

      {id, Enum.sort(ps)}
    end)
  end

  # Longest-path rank, parents above children; a cycle is cut where it is first re-entered.
  defp rank_all(ids, parents) do
    Enum.reduce(ids, %{}, fn id, memo -> elem(rank(id, parents, memo, %{}), 1) end)
  end

  defp rank(id, parents, memo, visiting) do
    cond do
      Map.has_key?(memo, id) ->
        {memo[id], memo}

      Map.has_key?(visiting, id) ->
        {0, memo}

      true ->
        visiting = Map.put(visiting, id, true)

        {r, memo} =
          Enum.reduce(parents[id] || [], {0, memo}, fn p, {acc, m} ->
            {pr, m} = rank(p, parents, m, visiting)
            {max(acc, pr + 1), m}
          end)

        {r, Map.put(memo, id, r)}
    end
  end

  defp place(ids, ranks, parents, nodes) do
    by_rank = Enum.group_by(ids, &ranks[&1])

    {placed, _y} =
      by_rank
      |> Map.keys()
      |> Enum.sort()
      |> Enum.reduce({%{}, @pad}, fn r, {acc, y} ->
        ordered =
          by_rank[r]
          |> Enum.sort_by(fn id ->
            {barycentre(parents[id], acc), nodes[id].kind == :stub, nodes[id].name, id}
          end)

        ordered
        |> Enum.chunk_every(@per_row)
        |> Enum.reduce({acc, y}, fn row, {acc, y} ->
          row_h = row |> Enum.map(&nodes[&1].h) |> Enum.max()

          acc =
            row
            |> Enum.with_index()
            |> Enum.reduce(acc, fn {id, i}, acc ->
              Map.put(acc, id, Map.merge(nodes[id], %{x: @pad + i * (@box_w + @col_gap), y: y}))
            end)

          {acc, y + row_h + @row_gap}
        end)
      end)

    placed
  end

  defp barycentre(parents, placed) do
    xs = for p <- parents || [], Map.has_key?(placed, p), do: placed[p].x

    case xs do
      [] -> 1_000_000
      _ -> Enum.sum(xs) / length(xs)
    end
  end

  # Ports: each box spreads its top and bottom attachments across its width in the order
  # of the far end's x, so parallel edges fan out instead of stacking on one point.
  defp route(edges, placed) do
    geo =
      Enum.map(edges, fn e ->
        c = placed[e.from]
        p = placed[e.to]

        side =
          cond do
            e.from == e.to -> :self
            c.y > p.y -> :down
            c.y < p.y -> :up
            true -> :level
          end

        %{edge: e, c: c, p: p, side: side}
      end)

    ports = ports(geo)
    rows = rows(placed)

    # An edge that skips a row would otherwise run behind the boxes in between: route it
    # up the nearest column gutter instead, fanning parallel gutter runs apart.
    {geo, _} =
      geo
      |> Enum.sort_by(&{&1.edge.from, &1.edge.name, &1.edge.to})
      |> Enum.map_reduce(%{}, fn g, used ->
        if g.side == :down and skips_row?(g, rows) do
          gx = gutter(ports[{g.edge, :c}], ports[{g.edge, :p}])
          n = Map.get(used, gx, 0)
          off = if rem(n, 2) == 0, do: div(n, 2) * 7, else: -(div(n, 2) + 1) * 7
          {Map.put(g, :gutter, gx + off), Map.put(used, gx, n + 1)}
        else
          {g, used}
        end
      end)

    geo
    |> Enum.map(fn g -> draw(g, ports, rows) end)
    |> Enum.sort_by(&{&1.from, &1.label, &1.to})
  end

  # Each placed row as `{top, bottom}`, top to bottom.
  defp rows(placed) do
    placed
    |> Map.values()
    |> Enum.group_by(& &1.y)
    |> Enum.map(fn {y, ns} -> {y, ns |> Enum.map(&(&1.y + &1.h)) |> Enum.max()} end)
    |> Enum.sort()
  end

  defp skips_row?(%{c: c, p: p}, rows), do: Enum.any?(rows, fn {y, _} -> y > p.y and y < c.y end)

  defp gutter(sx, ex) do
    0..@per_row
    |> Enum.map(fn i ->
      if i == 0, do: @pad / 2, else: @pad + i * (@box_w + @col_gap) - @col_gap / 2
    end)
    |> Enum.min_by(&(abs(&1 - sx) + abs(&1 - ex)))
  end

  defp row_bottom(rows, y), do: rows |> List.keyfind(y, 0) |> elem(1)

  # A polyline through `points` with each corner rounded by radius `r`.
  defp rounded([p0 | rest], r) do
    {_, d} =
      rest
      |> Enum.chunk_every(2, 1)
      |> Enum.reduce({p0, "M#{f(elem(p0, 0))} #{f(elem(p0, 1))}"}, fn
        [{cx, cy}, {nx, ny}], {{px, py}, d} ->
          {ax, ay} = toward({cx, cy}, {px, py}, r)
          {bx, by} = toward({cx, cy}, {nx, ny}, r)
          {{cx, cy}, d <> " L#{f(ax)} #{f(ay)} Q#{f(cx)} #{f(cy)} #{f(bx)} #{f(by)}"}

        [{cx, cy}], {_prev, d} ->
          {{cx, cy}, d <> " L#{f(cx)} #{f(cy)}"}
      end)

    d
  end

  defp toward({x, y}, {tx, ty}, r) do
    len = :math.sqrt((tx - x) * (tx - x) + (ty - y) * (ty - y))
    k = if len == 0, do: 0, else: min(r, len / 2) / len
    {x + (tx - x) * k, y + (ty - y) * k}
  end

  defp ports(geo) do
    attachments =
      Enum.flat_map(geo, fn %{edge: e, c: c, p: p, side: side} ->
        case side do
          :down -> [{{e, :c}, c, :top, p.x}, {{e, :p}, p, :bottom, c.x}]
          :up -> [{{e, :c}, c, :bottom, p.x}, {{e, :p}, p, :top, c.x}]
          _ -> []
        end
      end)

    attachments
    |> Enum.group_by(fn {_k, box, face, _} -> {box.resource, face} end)
    |> Enum.flat_map(fn {_, list} ->
      sorted = Enum.sort_by(list, fn {{e, end_}, _box, _f, far} -> {far, e.name, end_} end)
      n = length(sorted)

      sorted
      |> Enum.with_index()
      |> Enum.map(fn {{key, box, _f, _}, i} ->
        {key, box.x + box.w * (0.2 + 0.6 * (i + 0.5) / n)}
      end)
    end)
    |> Map.new()
  end

  defp draw(%{edge: e, c: c, p: p, gutter: gx}, ports, rows) do
    sx = ports[{e, :c}]
    ex = ports[{e, :p}]
    sy = c.y
    ey = p.y + p.h
    above_child = c.y - @row_gap / 2
    below_parent = row_bottom(rows, p.y) + @row_gap / 2

    d =
      rounded(
        [
          {sx, sy},
          {sx, above_child},
          {gx, above_child},
          {gx, below_parent},
          {ex, below_parent},
          {ex, ey}
        ],
        10
      )

    %{
      from: e.from,
      to: e.to,
      type: e.type,
      label: label(e),
      d: d,
      lx: f(gx + 6),
      ly: f((above_child + below_parent) / 2 + 4),
      anchor: "start"
    }
  end

  defp draw(%{edge: e, c: c, p: p, side: side}, ports, _rows) do
    {sx, sy, ex, ey, d} =
      case side do
        :down ->
          sx = ports[{e, :c}]
          ex = ports[{e, :p}]
          sy = c.y
          ey = p.y + p.h
          k = max(36, (sy - ey) / 2)

          {sx, sy, ex, ey,
           "M#{f(sx)} #{f(sy)} C#{f(sx)} #{f(sy - k)} #{f(ex)} #{f(ey + k)} #{f(ex)} #{f(ey)}"}

        :up ->
          sx = ports[{e, :c}]
          ex = ports[{e, :p}]
          sy = c.y + c.h
          ey = p.y
          k = max(36, (ey - sy) / 2)

          {sx, sy, ex, ey,
           "M#{f(sx)} #{f(sy)} C#{f(sx)} #{f(sy + k)} #{f(ex)} #{f(ey - k)} #{f(ex)} #{f(ey)}"}

        :level ->
          {sx, ex} = if c.x > p.x, do: {c.x, p.x + p.w}, else: {c.x + c.w, p.x}
          sy = c.y + 23
          ey = p.y + 23
          k = (ex - sx) / 2

          {sx, sy, ex, ey,
           "M#{f(sx)} #{f(sy)} C#{f(sx + k)} #{f(sy)} #{f(ex - k)} #{f(ey)} #{f(ex)} #{f(ey)}"}

        :self ->
          x = c.x + c.w

          {x, c.y + 14, x, c.y + 34,
           "M#{f(x)} #{f(c.y + 14)} C#{f(x + 44)} #{f(c.y + 6)} #{f(x + 44)} #{f(c.y + 42)} #{f(x)} #{f(c.y + 34)}"}
      end

    {lx, ly} =
      if side == :self, do: {sx + 30, sy + 10}, else: {(sx + ex) / 2, (sy + ey) / 2 + 4}

    %{
      from: e.from,
      to: e.to,
      type: e.type,
      label: label(e),
      d: d,
      lx: f(lx),
      ly: f(ly),
      anchor: "middle"
    }
  end

  defp label(%{type: :many_to_many, name: name, through: through}) when is_binary(through),
    do: "#{name} via #{through |> String.split(".") |> List.last()}"

  defp label(%{name: name}), do: name

  defp f(n) when is_integer(n), do: Integer.to_string(n)
  defp f(n), do: :erlang.float_to_binary(n * 1.0, decimals: 1)
end
