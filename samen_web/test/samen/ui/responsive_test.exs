defmodule Samen.UI.ResponsiveTest do
  @moduledoc """
  WS-E E6.1 / E6.2 (ADR-030) — structural proofs for the RESPONSIVE kit pass:

    * `app_shell/1` carries the pure-CSS off-canvas drawer scaffold (hidden
      checkbox + hamburger label + scrim label) — no JS framework, no hook.
    * `data_table/1` wraps its `<table>` in a `.table-scroll` container (bounded
      horizontal scroll — the value-blind responsive variant).
    * `skeleton/1` renders abstract shimmer bars and NO data (AC-G20-1).
    * `list_view/1` renders the skeleton in its `loading` state.
    * `search_box/1` is a real GET form (icon + `⌘K` kbd + `data-cmdk` focus hook).
    * `samen_ui.css` gains ≥2 `@media` breakpoints, the drawer `:checked ~` rule,
      the `.table-scroll` variant, the `.cmdk*` palette styles, and the
      `samen-shimmer` keyframes + `.skeleton-line` (AC-G20-1).

  The masking-survival proof (a `%Masked{}` cell renders `••••` through the
  responsive markup at every width, refutably) lives in
  `Samen.Web.ResponsiveMaskingTest`.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Samen.Web.Page

  defp css, do: File.read!(Samen.UI.stylesheet_path())

  # -- app_shell drawer scaffold (E6.1) ----------------------------------------

  test "app_shell/1 renders the pure-CSS drawer scaffold (checkbox + hamburger + scrim)" do
    html =
      render_component(&Samen.UI.app_shell/1, %{
        sidebar: [%{inner_block: fn _, _ -> Phoenix.HTML.raw(~s(<aside class="side">nav</aside>)) end}],
        inner_block: [%{inner_block: fn _, _ -> Phoenix.HTML.raw("<p>main</p>") end}]
      })

    assert html =~ ~s(id="samen-nav-toggle")
    assert html =~ ~s(class="nav-toggle-cb")
    assert html =~ ~s(class="nav-hamburger")
    assert html =~ ~s(class="nav-scrim")
    # The toggle labels drive the checkbox — no phx event, no JS hook.
    assert html =~ ~s(for="samen-nav-toggle")
    refute html =~ "phx-click"
  end

  # -- data_table responsive variant (E6.1) ------------------------------------

  test "data_table/1 wraps the table in a .table-scroll container" do
    html =
      render_component(&Samen.UI.data_table/1, %{
        head: [%{inner_block: fn _, _ -> Phoenix.HTML.raw(~s(<th>Name</th>)) end}],
        inner_block: [%{inner_block: fn _, _ -> Phoenix.HTML.raw(~s(<tr><td>A</td></tr>)) end}]
      })

    assert html =~ ~s(class="card")
    assert html =~ ~s(class="table-scroll")
    assert html =~ "<table>"
    # Scroll wrapper sits BETWEEN the card and the table.
    assert html =~ ~r/class="card">\s*<div class="table-scroll">\s*<table>/
  end

  # -- skeleton primitive (E6.2) -----------------------------------------------

  test "skeleton/1 renders N shimmer rows and NO data (value-free)" do
    html = render_component(&Samen.UI.skeleton/1, %{rows: 4, avatar: true})

    assert html =~ ~s(class="skeleton")
    assert html =~ ~s(role="status")
    assert html =~ "aria-busy=\"true\""
    assert length(String.split(html, "skeleton-row")) - 1 == 4
    assert html =~ "skeleton-line avatar"
  end

  test "list_view/1 renders the skeleton in its loading state" do
    html =
      render_component(&Samen.UI.list_view/1, %{
        page: %Page{items: [%{id: "1", name: "A"}], page_size: 5},
        loading: true,
        head: [%{inner_block: fn _, _ -> Phoenix.HTML.raw(~s(<th>Name</th>)) end}],
        row: [%{inner_block: fn _, item -> item.name end}]
      })

    assert html =~ ~s(class="skeleton")
    assert html =~ "list-loading"
    # While loading, the record rows are NOT painted.
    refute html =~ "<table>"
  end

  # -- search_box (E4.3 / carry b) ---------------------------------------------

  test "search_box/1 is a real GET form with icon, ⌘K kbd, and the data-cmdk focus hook" do
    html = render_component(&Samen.UI.search_box/1, %{org_id: "ORG-9", placeholder: "Search x…"})

    assert html =~ ~s(<form class="search" method="get" action="/search" role="search">)
    assert html =~ ~s(class="search-input")
    assert html =~ "data-cmdk"
    assert html =~ "Search x…"
    assert html =~ "⌘K"
    assert html =~ ~s(<input type="hidden" name="org" value="ORG-9">)
  end

  # -- samen_ui.css responsive tokens (AC-G20-1) -------------------------------

  test "samen_ui.css ships ≥2 @media breakpoints, the drawer rule, and the table-scroll variant" do
    css = css()

    media_count = length(String.split(css, "@media")) - 1
    assert media_count >= 2, "expected ≥2 @media breakpoints, got #{media_count}"

    assert css =~ "@media (max-width: 860px)"
    assert css =~ "@media (max-width: 560px)"
    # The off-canvas drawer is driven by the checkbox :checked sibling rule.
    assert css =~ ".nav-toggle-cb:checked ~ .side"
    assert css =~ ".table-scroll"
    # The .app grid collapses to a single column at mobile width.
    assert css =~ ~r/@media \(max-width: 560px\)[^}]*\{[\s\S]*\.app\s*\{[^}]*grid-template-columns:\s*1fr/
  end

  test "samen_ui.css ships the skeleton keyframes + the ⌘K palette styles" do
    css = css()

    assert css =~ "@keyframes samen-shimmer"
    assert css =~ ".skeleton-line"
    assert css =~ ".cmdk-input"
    assert css =~ ".cmdk-results"
  end
end
