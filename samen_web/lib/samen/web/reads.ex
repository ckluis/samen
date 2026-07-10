defmodule Samen.Web.Reads.UnboundedReadError do
  @moduledoc """
  Raised by `Samen.Web.Reads.bounded!/4` when a `ListLive` reads function returns the
  FULL set (no `limit`) instead of a bounded `%Samen.Web.Page{}` — the `read!`-elimination
  guard (RP-G1-5, pinned A2 gate carry A2-N1). A raise here is the LOUD rejection the
  design requires: an unbounded read must FAIL, never silently return everything.
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

  alias Samen.Web.ListState
  alias Samen.Web.Page
  alias Samen.Web.Reads.UnboundedReadError

  @default_page_size 50
  @max_page_size 200

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
