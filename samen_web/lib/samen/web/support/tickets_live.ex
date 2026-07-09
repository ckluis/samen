defmodule Samen.Web.Support.TicketsLive do
  @moduledoc """
  Framework Support / Ticket Inbox — the inherited Support domain rendered as real UI,
  host-agnostic (ADR-009).

  Reads the host's `<namespace>.Ticket` (+ agent PII) via `Samen.Web.Support.Reads`. Agent
  `full_name` / `email` are PII:

    * TENANT plane — CLEAR.
    * OPERATOR plane — `%Masked{}` → •••• via `Phoenix.HTML.Safe`.

  Metric cards (open tickets, breaching SLA, solved this week, CSAT avg) are non-PII.
  NEVER calls the vault; renders whatever the resolver returned.
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.Support.Live, only: [assign_mount: 2, support_sidebar: 1]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount

  alias Samen.Web.Support.Reads

  @impl true
  def mount(params, session, socket) do
    socket = assign_mount(socket, session)
    org_id = CurrentOrg.resolve(socket.assigns[:samen_mount], params, session)
    {:ok, load(assign(socket, org_id: org_id), org_id)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    org_id = Map.get(params, "org") || socket.assigns.org_id
    {:noreply, load(assign(socket, org_id: org_id, return_to: return_path(uri)), org_id)}
  end

  @doc false
  def load(socket, nil) do
    socket
    |> ensure_return_to()
    |> assign(no_org: CurrentOrg.no_org?(socket.assigns[:samen_mount], nil), org_id: nil, tickets: [], agents_by_id: %{}, metrics: nil)
  end

  def load(socket, org_id) do
    mount = socket.assigns.samen_mount
    scope = Mount.scope(mount, org_id)

    socket
    |> ensure_return_to()
    |> assign(
      no_org: false,
      org_id: org_id,
      tickets: Reads.tickets(mount, scope),
      agents_by_id: Reads.agents_by_id(mount, scope),
      metrics: Reads.metrics(mount, scope)
    )
  end

  defp ensure_return_to(socket) do
    if Map.has_key?(socket.assigns, :return_to), do: socket, else: assign(socket, return_to: nil)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="support">
      <.app_shell>
        <:sidebar>
          <.support_sidebar mount={@samen_mount} org_id={@org_id} active={:support_tickets} return_to={@return_to} />
        </:sidebar>

        <.topbar title="Support" crumbs={crumbs(@samen_mount, @org_id, "Inbox")}>
          <:actions>
            <.button variant="primary">
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <path d="M12 3v18M3 12h18" />
                </svg>
              </:icon>
              New ticket
            </.button>
          </:actions>
        </.topbar>

        <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

        <%= if @no_org do %>
          <.no_org_card mount={@samen_mount} />
        <% else %>
          <span id="org-banner" style="display:none">Support org: {@org_id}</span>

          <div class="metrics">
            <.metric label="Open tickets" value={(@metrics && @metrics.open_tickets) || 0}>
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z" />
                </svg>
              </:icon>
            </.metric>
            <.metric label="Breaching SLA" value={(@metrics && @metrics.breaching_sla) || 0}>
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <circle cx="12" cy="12" r="9" /><path d="M12 7v5l3 3" />
                </svg>
              </:icon>
            </.metric>
            <.metric label="Solved this week" value={(@metrics && @metrics.solved_this_week) || 0}>
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <path d="M9 12l2 2 4-4" /><circle cx="12" cy="12" r="9" />
                </svg>
              </:icon>
            </.metric>
            <.metric label="CSAT avg" value={csat_display((@metrics && @metrics.csat_avg))} sub="/ 5">
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <path d="M12 2l3.09 6.26L22 9.27l-5 4.87 1.18 6.88L12 17.77l-6.18 3.25L7 14.14 2 9.27l6.91-1.01L12 2z" />
                </svg>
              </:icon>
            </.metric>
          </div>

          <div class="wrap">
            <div id="tickets">
              <div class="gtitle">
                <h3>Ticket Inbox</h3>
                <span class="n">{length(@tickets)}</span>
                <span class="lane">· agent PII via PiiResolution · {plane_note(@samen_mount)}</span>
              </div>
              <.data_table>
                <:head>
                  <th style="width:32%">Subject</th>
                  <th style="width:14%">Status</th>
                  <th style="width:12%">Priority</th>
                  <th style="width:22%">SLA</th>
                  <th style="width:20%">Assignee</th>
                </:head>
                <tr :for={ticket <- @tickets} class="ticket-row" id={"ticket-#{ticket.id}"}>
                  <td class="tk-subject">
                    <a href={"#{support_path(@samen_mount)}/tickets/#{ticket.id}?org=#{@org_id}"} style="font-weight:500;color:#3a3b45;text-decoration:none">
                      {ticket.subject}
                    </a>
                  </td>
                  <td class="tk-status">
                    <.pill variant={status_variant(ticket.status)}>{status_label(ticket.status)}</.pill>
                  </td>
                  <td class="tk-priority">
                    <.pill variant={priority_variant(ticket.priority)}>{priority_label(ticket.priority)}</.pill>
                  </td>
                  <td class="tk-sla" style="font-size:12px;color:var(--muted)">
                    {sla_cell(ticket)}
                  </td>
                  <td class="tk-assignee" style="font-size:12px;color:var(--muted)">
                    {render_assignee(ticket, @agents_by_id)}
                  </td>
                </tr>
              </.data_table>
            </div>
          </div>
        <% end %>
      </.app_shell>
    </div>
    """
  end

  # -- helpers (MASKING INVARIANT) -------------------------------------------

  defp crumbs(mount, org_id, leaf), do: [CurrentOrg.name(mount, org_id), "Support", leaf]

  defp plane_note(%Mount{plane: %{kind: :operator}}), do: "operator plane · masked"
  defp plane_note(_), do: "your org in the clear"

  defp support_path(mount), do: Mount.label(mount, :support_path, "/support")

  defp status_variant(:open), do: "info"
  defp status_variant(:pending), do: "warn"
  defp status_variant(:on_hold), do: "mut"
  defp status_variant(:resolved), do: "ok"
  defp status_variant(:closed), do: "ok"
  defp status_variant(_), do: "mut"

  defp status_label(:open), do: "open"
  defp status_label(:pending), do: "pending"
  defp status_label(:on_hold), do: "on hold"
  defp status_label(:resolved), do: "resolved"
  defp status_label(:closed), do: "closed"
  defp status_label(other), do: to_string(other)

  defp priority_variant(:low), do: "mut"
  defp priority_variant(:normal), do: "info"
  defp priority_variant(:high), do: "warn"
  defp priority_variant(:urgent), do: "bad"
  defp priority_variant(_), do: "mut"

  defp priority_label(:low), do: "low"
  defp priority_label(:normal), do: "normal"
  defp priority_label(:high), do: "high"
  defp priority_label(:urgent), do: "urgent"
  defp priority_label(other), do: to_string(other)

  defp sla_cell(%{breached: true}) do
    Phoenix.HTML.raw(~s(<span class="pill bad"><span class="d"></span>SLA breached</span>))
  end

  defp sla_cell(%{sla_breach_at: %DateTime{} = dt, status: status})
       when status not in [:resolved, :closed] do
    now = DateTime.utc_now()

    case DateTime.diff(dt, now, :second) do
      secs when secs < 0 ->
        Phoenix.HTML.raw(~s(<span class="pill bad"><span class="d"></span>SLA breached</span>))

      secs when secs < 3600 ->
        mins = div(secs, 60)
        Phoenix.HTML.raw(~s(<span class="pill warn"><span class="d"></span>#{mins}m left</span>))

      secs when secs < 86_400 ->
        "#{div(secs, 3600)}h left"

      secs ->
        "#{div(secs, 86_400)}d left"
    end
  end

  defp sla_cell(_), do: "—"

  defp render_assignee(_ticket, agents_map) when map_size(agents_map) == 0, do: "—"

  defp render_assignee(_ticket, agents_map) do
    case first_agent(agents_map) do
      nil ->
        "—"

      agent ->
        Phoenix.HTML.raw(~s(<span class="tk-agent-handle" style="font-weight:500">#{agent.handle}</span>))
    end
  end

  defp first_agent(agents_map) do
    agents_map
    |> Map.values()
    |> Enum.find(fn a -> a.status == :active end)
    |> then(fn
      nil -> Map.values(agents_map) |> List.first()
      a -> a
    end)
  end

  defp csat_display(nil), do: "—"
  defp csat_display(avg) when is_float(avg), do: Float.to_string(avg)
  defp csat_display(avg), do: to_string(avg)
end
