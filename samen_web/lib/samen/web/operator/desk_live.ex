defmodule Samen.Web.Operator.DeskLive do
  @moduledoc """
  Framework OPERATOR / Desk page (ADR-010 §4c) — the SaaS company's OWN help desk. Each row is a
  ticket a TENANT filed WITH the SaaS: the requester is a tenant-org admin (`Identity.User`, PII
  CLEAR — the SaaS's own customer), with SLA/priority and the handling SaaS support agent.

  Reads the operator org's OWN `Support` rows on the TENANT plane — both parties (the tenant-admin
  requester and the SaaS agent) are the SaaS's own, so their PII is CLEAR by the own-org resolver
  branch. The tenant's DOWNSTREAM support (its end-customers' message bodies) is the impersonation
  path, NOT read here. NEVER unwraps a `%Masked{}`; NO plaintext branch.
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.Operator.Live

  alias Samen.Web.Operator
  alias Samen.Web.Operator.Reads

  @impl true
  def mount(_params, session, socket) do
    socket = assign_mount(socket, session)
    {:ok, load(socket)}
  end

  @doc false
  def load(socket) do
    mount = socket.assigns[:samen_mount]
    operator_org_id = mount && Operator.org_id(mount)

    case operator_org_id do
      nil ->
        assign(socket, no_org: true, tickets: [])

      _org_id ->
        scope = Operator.scope(mount)
        assign(socket, no_org: false, tickets: Reads.desk(mount, scope))
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="operator-desk">
      <.app_shell>
        <:sidebar>
          <.operator_sidebar mount={@samen_mount} active={:desk} />
        </:sidebar>

        <.topbar title="Desk" crumbs={["Operator plane", "Desk"]} />

        <%= if @no_org do %>
          <div class="wrap">
            <div class="card" id="no-org" style="padding:22px 20px;color:var(--muted)">
              No operator org resolved.
            </div>
          </div>
        <% else %>
          <div class="metrics">
            <.metric label="Open tickets" value={open_count(@tickets)} sub="filed by tenants">
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z" />
                </svg>
              </:icon>
            </.metric>
            <.metric label="Breaching SLA" value={breach_count(@tickets)} sub="past the deadline">
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <circle cx="12" cy="12" r="9" /><path d="M12 7v5l3 2" />
                </svg>
              </:icon>
            </.metric>
            <.metric label="Urgent / high" value={high_count(@tickets)} sub="priority">
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <path d="M12 9v4M12 17h.01M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z" />
                </svg>
              </:icon>
            </.metric>
          </div>

          <div class="wrap">
            <div id="desk-tickets">
              <div class="gtitle">
                <h3>Tickets filed with us</h3>
                <span class="n">{length(@tickets)}</span>
                <span class="lane">· requester = a tenant-admin (in the clear) · assigned to SaaS staff</span>
              </div>
              <.data_table>
                <:head>
                  <th style="width:30%">Subject</th>
                  <th style="width:22%">Requester (tenant-admin)</th>
                  <th style="width:20%">Assignee (SaaS staff)</th>
                  <th style="width:12%">Priority</th>
                  <th style="width:16%">SLA / status</th>
                </:head>
                <tr :for={t <- @tickets} class="desk-ticket-row" id={"desk-ticket-#{t.id}"}>
                  <td class="t-subject" style="font-weight:500;color:#3a3b45">{t.subject}</td>
                  <td class="t-requester" style="color:#3a3b45">
                    {requester_name(t.__requester__)}
                    <span :if={requester_email(t.__requester__) != "—"} class="t-requester-email" style="display:block;font-size:11px;color:var(--muted)">
                      {requester_email(t.__requester__)}
                    </span>
                  </td>
                  <td class="t-agent" style="color:var(--muted)">{agent_name(t.__agent__)}</td>
                  <td class="t-priority">
                    <.pill variant={priority_variant(t.priority)}>{t.priority}</.pill>
                  </td>
                  <td class="t-sla">
                    <.pill :if={t.breached} variant="bad">SLA breached</.pill>
                    <.pill :if={not t.breached} variant={status_variant(t.status)}>{t.status}</.pill>
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

  # -- helpers -----------------------------------------------------------------

  defp open_count(tickets), do: Enum.count(tickets, &(&1.status in [:open, :pending]))
  defp breach_count(tickets), do: Enum.count(tickets, & &1.breached)
  defp high_count(tickets), do: Enum.count(tickets, &(&1.priority in [:urgent, :high]))

  defp requester_name(nil), do: "—"
  defp requester_name(%{full_name: name}), do: render_name(name)
  defp requester_name(_), do: "—"

  defp requester_email(nil), do: "—"
  defp requester_email(%{emails: emails}), do: render_email(emails)
  defp requester_email(_), do: "—"

  defp agent_name(nil), do: "unassigned"
  defp agent_name(%{full_name: name}), do: render_name(name)
  defp agent_name(_), do: "unassigned"

  defp priority_variant(:urgent), do: "bad"
  defp priority_variant(:high), do: "warn"
  defp priority_variant(:normal), do: "info"
  defp priority_variant(_), do: "mut"

  defp status_variant(:open), do: "warn"
  defp status_variant(:pending), do: "info"
  defp status_variant(:resolved), do: "ok"
  defp status_variant(:closed), do: "mut"
  defp status_variant(_), do: "mut"
end
