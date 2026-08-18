defmodule Samen.UI.Tree do
  @moduledoc """
  The GENERIC hierarchical tree view — the framework renderer for a `%Samen.Web.Tree{}` (the
  value `Samen.Web.Reads.tree!/3` returns): a FOREST of expandable parent/child nodes rendered as
  nested `<ul>`/`<details>`. The hierarchical sibling of `Samen.UI.board/1` (columns) and
  `Samen.UI.gallery/1` (a flat grid). It is framework-level and holds NO vertical logic — it is
  parameterized by the NODE RENDERER (the required `:node` slot, `:let={node}`), so the Work Task
  tree (G6, first client), an org chart, or any self-referential resource reuses it at ≈0 authored
  LOC. The vertical part (which resource, which node fields) is thin wiring in the calling LiveView
  (`Samen.Web.Work.TaskTreeLive`).

  ## Masking posture (dumb renderer, same as the rest of the kit)

  The tree never inspects, coerces, or stringifies a node's field value: each node body is
  whatever the `:node` slot renders from `node.record`, which the CALLER already plane-resolved
  through `Samen.Api.PiiResolution`. A `%Samen.Masked{}` field renders `••••` through the shared
  `Phoenix.HTML.Safe` impl — the tree has no "show plaintext" branch. Nodes are keyed by `id` only
  (a non-PII opaque uuid); the STRUCTURAL parent key never reaches this component
  (`tree!/3` REFUSES a vault-routed parent field, so the hierarchy is never secret-driven).

  ## No-JS floor (progressive enhancement, ADR-042/T113)

  Every LOADED node is present in the server-rendered DOM — the tree is NOT JS-only. A node with
  loaded children renders as a native `<details open>` whose `<summary>` is the node row, so
  collapse/expand of the ALREADY-LOADED subtree works with JS off. A `truncated` node (its
  children were NOT loaded — `:depth`/`:budget`) renders a real `<a href>` DRILL-IN link
  (`?<expand_param>=<id>`) that RE-ROOTS the walk at that node by ordinary GET, so a JS-off client
  descends deeper without any JS. A `:cycle` node renders an inert marker (bad data — nothing to
  expand into). The optional `:expand_event` phx-click is layered on top, never a replacement.
  """
  use Phoenix.Component

  @doc """
  Render a `%Samen.Web.Tree{}` as nested expandable nodes.

    * `:tree` (required) — a `%Samen.Web.Tree{}` (`Samen.Web.Reads.tree!/3` output).
    * `:id` — the DOM id of the tree container (default `"tree"`).
    * `:label` — an `aria-label` for the tree region.
    * `:empty_text` — text when the tree has zero roots (default `"—"`).
    * `:expand_param` — the query-param name a drill-in link sets to a node id (default
      `"focus"`), i.e. a truncated node links to `?<prefix><expand_param>=<id>`.
    * `:expand_prefix` — extra query string prefixed before the expand param (e.g. `"org=123&"`);
      default `""`.
    * `:expand_event` — optional `phx-click` event for a drill-in (carries `phx-value-id`); the
      `<a href>` drill-in remains the no-JS floor regardless.
    * `:node` (required slot, `:let={node}`) — renders ONE node's body from `node.record`.
  """
  attr :id, :string, default: "tree"
  attr :tree, :any, required: true, doc: "a %Samen.Web.Tree{}"
  attr :label, :string, default: nil
  attr :empty_text, :string, default: "—"
  attr :expand_param, :string, default: "focus"
  attr :expand_prefix, :string, default: ""
  attr :expand_event, :string, default: nil
  slot :node, required: true, doc: "renders one node's body from node.record (:let={node})"

  def tree(assigns) do
    ~H"""
    <div id={@id} class="tree" role="tree" aria-label={@label}>
      <.branch
        nodes={@tree.roots}
        node_slot={@node}
        id={@id}
        expand_param={@expand_param}
        expand_prefix={@expand_prefix}
        expand_event={@expand_event}
      />
      <p :if={@tree.roots == []} class="tree-empty">{@empty_text}</p>
    </div>
    """
  end

  # Recursive level renderer — renders a list of sibling nodes, calling itself for each node's
  # loaded children. Slots/state ride as plain assigns so the recursion carries them down.
  attr :nodes, :list, required: true
  attr :node_slot, :any, required: true
  attr :id, :string, required: true
  attr :expand_param, :string, required: true
  attr :expand_prefix, :string, required: true
  attr :expand_event, :string, default: nil

  defp branch(assigns) do
    ~H"""
    <ul class="tree-lvl" role="group">
      <li
        :for={node <- @nodes}
        class="tree-node"
        role="treeitem"
        id={"#{@id}-node-#{node.id}"}
        aria-expanded={aria_expanded(node)}
      >
        <%= if node.children != [] do %>
          <details open class="tree-det">
            <summary class="tree-row">
              <span class="tree-twist" aria-hidden="true"></span>
              <div class="tree-label">{render_slot(@node_slot, node)}</div>
            </summary>
            <.branch
              nodes={node.children}
              node_slot={@node_slot}
              id={@id}
              expand_param={@expand_param}
              expand_prefix={@expand_prefix}
              expand_event={@expand_event}
            />
            <p :if={node.has_more_children} class="tree-more">
              +{remaining(node)} more
              <a
                href={expand_href(@expand_prefix, @expand_param, node.id)}
                class="tree-drill"
                rel="nofollow"
                phx-click={@expand_event}
                phx-value-id={node.id}
              >
                view all
              </a>
            </p>
          </details>
        <% else %>
          <div class={["tree-row", "tree-leaf", node.truncated == :cycle && "tree-cyc"]}>
            <span class="tree-twist tree-twist-leaf" aria-hidden="true"></span>
            <div class="tree-label">{render_slot(@node_slot, node)}</div>
            <%= cond do %>
              <% node.truncated == :cycle -> %>
                <span class="tree-cycle" title="cycle detected — hierarchy stopped here">↻ cycle</span>
              <% node.expandable? -> %>
                <a
                  href={expand_href(@expand_prefix, @expand_param, node.id)}
                  class="tree-drill"
                  rel="nofollow"
                  phx-click={@expand_event}
                  phx-value-id={node.id}
                  aria-label="Expand this branch"
                >
                  ▸ expand
                </a>
              <% true -> %>
            <% end %>
          </div>
        <% end %>
      </li>
    </ul>
    """
  end

  # An accurate "+N more" from the exact child_count (survives JS off); falls back to "some".
  defp remaining(%{child_count: count, children: children}) when is_integer(count),
    do: max(count - length(children), 0)

  defp remaining(_), do: "some"

  # The no-JS drill-in URL: `?<prefix><param>=<id>` on the same route (re-roots the walk).
  defp expand_href(prefix, param, id), do: "?#{prefix}#{param}=#{id}"

  defp aria_expanded(%{children: [_ | _]}), do: "true"
  defp aria_expanded(%{expandable?: true}), do: "false"
  defp aria_expanded(_), do: nil
end
