defmodule Samen.UI.ListViewTest do
  @moduledoc """
  Unit tests for the A2 list primitives (ADR-016 §2, AC-G1-3 + AC-G1-9 partial):
  `Samen.UI.list_view/1` (filter box + keyset pagination footer + bulk-select as kit
  defaults) and `Samen.UI.sort_header/1` (sortable `<th>` with `scope`/`aria-sort`).
  Includes the component-level masking test: a `%Samen.Masked{}` cell renders `••••`
  with the vault token ABSENT.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Samen.Web.ListState
  alias Samen.Web.Page

  @token "vt_SECRET_TOKEN_should_never_render"
  @masked %Samen.Masked{token: @token, label: :pii_name}

  defp page(items, opts \\ []) do
    %Page{
      items: items,
      has_more: Keyword.get(opts, :has_more, false),
      cursor: Keyword.get(opts, :cursor),
      page_size: Keyword.get(opts, :page_size, 5)
    }
  end

  defp head_slot do
    [%{inner_block: fn _, _ -> Phoenix.HTML.raw(~s(<th scope="col">Name</th>)) end}]
  end

  defp row_slot(fun \\ fn item -> item.name end) do
    [%{inner_block: fn _, item -> fun.(item) end}]
  end

  defp render_list(assigns) do
    defaults = %{head: head_slot(), row: row_slot()}
    render_component(&Samen.UI.list_view/1, Map.merge(defaults, assigns))
  end

  defp element_with(html, marker) do
    html
    |> String.split("<button")
    |> Enum.find("", &String.contains?(&1, marker))
  end

  # -- kit defaults: filter box + pagination footer (AC-G1-3) ------------------

  test "renders the debounced filter box wired to the ListLive 'filter' event" do
    html = render_list(%{page: page([%{id: "1", name: "A"}]), filter: "north"})

    assert html =~ ~s(phx-change="filter")
    assert html =~ ~s(phx-debounce="300")
    assert html =~ ~s(name="filter")
    assert html =~ ~s(value="north")
    assert html =~ ~s(aria-label="Filter list")
  end

  test "pagination footer: first page with more → Prev disabled, Next enabled" do
    html = render_list(%{page: page([%{id: "1", name: "A"}], has_more: true, cursor: nil)})

    assert element_with(html, ~s(phx-value-dir="prev")) =~ "disabled"
    refute element_with(html, ~s(phx-value-dir="next")) =~ "disabled"
    assert html =~ ~s(phx-click="paginate")
  end

  test "pagination footer: mid-walk state → Prev enabled; last page → Next disabled" do
    state = %ListState{cursor: {"c", "id-5"}, cursor_stack: [nil]}
    html = render_list(%{page: page([%{id: "6", name: "F"}], has_more: false), state: state})

    refute element_with(html, ~s(phx-value-dir="prev")) =~ "disabled"
    assert element_with(html, ~s(phx-value-dir="next")) =~ "disabled"
    assert html =~ "page size 5"
  end

  # -- bulk-select affordance (AC-G1-3) ----------------------------------------

  test "selectable renders the select-all header + per-row checkboxes; bulk bar hidden at 0 selected" do
    html =
      render_list(%{
        page: page([%{id: "r1", name: "A"}, %{id: "r2", name: "B"}]),
        selectable: true,
        bulk_actions: [%{name: "archive", label: "Archive"}]
      })

    assert html =~ ~s(phx-click="select_all")
    assert html =~ ~s(phx-click="select")
    assert html =~ ~s(phx-value-id="r1")
    assert html =~ ~s(phx-value-id="r2")
    # No selection yet → no bulk bar.
    refute html =~ ~s(class="bulk-bar")
  end

  test "bulk bar appears when ≥1 selected, with the count + default action buttons" do
    html =
      render_list(%{
        page: page([%{id: "r1", name: "A"}, %{id: "r2", name: "B"}]),
        selectable: true,
        selected: MapSet.new(["r1"]),
        bulk_actions: [%{name: "archive", label: "Archive"}]
      })

    assert html =~ ~s(class="bulk-bar")
    assert html =~ "1 selected"
    assert html =~ ~s(phx-click="bulk")
    assert html =~ ~s(phx-value-action="archive")
    assert html =~ "Archive"
    # The selected row's checkbox is checked.
    assert html =~ "checked"
  end

  test "a custom :bulk_bar slot replaces the default action buttons" do
    html =
      render_list(%{
        page: page([%{id: "r1", name: "A"}]),
        selectable: true,
        selected: MapSet.new(["r1"]),
        bulk_actions: [%{name: "archive", label: "Archive"}],
        bulk_bar: [%{inner_block: fn _, selected -> Phoenix.HTML.raw(~s(<em id="custom-bulk">#{MapSet.size(selected)}</em>)) end}]
      })

    assert html =~ ~s(id="custom-bulk")
    refute html =~ ~s(phx-value-action="archive")
  end

  # -- empty state --------------------------------------------------------------

  test "zero rows renders the :empty slot (no table)" do
    html =
      render_list(%{
        page: page([]),
        empty: [%{inner_block: fn _, _ -> Phoenix.HTML.raw(~s(<div id="my-empty">Nada</div>)) end}]
      })

    assert html =~ ~s(id="my-empty")
    refute html =~ "<table>"
  end

  test "zero rows without an :empty slot renders the kit empty_state by default (AC-G5-1)" do
    html = render_list(%{page: page([]), empty_text: "No records yet."})

    # ADR-016 §5: list_view's default :empty IS the standard empty_state component.
    assert html =~ ~s(class="card empty-state list-empty")
    assert html =~ ~s(class="empty-title")
    assert html =~ "No records yet."
  end

  # -- sort_header (AC-G1-3 + AC-G1-9 a11y) -------------------------------------

  test "sort_header emits the sort event with the field and carries scope/aria-sort" do
    active =
      render_component(&Samen.UI.sort_header/1, %{
        field: :display_name,
        label: "Name",
        sort: {:display_name, :asc}
      })

    assert active =~ ~s(scope="col")
    assert active =~ ~s(phx-click="sort")
    assert active =~ ~s(phx-value-field="display_name")
    assert active =~ ~s(aria-sort="ascending")
    assert active =~ "▲"

    desc =
      render_component(&Samen.UI.sort_header/1, %{
        field: :display_name,
        label: "Name",
        sort: {:display_name, :desc}
      })

    assert desc =~ ~s(aria-sort="descending")
    assert desc =~ "▼"

    inactive =
      render_component(&Samen.UI.sort_header/1, %{
        field: :job_title,
        label: "Title",
        sort: {:display_name, :asc}
      })

    refute inactive =~ "aria-sort"
    refute inactive =~ "▲"
  end

  # -- MASKING (the component-level guarantee) -----------------------------------

  test "a list_view row cell renders a %Masked{} as •••• and never leaks the token" do
    html =
      render_list(%{
        page: page([%{id: "m1", name: @masked}]),
        row: row_slot(fn item -> item.name end)
      })

    assert html =~ "••••"
    refute html =~ @token
  end

  test "list_view keys rows by id only — a masked id-adjacent value never reaches an attribute" do
    html = render_list(%{page: page([%{id: "row-77", name: @masked}]), selectable: true})

    # The row id and checkbox value come from item.id (opaque uuid), never a field value.
    assert html =~ ~s(id="list-row-row-77")
    assert html =~ ~s(phx-value-id="row-77")
    refute html =~ @token
  end
end
