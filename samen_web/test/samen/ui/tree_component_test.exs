defmodule Samen.UI.TreeComponentTest do
  @moduledoc """
  Unit proofs for the GENERIC tree renderer (`Samen.UI.tree/1`, T54/WS-G) — the reusable renderer
  the Work Task tree (and any self-referential resource) consumes. These test the FRAMEWORK
  component in isolation from any vertical, against a hand-built `%Samen.Web.Tree{}`:

    * NEST — nodes render as nested `<ul>`/`<details>`; a node's body comes through the `:node`
      slot; every loaded node is in the server-rendered DOM (no-JS).
    * NO-JS EXPAND — a loaded subtree is a native `<details open>` (collapses with JS off); a
      `truncated` (:depth/:budget) node exposes a real `?focus=<id>` drill-in link (the no-JS
      floor), carrying the `expand_prefix`.
    * +N MORE — a capped node shows a server-computed "+N more" from the exact `child_count`.
    * CYCLE — a `:cycle` node renders an inert marker, NOT a drill-in link.
    * MASKING — a dumb renderer: a `%Samen.Masked{}` in a node's record renders `••••` through
      `Phoenix.HTML.Safe`; the component has no "show plaintext" branch.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Samen.Web.Tree

  defp node_slot do
    [%{inner_block: fn _changed, node -> Phoenix.HTML.raw(~s(<b class="nm">#{node.record.title}</b>)) end}]
  end

  defp n(id, title, extra) do
    Map.merge(%Tree.Node{id: id, record: %{id: id, title: title}, depth: 0}, extra)
  end

  defp sample_tree do
    %Tree{
      parent_field: :parent_id,
      sibling_limit: 3,
      max_depth: 8,
      max_nodes: 500,
      node_count: 5,
      roots: [
        n("r1", "ROOT-ONE", %{
          expandable?: true,
          has_more_children: true,
          child_count: 5,
          children: [
            n("c1", "CHILD-ONE", %{depth: 1}),
            n("c2", "CHILD-TWO", %{depth: 1})
          ]
        }),
        n("r2", "ROOT-DEEP", %{depth: 0, expandable?: true, truncated: :depth}),
        n("r3", "ROOT-CYCLE", %{depth: 0, truncated: :cycle})
      ]
    }
  end

  defp render(assigns) do
    render_component(
      &Samen.UI.tree/1,
      Map.merge(
        %{id: "t", tree: sample_tree(), node: node_slot(), expand_prefix: "org=OrgX&"},
        assigns
      )
    )
  end

  test "NEST: nodes render nested, node bodies come through the :node slot, all in the DOM" do
    html = render(%{})

    assert html =~ ~s(id="t-node-r1")
    assert html =~ ~s(id="t-node-c1")
    assert html =~ "ROOT-ONE"
    assert html =~ "CHILD-ONE"
    assert html =~ "CHILD-TWO"
    # A loaded subtree is a native <details open> (no-JS collapse).
    assert html =~ "<details open"
    # Nested <ul> group for the children.
    assert html =~ ~s(class="tree-lvl")
  end

  test "NO-JS EXPAND: a truncated node exposes a real ?focus=<id> drill-in link with the prefix" do
    html = render(%{})

    # The :depth-truncated root offers a drill-in GET link carrying the expand prefix
    # (the `&` is HTML-escaped in the attribute).
    assert html =~ ~s(href="?org=OrgX&amp;focus=r2")
    assert html =~ "▸ expand"
  end

  test "+N MORE: a capped node shows a server-computed '+N more' from the exact child_count" do
    html = render(%{})
    # 5 total − 2 loaded = 3 remaining, present in the no-JS DOM.
    assert html =~ "+3 more"
    # …and a "view all" drill-in for the rest.
    assert html =~ ~s(href="?org=OrgX&amp;focus=r1")
  end

  test "CYCLE: a :cycle node renders an inert marker, not a drill-in link" do
    html = render(%{})

    assert html =~ "↻ cycle"
    # The cycle node must NOT offer an expand link (it is bad data, nothing below it).
    refute html =~ ~s(focus=r3)
  end

  test "EMPTY: a tree with no roots renders the empty text" do
    html = render(%{tree: %Tree{roots: []}, empty_text: "No nodes"})
    assert html =~ "No nodes"
    assert html =~ "tree-empty"
  end

  test "MASKING: a %Samen.Masked{} in a node record renders ••••, never plaintext, via HTML.Safe" do
    masked = %Samen.Masked{token: "vt_secret_777", label: :secret}

    tree = %Tree{
      roots: [
        %Tree.Node{
          id: "m1",
          depth: 0,
          record: %{id: "m1", secret: masked}
        }
      ]
    }

    slot = [%{inner_block: fn _c, node -> node.record.secret end}]

    html = render_component(&Samen.UI.tree/1, %{id: "t", tree: tree, node: slot})

    assert html =~ "••••"
    refute html =~ "vt_"
  end
end
