defmodule Samen.Web.Reads.UnboundedReadError do
  @moduledoc """
  Raised by `Samen.Web.Reads.bounded!/4` when a `ListLive` reads function returns the
  FULL set (no `limit`) instead of a bounded `%Samen.Web.Page{}` — the `read!`-elimination
  guard (RP-G1-5, pinned A2 gate carry A2-N1). A raise here is the LOUD rejection the
  design requires: an unbounded read must FAIL, never silently return everything.
  """
  defexception [:message]
end

defmodule Samen.Web.Reads.MaskedGroupKeyError do
  @moduledoc """
  Raised by `Samen.Web.Reads.group_by!/3` when asked to group a resource by a VAULT-ROUTED
  (🔒) field (INV-1, the masking keystone). Grouping by a vaulted field is refused, never
  silently honored: the stored value is an opaque vault token, so a bucket keyed on it would
  either leak plaintext (if resolved) or produce meaningless ciphertext columns/counts (if
  not). The primitive REFUSES rather than leak — a group key/count must be a non-secret facet.
  Route boards through a non-vaulted grouping attribute (a stage, status, tag, owner id, …).
  """
  defexception [:message]
end

defmodule Samen.Web.Reads.MaskedMeasureError do
  @moduledoc """
  Raised by `Samen.Web.Reads.aggregate_by!/3` and `time_series!/3` when asked to SUM/AVG a
  VAULT-ROUTED (🔒) MEASURE field (INV-1, the aggregate-leak keystone). Summing or averaging a
  secret is the SUBTLE aggregate hazard: the stored value is an opaque vault token, so a SUM
  would either add ciphertext garbage or, if resolved, leak plaintext into a headline number —
  and even a token-blind aggregate over a 1-row cohort reveals that one subject's value. The
  primitive REFUSES rather than leak — a charted measure must be a non-secret numeric facet (a
  deal `value`, a `probability`, a `count`). Sibling of `MaskedGroupKeyError` for the MEASURE
  (vs the DIMENSION) axis; both fire off the same `Samen.Pii.Info.vault_routed?/2` check.
  """
  defexception [:message]
end

defmodule Samen.Web.Reads.UnboundedSeriesRangeError do
  @moduledoc """
  Raised by `Samen.Web.Reads.time_series!/3` when the requested window is EMPTY/inverted or
  would fan out into MORE buckets than the hard cap (`Samen.Web.Reads.max_series_buckets/0`).
  A time series is a bucketed, TIME-WINDOWED read — one bounded SQL aggregate per bucket; an
  unbounded (multi-decade daily) or inverted window is refused LOUDLY rather than fanned out
  into a query storm. Narrow the window or coarsen the `:unit` (day → week → month).
  """
  defexception [:message]
end

defmodule Samen.Web.Reads.UnboundedCalendarRangeError do
  @moduledoc """
  Raised by `Samen.Web.Reads.calendar_by_day!/3` when the requested calendar window spans
  MORE days than the hard cap (`Samen.Web.Reads.max_calendar_days/0`). A calendar is a
  time-WINDOWED read — one month is ≤ 31 days; a caller asking for a multi-year span would
  fan out into thousands of per-day column reads (a query storm), the exact unbounded scan
  the reads discipline forbids. The primitive REFUSES loudly rather than silently read an
  unbounded number of day columns — narrow the window to a bounded range (a month/week).
  """
  defexception [:message]
end

defmodule Samen.Web.Reads.UnboundedTimelineRangeError do
  @moduledoc """
  Raised by `Samen.Web.Reads.timeline_window!/3` when the requested timeline/Gantt window is
  EMPTY/inverted or spans MORE days than the hard cap (`Samen.Web.Reads.max_timeline_days/0`).
  A timeline is a time-WINDOWED read over `[range_start, range_end)`; an unbounded (multi-year)
  or inverted window is refused LOUDLY rather than read — narrow the window to a bounded range
  (a week/month/quarter). The sibling of `UnboundedCalendarRangeError` for the Gantt lens (G3).
  """
  defexception [:message]
end

defmodule Samen.Web.Reads.MaskedCoordinateError do
  @moduledoc """
  Raised by `Samen.Web.Reads.geo_markers!/3` when asked to plot a marker's `lat`/`lng` from a
  VAULT-ROUTED (🔒) field (INV-1, the G7/T55 coordinate-leak keystone). A precise coordinate
  IS location PII: plotting one resolved from a vaulted field would leak a subject's exact
  position onto a map plane that may hold no reveal grant — and even a masked (`••••`) label
  can't hide a pin the eye can read off the canvas. The primitive REFUSES rather than leak — a
  plotted coordinate must be a NON-secret facet. Sibling of `MaskedMeasureError`/`MaskedGroupKeyError`
  for the geographic axis; all three fire off the same `Samen.Pii.Info.vault_routed?/2` check.
  A vertical whose coordinates ARE sensitive must blur/omit them before plotting (a public
  region centroid, a coarsened grid) — never hand the vaulted scalar to `geo_markers!/3`.
  """
  defexception [:message]
end

defmodule Samen.Web.Reads do
  @moduledoc """
  The shared BOUNDED-reads convention for `samen_web` list pages (ADR-016 §3,
  WS-A design §1.1) — a keyset-pagination query builder every `Reads` module funnels
  its list queries through.

  ## Keyset, not offset

  `build/3` applies `sort → cursor-filter → limit(page_size + 1)`:

    * **sort** — the single UI sort `{field, dir}` with `id` as a same-direction
      tiebreaker, so the total order is strict and a cursor names a unique position.
    * **cursor-filter** — `(field, id) > (cursor_value, cursor_id)` (direction-aware),
      so the page after the cursor is STABLE UNDER CONCURRENT INSERTS: a row inserted
      before the cursor can never shift rows onto the next page (the offset failure
      mode) and no row is skipped or duplicated.
    * **limit** — ALWAYS present; `page_size + 1` probes for `has_more` without a
      count query. Page size is clamped to `max_page_size/0` (a hostile/buggy
      `page_size` is capped, never honored).

  ## Masking / PII posture

  This module builds QUERIES and slices RESULT LISTS. It never renders, stringifies,
  or inspects a field value, never calls `Samen.Vault.reveal/3`, and never unwraps a
  `%Samen.Masked{}`. Cursor values are raw stored terms (for a vaulted attribute that
  is the opaque vault token, never plaintext) that live ONLY in server-side assigns —
  they are never serialized to the client (see `Samen.Web.ListState`). Sort/filter
  fields should be bounded, non-vaulted attributes; filtering a vaulted column would
  match ciphertext tokens, not plaintext — useless, but never a leak.
  """

  import Ash.Expr

  alias Samen.Web.Board
  alias Samen.Web.Geo.Projection
  alias Samen.Web.GeoSet
  alias Samen.Web.GeoSet.Marker
  alias Samen.Web.ListState
  alias Samen.Web.Page
  alias Samen.Web.Tree
  alias Samen.Web.Reads.MaskedCoordinateError
  alias Samen.Web.Reads.MaskedGroupKeyError
  alias Samen.Web.Reads.MaskedMeasureError
  alias Samen.Web.Reads.UnboundedCalendarRangeError
  alias Samen.Web.Reads.UnboundedReadError
  alias Samen.Web.Reads.UnboundedSeriesRangeError
  alias Samen.Web.Reads.UnboundedTimelineRangeError
  alias Samen.Web.Series

  @default_page_size 50
  @max_page_size 200

  # Group-by (G4) bounds. A grouped board is per-COLUMN bounded (a hot column returns the cap
  # + a count + has_more, never the whole set) AND the number of columns is bounded.
  @default_group_cap 100
  @max_group_cap 500
  @default_max_groups 50

  # Aggregate/chart (G8, T56) bounds. An aggregate breakdown is a set of SQL-computed measures
  # (count/sum/avg) — ONE number per slice, never a row set. The number of slices is bounded
  # (a hot dimension caps at @default_agg_points slices + a bucketed `Other` tail); a time
  # series is bounded to @max_series_buckets bounded per-bucket aggregates (never a per-day
  # multi-decade fan-out). Same discipline as the group-by column bound, applied to slices.
  @default_agg_points 12
  @max_agg_points 100
  @default_series_buckets 12
  @max_series_buckets 366
  # The bounded time-series bucket units (coarsen day → week → month to stay under the cap).
  @series_units [:day, :week, :month]
  # The sentinel key for the bounded tail slice (over-cap dimension keys + small-label collapse).
  @other_key :__other__

  # Calendar (G2, WS-G) window bound. A calendar is a TIME-WINDOWED grouped read — one day
  # per column over a bounded date span. A month is ≤ 31 days; the hard cap gives headroom
  # for a 6-week month grid (42 days) without ever allowing a multi-year fan-out.
  @max_calendar_days 62
  # The default per-DAY (per-cell) row cap — a day with hundreds of events shows the cap +
  # a "+N more" overflow, never the whole day (the board's per-column cap, applied per cell).
  @default_calendar_cap 20

  # Timeline/Gantt (G3, WS-G) window bound. A timeline is a TIME-WINDOWED read over
  # [range_start, range_end) whose rows are positioned by a start..end range. Unlike a calendar
  # it does NOT fan out into per-day columns (lanes come from a bounded lane_field/groups list,
  # rows per lane are capped), but a bounded window is still enforced for discipline (a
  # multi-year Gantt is refused, mirroring the calendar). Generous headroom for a quarter/year
  # lens without ever allowing a multi-decade span.
  @max_timeline_days 372
  # The default per-LANE (or single-lane) row/bar cap — a lane over the cap shows the cap +
  # a "+N more" overflow, never the whole lane.
  @default_timeline_cap 100
  # Tree (G6, WS-G) bounds. A hierarchical read over a self-referential parent pointer is bounded
  # THREE independent ways so a pathological/corrupt hierarchy can never OOM or hang the LiveView:
  #   * per-parent (per-level) cap — a node with thousands of children returns at most the cap +
  #     "+N more" (the board's per-column cap, applied per node);
  #   * depth cap — the descent stops at a bounded depth (a node at the boundary is truncated);
  #   * total-node budget — a hard cap across the whole walk (worst-case nodes ≤ max_nodes).
  # Generous headroom for a real org chart / task WBS without ever allowing an unbounded fan-out.
  @default_tree_sibling_limit 50
  @max_tree_sibling_limit 200
  @default_tree_max_depth 8
  @max_tree_max_depth 32
  @default_tree_max_nodes 500
  @max_tree_max_nodes 5000

  # Map / geo (G7, T55) bound. A map plots at most @default_markers pins (a hot geo table
  # returns the cap + a `capped` flag + a withheld count, never the whole set) so a 100k-row
  # resource can never OOM the LiveView or blow up the DOM/SVG. Same discipline as the list
  # page bound + the group-by column bound, applied to plotted points.
  @default_markers 200
  @max_markers 2000

  # The temporal attribute types a timeline start/end field may be (positioned along the axis).
  @time_types [
    Ash.Type.Date,
    Ash.Type.UtcDatetime,
    Ash.Type.UtcDatetimeUsec,
    Ash.Type.DateTime,
    Ash.Type.NaiveDatetime
  ]

  @doc "The default list page size (ADR-016 §3)."
  def default_page_size, do: @default_page_size

  @doc "The hard page-size cap — a larger request is clamped, not honored (ADR-016 §3)."
  def max_page_size, do: @max_page_size

  @doc """
  Clamp a requested page size into `1..max_page_size/0` (nil/garbage → the default).
  """
  def bounded_page_size(size) when is_integer(size) and size >= 1, do: min(size, @max_page_size)
  def bounded_page_size(_), do: @default_page_size

  @doc """
  The `read!`-elimination LINT (RP-G1-5, WS-A design §1.1, pinned A2 gate carry A2-N1):
  assert that a `ListLive` reads function is BOUNDED — that no matter how large the
  underlying dataset, one call returns at most a clamped page of items and a `%Page{}`
  whose `page_size` is honored.

  ## Why a runtime probe, not a static AST scan

  The design's chosen mechanism is that the mixin's reads fn "routes through
  `Samen.Web.Reads.page!/3` (or an equivalent limit-verified path)". A static "did you
  literally call `page!`" scan is brittle (it green-lights `page!(q, %{state | page_size:
  10_000})` and red-lights an equivalent hand-rolled `limit`). Instead this lint
  EXERCISES the read against a dataset that EXCEEDS the requested page size and proves
  the OBSERVABLE bound: the fn cannot return the full set. An unbounded reads fn (a raw
  `Ash.read!` with no `limit`, or one that stuffs every row into `page.items`) fails
  LOUDLY here — it does not silently return the full set.

  ## Contract asserted

  Given `reads :: (mount, scope, %ListState{}) -> %Page{}`, for a probe page size `p`
  over a dataset of `> p` rows:

    * the result is a `%Page{}` (not a bare list — the bounded carrier), AND
    * `length(page.items) <= bounded_page_size(p)` (the limit held — the full set was
      NOT returned), AND
    * `page.page_size == bounded_page_size(p)` (the page reports its own honored bound,
      so a hostile `page_size` is clamped, never honored).

  Returns `:ok` on a bounded read; RAISES `Samen.Web.Reads.UnboundedReadError` on a
  read that leaks the full set (the RP-G1-5 red path — the test asserts the raise).

  `opts`:

    * `:page_size` — the probe page size (default `10`; must be < the dataset size the
      caller seeds, so the bound is observable).
  """
  def bounded!(reads, mount, scope, opts \\ []) when is_function(reads, 3) do
    probe_size = Keyword.get(opts, :page_size, 10)
    state = %ListState{page_size: probe_size}
    expected_bound = bounded_page_size(probe_size)

    page = reads.(mount, scope, state)

    cond do
      not match?(%Page{}, page) ->
        raise UnboundedReadError,
          message:
            "reads fn did not return a %Samen.Web.Page{} (got #{inspect(page)}) — an " <>
              "unbounded read is structurally impossible only through the %Page{} carrier " <>
              "produced by page!/3 (or an equivalent limit-verified path)."

      length(page.items) > expected_bound ->
        raise UnboundedReadError,
          message:
            "UNBOUNDED READ: reads fn returned #{length(page.items)} items for a bounded " <>
              "page_size of #{expected_bound} — the read did not apply a limit and would " <>
              "return the full set. Route the query through Samen.Web.Reads.page!/3 " <>
              "(RP-G1-5 / A2-N1)."

      page.page_size != expected_bound ->
        raise UnboundedReadError,
          message:
            "reads fn returned a %Page{} reporting page_size #{inspect(page.page_size)} " <>
              "but the honored bound is #{expected_bound} — the page must report its own " <>
              "clamped bound so a hostile page_size is never honored (RP-Page-1)."

      true ->
        :ok
    end
  end

  @doc """
  Build the BOUNDED keyset query for one page: filter box → sort (+ `id` tiebreak) →
  cursor filter → `limit(page_size + 1)`. The returned query ALWAYS carries a limit —
  this is the `read!`-elimination chokepoint the bounding red-path test asserts on.

  `opts`:

    * `:filter_fields` — bounded, non-vaulted attributes the filter box matches
      (case-insensitive `contains`); `[]` (default) disables the filter box.
  """
  def build(query, %ListState{} = state, opts \\ []) do
    size = bounded_page_size(state.page_size)
    sort = state.sort || {:id, :asc}

    query
    |> apply_filter(state.filter, Keyword.get(opts, :filter_fields, []))
    |> apply_sort(sort)
    |> apply_cursor(state.cursor, sort)
    |> Ash.Query.limit(size + 1)
  end

  @doc """
  Read one keyset page for `state` on `scope` and wrap it in a `%Samen.Web.Page{}`.
  The caller may post-process `page.items` (e.g. `Samen.Api.PiiResolution`) — the
  page struct never touches field values itself.

  `opts` — `:scope` (required) plus `build/3` options, and optionally:

    * `:authorize?` — passed through to `Ash.read!/2` when present. ONLY for reads
      that are already sanctioned as trusted framework reads of non-PII grouping rows
      (e.g. the operator's account `Org` rows, ADR-010 §6 — `OrgIsSelf` would return
      only the reader's own row). The BOUND is unaffected: the limit is applied by
      `build/3` regardless of authorization, so an `authorize?: false` page is still
      bounded by construction.
  """
  def page!(query, %ListState{} = state, opts) do
    size = bounded_page_size(state.page_size)
    sort = state.sort || {:id, :asc}

    read_opts =
      case Keyword.fetch(opts, :authorize?) do
        {:ok, authorize?} -> [scope: Keyword.fetch!(opts, :scope), authorize?: authorize?]
        :error -> [scope: Keyword.fetch!(opts, :scope)]
      end

    records = query |> build(state, opts) |> Ash.read!(read_opts)

    has_more = length(records) > size
    items = Enum.take(records, size)

    %Page{
      items: items,
      cursor: state.cursor,
      next_cursor: if(has_more, do: cursor_for(List.last(items), sort)),
      prev_cursor: List.first(state.cursor_stack),
      has_more: has_more,
      page_size: size,
      sort: state.sort,
      filter: state.filter,
      total_estimate: nil
    }
  end

  @doc """
  The opaque server-side cursor naming the position AFTER `record` under `sort` —
  `{sort_field_value, id}` (or `{id}` when sorting by `id` itself). The value is the
  raw stored term; it is never serialized or rendered.
  """
  def cursor_for(nil, _sort), do: nil
  def cursor_for(record, {:id, _dir}), do: {Map.get(record, :id)}
  def cursor_for(record, {field, _dir}), do: {Map.get(record, field), Map.get(record, :id)}

  # -- group-by (G4, WS-G) -----------------------------------------------------

  @doc "The default per-group row cap for `group_by!/3` (a hot column is bounded to this)."
  def default_group_cap, do: @default_group_cap

  @doc "The hard per-group cap — a larger `:per_group_limit` is clamped, never honored."
  def max_group_cap, do: @max_group_cap

  @doc "The default cap on the NUMBER of groups (columns) `group_by!/3` discovers."
  def default_max_groups, do: @default_max_groups

  @doc "Clamp a requested per-group cap into `1..max_group_cap/0` (nil/garbage → the default)."
  def bounded_group_cap(n) when is_integer(n) and n >= 1, do: min(n, @max_group_cap)
  def bounded_group_cap(_), do: @default_group_cap

  @doc """
  The GENERIC group-by read primitive (G4, WS-G) — group a resource's rows by
  `group_field` into an ORDERED, PER-GROUP-BOUNDED `%Samen.Web.Board{}` (group key → its
  bounded rows). The framework-level building block every WS-G grouped view consumes
  (kanban = columns, calendar = days, gallery = sections, tree = nodes) at ≈0 authored LOC;
  it holds NO vertical-specific logic. First client: the G1 CRM kanban (T51), which groups
  Pipeline opportunities by stage.

  `query` is an `Ash.Query` or resource module — ALREADY resolved through the host mount
  (`Samen.Web.Mount.resource/2`) and any base filter; grouping composes onto it.

  ## Org-scope is UNCONDITIONAL (no opt disables it)

  Every read — rows, discovery, AND the per-group count aggregate — runs through
  `Ash.read!`/`Ash.count!` with the caller's `:scope` AND with authorization ALWAYS ON, so
  `Samen.Policy.OrgScope` narrows EVERY column to the actor's org: a cross-org row (or a
  cross-org count cardinality) can NEVER appear in a group. There is deliberately NO
  `authorize?` opt on this primitive. The CRM resources isolate by the `OrgScope` POLICY
  only (no attribute multitenancy), so `authorize?: false` would be `OrgScope` OFF — a
  boards/kanban has no legitimate system-read case (unlike `page!/3`'s `OrgIsSelf`-style
  account-`Org` reads), so the escape hatch is simply not offered here. The boundary is thus
  not disableable by any caller opt — governed by construction (see
  `reads_group_by_test.exs` "no opt disables org-scoping").

  ## Masking (INV-1)

  REFUSES a vault-routed (🔒) `group_field` with `Samen.Web.Reads.MaskedGroupKeyError` —
  grouping by a secret would leak plaintext or bucket by opaque tokens. Group keys and counts
  are therefore always a non-secret facet. The RETURNED `rows` are raw records the caller
  PII-resolves on its plane (`Samen.Api.PiiResolution`), exactly like a `%Page{}`'s items;
  the board never plaintext-downgrades.

  ## Bounding strategy (no unbounded board)

  Per COLUMN, not one global window: each group is read with its OWN `limit(cap + 1)` probe
  (`filter(group_field == key)`), so a hot column returns at most `cap` rows plus `has_more`
  and an exact DB `count` (aggregate — no row transfer), never the whole column. The number
  of columns is bounded too (`:max_groups`, applied to discovery). Worst-case rows
  transferred ≤ `length(groups) * (cap + 1)` — a 10k-row pipeline can never OOM the LiveView.
  Each group also carries a keyset `next_cursor` (via `cursor_for/2`) so a column is
  paginatable ("load more") later.

  `opts`:

    * `:scope` (REQUIRED) — the org scope; every read/count resolves through it (OrgScope).
    * `:groups` — an ORDERED list of columns as `{key, label}` (or bare `key`) — the kanban
      case where columns are the known Pipeline stages in `stage_order`. When omitted, the
      distinct group keys are DISCOVERED (bounded, `:max_groups` columns) and used as labels.
    * `:per_group_limit` — per-column row cap (default `#{@default_group_cap}`; clamped to
      `max_group_cap/0`).
    * `:max_groups` — cap on DISCOVERED columns (default `#{@default_max_groups}`; ignored
      when `:groups` is given).
    * `:row_sort` — `{field, dir}` order WITHIN each column (default `{:id, :asc}`; `id` is
      the same-direction tiebreaker, so `next_cursor` names a unique position).
    * `:count?` — compute the exact per-group `count` (default `true`); `false` skips it.

  There is NO `authorize?` opt — org-scope is unconditional (see above). An `:authorize?`
  key in `opts` is IGNORED (never forwarded to a read), so no caller can drop the boundary.
  """
  def group_by!(query, group_field, opts) when is_atom(group_field) and is_list(opts) do
    scope = Keyword.fetch!(opts, :scope)
    base = Ash.Query.new(query)
    resource = base.resource

    if Samen.Pii.Info.vault_routed?(resource, group_field) do
      raise MaskedGroupKeyError,
        message:
          "REFUSED: cannot group #{inspect(resource)} by the vault-routed (🔒) field " <>
            "#{inspect(group_field)} — a group key/count must be a non-secret facet, never " <>
            "a plaintext or vault-token bucket (INV-1). Group by a non-vaulted attribute."
    end

    cap = bounded_group_cap(Keyword.get(opts, :per_group_limit))
    max_groups = bounded_max_groups(Keyword.get(opts, :max_groups))
    row_sort = Keyword.get(opts, :row_sort, {:id, :asc})
    count? = Keyword.get(opts, :count?, true)

    # UNCONDITIONAL org-scope: authorization is ALWAYS on (no authorize? forwarding), so
    # OrgScope narrows every rows/discovery/count read — the boundary is not disableable.
    read_opts = [scope: scope]

    groups =
      base
      |> group_specs(group_field, Keyword.get(opts, :groups), max_groups, read_opts)
      |> Enum.map(&read_group(base, group_field, &1, cap, row_sort, count?, read_opts))

    %Board{
      groups: groups,
      group_field: group_field,
      per_group_limit: cap,
      max_groups: max_groups
    }
  end

  defp bounded_max_groups(n) when is_integer(n) and n >= 1, do: min(n, @max_group_cap)
  defp bounded_max_groups(_), do: @default_max_groups

  # -- aggregate / chart (G8, T56) ---------------------------------------------

  @doc "The default cap on the NUMBER of chart slices `aggregate_by!/3` discovers."
  def default_agg_points, do: @default_agg_points

  @doc "The hard cap on chart slices — a larger `:max_points` is clamped, never honored."
  def max_agg_points, do: @max_agg_points

  @doc "The default number of `time_series!/3` buckets."
  def default_series_buckets, do: @default_series_buckets

  @doc "The hard cap on `time_series!/3` buckets — a window fanning past it is REFUSED."
  def max_series_buckets, do: @max_series_buckets

  @doc "The sentinel dimension key for the bounded `Other` tail slice."
  def other_key, do: @other_key

  @doc "Clamp a requested slice cap into `1..max_agg_points/0` (nil/garbage → the default)."
  def bounded_agg_points(n) when is_integer(n) and n >= 1, do: min(n, @max_agg_points)
  def bounded_agg_points(_), do: @default_agg_points

  @doc """
  The GENERIC aggregate-breakdown primitive (G8, T56) — group a resource by a NON-VAULTED
  `group_field` and compute a SQL MEASURE (count / sum / avg) per slice into a bounded
  `%Samen.Web.Series{}` (dimension key → its aggregate number). The framework building block a
  bar/pie chart tile (`Samen.UI.bar_chart/1`, `pie_chart/1`) consumes at ≈0 authored LOC; it
  holds NO vertical logic. First client: the CRM dashboard (`Samen.Web.CRM.DashboardLive`) —
  pipeline value by stage, opportunities by status.

  `query` is an `Ash.Query` or resource module — ALREADY resolved through the host mount
  (`Samen.Web.Mount.resource/2`) and any base filter; the aggregation composes onto it.

  ## Org-scope is UNCONDITIONAL (no opt disables it)

  Every read — slice discovery, EVERY per-slice measure, AND the grand total — runs through
  `Ash.count!`/`Ash.sum!`/`Ash.avg!` with the caller's `:scope` AND authorization ALWAYS ON,
  so `Samen.Policy.OrgScope` narrows EVERY slice to the actor's org: a cross-org row can NEVER
  contribute to a slice measure or to the total. There is deliberately NO `authorize?` opt
  (the T50 boundary; an `:authorize?` key in `opts` is IGNORED, never forwarded) — the
  boundary is not disableable by any caller (see `reads_aggregate_test.exs`).

  ## Computed IN SQL, never load-then-sum (the DB-aggregate keystone)

  Each slice's `value` is a DB aggregate over the org-scoped, group-filtered set — the rows are
  NEVER transferred and summed in Elixir (that would OOM and defeat the point). The returned
  `%Series{}` carries only numbers (no `rows` field exists), so a 10k-row table yields at most
  `max_points` + 1 Points, each a single measure.

  ## Bounded slice set (no unbounded breakdown)

  The number of slices is bounded to `:max_points` (clamped to `max_agg_points/0`): DISCOVERED
  keys past the cap collapse into ONE `Other` slice (`@other_key`), computed as the grand total
  minus the shown slices (arithmetic on SQL aggregates — still no rows), so the breakdown is
  bounded even over an unbounded-cardinality dimension. When `:groups` is given (the caller
  enumerated a bounded domain, e.g. a status enum), those slices are used verbatim.

  ## Masking / aggregate-leak (INV-1, the subtle hazard)

  The PII guarantee here is UNCONDITIONAL: REFUSES a vault-routed (🔒) `group_field` with
  `MaskedGroupKeyError` (a chart label/axis must be a non-secret facet) AND a vault-routed
  SUM/AVG measure field with `MaskedMeasureError` (a summed/averaged secret leaks plaintext or a
  1-cohort value). That refusal — not any option — is what keeps a secret off a chart.

  `:collapse_below` (default `1`, count measures only) is a LABEL-TIDINESS knob, NOT a
  disclosure/anonymity control: a slice whose cohort count is below it is folded into `Other` so
  a long tail of tiny slices does not clutter the chart. It is EXPLICITLY NOT k-anonymity — the
  `Other` VALUE is the arithmetic remainder (`total − shown`, see `other_slice_value/5`), so a
  LONE collapsed cohort's value is fully reconstructable by subtraction (a single hidden slice ⇒
  `Other` == that slice's value). Do NOT rely on it to hide a sensitive dimension's values; the
  only disclosure protection on this path is the vault dimension/measure refusal above.

  `opts`:

    * `:scope` (REQUIRED) — the org scope; every measure resolves through it (OrgScope).
    * `:measure` — `:count` (default), `{:sum, field}`, or `{:avg, field}` (the SQL aggregate).
    * `:groups` — an ORDERED `[{key, label}]` (or bare `key`) list of slices (the bounded-domain
      case, e.g. a status enum); when omitted the distinct keys are DISCOVERED (bounded).
    * `:max_points` — cap on slices (default `#{@default_agg_points}`; clamped to `max_agg_points/0`).
    * `:collapse_below` — a LABEL-tidiness threshold for COUNT measures (default `1` = keep all
      slices); a slice with a smaller count is folded into `Other`. NOT an anonymity control —
      the `Other` value is the arithmetic remainder, so a lone collapsed cohort is recoverable.
    * `:other_label` — the label for the bounded tail slice (default `"Other"`).
  """
  def aggregate_by!(query, group_field, opts) when is_atom(group_field) and is_list(opts) do
    scope = Keyword.fetch!(opts, :scope)
    measure = normalize_measure(Keyword.get(opts, :measure, :count))
    base = Ash.Query.new(query)
    resource = base.resource

    refuse_vaulted_dimension!(resource, group_field)
    refuse_vaulted_measure!(resource, measure)

    max_points = bounded_agg_points(Keyword.get(opts, :max_points))
    collapse_below = bounded_collapse_below(Keyword.get(opts, :collapse_below))
    other_label = Keyword.get(opts, :other_label, "Other")
    read_opts = [scope: scope]

    # Grand total is a SINGLE SQL aggregate over the whole org-scoped set (no rows).
    total = numeric_value(measure_over!(base, measure, read_opts))

    {specs, has_tail} =
      aggregate_specs(base, group_field, Keyword.get(opts, :groups), max_points, read_opts)

    shown =
      Enum.map(specs, fn {key, label} ->
        filtered = apply_group_filter(base, group_field, key)
        raw = measure_over!(filtered, measure, read_opts)
        %Series.Point{key: key, label: label, value: numeric_value(raw), raw: raw}
      end)

    {kept, tail_value, collapsed?} = apply_collapse(shown, measure, collapse_below)
    other_value = other_slice_value(measure, total, kept, tail_value, has_tail)

    points =
      if other_value != nil do
        kept ++ [%Series.Point{key: @other_key, label: other_label, value: other_value, raw: other_value}]
      else
        kept
      end

    %Series{
      points: points,
      measure: measure,
      dimension: group_field,
      total: total_for(measure, total),
      capped: has_tail or collapsed?,
      max_points: max_points
    }
  end

  @doc """
  The GENERIC time-series primitive (G8, T56) — bucket a resource's rows by a NON-VAULTED DATE
  `date_field` over a bounded window `[range_start, range_end)` and compute a SQL MEASURE
  (count / sum / avg) per bucket into a `%Samen.Web.Series{}` (`dimension: :bucket`). The
  framework building block a line-chart tile (`Samen.UI.line_chart/1`) consumes at ≈0 authored
  LOC. First client: the CRM dashboard (opportunities closing over time).

  Each bucket's `value` is a bounded SQL aggregate over `date_field >= bucket_start and
  date_field < bucket_end` (org-scoped, authorization ALWAYS on — no `authorize?` opt) — the
  rows are never transferred. The number of buckets is BOUNDED to `max_series_buckets/0`; a
  window that would fan out past that (or an empty/inverted window) is REFUSED with
  `UnboundedSeriesRangeError`. Coarsen `:unit` (day → week → month) to stay under the cap.

  REFUSES a vault-routed (🔒) `date_field` (`MaskedGroupKeyError`) and a vault-routed SUM/AVG
  measure field (`MaskedMeasureError`) — a time axis and a charted measure must be non-secret.

  `opts`:

    * `:scope` (REQUIRED) — the org scope; every bucket measure resolves through it (OrgScope).
    * `:range_start` / `:range_end` (REQUIRED) — the window as `Date`s (`range_end` EXCLUSIVE).
    * `:unit` — `:day | :week | :month` bucket width (default `:month`).
    * `:measure` — `:count` (default), `{:sum, field}`, or `{:avg, field}`.
  """
  def time_series!(query, date_field, opts) when is_atom(date_field) and is_list(opts) do
    scope = Keyword.fetch!(opts, :scope)
    measure = normalize_measure(Keyword.get(opts, :measure, :count))
    base = Ash.Query.new(query)
    resource = base.resource

    refuse_vaulted_dimension!(resource, date_field)
    refuse_vaulted_measure!(resource, measure)

    unit = series_unit!(Keyword.get(opts, :unit, :month))
    range_start = to_date!(Keyword.fetch!(opts, :range_start))
    range_end = to_date!(Keyword.fetch!(opts, :range_end))
    read_opts = [scope: scope]

    buckets = series_buckets!(range_start, range_end, unit)

    points =
      Enum.map(buckets, fn {b_start, b_next, label} ->
        filtered =
          Ash.Query.do_filter(
            base,
            expr(^ref(date_field) >= ^b_start and ^ref(date_field) < ^b_next)
          )

        raw = measure_over!(filtered, measure, read_opts)
        %Series.Point{key: b_start, label: label, value: numeric_value(raw), raw: raw}
      end)

    total = numeric_value(measure_over!(base, measure, read_opts))

    %Series{
      points: points,
      measure: measure,
      dimension: :bucket,
      total: total_for(measure, total),
      capped: false,
      max_points: length(points)
    }
  end

  # A SUM/AVG grand total is meaningful; an AVG has no grand sum → nil total.
  defp total_for({:avg, _}, _total), do: nil
  defp total_for(_measure, total), do: total

  # -- aggregate helpers -------------------------------------------------------

  defp normalize_measure(:count), do: :count
  defp normalize_measure({op, field}) when op in [:sum, :avg] and is_atom(field), do: {op, field}

  defp normalize_measure(other),
    do: raise(ArgumentError, "measure must be :count | {:sum, field} | {:avg, field}, got #{inspect(other)}")

  defp bounded_collapse_below(n) when is_integer(n) and n >= 1, do: n
  defp bounded_collapse_below(_), do: 1

  # INV-1: the DIMENSION (group/date) field must be non-vaulted — a chart label/axis/bucket
  # keyed on a secret would leak plaintext or bucket by opaque tokens. Refuse like T50.
  defp refuse_vaulted_dimension!(resource, field) do
    if Samen.Pii.Info.vault_routed?(resource, field) do
      raise MaskedGroupKeyError,
        message:
          "REFUSED: cannot aggregate #{inspect(resource)} by the vault-routed (🔒) dimension " <>
            "#{inspect(field)} — a chart label/axis/bucket must be a non-secret facet, never a " <>
            "plaintext or vault-token slice (INV-1). Aggregate by a non-vaulted attribute."
    end
  end

  # INV-1 (aggregate-leak): a SUM/AVG measure field must be non-vaulted — summing/averaging a
  # secret leaks plaintext or a 1-cohort value. :count has no measure field to check.
  defp refuse_vaulted_measure!(_resource, :count), do: :ok

  defp refuse_vaulted_measure!(resource, {op, field}) when op in [:sum, :avg] do
    if Samen.Pii.Info.vault_routed?(resource, field) do
      raise MaskedMeasureError,
        message:
          "REFUSED: cannot #{op} the vault-routed (🔒) field #{inspect(field)} of " <>
            "#{inspect(resource)} — a charted measure must be a non-secret numeric facet, never " <>
            "a summed/averaged secret (INV-1). Measure a non-vaulted numeric field, or :count."
    end
  end

  # ONE SQL aggregate over the (possibly filtered) org-scoped query — count/sum/avg pushed to
  # Postgres, NO row transfer. The limit/sort are unset so the aggregate spans the whole set.
  defp measure_over!(query, measure, read_opts) do
    q = Ash.Query.unset(query, [:limit, :offset, :sort])

    case measure do
      :count -> Ash.count!(q, read_opts)
      {:sum, field} -> Ash.sum!(q, field, read_opts)
      {:avg, field} -> Ash.avg!(q, field, read_opts)
    end
  end

  # The ordered `{key, label}` slices + a has_tail? flag. Caller-provided groups enumerate a
  # bounded domain (no tail); DISCOVERED keys are bounded to max_points with the over-cap
  # remainder signalled as a tail (collapsed into the `Other` slice by the caller).
  defp aggregate_specs(_base, _field, groups, _max, _read_opts) when is_list(groups) do
    {group_specs(nil, nil, groups, nil, nil), false}
  end

  defp aggregate_specs(base, field, nil, max_points, read_opts) do
    keys =
      base
      |> Ash.Query.unset([:limit, :offset, :sort, :distinct])
      |> Ash.Query.select([field])
      |> Ash.Query.distinct([field])
      |> Ash.Query.sort([{field, :asc}])
      |> Ash.Query.limit(max_points + 1)
      |> Ash.read!(read_opts)
      |> Enum.map(&Map.get(&1, field))
      |> Enum.uniq()

    shown = Enum.take(keys, max_points)
    {Enum.map(shown, fn key -> {key, group_label(key)} end), length(keys) > max_points}
  end

  # LABEL-tidiness collapse for COUNT measures: a slice below `collapse_below` is folded into the
  # `Other` tail so a long tail of tiny slices does not clutter the chart. This is NOT anonymity
  # — the folded value is recoverable from the `Other` remainder (see `other_slice_value/5`); the
  # only disclosure control on this path is the vault dimension/measure refusal. Non-count
  # measures pass through untouched (the threshold is a cohort SIZE, which only :count's value
  # is). Returns `{kept_points, collapsed_tail_value, collapsed?}`.
  defp apply_collapse(points, :count, collapse_below) when collapse_below > 1 do
    {kept, collapsed} = Enum.split_with(points, &(&1.value >= collapse_below))
    tail = Enum.reduce(collapsed, 0, &(&1.value + &2))
    {kept, tail, collapsed != []}
  end

  defp apply_collapse(points, _measure, _collapse_below), do: {points, 0, false}

  # The `Other` slice value, or nil when there is no tail. Count/sum: grand total minus the
  # shown slices, PLUS any collapsed small-label value (arithmetic on SQL aggregates — no rows).
  # AVG has no additive tail (an average of an unknown remainder is meaningless) → no Other.
  defp other_slice_value({:avg, _}, _total, _kept, _tail_value, _has_tail), do: nil

  defp other_slice_value(_measure, total, kept, tail_value, has_tail) do
    if has_tail or tail_value > 0 do
      shown = Enum.reduce(kept, 0, &(&1.value + &2))
      max(total - shown, 0)
    end
  end

  # Normalize a SQL aggregate result to a plain NUMBER for chart geometry (count integer, a
  # Money sum → minor units, a Decimal avg → float). The `raw` value keeps the domain type.
  defp numeric_value(nil), do: 0
  defp numeric_value(n) when is_number(n), do: n
  defp numeric_value(%Decimal{} = d), do: Decimal.to_float(d)
  defp numeric_value(%Money{} = m), do: Samen.Type.Money.cents(m)
  defp numeric_value(_), do: 0

  # -- time-series bucket helpers ----------------------------------------------

  defp series_unit!(unit) when unit in @series_units, do: unit

  defp series_unit!(unit),
    do: raise(ArgumentError, "time_series!/3 :unit must be one of #{inspect(@series_units)}, got #{inspect(unit)}")

  defp to_date!(%Date{} = d), do: d
  defp to_date!(%DateTime{} = dt), do: DateTime.to_date(dt)
  defp to_date!(%NaiveDateTime{} = dt), do: NaiveDateTime.to_date(dt)

  defp to_date!(other),
    do: raise(ArgumentError, "time_series!/3 range endpoints must be Date/DateTime, got #{inspect(other)}")

  # Bounded `[{bucket_start, bucket_next, label}]` for the window, stepping by unit. Refuses an
  # empty/inverted window or one that would fan out past @max_series_buckets buckets.
  defp series_buckets!(range_start, range_end, unit) do
    if Date.compare(range_start, range_end) != :lt do
      raise UnboundedSeriesRangeError,
        message: "time_series!/3 window must be non-empty [start < end); got #{range_start}..#{range_end}."
    end

    buckets = build_buckets(range_start, range_end, unit, [], 0)
    Enum.reverse(buckets)
  end

  defp build_buckets(cursor, range_end, _unit, acc, count) when count >= @max_series_buckets do
    if Date.compare(cursor, range_end) == :lt do
      raise UnboundedSeriesRangeError,
        message:
          "time_series!/3 window fans out past the #{@max_series_buckets}-bucket cap — coarsen " <>
            ":unit (day → week → month) or narrow the window."
    end

    acc
  end

  defp build_buckets(cursor, range_end, unit, acc, count) do
    if Date.compare(cursor, range_end) == :lt do
      nxt = step_date(cursor, unit, 1)
      # The last bucket is clamped to range_end (a partial trailing bucket is fine).
      nxt = if Date.compare(nxt, range_end) == :gt, do: range_end, else: nxt
      label = bucket_label(cursor, unit)
      build_buckets(nxt, range_end, unit, [{cursor, nxt, label} | acc], count + 1)
    else
      acc
    end
  end

  defp step_date(%Date{} = d, :day, n), do: Date.add(d, n)
  defp step_date(%Date{} = d, :week, n), do: Date.add(d, 7 * n)
  defp step_date(%Date{} = d, :month, n), do: add_months(d, n)

  defp add_months(%Date{year: y, month: m, day: day}, n) do
    total = (y * 12 + (m - 1)) + n
    ny = div(total, 12)
    nm = rem(total, 12) + 1
    last = Date.days_in_month(%Date{year: ny, month: nm, day: 1})
    Date.new!(ny, nm, min(day, last))
  end

  @month_abbr ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  defp bucket_label(%Date{} = d, :month), do: "#{Enum.at(@month_abbr, d.month - 1)} #{d.year}"
  defp bucket_label(%Date{} = d, :week), do: "Wk #{Enum.at(@month_abbr, d.month - 1)} #{d.day}"
  defp bucket_label(%Date{} = d, :day), do: "#{Enum.at(@month_abbr, d.month - 1)} #{d.day}"

  # -- map / geo (G7, T55) -----------------------------------------------------

  @doc "The default cap on the NUMBER of plotted markers (`geo_markers!/3`)."
  def default_markers, do: @default_markers

  @doc "The hard cap on plotted markers — a larger `:max_markers` is clamped, never honored."
  def max_markers, do: @max_markers

  @doc "Clamp a requested marker cap into `1..max_markers/0` (nil/garbage → the default)."
  def bounded_markers(n) when is_integer(n) and n >= 1, do: min(n, @max_markers)
  def bounded_markers(_), do: @default_markers

  @doc """
  The GENERIC map-marker primitive (G7, T55) — read a BOUNDED, ORG-SCOPED set of records and
  project each to a `%Samen.Web.GeoSet.Marker{}` for the `Samen.UI.map/1` renderer. The
  geographic analogue of `aggregate_by!/3`: the value a map tile consumes.

  Org-scope is UNCONDITIONAL — the read runs through `Ash.read!` with the caller's `:scope` and
  authorization ALWAYS on (no `authorize?` forwarding), so `Samen.Policy.OrgScope` narrows the
  set by construction; org B's points can never enter org A's map.

  BOUNDED BY CONSTRUCTION — reads `limit(max_markers + 1)`; when MORE than the cap exist, the
  overflow is dropped and the returned `%GeoSet{}` carries `capped: true` + a withheld count, so
  a 100k-row geo table can never OOM the LiveView or the DOM. Never a `read!` of the full set.

  ## Coordinate & label masking (INV-1)

    * `:lat` / `:lng` — REQUIRED. Each is a **field atom** (read from the record) or a 1-arg
      **fun** `(record -> number)`. When given a field atom, the primitive REFUSES a VAULT-ROUTED
      (🔒) coordinate field (`Samen.Web.Reads.MaskedCoordinateError`) — a precise location is PII
      and must not be plotted from the vault (the coordinate-leak guard). A fun is host-computed
      (the host owns any coarsening/blurring; documented, same trust model as a chart `:format`).
    * `:label` — OPTIONAL. A field atom or a 1-arg fun for the marker popover/tooltip text. A
      vaulted label is masked per plane via `:resolve` (below): the renderer draws it verbatim.
    * `:resolve` — OPTIONAL 1-arg fun `([record] -> [record])` run on the bounded rows BEFORE
      marker projection — the seam a caller uses to run `Samen.Api.PiiResolution.resolve/4` on
      the actor's plane, so a vaulted `:label` becomes `%Samen.Masked{}` (→ `••••`) for an
      operator-without-grant, plaintext for the tenant. Defaults to identity (non-PII labels).

  `opts`: `:scope` (required), `:lat` (required), `:lng` (required), `:label`, `:resolve`,
  `:max_markers` (default `#{@default_markers}`; clamped to `max_markers/0`), `:sort`
  (`{field, dir}` within the bound, default `{:id, :asc}` for a stable, non-PII cursor).
  """
  def geo_markers!(query, opts) when is_list(opts) do
    scope = Keyword.fetch!(opts, :scope)
    lat_spec = Keyword.fetch!(opts, :lat)
    lng_spec = Keyword.fetch!(opts, :lng)
    label_spec = Keyword.get(opts, :label)
    resolve = Keyword.get(opts, :resolve, & &1)

    base = Ash.Query.new(query)
    resource = base.resource

    refuse_vaulted_coord!(resource, lat_spec)
    refuse_vaulted_coord!(resource, lng_spec)

    cap = bounded_markers(Keyword.get(opts, :max_markers))
    sort = Keyword.get(opts, :sort, {:id, :asc})

    # Any coordinate/label given as a FIELD ATOM must be selected so it lands on the record (a
    # vault-routed label like `:full_name` is not selected by a default read). Fun specs read
    # whatever the record already carries.
    select = Enum.filter([lat_spec, lng_spec, label_spec], &(is_atom(&1) and not is_nil(&1)))

    # UNCONDITIONAL org-scope: authorization is always on (no authorize? forwarding), so
    # OrgScope narrows the read — the boundary is not disableable.
    records =
      base
      |> ensure_selected_fields(select)
      |> apply_sort(sort)
      |> Ash.Query.limit(cap + 1)
      |> Ash.read!(scope: scope)

    capped = length(records) > cap
    kept = Enum.take(records, cap)

    markers =
      kept
      |> resolve.()
      |> Enum.map(&build_marker(&1, lat_spec, lng_spec, label_spec))

    %GeoSet{
      markers: markers,
      projection: Projection,
      max_markers: cap,
      shown: length(markers),
      capped: capped,
      capped_count: if(capped, do: nil, else: 0)
    }
  end

  # A field-atom coordinate that is vault-routed is REFUSED (the coordinate-leak guard); a fun
  # spec is host-computed and not field-checked (the host owns any blurring/coarsening).
  defp refuse_vaulted_coord!(resource, field) when is_atom(field) and not is_nil(field) do
    if Samen.Pii.Info.vault_routed?(resource, field) do
      raise MaskedCoordinateError,
        message:
          "REFUSED: cannot plot #{inspect(resource)} markers from the vault-routed (🔒) " <>
            "coordinate field #{inspect(field)} — a precise location is PII and must not be " <>
            "plotted from the vault (INV-1). Plot a non-secret facet (a public centroid, a " <>
            "coarsened grid), never the vaulted scalar."
    end

    :ok
  end

  defp refuse_vaulted_coord!(_resource, _fun), do: :ok

  defp ensure_selected_fields(query, []), do: query
  defp ensure_selected_fields(query, fields), do: Ash.Query.ensure_selected(query, fields)

  defp build_marker(record, lat_spec, lng_spec, label_spec) do
    lat = coord_value(record, lat_spec)
    lng = coord_value(record, lng_spec)
    {x, y} = project_or_nil(lat, lng)

    %Marker{
      id: Map.get(record, :id),
      lat: lat,
      lng: lng,
      x: x,
      y: y,
      label: label_value(record, label_spec),
      raw: record
    }
  end

  defp coord_value(record, field) when is_atom(field) and not is_nil(field), do: numberize(Map.get(record, field))
  defp coord_value(record, fun) when is_function(fun, 1), do: numberize(fun.(record))
  defp coord_value(_record, _), do: nil

  defp numberize(v) when is_number(v), do: v
  defp numberize(_), do: nil

  defp label_value(_record, nil), do: nil
  defp label_value(record, field) when is_atom(field), do: Map.get(record, field)
  defp label_value(record, fun) when is_function(fun, 1), do: fun.(record)

  defp project_or_nil(lat, lng) do
    case Projection.project(lat, lng) do
      {x, y} -> {x, y}
      nil -> {nil, nil}
    end
  end

  # -- tree (G6, WS-G) ---------------------------------------------------------

  @doc "The default per-parent (per-level) children cap for `tree!/3`."
  def default_tree_sibling_limit, do: @default_tree_sibling_limit

  @doc "The hard per-parent cap — a larger `:sibling_limit` is clamped, never honored."
  def max_tree_sibling_limit, do: @max_tree_sibling_limit

  @doc "The default max descent depth for `tree!/3` (levels below the roots)."
  def default_tree_max_depth, do: @default_tree_max_depth

  @doc "The hard depth cap — a deeper `:max_depth` is clamped, never honored."
  def max_tree_max_depth, do: @max_tree_max_depth

  @doc "The default total-node budget for `tree!/3` (materialized nodes across the whole walk)."
  def default_tree_max_nodes, do: @default_tree_max_nodes

  @doc "The hard total-node budget — a larger `:max_nodes` is clamped, never honored."
  def max_tree_max_nodes, do: @max_tree_max_nodes

  @doc "Clamp a requested per-parent cap into `1..max_tree_sibling_limit/0` (nil/garbage → default)."
  def bounded_tree_sibling_limit(n) when is_integer(n) and n >= 1, do: min(n, @max_tree_sibling_limit)
  def bounded_tree_sibling_limit(_), do: @default_tree_sibling_limit

  @doc "Clamp a requested depth into `1..max_tree_max_depth/0` (nil/garbage → default)."
  def bounded_tree_max_depth(n) when is_integer(n) and n >= 1, do: min(n, @max_tree_max_depth)
  def bounded_tree_max_depth(_), do: @default_tree_max_depth

  @doc "Clamp a requested node budget into `1..max_tree_max_nodes/0` (nil/garbage → default)."
  def bounded_tree_max_nodes(n) when is_integer(n) and n >= 1, do: min(n, @max_tree_max_nodes)
  def bounded_tree_max_nodes(_), do: @default_tree_max_nodes

  @doc """
  The GENERIC hierarchical read primitive (G6, WS-G) — walk a resource's self-referential
  `parent_field` (a `belongs_to :parent` pointer, e.g. Work `Task`'s `:parent_id`) into a
  DEPTH-BOUNDED, CYCLE-SAFE, per-parent-BOUNDED `%Samen.Web.Tree{}`. The framework-level
  building block a tree view (`Samen.UI.tree/1`) consumes at ≈0 authored LOC; it holds NO
  vertical-specific logic. First client: the Work Task tree (`Samen.Web.Work.TaskTreeLive`).

  `query` is an `Ash.Query` or resource module — ALREADY resolved through the host mount
  (`Samen.Web.Mount.resource/2`) and any base filter; the hierarchy walk composes onto it.

  ## Org-scope is UNCONDITIONAL, AT EVERY LEVEL (no opt disables it)

  EVERY level's children read (roots AND every descendant fetch AND every per-node count) runs
  through `Ash.read!`/`Ash.count!` with the caller's `:scope` AND authorization ALWAYS ON, so
  `Samen.Policy.OrgScope` narrows EVERY level to the actor's org: a cross-org node can NEVER
  appear as a child anywhere in the tree, and no per-node count can leak cross-org cardinality.
  There is deliberately NO `authorize?` opt on this primitive (the T50 boundary; an `:authorize?`
  key in `opts` is IGNORED, never forwarded) — the boundary is not disableable by any caller
  (see `reads_tree_test.exs` "ORG-SCOPE AT EVERY LEVEL").

  ## Cycle safety + depth bound (the hierarchy hazards)

  The CycleGuard prevents a cycle on WRITE, but this READ never TRUSTS the data: a `visited` id
  set is threaded through the walk, so a node whose id was already expanded higher on the path is
  a `truncated: :cycle` leaf and is NOT descended into — the walk ALWAYS terminates (a self-parent
  or an A↔B cycle can never stack-overflow / infinite-loop, proven in `reads_tree_test.exs`). The
  descent is also hard-capped at `max_depth` levels, and the whole walk at a `max_nodes` budget.

  ## Masking (INV-1)

  REFUSES a vault-routed (🔒) `parent_field` with `Samen.Web.Reads.MaskedGroupKeyError` — a
  hierarchy driven by a secret would leak plaintext or nest by opaque tokens. The parent key is
  therefore always a non-secret facet. The returned node `record`s are raw rows the caller
  PII-resolves on its plane (`Samen.Api.PiiResolution`), exactly like a `%Page{}`'s items; the
  tree never plaintext-downgrades.

  ## N+1 strategy (bounded fan-out, NOT unbounded)

  One bounded, org-scoped `limit(sibling_limit + 1)` read per EXPANDED node (roots + each
  descended node) — so at most `max_nodes` bounded queries total, a HARD-BOUNDED fan-out, never
  an unbounded per-node N+1 that could DoS the DB. (A single batched `WHERE parent_id IN (...)`
  per level cannot express a PER-PARENT `LIMIT` in portable SQL; the per-node bounded read buys
  an exact, honest per-parent "+N more" at the cost of ≤ `max_nodes` bounded queries.) Lazy
  drill-in is preferred over eager depth — a `truncated: :depth`/`:budget` node exposes a
  drill-in link that RE-ROOTS the walk at that node (`:root`), so the whole forest is never
  materialized at once.

  `opts`:

    * `:scope` (REQUIRED) — the org scope; every level's read/count resolves through it (OrgScope).
    * `:root` — the node id to walk BELOW (the drill-in focus). `nil` (default) walks the TRUE
      roots (rows whose `parent_field` is `NULL`). The focus id is pre-seeded into `visited`, so
      focusing INTO a cycle terminates immediately.
    * `:sibling_limit` — per-parent (per-level) children cap (default `#{@default_tree_sibling_limit}`;
      clamped to `max_tree_sibling_limit/0`).
    * `:max_depth` — max levels below the roots (default `#{@default_tree_max_depth}`; clamped).
    * `:max_nodes` — total materialized-node budget (default `#{@default_tree_max_nodes}`; clamped).
    * `:row_sort` — `{field, dir}` order WITHIN each level (default `{:id, :asc}`; `id` tiebreaker).
    * `:child_count?` — compute the exact per-node `child_count` (default `true`); `false` skips it.
  """
  def tree!(query, parent_field, opts) when is_atom(parent_field) and is_list(opts) do
    scope = Keyword.fetch!(opts, :scope)
    base = Ash.Query.new(query)
    resource = base.resource

    if Samen.Pii.Info.vault_routed?(resource, parent_field) do
      raise MaskedGroupKeyError,
        message:
          "REFUSED: cannot build a tree of #{inspect(resource)} on the vault-routed (🔒) parent " <>
            "field #{inspect(parent_field)} — a hierarchy key must be a non-secret facet, never " <>
            "a plaintext or vault-token pointer (INV-1). Use a non-vaulted parent attribute."
    end

    sibling_limit = bounded_tree_sibling_limit(Keyword.get(opts, :sibling_limit))
    max_depth = bounded_tree_max_depth(Keyword.get(opts, :max_depth))
    max_nodes = bounded_tree_max_nodes(Keyword.get(opts, :max_nodes))
    row_sort = Keyword.get(opts, :row_sort, {:id, :asc})
    count? = Keyword.get(opts, :child_count?, true)
    root = Keyword.get(opts, :root)

    ctx = %{
      base: base,
      parent_field: parent_field,
      sibling_limit: sibling_limit,
      max_depth: max_depth,
      row_sort: row_sort,
      count?: count?,
      # UNCONDITIONAL org-scope: authorization ALWAYS on (no authorize? forwarding) — OrgScope
      # narrows every level's children read + count. The boundary is not disableable.
      read_opts: [scope: scope]
    }

    # Pre-seed `visited` with the focus id so drilling INTO a cycle terminates at once.
    acc = %{visited: MapSet.new(if(root, do: [root], else: [])), remaining: max_nodes}

    {roots, _more, _count, acc} = tree_level(root, 0, ctx, acc)

    %Tree{
      roots: roots,
      parent_field: parent_field,
      node_count: max_nodes - acc.remaining,
      sibling_limit: sibling_limit,
      max_depth: max_depth,
      max_nodes: max_nodes,
      truncated?: acc.remaining <= 0
    }
  end

  # Read the CHILDREN of `parent_key` (nil = the true roots) as bounded, org-scoped nodes at
  # `depth`. Returns {nodes, has_more, child_count, acc}.
  defp tree_level(parent_key, depth, ctx, acc) do
    {rows, has_more, count} = read_children(parent_key, ctx)

    {nodes, acc} =
      Enum.reduce(rows, {[], acc}, fn record, {nodes, acc} ->
        {node, acc} = build_tree_node(record, depth, ctx, acc)
        {[node | nodes], acc}
      end)

    {Enum.reverse(nodes), has_more, count, acc}
  end

  # One PER-PARENT-BOUNDED children read: filter to the parent key (is_nil for roots), sort
  # within the level, probe limit(cap + 1). Org-scoped via ctx.read_opts (unconditional).
  defp read_children(parent_key, ctx) do
    filtered =
      ctx.base
      |> apply_group_filter(ctx.parent_field, parent_key)
      |> apply_sort(ctx.row_sort)

    records = filtered |> Ash.Query.limit(ctx.sibling_limit + 1) |> Ash.read!(ctx.read_opts)
    has_more = length(records) > ctx.sibling_limit
    rows = Enum.take(records, ctx.sibling_limit)
    count = if ctx.count?, do: safe_count(filtered, ctx.read_opts)
    {rows, has_more, count}
  end

  # Materialize ONE node, descending into its children unless a bound stops us:
  #   * :cycle  — its id was already expanded on the path (bad data) — DO NOT recurse (terminate);
  #   * :depth  — the next level would exceed max_depth — stop, offer a drill-in;
  #   * :budget — the node budget is exhausted — stop, offer a drill-in;
  #   * else    — mark visited, read + attach its bounded children (org-scoped), recurse.
  defp build_tree_node(record, depth, ctx, acc) do
    id = Map.get(record, :id)
    acc = %{acc | remaining: acc.remaining - 1}
    node = %Tree.Node{record: record, id: id, depth: depth}

    cond do
      not is_nil(id) and MapSet.member?(acc.visited, id) ->
        {%{node | truncated: :cycle, expandable?: false}, acc}

      depth + 1 >= ctx.max_depth ->
        {%{node | truncated: :depth, expandable?: true}, acc}

      acc.remaining <= 0 ->
        {%{node | truncated: :budget, expandable?: true}, acc}

      true ->
        acc = %{acc | visited: MapSet.put(acc.visited, id)}
        {children, child_more, child_count, acc} = tree_level(id, depth + 1, ctx, acc)

        {%{
           node
           | children: children,
             has_more_children: child_more,
             child_count: child_count,
             expandable?: children != [] or child_more
         }, acc}
    end
  end

  # -- calendar (G2, WS-G) -----------------------------------------------------

  @doc "The hard cap on a calendar window's day span — a wider window is REFUSED, not read."
  def max_calendar_days, do: @max_calendar_days

  @doc "The default per-day (per-cell) row cap for `calendar_by_day!/3`."
  def default_calendar_cap, do: @default_calendar_cap

  @doc """
  The GENERIC calendar read primitive (G2, WS-G) — a TIME-WINDOWED grouped read that buckets
  a resource's rows by the DAY of a `:date` field into an ORDERED, per-DAY-BOUNDED
  `%Samen.Web.Board{}` (one `%Board.Group{}` per calendar day, its `key` a `Date`). The
  framework building block a calendar view renders (columns = days); it holds NO
  vertical-specific logic. First client: the G2 CRM opportunity calendar (T52), which windows
  Opportunities by `:close_date`.

  This is `group_by!/3` SPECIALIZED to a bounded date window, not a reinvention: it computes
  the window's ordered day columns and DELEGATES all grouping, per-column bounding, exact
  counts, org-scoping, AND the vault-field refusal to `group_by!/3`. Everything the calendar
  needs is inherited:

    * **Org-scope is UNCONDITIONAL** — `group_by!/3` reads every day column (rows, discovery,
      count) with authorization ALWAYS ON; there is no `authorize?` opt here either, so a
      cross-org row can never land in a cell (the T50 boundary, honored by construction).
    * **Masking (INV-1)** — `group_by!/3` RAISES `Samen.Web.Reads.MaskedGroupKeyError` if the
      date field is vault-routed (🔒): positioning rows by a secret would leak plaintext or
      bucket by opaque tokens. A calendar's date facet must be a non-secret field.
    * **Per-cell bounding** — each day is read with its own `limit(cap + 1)` probe, so a day
      with hundreds of events returns at most `cap` rows plus `has_more` and an exact DB
      `count` (the "+N more"), never the whole day.

  ## Window bounding (no unbounded scan)

  The number of day columns is bounded TWICE: the window is a bounded date span (`:month` →
  one calendar month; or an explicit `:range`), and a span WIDER than `max_calendar_days/0`
  is REFUSED with `Samen.Web.Reads.UnboundedCalendarRangeError` — a calendar can never fan out
  into a multi-year per-day query storm. The base query is also filtered to the window
  (`date_field >= range_start and date_field < range_end`), so the read is windowed at the
  SQL level, not just partitioned by the day list.

  `date_field` must be a `:date` attribute — day columns key on the exact stored `Date`. A
  non-date field is REFUSED (`ArgumentError`): grouping a `:utc_datetime` by exact value would
  bucket per-timestamp, not per-day (day-truncation is a deliberate future extension, not a
  silent wrong answer).

  `opts`:

    * `:scope` (REQUIRED) — the org scope; every read/count resolves through it (OrgScope).
    * `:month` — any `Date` in the month to render; the window is that whole calendar month
      `[first_of_month, first_of_next_month)`. Mutually exclusive with `:range`.
    * `:range` — an explicit `{range_start, range_end}` (both `Date`, `range_end` EXCLUSIVE).
    * `:per_group_limit` — per-DAY row cap (default `#{@default_calendar_cap}`; clamped to
      `max_group_cap/0` by `group_by!/3`).
    * `:row_sort` — `{field, dir}` order WITHIN a day (default `{:id, :asc}`).
    * `:count?` — compute the exact per-day `count` (default `true`).

  Returns a `%Samen.Web.Board{}` whose `groups` are the window's days IN ORDER (each `key` a
  `Date`, `label` the ISO day string). A day with no rows is still present as an empty column,
  so the calendar grid always has a cell to render. There is NO `authorize?` opt — org-scope
  is unconditional (inherited from `group_by!/3`).
  """
  def calendar_by_day!(query, date_field, opts) when is_atom(date_field) and is_list(opts) do
    scope = Keyword.fetch!(opts, :scope)
    {range_start, range_end} = calendar_window!(opts)

    span = Date.diff(range_end, range_start)

    cond do
      span <= 0 ->
        raise UnboundedCalendarRangeError,
          message:
            "EMPTY/INVALID calendar window: range_start #{range_start} is not before " <>
              "range_end #{range_end} (range_end is EXCLUSIVE) — a calendar window must be a " <>
              "forward span of at least one day."

      span > @max_calendar_days ->
        raise UnboundedCalendarRangeError,
          message:
            "UNBOUNDED CALENDAR WINDOW: #{span} days requested (#{range_start} .. #{range_end}), " <>
              "cap is #{@max_calendar_days} — a calendar is a bounded time window (a month/week), " <>
              "never a multi-year per-day fan-out. Narrow the range (Samen.Web.Reads / G2)."

      true ->
        :ok
    end

    assert_date_field!(query, date_field)

    day_groups =
      range_start
      |> Date.range(Date.add(range_end, -1))
      |> Enum.map(fn day -> {day, Date.to_iso8601(day)} end)

    # SQL-level window filter (belt-and-suspenders with the exact-day columns): the read only
    # ever touches rows inside [range_start, range_end).
    windowed =
      Ash.Query.do_filter(
        Ash.Query.new(query),
        expr(^ref(date_field) >= ^range_start and ^ref(date_field) < ^range_end)
      )

    group_by!(windowed, date_field,
      scope: scope,
      groups: day_groups,
      per_group_limit: Keyword.get(opts, :per_group_limit, @default_calendar_cap),
      row_sort: Keyword.get(opts, :row_sort, {:id, :asc}),
      count?: Keyword.get(opts, :count?, true)
    )
  end

  # Resolve the [range_start, range_end) window (range_end EXCLUSIVE) from :month or :range.
  defp calendar_window!(opts) do
    case {Keyword.get(opts, :month), Keyword.get(opts, :range)} do
      {%Date{} = month, nil} ->
        start = Date.beginning_of_month(month)
        {start, Date.add(Date.end_of_month(start), 1)}

      {nil, {%Date{} = s, %Date{} = e}} ->
        {s, e}

      {nil, nil} ->
        raise ArgumentError,
          "calendar_by_day!/3 requires :month (a Date) or :range ({start, end_exclusive})"

      _ ->
        raise ArgumentError, "calendar_by_day!/3 takes :month OR :range, not both"
    end
  end

  # A calendar day-column keys on the exact stored Date, so the facet MUST be a :date. A
  # datetime would bucket per-timestamp (day-truncation is a future extension), so refuse it
  # loudly rather than silently return the wrong (per-second) grouping.
  defp assert_date_field!(query, date_field) do
    resource = Ash.Query.new(query).resource

    case Ash.Resource.Info.attribute(resource, date_field) do
      %{type: Ash.Type.Date} ->
        :ok

      %{type: type} ->
        raise ArgumentError,
          "calendar_by_day!/3 requires a :date field; #{inspect(resource)}.#{date_field} is " <>
            "#{inspect(type)} — per-day bucketing of a non-date field is refused (day-truncation " <>
            "of a datetime is a deliberate future extension, not a silent per-timestamp grouping)."

      nil ->
        raise ArgumentError,
          "calendar_by_day!/3: #{inspect(resource)} has no attribute #{inspect(date_field)}."
    end
  end

  # -- timeline / Gantt (G3, WS-G) ---------------------------------------------

  @doc "The hard cap on a timeline window's day span — a wider window is REFUSED, not read."
  def max_timeline_days, do: @max_timeline_days

  @doc "The default per-lane (or single-lane) row/bar cap for `timeline_window!/3`."
  def default_timeline_cap, do: @default_timeline_cap

  @doc """
  The GENERIC timeline/Gantt read primitive (G3, WS-G) — a TIME-WINDOWED read that positions a
  resource's rows as horizontal BARS along a time axis by a `start_field`..`end_field` RANGE
  (start + optional end/duration), grouped into an ORDERED, per-lane-BOUNDED `%Samen.Web.Board{}`
  (one `%Board.Group{}` per LANE, or a single lane when no `:lane_field` is given). The framework
  building block a Gantt view renders (`Samen.UI.gantt/1`); it holds NO vertical-specific logic.
  First client: the Work Tasks timeline (T53), which positions Tasks by `:inserted_at`..`:due_at`.

  Where `calendar_by_day!/3` buckets a resource by a single date INTO day columns, a timeline
  spans a RANGE per record, so the window predicate is an OVERLAP test, not a point-in-day test.

  ## Windowed overlap filter (DB-bounded, NOT load-then-filter)

  A record overlaps `[range_start, range_end)` iff `start < range_end AND end >= range_start`.
  This overlap predicate is pushed into SQL (an `Ash.Query.do_filter` on the base query), so the
  read only ever touches rows inside the window — never load-then-filter. A record whose
  `end_field` is NULL/absent is treated as a POINT at its start (`end := start`) — it is included
  when `start` itself falls in the window, and never renders an infinite bar (documented, tested).
  With no `:end_field` at all, every record is a point (`start >= range_start AND start < range_end`).

  ## Org-scope is UNCONDITIONAL (no opt disables it)

  Every read/count runs with the caller's `:scope` and authorization ALWAYS ON (`OrgScope`), so a
  cross-org row can never land in a lane. The lane path DELEGATES to `group_by!/3` (the T50
  boundary, inherited by construction); the single-lane path reads with the same `[scope: scope]`
  and no `authorize?` opt. There is deliberately NO `authorize?` opt on this primitive.

  ## Masking (INV-1)

  REFUSES a vault-routed (🔒) `start_field`/`end_field` with `Samen.Web.Reads.MaskedGroupKeyError`
  — POSITIONING a bar by a secret timestamp would leak plaintext (if resolved) or place it by an
  opaque token (if not). A timeline's temporal facet must be a non-secret field (the T50-style
  refusal, applied to the axis fields; `group_by!/3` separately refuses a vaulted `:lane_field`).
  The RETURNED `rows` are raw records the caller PII-resolves on its plane (like a `%Board{}`).

  ## Bounding (no unbounded timeline)

  Per LANE, not one global window: each lane is read with its OWN `limit(cap + 1)` probe, so a hot
  lane returns at most `cap` rows plus `has_more` and an exact DB `count` (the "+N more"), never
  the whole lane. The number of lanes is bounded too (`:max_groups` on discovery, or the explicit
  `:groups`). The WINDOW span is bounded: an inverted/empty range, or a span wider than
  `max_timeline_days/0`, is REFUSED with `Samen.Web.Reads.UnboundedTimelineRangeError`.

  `start_field` (and `end_field`, when given) must be a temporal attribute (a `:date` or
  `:utc_datetime`-family type); a non-temporal field is REFUSED (`ArgumentError`) — you cannot
  position a bar by a string/enum.

  `opts`:

    * `:scope` (REQUIRED) — the org scope; every read/count resolves through it (OrgScope).
    * `:range` (REQUIRED) — `{range_start, range_end}` (`range_end` EXCLUSIVE); both `Date` OR
      both a `DateTime`, matching the field type.
    * `:end_field` — the bar END attribute (nil = point events at `start_field`).
    * `:lane_field` — group rows into lanes by this non-vaulted attribute (nil = a single lane).
    * `:groups` — an ORDERED `[{key, label}]` list of lanes (forwarded to `group_by!/3`; the known
      status/owner lanes). When omitted with a `:lane_field`, lanes are DISCOVERED (bounded).
    * `:per_group_limit` — per-lane row/bar cap (default `#{@default_timeline_cap}`).
    * `:max_groups` — cap on DISCOVERED lanes (default `#{@default_max_groups}`).
    * `:row_sort` — order WITHIN a lane (default `{start_field, :asc}` — bars left-to-right).
    * `:count?` — compute the exact per-lane `count` (default `true`).

  Returns a `%Samen.Web.Board{}` whose `groups` are the lanes (each row a bar). There is NO
  `authorize?` opt — org-scope is unconditional.
  """
  def timeline_window!(query, start_field, opts) when is_atom(start_field) and is_list(opts) do
    scope = Keyword.fetch!(opts, :scope)
    end_field = Keyword.get(opts, :end_field)
    lane_field = Keyword.get(opts, :lane_field)
    {range_start, range_end} = timeline_window!(opts)

    span = timeline_span_days!(range_start, range_end)

    cond do
      span <= 0 ->
        raise UnboundedTimelineRangeError,
          message:
            "EMPTY/INVALID timeline window: range_start #{inspect(range_start)} is not before " <>
              "range_end #{inspect(range_end)} (range_end is EXCLUSIVE) — a timeline window must " <>
              "be a forward span of at least one day."

      span > @max_timeline_days ->
        raise UnboundedTimelineRangeError,
          message:
            "UNBOUNDED TIMELINE WINDOW: #{span} days requested, cap is #{@max_timeline_days} — a " <>
              "timeline is a bounded time window (a week/month/quarter), never a multi-year span. " <>
              "Narrow the range (Samen.Web.Reads / G3)."

      true ->
        :ok
    end

    resource = Ash.Query.new(query).resource
    # A vaulted axis is a SECRET first — refuse it before the type check (INV-1 takes precedence).
    assert_unmasked_axis!(resource, start_field)
    if end_field, do: assert_unmasked_axis!(resource, end_field)
    assert_time_field!(resource, start_field)
    if end_field, do: assert_time_field!(resource, end_field)

    windowed =
      Ash.Query.do_filter(
        Ash.Query.new(query),
        timeline_overlap_expr(start_field, end_field, range_start, range_end)
      )

    cap = Keyword.get(opts, :per_group_limit, @default_timeline_cap)
    row_sort = Keyword.get(opts, :row_sort, {start_field, :asc})
    count? = Keyword.get(opts, :count?, true)

    if lane_field do
      group_by!(windowed, lane_field,
        scope: scope,
        groups: Keyword.get(opts, :groups),
        max_groups: Keyword.get(opts, :max_groups, @default_max_groups),
        per_group_limit: cap,
        row_sort: row_sort,
        count?: count?
      )
    else
      single_lane_board!(windowed, cap, row_sort, count?, scope: scope)
    end
  end

  # The [range_start, range_end) window (range_end EXCLUSIVE) from :range.
  defp timeline_window!(opts) do
    case Keyword.get(opts, :range) do
      {%Date{} = s, %Date{} = e} -> {s, e}
      {%DateTime{} = s, %DateTime{} = e} -> {s, e}
      {%NaiveDateTime{} = s, %NaiveDateTime{} = e} -> {s, e}
      nil -> raise ArgumentError, "timeline_window!/3 requires :range ({start, end_exclusive})"
      other -> raise ArgumentError, "timeline_window!/3 :range must be {start, end}, got #{inspect(other)}"
    end
  end

  # Window span in whole days, for the bound guard (Date → diff; datetime → seconds/86400).
  defp timeline_span_days!(%Date{} = s, %Date{} = e), do: Date.diff(e, s)
  defp timeline_span_days!(%DateTime{} = s, %DateTime{} = e), do: div(DateTime.diff(e, s, :second), 86_400)

  defp timeline_span_days!(%NaiveDateTime{} = s, %NaiveDateTime{} = e),
    do: div(NaiveDateTime.diff(e, s, :second), 86_400)

  defp timeline_span_days!(s, e),
    do: raise(ArgumentError, "timeline range endpoints must be the same Date/DateTime type, got #{inspect({s, e})}")

  # The OVERLAP predicate, pushed to SQL. A NULL end is a POINT at start (never an infinite bar).
  defp timeline_overlap_expr(start_field, nil, range_start, range_end) do
    expr(^ref(start_field) >= ^range_start and ^ref(start_field) < ^range_end)
  end

  defp timeline_overlap_expr(start_field, end_field, range_start, range_end) do
    expr(
      ^ref(start_field) < ^range_end and
        ((not is_nil(^ref(end_field)) and ^ref(end_field) >= ^range_start) or
           (is_nil(^ref(end_field)) and ^ref(start_field) >= ^range_start))
    )
  end

  # A timeline axis field must be temporal (a bar is positioned by it). A non-temporal field is
  # refused loudly rather than silently mispositioned.
  defp assert_time_field!(resource, field) do
    case Ash.Resource.Info.attribute(resource, field) do
      %{type: type} when type in @time_types ->
        :ok

      %{type: type} ->
        raise ArgumentError,
          "timeline_window!/3 requires a temporal (:date/:utc_datetime) field; " <>
            "#{inspect(resource)}.#{field} is #{inspect(type)} — a bar cannot be positioned by it."

      nil ->
        raise ArgumentError,
          "timeline_window!/3: #{inspect(resource)} has no attribute #{inspect(field)}."
    end
  end

  # INV-1: a bar's axis (start/end) field must be non-vaulted — positioning by a secret would
  # leak plaintext or place the bar by an opaque token. Refuse it like a vaulted group key (T50).
  defp assert_unmasked_axis!(resource, field) do
    if Samen.Pii.Info.vault_routed?(resource, field) do
      raise MaskedGroupKeyError,
        message:
          "REFUSED: cannot position a timeline bar of #{inspect(resource)} by the vault-routed " <>
            "(🔒) field #{inspect(field)} — a timeline axis (start/end) must be a non-secret " <>
            "facet, never a plaintext or vault-token position (INV-1). Use a non-vaulted field."
    end
  end

  # The single-lane (no :lane_field) board — one bounded, org-scoped lane (key nil). Reuses the
  # same per-column bounding discipline as read_group: a limit(cap + 1) probe + exact count +
  # keyset next_cursor, all through [scope: scope] (org-scope unconditional).
  defp single_lane_board!(windowed, cap, row_sort, count?, read_opts) do
    cap = bounded_group_cap(cap)
    sorted = apply_sort(windowed, row_sort)
    records = sorted |> Ash.Query.limit(cap + 1) |> Ash.read!(read_opts)
    has_more = length(records) > cap
    rows = Enum.take(records, cap)

    %Board{
      groups: [
        %Board.Group{
          key: nil,
          label: nil,
          rows: rows,
          count: if(count?, do: safe_count(windowed, read_opts)),
          has_more: has_more,
          next_cursor: cursor_for(List.last(rows), row_sort)
        }
      ],
      group_field: nil,
      per_group_limit: cap,
      max_groups: 1
    }
  end

  # The ordered `{key, label}` columns: caller-provided (kanban stages) or DISCOVERED
  # (bounded distinct keys). Discovery is org-scoped (through read_opts) and column-bounded.
  defp group_specs(_base, _field, groups, _max, _read_opts) when is_list(groups) do
    Enum.map(groups, fn
      {key, label} -> {key, label}
      %{key: key, label: label} -> {key, label}
      key -> {key, group_label(key)}
    end)
  end

  defp group_specs(base, field, nil, max_groups, read_opts) do
    base
    |> Ash.Query.unset([:limit, :offset, :sort, :distinct])
    |> Ash.Query.select([field])
    |> Ash.Query.distinct([field])
    |> Ash.Query.sort([{field, :asc}])
    |> Ash.Query.limit(max_groups + 1)
    |> Ash.read!(read_opts)
    |> Enum.map(&Map.get(&1, field))
    |> Enum.uniq()
    |> Enum.take(max_groups)
    |> Enum.map(fn key -> {key, group_label(key)} end)
  end

  # One PER-GROUP-BOUNDED column: filter to the key, sort within, probe limit(cap + 1).
  defp read_group(base, field, {key, label}, cap, sort, count?, read_opts) do
    filtered = base |> apply_group_filter(field, key) |> apply_sort(sort)

    records = filtered |> Ash.Query.limit(cap + 1) |> Ash.read!(read_opts)
    has_more = length(records) > cap
    rows = Enum.take(records, cap)

    %Board.Group{
      key: key,
      label: label,
      rows: rows,
      count: if(count?, do: safe_count(filtered, read_opts)),
      has_more: has_more,
      next_cursor: cursor_for(List.last(rows), sort)
    }
  end

  defp apply_group_filter(query, field, nil),
    do: Ash.Query.do_filter(query, expr(is_nil(^ref(field))))

  defp apply_group_filter(query, field, key),
    do: Ash.Query.do_filter(query, expr(^ref(field) == ^key))

  # Exact per-group total (aggregate — no row transfer, bounded by construction). The count
  # query carries the group filter but NOT the row limit, so it counts the WHOLE column.
  defp safe_count(query, read_opts) do
    Ash.count!(Ash.Query.unset(query, [:limit, :offset, :sort]), read_opts)
  rescue
    _ -> nil
  end

  defp group_label(nil), do: nil
  defp group_label(key) when is_atom(key), do: Atom.to_string(key)
  defp group_label(key) when is_binary(key), do: key
  defp group_label(key), do: to_string(key)

  # -- query building ----------------------------------------------------------

  defp apply_sort(query, {:id, dir}), do: Ash.Query.sort(query, [{:id, dir}])
  defp apply_sort(query, {field, dir}), do: Ash.Query.sort(query, [{field, dir}, {:id, dir}])

  defp apply_cursor(query, nil, _sort), do: query

  defp apply_cursor(query, {id}, {:id, dir}) do
    Ash.Query.do_filter(query, id_after(id, dir))
  end

  defp apply_cursor(query, {nil, id}, {field, :asc}) do
    # ASC sorts nulls LAST: past a null-valued cursor only the null tail (by id) remains.
    Ash.Query.do_filter(query, expr(is_nil(^ref(field)) and ^id_after(id, :asc)))
  end

  defp apply_cursor(query, {nil, id}, {field, :desc}) do
    # DESC sorts nulls FIRST: past a null-valued cursor come the null tail (by id),
    # then every non-null row.
    Ash.Query.do_filter(
      query,
      expr((is_nil(^ref(field)) and ^id_after(id, :desc)) or not is_nil(^ref(field)))
    )
  end

  defp apply_cursor(query, {value, id}, {field, :asc}) do
    # Strictly after (value, id) — including the nulls-last tail.
    Ash.Query.do_filter(
      query,
      expr(
        ^ref(field) > ^value or
          (^ref(field) == ^value and ^id_after(id, :asc)) or
          is_nil(^ref(field))
      )
    )
  end

  defp apply_cursor(query, {value, id}, {field, :desc}) do
    Ash.Query.do_filter(
      query,
      expr(^ref(field) < ^value or (^ref(field) == ^value and ^id_after(id, :desc)))
    )
  end

  defp id_after(id, :asc), do: expr(id > ^id)
  defp id_after(id, :desc), do: expr(id < ^id)

  defp apply_filter(query, filter, fields) when is_binary(filter) do
    case {String.trim(filter), fields} do
      {"", _} -> query
      {_, []} -> query
      {q, fields} -> Ash.Query.do_filter(query, filter_expr(fields, String.downcase(q)))
    end
  end

  defp apply_filter(query, _filter, _fields), do: query

  defp filter_expr(fields, q) do
    fields
    |> Enum.map(fn field -> expr(contains(string_downcase(^ref(field)), ^q)) end)
    |> Enum.reduce(fn e, acc -> expr(^acc or ^e) end)
  end
end
