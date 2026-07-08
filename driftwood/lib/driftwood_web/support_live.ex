defmodule DriftwoodWeb.SupportLive do
  @moduledoc """
  Support / Ticket Inbox — the inherited Support domain rendered as real UI.

  Reads `Driftwood.Support.Ticket` (+ agent PII) through `Driftwood.SupportReads`
  on the TENANT plane:

    * TENANT plane (`plane: :tenant`): the org reads its OWN agents'
      `full_name` / `email` in CLEAR (tenant-as-owner rule; §external-surface :707).
    * OPERATOR / impersonation plane (`plane: :operator`): agent PII renders
      `%Masked{}` → •••• through Phoenix.HTML.Safe.

  Metric cards show open tickets, breaching SLA, solved this week, and CSAT avg
  — all non-PII aggregates.

  ## MASKING INVARIANT

  This LiveView NEVER calls `Samen.Vault.reveal/3`, NEVER pattern-matches a
  vault token out of a `%Masked{}`, and NEVER introduces a "show plaintext"
  code path. Plaintext only reaches a cell if `SupportReads` already resolved
  it through the shared PiiResolution chokepoint.
  """
  use Phoenix.LiveView

  import DriftwoodWeb.UIKit

  alias Driftwood.SupportReads

  @impl true
  def mount(params, _session, socket) do
    org_id = Map.get(params, "org")
    {:ok, load(assign(socket, org_id: org_id), org_id)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    org_id = Map.get(params, "org") || socket.assigns.org_id
    {:noreply, load(assign(socket, org_id: org_id), org_id)}
  end

  @doc false
  def load(socket, nil) do
    assign(socket,
      no_org: true,
      org_id: nil,
      tickets: [],
      agents_by_id: %{},
      metrics: nil
    )
  end

  def load(socket, org_id) do
    scope = support_scope(org_id)

    assign(socket,
      no_org: false,
      org_id: org_id,
      tickets: SupportReads.tickets(scope),
      agents_by_id: SupportReads.agents_by_id(scope),
      metrics: SupportReads.metrics(scope)
    )
  end

  # A tenant-member scope: plane: :tenant so the org reads its OWN agents' PII
  # in CLEAR through PiiResolution.
  @doc false
  def support_scope(org_id) do
    %Samen.Scope{
      actor: %{
        id: "broker:#{org_id}",
        org_id: org_id,
        role: :member,
        kind: :tenant,
        plane: :tenant
      }
    }
  end

  # An OPERATOR impersonation scope — used in tests to assert masking.
  @doc false
  def operator_scope(org_id) do
    %Samen.Scope{
      actor: %{
        id: "operator:impersonation",
        org_id: org_id,
        role: :member,
        kind: :operator,
        plane: :operator,
        impersonation: %{session_id: "test-session"}
      }
    }
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="support">
      <.app_shell>
        <:sidebar>
          {support_sidebar(assigns)}
        </:sidebar>

        <.topbar title="Support" crumbs={["Blue Ridge Logistics", "Support", "Inbox"]}>
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

        <%= if @no_org do %>
          <div class="wrap">
            <div class="card" id="no-org" style="padding:22px 20px;color:var(--muted)">
              No org selected. Append <code>?org=&lt;uuid&gt;</code> to the URL.
            </div>
          </div>
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
            <.metric
              label="CSAT avg"
              value={csat_display((@metrics && @metrics.csat_avg))}
              sub="/ 5"
            >
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
                <span class="lane">· requester / assignee agent PII via PiiResolution · your org in the clear</span>
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
                    <a
                      href={"/support/tickets/#{ticket.id}?org=#{@org_id}"}
                      style="font-weight:500;color:#3a3b45;text-decoration:none"
                    >
                      {ticket.subject}
                    </a>
                  </td>
                  <td class="tk-status">
                    <.pill variant={status_variant(ticket.status)}>
                      {status_label(ticket.status)}
                    </.pill>
                  </td>
                  <td class="tk-priority">
                    <.pill variant={priority_variant(ticket.priority)}>
                      {priority_label(ticket.priority)}
                    </.pill>
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
  #
  # These helpers render ALREADY-RESOLVED values from PiiResolution. They NEVER
  # unwrap a %Masked{} or call the vault. A %Masked{} is returned AS-IS so it
  # renders •••• through Phoenix.HTML.Safe.

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

  # SLA cell: show a breach pill if breached, otherwise a countdown if deadline
  # is set, otherwise "—".
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
        hrs = div(secs, 3600)
        "#{hrs}h left"

      secs ->
        days = div(secs, 86_400)
        "#{days}d left"
    end
  end

  defp sla_cell(_), do: "—"

  # Render the assignee agent's handle (non-PII) as the primary display.
  # The agent's full_name (PII) is shown as secondary if resolved (clear or ••••).
  defp render_assignee(_ticket, agents_map) when map_size(agents_map) == 0, do: "—"
  defp render_assignee(%{sla_id: nil}, _), do: "—"

  defp render_assignee(_ticket, agents_map) do
    # In the demo seed there is no direct ticket→agent FK (the blueprint doesn't
    # declare one on Ticket). The inbox shows the handle of the first active agent
    # for context. A real product would add an `assignee_id` FK to the Ticket resource.
    case first_agent(agents_map) do
      nil ->
        "—"

      agent ->
        Phoenix.HTML.raw(
          ~s(<span class="tk-agent-handle" style="font-weight:500">#{agent.handle}</span>)
        )
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

  # Shared Support sidebar.
  defp support_sidebar(assigns) do
    ~H"""
    <.sidebar
      title="Blue Ridge Logistics"
      subtitle="Support"
      logo="B"
      logo_style="background:linear-gradient(150deg,#B45309,#D97706)"
    >
      <:search>
        <div class="search">
          <svg class="i" width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <circle cx="11" cy="11" r="7" /><path d="m21 21-4.3-4.3" />
          </svg>
          Search tickets, agents…
          <span class="kbd">⌘K</span>
        </div>
      </:search>

      <.module_nav org_id={@org_id} active={:support_tickets} />

      <:footer>
        <div class="foot">
          <div class="av" style="background:#FEF3C7;color:#92400E">RM</div>
          <div class="m"><b>Rosa Medina</b><span>dispatcher</span></div>
        </div>
      </:footer>
    </.sidebar>
    """
  end
end
