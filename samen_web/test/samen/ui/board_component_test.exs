defmodule Samen.UI.BoardComponentTest do
  @moduledoc """
  Unit proofs for the GENERIC grouped-columns board (`Samen.UI.board/1`, T51/WS-G) — the
  reusable renderer the CRM Pipeline (and later calendar/gallery/tree) consume. These test
  the FRAMEWORK component in isolation from any vertical, against a hand-built
  `%Samen.Web.Board{}`:

    * COLUMNS + CARDS + COUNTS — one column per group, header label + exact count, the
      `:card` slot renders each row (the card-renderer parameterization).
    * NO-JS FLOOR — a capped column shows a legible `+N more` text server-side, and the
      `phx-click` "Load more" button is an ENHANCEMENT layered on top (present only when
      `:load_more_event` is set), never the sole affordance.
    * CUSTOM HEADER — the `:col_header` slot overrides the default header.
    * EMPTY COLUMN — a zero-row column renders its placeholder, not a card.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Samen.Web.Board

  defp card_slot do
    [%{inner_block: fn _changed, row -> Phoenix.HTML.raw(~s(<b class="nm">#{row.name}</b>)) end}]
  end

  defp sample_board do
    %Board{
      group_field: :stage,
      per_group_limit: 2,
      max_groups: 50,
      groups: [
        %Board.Group{
          key: :open,
          label: "Open",
          rows: [%{id: 1, name: "Alpha"}, %{id: 2, name: "Bravo"}],
          count: 5,
          has_more: true,
          next_cursor: {2}
        },
        %Board.Group{key: :won, label: "Won", rows: [%{id: 3, name: "Gamma"}], count: 1, has_more: false},
        %Board.Group{key: nil, label: "Uncategorized", rows: [], count: 0, has_more: false}
      ]
    }
  end

  test "renders one column per group with label + exact count, cards via the :card slot" do
    html =
      render_component(&Samen.UI.board/1, %{
        id: "b",
        board: sample_board(),
        load_more_event: "lm",
        card: card_slot()
      })

    # Three columns, each keyed off the board id + a key slug.
    assert html =~ ~s(id="b-col-open")
    assert html =~ ~s(id="b-col-won")
    assert html =~ ~s(id="b-col-none")

    # Header labels + exact counts (from the group, not from length(rows)).
    assert html =~ "Open"
    assert html =~ "Won"
    assert html =~ ~s(class="bcol-n">5<)
    assert html =~ ~s(class="bcol-n">1<)

    # Cards rendered by the caller's :card slot (the renderer parameterization).
    assert html =~ "Alpha"
    assert html =~ "Bravo"
    assert html =~ "Gamma"
  end

  test "NO-JS FLOOR: a capped column shows +N more text AND a phx-click load-more button" do
    html =
      render_component(&Samen.UI.board/1, %{
        id: "b",
        board: sample_board(),
        load_more_event: "board_load_more",
        card: card_slot()
      })

    # Server-computed remaining count (5 total − 2 loaded), legible with JS OFF.
    assert html =~ "+3 more"
    # The enhancement: a phx-click button carrying the column key.
    assert html =~ ~s(phx-click="board_load_more")
    assert html =~ ~s(phx-value-key="open")

    # The un-capped column (Won) shows NEITHER a "+N more" nor a load-more button.
    refute html =~ "+0 more"
    refute html =~ ~s(phx-value-key="won")
  end

  test "read-only board (no :load_more_event) shows +N more text but NO button" do
    html =
      render_component(&Samen.UI.board/1, %{
        id: "b",
        board: sample_board(),
        card: card_slot()
      })

    # The count is still legible …
    assert html =~ "+3 more"
    # … but there is no phx-click affordance at all (a purely read-only lens).
    refute html =~ "phx-click"
  end

  test "CUSTOM HEADER: the :col_header slot overrides the default label+count header" do
    html =
      render_component(&Samen.UI.board/1, %{
        id: "b",
        board: sample_board(),
        card: card_slot(),
        col_header: [
          %{inner_block: fn _changed, group -> Phoenix.HTML.raw(~s(<em class="ch">#{group.label}!</em>)) end}
        ]
      })

    assert html =~ ~s(<em class="ch">Open!</em>)
    # The default header markup is NOT emitted when a custom header is supplied.
    refute html =~ ~s(class="bcol-t">Open<)
  end

  test "EMPTY COLUMN: a zero-row column renders the placeholder, not a card" do
    html =
      render_component(&Samen.UI.board/1, %{
        id: "b",
        board: sample_board(),
        empty_col_text: "No items",
        card: card_slot()
      })

    assert html =~ "No items"
  end

  test "the kit CSS carries the board classes (bounded horizontal scroll, no-JS legibility)" do
    css = File.read!(Samen.UI.stylesheet_path())

    assert css =~ ".board {"
    assert css =~ ".bcol {"
    assert css =~ ".bcard {"
    assert css =~ ".bcol-more"
    # Bounded horizontal scroll (value-blind responsive, like .table-scroll).
    assert css =~ "overflow-x: auto"
  end
end
