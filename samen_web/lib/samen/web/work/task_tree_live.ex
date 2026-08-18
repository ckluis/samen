defmodule Samen.Web.Work.TaskTreeLive do
  @moduledoc """
  Framework Work / Tree page — Tasks rendered as a hierarchical parent/child TREE over the
  self-referential `Task.:parent_id`, the G6 TREE view and the FIRST client of the generic
  `Samen.Web.Reads.tree!/3` (T54/WS-G) rendered through `Samen.UI.tree/1`.

  ## Framework-first (T54)

  This LiveView is THIN wiring over two framework primitives — it re-implements neither the
  depth-bounded/cycle-safe/per-parent-bounded hierarchy walk nor the nested render:

    * READ — `Samen.Web.Work.Reads.tasks_tree/4` builds a `%Samen.Web.Tree{}` via `tree!/3`: the
      Task hierarchy walked from the TRUE roots (or a `?focus=` drill-in node), org-scoped AT
      EVERY LEVEL by construction (unconditional OrgScope — the T50 boundary), depth-bounded,
      cycle-safe, per-parent-bounded.
    * RENDER — `Samen.UI.tree/1` lays that `%Tree{}` out as nested expandable nodes; this module
      supplies only the Work-specific `:node` (task title/status) and the drill-in nav params.
      Any other self-referential domain reuses `tree/1` with its own node slot at ≈0 LOC.

  ## No-JS drill-in floor (ADR-042/T113)

  A `truncated` node (children not loaded — hit the depth cap or node budget) exposes a real
  `?focus=<id>` link on this same route that RE-ROOTS the walk at that node via ordinary GET, so
  a JS-off client descends deeper without any JS. Loaded subtrees collapse/expand via native
  `<details>`. A hostile/garbage `?focus=` is a bounded uuid string — an unresolvable id simply
  yields an empty subtree, never a crash.

  ## Masking

  Tasks are NON-PII (no vault field on a node) and the structural key `:parent_id` is non-vaulted
  (`tree!/3` would REFUSE a vaulted parent field via `Samen.Web.Reads.MaskedGroupKeyError`), so no
  node field masks and no per-plane masking proof is required for this surface. Reads still ride
  Ash/OrgScope.
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.Work.Live, only: [assign_mount: 2, work_sidebar: 1]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount
  alias Samen.Web.Tree
  alias Samen.Web.Work.Reads

  @impl true
  def mount(params, session, socket) do
    socket = assign_mount(socket, session)
    org_id = CurrentOrg.resolve(socket.assigns[:samen_mount], params, session)
    focus = parse_focus(Map.get(params, "focus"))
    {:ok, load(assign(socket, org_id: org_id, focus: focus), org_id)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    org_id = Samen.Web.CurrentOrg.reresolve(socket, params)
    focus = parse_focus(Map.get(params, "focus"))
    {:noreply, load(assign(socket, org_id: org_id, focus: focus, return_to: return_path(uri)), org_id)}
  end

  @doc false
  def load(socket, org_id, focus \\ nil)

  def load(socket, nil, _focus) do
    socket
    |> ensure_return_to()
    |> assign(
      no_org: CurrentOrg.no_org?(socket.assigns[:samen_mount], nil),
      org_id: nil,
      focus: nil,
      tree: %Tree{roots: [], parent_field: :parent_id},
      total_nodes: 0
    )
    |> assign_nav(nil)
  end

  def load(socket, org_id, focus) do
    mount = socket.assigns.samen_mount
    scope = Mount.scope(mount, org_id)
    focus = focus || socket.assigns[:focus]

    %{tree: tree} = Reads.tasks_tree(mount, scope, focus)

    socket
    |> ensure_return_to()
    |> assign(
      no_org: false,
      org_id: org_id,
      focus: focus,
      tree: tree,
      total_nodes: tree.node_count
    )
    |> assign_nav(org_id)
  end

  defp ensure_return_to(socket) do
    if Map.has_key?(socket.assigns, :return_to), do: socket, else: assign(socket, return_to: nil)
  end

  # The expand-link query prefix (keeps `?org=` on the drill-in link) + the "back to roots"
  # link — both real GETs, the no-JS floor.
  defp assign_nav(socket, org_id) do
    prefix = if org_id, do: "org=#{org_id}&", else: ""

    assign(socket,
      expand_prefix: prefix,
      roots_href: if(org_id, do: "?org=#{org_id}", else: "?")
    )
  end

  # `?focus=` is a bounded uuid string; a non-uuid is ignored (walk the roots), never trusted.
  defp parse_focus(value) when is_binary(value) do
    case Ecto.UUID.cast(String.trim(value)) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp parse_focus(_), do: nil

  @impl true
  def render(assigns) do
    ~H"""
    <div id="work-tree">
      <.app_shell>
        <:sidebar>
          <.work_sidebar mount={@samen_mount} org_id={@org_id} active={:work_tree} return_to={@return_to} />
        </:sidebar>

        <.topbar title="Tree" crumbs={crumbs(@samen_mount, @org_id, "Tree")} />

        <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

        <%= if @no_org do %>
          <.no_org_card mount={@samen_mount} />
        <% else %>
          <span id="org-banner" style="display:none">Work org: {@org_id}</span>

          <div class="metrics">
            <.metric label="Tasks in view" value={@total_nodes} sub="hierarchical, depth-bounded">
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <path d="M5 4v6a2 2 0 002 2h4M5 12v4a2 2 0 002 2h4" />
                </svg>
              </:icon>
            </.metric>
          </div>

          <div class="wrap">
            <p :if={@focus} class="tree-focus-note">
              Viewing a sub-tree. <a href={@roots_href} rel="nofollow" class="tree-drill">↑ back to all tasks</a>
            </p>

            <.tree
              id="work-tree-view"
              tree={@tree}
              label="Task hierarchy"
              empty_text="No tasks"
              expand_param="focus"
              expand_prefix={@expand_prefix}
            >
              <:node :let={node}>
                <span class="mono tree-task-name" id={"tree-task-#{node.id}"}>{node.record.title || "(untitled)"}</span>
                <.pill variant={status_variant(node.record.status)}>{status_label(node.record.status)}</.pill>
              </:node>
            </.tree>
          </div>
        <% end %>
      </.app_shell>
    </div>
    """
  end

  defp crumbs(mount, org_id, leaf), do: [CurrentOrg.name(mount, org_id), "Work", leaf]

  defp status_variant(:pending), do: "mut"
  defp status_variant(:in_progress), do: "info"
  defp status_variant(:completed), do: "ok"
  defp status_variant(:cancelled), do: "bad"
  defp status_variant(_), do: "mut"

  defp status_label(:pending), do: "pending"
  defp status_label(:in_progress), do: "in progress"
  defp status_label(:completed), do: "completed"
  defp status_label(:cancelled), do: "cancelled"
  defp status_label(other), do: to_string(other)
end
