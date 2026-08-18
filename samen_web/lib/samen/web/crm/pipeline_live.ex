defmodule Samen.Web.CRM.PipelineLive do
  @moduledoc """
  Framework CRM / Pipeline page — opportunities grouped by pipeline stage (ADR-009), the
  G1 KANBAN board and the FIRST client of the generic grouped-columns kit (T51/WS-G).

  ## Framework-first (T51)

  This LiveView is THIN wiring over two framework primitives — it re-implements neither
  grouping nor board rendering:

    * READ — `Samen.Web.CRM.Reads.pipeline_board/2` builds a `%Samen.Web.Board{}` via the
      generic `Samen.Web.Reads.group_by!/3` (T50): Opportunities grouped by `:pipeline_id`
      into ORDERED, per-column-BOUNDED stage columns, org-scoped by construction.
    * RENDER — `Samen.UI.board/1` renders that `%Board{}` as columns; this module supplies
      only the CRM-specific `:card` (opportunity name/value/status/close) and the stage-type
      column header. Any other domain reuses `board/1` with its own card slot at ≈0 LOC.

  ## Read-only lens — move DEFERRED (not gold-plated)

  The pipeline is a read-only kanban LENS over opportunities: G1 (WS-A) shipped it with no
  create/mutate flow, and neither the WS-G specs nor the T51 contract call for card MOVES
  (a stage change). Move is therefore DEFERRED, not faked. When it lands it MUST go through
  the governed action path — the org-scoped Opportunity `:update` action changing
  `pipeline_id` (guarded by `OrgScope` + `Samen.Policy.SameOrgFk[:pipeline]`, which refuses a
  cross-org target stage) — NEVER a raw update. The `board/1` component already exposes the
  seam (a per-card action slot / `load_more_event`-style event), so adding move later is thin
  wiring, no framework change.

  ## Load-more (bounded, no-JS floor)

  Each stage column is capped by `group_by!/3`; a capped column shows a legible `+N more`
  (server-computed from the exact count — visible with JS off) plus a `phx-click` "Load more"
  button that reads the NEXT keyset page for THAT column
  (`Samen.Web.CRM.Reads.pipeline_stage_page/4`) and appends. Columns, cards, and counts are
  all server-rendered — the board is not JS-only.

  ## Masking

  Opportunities are NON-PII (no vault field on a card) and the group facet `:pipeline_id` is
  non-vaulted (`group_by!/3` would REFUSE a vaulted group field), so no card field masks and
  no per-plane masking proof is required for this surface. Reads still ride Ash/OrgScope.
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.CRM.Live, only: [assign_mount: 2, crm_sidebar: 1]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Web.Board
  alias Samen.Web.CRM.Reads
  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount

  @impl true
  def mount(params, session, socket) do
    socket = assign_mount(socket, session)
    org_id = CurrentOrg.resolve(socket.assigns[:samen_mount], params, session)
    {:ok, load(assign(socket, org_id: org_id), org_id)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    org_id = Samen.Web.CurrentOrg.reresolve(socket, params)
    {:noreply, load(assign(socket, org_id: org_id, return_to: return_path(uri)), org_id)}
  end

  @doc false
  def load(socket, nil) do
    socket
    |> ensure_return_to()
    |> assign(
      no_org: CurrentOrg.no_org?(socket.assigns[:samen_mount], nil),
      org_id: nil,
      board: %Board{groups: [], group_field: :pipeline_id},
      stage_meta: %{},
      total_opps: 0,
      total_value_cents: 0
    )
  end

  def load(socket, org_id) do
    mount = socket.assigns.samen_mount
    scope = Mount.scope(mount, org_id)

    %{board: board, stages: stages} = Reads.pipeline_board(mount, scope)

    socket
    |> ensure_return_to()
    |> assign(
      no_org: false,
      org_id: org_id,
      board: board,
      stage_meta: Map.new(stages, fn s -> {s.id, s} end),
      total_opps: total_opps(board),
      total_value_cents: Reads.pipeline_value_cents(mount, scope)
    )
  end

  # Load the NEXT keyset page for one stage column and append it (per-column bounded).
  @impl true
  def handle_event("board_load_more", %{"key" => key}, socket) do
    mount = socket.assigns.samen_mount
    scope = Mount.scope(mount, socket.assigns.org_id)

    board =
      case group_for(socket.assigns.board, key) do
        nil ->
          socket.assigns.board

        group ->
          page = Reads.pipeline_stage_page(mount, scope, key, group.next_cursor)
          merge_group(socket.assigns.board, group, page)
      end

    {:noreply, assign(socket, board: board, total_opps: total_opps(board))}
  end

  defp ensure_return_to(socket) do
    if Map.has_key?(socket.assigns, :return_to), do: socket, else: assign(socket, return_to: nil)
  end

  # -- board helpers -----------------------------------------------------------

  defp total_opps(%Board{groups: groups}),
    do: Enum.reduce(groups, 0, fn g, acc -> acc + (g.count || length(g.rows)) end)

  # Match the column whose key stringifies to the event's phx-value-key ("" = nil key).
  defp group_for(%Board{groups: groups}, key),
    do: Enum.find(groups, fn g -> to_string(g.key) == key end)

  # Append a loaded page's rows to a column and refresh its has_more/next_cursor.
  defp merge_group(%Board{groups: groups} = board, %Board.Group{} = group, page) do
    updated = %Board.Group{
      group
      | rows: group.rows ++ page.items,
        has_more: page.has_more,
        next_cursor: page.next_cursor
    }

    %Board{board | groups: Enum.map(groups, fn g -> if g.key == group.key, do: updated, else: g end)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="crm-pipeline">
      <.app_shell>
        <:sidebar>
          <.crm_sidebar mount={@samen_mount} org_id={@org_id} active={:crm_pipeline} return_to={@return_to} />
        </:sidebar>

        <%!-- No create CTA: the pipeline is a read-only kanban LENS over opportunities
             (no UI create/move flow — T51 defers move to the governed Opportunity :update
             action). A primary button with no phx-click is the exact decorative-CTA defect
             AC-G1-1 eliminates (gate WSA-GATE2-P2-01). --%>
        <.topbar title="Pipeline" crumbs={crumbs(@samen_mount, @org_id, "Pipeline")} />

        <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

        <%= if @no_org do %>
          <.no_org_card mount={@samen_mount} />
        <% else %>
          <span id="org-banner" style="display:none">CRM org: {@org_id}</span>

          <div class="metrics">
            <.metric label="Pipeline stages" value={length(@board.groups)}>
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <path d="M5 3v18M12 6v15M19 9v12" />
                </svg>
              </:icon>
            </.metric>
            <.metric label="Opportunities" value={@total_opps}>
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <circle cx="12" cy="12" r="9" /><path d="M12 7v5l3 2" />
                </svg>
              </:icon>
            </.metric>
            <.metric label="Pipeline value" value={dollars(@total_value_cents)} sub="all stages">
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <path d="M12 2v20M17 5H9.5a3.5 3.5 0 0 0 0 7h5a3.5 3.5 0 0 1 0 7H6" />
                </svg>
              </:icon>
            </.metric>
          </div>

          <div class="wrap">
            <%= if @board.groups == [] do %>
              <.empty_state
                class="pipeline-empty"
                icon="◇"
                title="No pipeline stages yet."
                body="Stages appear here once your pipeline has stages configured and opportunities in flight."
              />
            <% else %>
              <.board id="pipeline" board={@board} load_more_event="board_load_more" empty_col_text="No opportunities">
                <:col_header :let={group}>
                  <h3 class="bcol-t" id={"stage-#{stage_dom(group.key)}"}>{group.label}</h3>
                  <span class="bcol-n">{group.count}</span>
                  <.pill variant={stage_variant(stage_type(@stage_meta, group.key))}>
                    {stage_type(@stage_meta, group.key)}
                  </.pill>
                </:col_header>
                <:card :let={opp}>
                  <div class="opp-row" id={"opp-#{opp.id}"}>
                    <div class="opp-name">
                      <span class="mono" style="color:#454652;font-weight:500">{opp.name}</span>
                    </div>
                    <div class="opp-meta">
                      <span class="opp-value mono num">{dollars(opp.value)}</span>
                      <.pill variant={status_variant(opp.status)}>{opp.status}</.pill>
                    </div>
                    <div class="opp-close" style="color:var(--muted);font-size:12px">
                      {opp.close_date || "—"} · {(opp.value && opp.value.currency) || "USD"}
                    </div>
                  </div>
                </:card>
              </.board>
            <% end %>
          </div>
        <% end %>
      </.app_shell>
    </div>
    """
  end

  # -- helpers -----------------------------------------------------------------

  defp crumbs(mount, org_id, leaf), do: [CurrentOrg.name(mount, org_id), "CRM", leaf]

  defp stage_dom(nil), do: "none"
  defp stage_dom(key), do: key |> to_string() |> String.replace(~r/[^A-Za-z0-9_-]/, "-")

  defp stage_type(stage_meta, key) do
    case Map.get(stage_meta, key) do
      nil -> nil
      stage -> Map.get(stage, :stage_type)
    end
  end

  defp stage_variant(:open), do: "info"
  defp stage_variant(:qualified), do: "warn"
  defp stage_variant(:proposal), do: "info"
  defp stage_variant(:won), do: "ok"
  defp stage_variant(:lost), do: "bad"
  defp stage_variant(_), do: "mut"

  defp status_variant(:open), do: "info"
  defp status_variant(:won), do: "ok"
  defp status_variant(:lost), do: "bad"
  defp status_variant(:on_hold), do: "warn"
  defp status_variant(s) when is_binary(s), do: status_variant(String.to_atom(s))
  defp status_variant(_), do: "mut"

  # ADR-036 §4.5(3): opp.value is now the Money composite (dollars(opp.value)).
  defp dollars(%Money{} = money), do: dollars(Samen.Type.Money.cents(money))

  defp dollars(cents) when is_integer(cents),
    do: "$#{:erlang.float_to_binary(cents / 100, decimals: 2)}"

  defp dollars(_), do: "$0.00"
end
