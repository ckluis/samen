defmodule Samen.UI.Table do
  @moduledoc """
  Table / list primitives of the `Samen.UI` kit: `data_table/1`, the
  behaviour-bearing `list_view/1` (ADR-016 §2), and `sort_header/1`. Split out of
  the `Samen.UI` god-module (behaviour-identical). `list_view/1` composes
  `data_table/1` (SIBLING here), plus `button/1` (from `Samen.UI.Shell`) and
  `empty_state/1`/`skeleton/1` (from `Samen.UI.Feedback`) — imported below.
  `Samen.UI` re-exports each via `defdelegate`.
  """
  use Phoenix.Component

  import Samen.UI.Shell, only: [button: 1]
  import Samen.UI.Feedback, only: [empty_state: 1, skeleton: 1]

  # ---------------------------------------------------------------------------
  # Data table
  # ---------------------------------------------------------------------------

  @doc """
  A data table wrapped in a `.card`. The `:head` slot supplies the `<tr>` of
  `<th>`s; the default inner block supplies the `<tbody>` rows (`<tr class="...">`).
  The kit does NOT interpret cell values — a row renders whatever the caller puts
  in it, so a `%Samen.Masked{}` cell shows `••••` via `Phoenix.HTML.Safe`.

  ## Responsive variant (WS-E E6.1, ADR-030)

  The `<table>` is wrapped in a `.table-scroll` container that, at the mobile
  breakpoint, gives the table a bounded HORIZONTAL scroll instead of clipping or
  reflowing cells. This is deliberately value-blind: it never reads, stringifies,
  or reflows a cell VALUE (which would be the only way to disturb masking), so a
  `%Samen.Masked{}` cell renders `••••` identically at every width (AC-G20-2).
  """
  slot :head, required: true
  slot :inner_block, required: true

  def data_table(assigns) do
    ~H"""
    <div class="card">
      <div class="table-scroll">
        <table>
          <thead>
            <tr>{render_slot(@head)}</tr>
          </thead>
          <tbody>
            {render_slot(@inner_block)}
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # List view (ADR-016 §2 — data_table + sort/filter/keyset-pagination/bulk as
  # KIT DEFAULTS; every vertical inherits list ergonomics at ≈0 lines)
  # ---------------------------------------------------------------------------

  @doc """
  The behaviour-bearing list primitive (ADR-016 §2, WS-A design §1.1): wraps
  `data_table/1` and adds, as **kit defaults**, a debounced filter box
  (`phx-change="filter"`), sortable headers (via `sort_header/1` in the `:head`
  slot), a KEYSET pagination footer (`phx-click="paginate"`, prev/next — stable
  under concurrent inserts, see `Samen.Web.Reads`), and an optional bulk-select
  affordance (checkbox column + a bulk-action bar that appears when ≥ 1 row is
  selected). Pairs with the `Samen.Web.ListLive` mixin, which owns every event
  this component emits.

  Attrs:

    * `page`        — a `%Samen.Web.Page{}` (the bounded read's result)
    * `state`       — a `%Samen.Web.ListState{}`; supplies `sort`/`filter`/
      `selected`/prev-availability (each also individually overridable)
    * `selectable`  — render the bulk-select checkbox column (default `false`)
    * `bulk_actions`— `[%{name: "archive", label: "Archive"}]` rendered in the
      default bulk bar (`phx-click="bulk"` with `phx-value-action`)
    * `empty_text`  — the default zero-row copy, rendered as the title of the
      default `empty_state/1` (ADR-016 §5 — every `list_view` adopter gets the
      consistent empty state at zero cost; the `:empty` slot overrides it)
    * `empty_icon` / `empty_body` — forwarded to the default `empty_state/1`
      (WS-A design §3.1 / AC-G5-1: icon + message on every list's empty state)

  Slots: `:head` (the `<th>`s — use `sort_header/1` for sortable columns),
  `:row` (`:let={item}` — the `<td>`s for one record), `:bulk_bar`
  (`:let={selected}` — replaces the default bulk-action buttons), `:empty`,
  `:empty_actions` (the surface's primary CREATE action, forwarded into the
  default empty state's `:actions` — AC-G5-1's "wired CTA" half), and
  `:empty_sample` (the load-sample-data affordance, forwarded into `:sample` —
  the AC-G5-3 hook).

  ## Masking (LOAD-BEARING)

  A row cell renders whatever the `:row` slot puts in it — an ALREADY-RESOLVED
  value. A `%Samen.Masked{}` renders `••••` via `Phoenix.HTML.Safe`; this component
  never stringifies, inspects, or unwraps a field value (rows are keyed by `id`
  only, a non-PII opaque uuid). The kit adds no unmasking here.
  """
  attr :id, :string, default: "list"
  attr :page, :any, required: true, doc: "a %Samen.Web.Page{}"
  attr :state, :any, default: nil, doc: "a %Samen.Web.ListState{} (or nil)"
  attr :loading, :boolean,
    default: false,
    doc: "render the skeleton/1 placeholder instead of rows/empty (WS-E E6.2)"

  attr :filter, :string, default: nil
  attr :selected, :any, default: nil, doc: "MapSet of selected row ids"
  attr :selectable, :boolean, default: false
  attr :row_class, :string, default: nil, doc: "extra class on each row <tr> (e.g. \"contact-row\")"
  attr :bulk_actions, :list, default: []
  attr :filter_placeholder, :string, default: "Filter…"
  attr :empty_text, :string, default: "Nothing here yet."
  attr :empty_icon, :string, default: nil
  attr :empty_body, :string, default: nil
  slot :head, required: true
  slot :row, required: true
  slot :bulk_bar
  slot :empty
  slot :empty_actions, doc: "forwarded to the default empty_state's :actions (the create CTA)"
  slot :empty_sample, doc: "forwarded to the default empty_state's :sample (load sample data)"

  def list_view(assigns) do
    assigns =
      assigns
      |> assign(:filter, assigns.filter || list_state_get(assigns.state, :filter, ""))
      |> assign(:selected, assigns.selected || list_state_get(assigns.state, :selected, MapSet.new()))
      |> assign(:prev?, list_prev?(assigns.state, assigns.page))
      |> assign(:row_class_attr, Enum.join(["list-row"] ++ List.wrap(assigns.row_class), " "))

    ~H"""
    <div class="list-view" id={@id}>
      <div class="list-toolbar" style="display:flex;align-items:center;gap:10px;margin-bottom:10px;flex-wrap:wrap">
        <form class="list-filter" phx-change="filter" phx-submit="filter" style="flex:0 0 auto">
          <input
            type="search"
            name="filter"
            value={@filter}
            placeholder={@filter_placeholder}
            phx-debounce="300"
            autocomplete="off"
            aria-label="Filter list"
          />
        </form>
        <div
          :if={@selectable and MapSet.size(@selected) > 0}
          class="bulk-bar"
          role="toolbar"
          aria-label="Bulk actions"
          style="display:flex;align-items:center;gap:8px"
        >
          <span class="bulk-count">{MapSet.size(@selected)} selected</span>
          <%= if @bulk_bar != [] do %>
            {render_slot(@bulk_bar, @selected)}
          <% else %>
            <.button :for={action <- @bulk_actions} phx-click="bulk" phx-value-action={bulk_action_name(action)}>
              {bulk_action_label(action)}
            </.button>
          <% end %>
        </div>
      </div>

      <%= cond do %>
        <% @loading -> %>
          <div class="card list-loading" style="padding:14px 16px">
            <.skeleton rows={5} avatar />
          </div>
        <% @page.items == [] and @empty != [] -> %>
          {render_slot(@empty)}
        <% @page.items == [] -> %>
          <.empty_state class="list-empty" title={@empty_text} body={@empty_body} icon={@empty_icon}>
            <:actions :if={@empty_actions != []}>{render_slot(@empty_actions)}</:actions>
            <:sample :if={@empty_sample != []}>{render_slot(@empty_sample)}</:sample>
          </.empty_state>
        <% true -> %>
        <.data_table>
          <:head>
            <th :if={@selectable} scope="col" class="list-select-col" style="width:28px">
              <input
                type="checkbox"
                phx-click="select_all"
                checked={list_all_selected?(@page.items, @selected)}
                aria-label="Select all rows on this page"
              />
            </th>
            {render_slot(@head)}
          </:head>
          <tr :for={item <- @page.items} class={@row_class_attr} id={"#{@id}-row-#{item.id}"}>
            <td :if={@selectable} class="list-select-cell">
              <input
                type="checkbox"
                phx-click="select"
                phx-value-id={item.id}
                checked={MapSet.member?(@selected, item.id)}
                aria-label="Select row"
              />
            </td>
            {render_slot(@row, item)}
          </tr>
        </.data_table>

        <div class="list-footer" style="display:flex;align-items:center;gap:10px;margin-top:10px">
          <.button phx-click="paginate" phx-value-dir="prev" disabled={not @prev?} aria-label="Previous page">
            ‹ Prev
          </.button>
          <.button phx-click="paginate" phx-value-dir="next" disabled={not @page.has_more} aria-label="Next page">
            Next ›
          </.button>
          <span class="list-page-size" style="color:var(--muted);font-size:12px">
            page size {@page.page_size}
          </span>
        </div>
      <% end %>
    </div>
    """
  end

  @doc """
  A sortable column header for `list_view/1`'s `:head` slot. Emits
  `phx-click="sort"` with `phx-value-field` (the `Samen.Web.ListLive` mixin matches
  it against the view's BOUNDED sortable list — client input never mints an atom).
  Carries `scope="col"` + `aria-sort` (AC-G1-9).
  """
  attr :field, :atom, required: true
  attr :label, :string, required: true
  attr :sort, :any, default: nil, doc: "{field, :asc | :desc} — usually @list_state.sort"
  attr :width, :string, default: nil

  def sort_header(assigns) do
    {active, dir} =
      case assigns.sort do
        {field, dir} when field == assigns.field -> {true, dir}
        _ -> {false, nil}
      end

    assigns = assign(assigns, active: active, dir: dir)

    ~H"""
    <th
      scope="col"
      class={["sort-th", @active && "sorted"]}
      style={@width && "width:#{@width}"}
      aria-sort={sort_aria(@active, @dir)}
    >
      <button
        type="button"
        class="sort-btn"
        phx-click="sort"
        phx-value-field={Atom.to_string(@field)}
        style="background:none;border:0;padding:0;font:inherit;color:inherit;cursor:pointer;display:inline-flex;align-items:center;gap:4px"
      >
        {@label}
        <span :if={@active} class="sort-dir" aria-hidden="true">{if @dir == :asc, do: "▲", else: "▼"}</span>
      </button>
    </th>
    """
  end

  defp sort_aria(true, :asc), do: "ascending"
  defp sort_aria(true, :desc), do: "descending"
  defp sort_aria(_, _), do: nil

  # list_view helpers — STATE plumbing only; these never touch a field value.

  defp list_state_get(nil, _key, default), do: default
  defp list_state_get(state, key, default), do: Map.get(state, key) || default

  # Prev is available when the current page has a cursor (i.e. not the first page).
  defp list_prev?(%{cursor_stack: stack}, _page) when is_list(stack), do: stack != []
  defp list_prev?(_state, %{cursor: cursor}), do: cursor != nil
  defp list_prev?(_state, _page), do: false

  defp list_all_selected?([], _selected), do: false

  defp list_all_selected?(items, selected),
    do: Enum.all?(items, fn item -> MapSet.member?(selected, item.id) end)

  defp bulk_action_name(%{name: name}), do: name
  defp bulk_action_name(name) when is_binary(name), do: name

  defp bulk_action_label(%{label: label}), do: label
  defp bulk_action_label(%{name: name}), do: name
  defp bulk_action_label(name) when is_binary(name), do: name
end
