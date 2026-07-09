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

  `opts` — `:scope` (required) plus `build/3` options.
  """
  def page!(query, %ListState{} = state, opts) do
    size = bounded_page_size(state.page_size)
    sort = state.sort || {:id, :asc}
    records = query |> build(state, opts) |> Ash.read!(scope: Keyword.fetch!(opts, :scope))

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
