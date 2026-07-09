defmodule Samen.Web.Support.TicketLive do
  @moduledoc """
  Framework Support / Ticket Detail — conversation thread + ticket metadata, host-agnostic
  (ADR-009).

  Reads the host's Support `Ticket` / `Conversation` / `Message` / `Agent` via
  `Samen.Web.Support.Reads`. PII surface:

    * `Agent.full_name` (composite vault), `Agent.email` (scalar vault) — shown per message
      and in the Details tab.
    * `Message.body` (scalar vault) — the message thread body.

  All plane-resolved by `Samen.Api.PiiResolution` (tenant CLEAR / operator ••••). This
  LiveView NEVER calls the vault or unwraps a `%Masked{}`; it renders whatever the resolver
  returned.
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
    ticket_id = Map.get(params, "id")

    {:ok, load(assign(socket, org_id: org_id, ticket_id: ticket_id, active_tab: "conversation", return_to: nil), org_id, ticket_id)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    org_id = Map.get(params, "org") || socket.assigns.org_id
    ticket_id = Map.get(params, "id") || socket.assigns.ticket_id
    tab = Map.get(params, "tab") || "conversation"

    {:noreply, load(assign(socket, org_id: org_id, ticket_id: ticket_id, active_tab: tab, return_to: return_path(uri)), org_id, ticket_id)}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, active_tab: tab)}
  end

  @doc false
  def load(socket, nil, _ticket_id) do
    current_tab = Map.get(socket.assigns, :active_tab, "conversation")

    socket
    |> ensure_return_to()
    |> assign(no_org: CurrentOrg.no_org?(socket.assigns[:samen_mount], nil), org_id: nil, ticket: nil, conversations: [], agents: [], active_tab: current_tab)
  end

  def load(socket, org_id, ticket_id) do
    mount = socket.assigns.samen_mount
    scope = Mount.scope(mount, org_id)

    {ticket, conversations, agents} =
      if ticket_id do
        t =
          case Reads.get_ticket(mount, scope, ticket_id) do
            {:ok, tk} -> tk
            :error -> nil
          end

        convs = if t, do: Reads.conversations_for_ticket(mount, scope, ticket_id), else: []
        ags = Reads.agents(mount, scope)
        {t, convs, ags}
      else
        {nil, [], []}
      end

    current_tab = Map.get(socket.assigns, :active_tab, "conversation")

    socket
    |> ensure_return_to()
    |> assign(
      no_org: false,
      org_id: org_id,
      ticket: ticket,
      conversations: conversations,
      agents: agents,
      active_tab: current_tab
    )
  end

  defp ensure_return_to(socket) do
    if Map.has_key?(socket.assigns, :return_to), do: socket, else: assign(socket, return_to: nil)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="support-ticket">
      <.app_shell>
        <:sidebar>
          <.support_sidebar mount={@samen_mount} org_id={@org_id} active={:support_tickets} return_to={@return_to} />
        </:sidebar>

        <.topbar title={ticket_subject(@ticket)} crumbs={crumbs(@samen_mount, @org_id, ticket_subject(@ticket))}>
          <:actions>
            <.button>
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <path d="M19 12H5M12 5l-7 7 7 7" />
                </svg>
              </:icon>
              Back to inbox
            </.button>
          </:actions>
        </.topbar>

        <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

        <%= if @no_org do %>
          <.no_org_card mount={@samen_mount} />
        <% else %>
          <span id="org-banner" style="display:none">Support org: {@org_id}</span>

          <%= if @ticket == nil do %>
            <div class="wrap">
              <div class="card" style="padding:22px 20px;color:var(--muted)">Ticket not found.</div>
            </div>
          <% else %>
            <div class="wrap" style="margin-bottom:0">
              <div class="card" id="ticket-header" style="padding:18px 20px;display:flex;align-items:center;gap:12px;flex-wrap:wrap">
                <div style="flex:1;min-width:0">
                  <div style="font-size:11px;color:var(--muted);margin-bottom:4px">Ticket</div>
                  <div class="tk-subject-title" style="font-weight:600;font-size:15px;color:#2a2b35">
                    {@ticket.subject}
                  </div>
                </div>
                <div style="display:flex;gap:8px;align-items:center;flex-wrap:wrap">
                  <.pill variant={status_variant(@ticket.status)}>{status_label(@ticket.status)}</.pill>
                  <.pill variant={priority_variant(@ticket.priority)}>{priority_label(@ticket.priority)}</.pill>
                  {sla_badge(@ticket)}
                </div>
              </div>
            </div>

            <div class="wrap" style="margin-bottom:0;padding-top:0">
              <.tabs>
                <.tab label="Conversation" href={"?org=#{@org_id}&tab=conversation"} active={@active_tab == "conversation"} />
                <.tab label="Details" href={"?org=#{@org_id}&tab=details"} active={@active_tab == "details"} />
              </.tabs>
            </div>

            <%= if @active_tab == "conversation" do %>
              <div class="wrap" id="conversation-pane">
                <%= if @conversations == [] do %>
                  <div class="card" style="padding:22px 20px;color:var(--muted)">No conversation thread yet.</div>
                <% else %>
                  <%= for conv <- @conversations do %>
                    <div class="card" id={"conv-#{conv.id}"} style="margin-bottom:12px">
                      <div style="padding:14px 18px 10px;border-bottom:1px solid var(--border);font-size:11px;color:var(--muted)">
                        Channel: {channel_label(conv.channel)} &nbsp;·&nbsp; Status: {conv.status}
                      </div>
                      <%= if conv.__messages__ == [] do %>
                        <div style="padding:18px 20px;color:var(--muted)">No messages yet.</div>
                      <% else %>
                        <div style="padding:0 20px">
                          <%= for msg <- conv.__messages__ do %>
                            <div class="msg-row" id={"msg-#{msg.id}"} style={"padding:14px 0;border-bottom:1px solid var(--border);#{msg == List.last(conv.__messages__) && "border-bottom:none" || ""}"}>
                              <div style="display:flex;align-items:flex-start;gap:10px">
                                <div class="av" style={"width:30px;height:30px;border-radius:50%;font-size:11px;font-weight:700;display:flex;align-items:center;justify-content:center;flex-shrink:0;background:#{sender_bg(msg.sender_type)};color:#{sender_fg(msg.sender_type)}"}>
                                  {msg_avatar(msg)}
                                </div>
                                <div style="flex:1;min-width:0">
                                  <div style="display:flex;align-items:center;gap:8px;margin-bottom:6px">
                                    <span class="msg-sender" style="font-weight:600;font-size:13px;color:#2a2b35">
                                      {render_sender(msg)}
                                    </span>
                                    <span style="font-size:11px;color:var(--muted)">{sender_type_label(msg.sender_type)}</span>
                                    <span style="font-size:11px;color:var(--muted);margin-left:auto">{message_type_label(msg.message_type)}</span>
                                  </div>
                                  <div class="msg-body" style="font-size:13px;color:#3a3b45;line-height:1.6;white-space:pre-wrap;word-break:break-word">
                                    {render_body(msg.body)}
                                  </div>
                                </div>
                              </div>
                            </div>
                          <% end %>
                        </div>
                      <% end %>
                    </div>
                  <% end %>
                <% end %>
              </div>
            <% else %>
              <div class="wrap" id="details-pane">
                <div class="card" style="padding:20px">
                  <div class="gtitle" style="margin-bottom:16px"><h3>Ticket details</h3></div>
                  <table style="width:100%;font-size:13px;border-collapse:collapse">
                    <tr style="border-bottom:1px solid var(--border)">
                      <td style="padding:10px 0;color:var(--muted);width:160px">Status</td>
                      <td style="padding:10px 0"><.pill variant={status_variant(@ticket.status)}>{status_label(@ticket.status)}</.pill></td>
                    </tr>
                    <tr style="border-bottom:1px solid var(--border)">
                      <td style="padding:10px 0;color:var(--muted)">Priority</td>
                      <td style="padding:10px 0"><.pill variant={priority_variant(@ticket.priority)}>{priority_label(@ticket.priority)}</.pill></td>
                    </tr>
                    <tr style="border-bottom:1px solid var(--border)">
                      <td style="padding:10px 0;color:var(--muted)">SLA deadline</td>
                      <td style="padding:10px 0;font-size:12px;color:var(--muted)">{format_dt(@ticket.sla_breach_at)}</td>
                    </tr>
                    <tr style="border-bottom:1px solid var(--border)">
                      <td style="padding:10px 0;color:var(--muted)">Breached</td>
                      <td style="padding:10px 0">{if @ticket.breached, do: "Yes", else: "No"}</td>
                    </tr>
                    <tr style="border-bottom:1px solid var(--border)">
                      <td style="padding:10px 0;color:var(--muted)">Resolved at</td>
                      <td style="padding:10px 0;font-size:12px;color:var(--muted)">{format_dt(@ticket.resolved_at)}</td>
                    </tr>
                    <tr style="border-bottom:1px solid var(--border)">
                      <td style="padding:10px 0;color:var(--muted)">Tags</td>
                      <td style="padding:10px 0;font-size:12px;color:var(--muted)">{tags_label(@ticket.tags)}</td>
                    </tr>
                  </table>

                  <%= if @agents != [] do %>
                    <div class="gtitle" style="margin:20px 0 12px"><h3>Agents <small style="font-weight:400;color:var(--muted)">(PII resolved per plane)</small></h3></div>
                    <.data_table>
                      <:head>
                        <th>Handle</th>
                        <th>Name (🔒 PII)</th>
                        <th>Email (🔒 PII)</th>
                        <th>Role</th>
                        <th>Status</th>
                      </:head>
                      <tr :for={agent <- @agents} class="agent-row" id={"agent-#{agent.id}"}>
                        <td class="ag-handle" style="font-weight:500">{agent.handle}</td>
                        <td class="ag-name" style="font-size:12px;color:var(--muted)">{render_agent_name(agent.full_name)}</td>
                        <td class="ag-email" style="font-size:12px;color:var(--muted)">{render_agent_email(agent.email)}</td>
                        <td class="ag-role" style="font-size:12px;color:var(--muted)">{agent.role}</td>
                        <td class="ag-status"><.pill variant={agent_status_variant(agent.status)}>{agent.status}</.pill></td>
                      </tr>
                    </.data_table>
                  <% end %>
                </div>
              </div>
            <% end %>
          <% end %>
        <% end %>
      </.app_shell>
    </div>
    """
  end

  # -- helpers (MASKING INVARIANT) -------------------------------------------

  defp crumbs(mount, org_id, leaf), do: [CurrentOrg.name(mount, org_id), "Support", "Inbox", leaf]

  defp ticket_subject(nil), do: "Ticket"
  defp ticket_subject(%{subject: s}), do: s

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

  defp agent_status_variant(:active), do: "ok"
  defp agent_status_variant(:inactive), do: "mut"
  defp agent_status_variant(:suspended), do: "bad"
  defp agent_status_variant(_), do: "mut"

  defp sla_badge(%{breached: true}) do
    Phoenix.HTML.raw(~s(<span class="pill bad"><span class="d"></span>SLA breached</span>))
  end

  defp sla_badge(%{sla_breach_at: %DateTime{} = dt, status: status})
       when status not in [:resolved, :closed] do
    now = DateTime.utc_now()

    case DateTime.diff(dt, now, :second) do
      secs when secs < 0 ->
        Phoenix.HTML.raw(~s(<span class="pill bad"><span class="d"></span>SLA breached</span>))

      secs when secs < 3600 ->
        mins = div(secs, 60)
        Phoenix.HTML.raw(~s(<span class="pill warn"><span class="d"></span>#{mins}m left</span>))

      _ ->
        Phoenix.HTML.raw("")
    end
  end

  defp sla_badge(_), do: Phoenix.HTML.raw("")

  defp channel_label(:email), do: "Email"
  defp channel_label(:chat), do: "Chat"
  defp channel_label(:api), do: "API"
  defp channel_label(:internal), do: "Internal"
  defp channel_label(other), do: to_string(other)

  defp sender_type_label(:customer), do: "customer"
  defp sender_type_label(:agent), do: "agent"
  defp sender_type_label(:system), do: "system"
  defp sender_type_label(other), do: to_string(other)

  defp message_type_label(:reply), do: "reply"
  defp message_type_label(:note), do: "note"
  defp message_type_label(:escalation), do: "escalation"
  defp message_type_label(:resolution), do: "resolution"
  defp message_type_label(other), do: to_string(other)

  defp sender_bg(:customer), do: "#DDE7F5"
  defp sender_bg(:agent), do: "#D1FAE5"
  defp sender_bg(:system), do: "#F3F4F6"
  defp sender_bg(_), do: "#F3F4F6"

  defp sender_fg(:customer), do: "#3B4CCA"
  defp sender_fg(:agent), do: "#065F46"
  defp sender_fg(:system), do: "#6B7280"
  defp sender_fg(_), do: "#6B7280"

  defp msg_avatar(%{sender_type: :agent, __agent__: %{handle: handle}}) when is_binary(handle) do
    handle |> String.upcase() |> String.slice(0, 2)
  end

  defp msg_avatar(%{sender_type: :customer}), do: "CX"
  defp msg_avatar(%{sender_type: :system}), do: "SY"
  defp msg_avatar(_), do: "??"

  defp render_sender(%{sender_type: :agent, __agent__: %{full_name: full_name, handle: handle}}) do
    case full_name do
      %Samen.Masked{} = m -> m
      name when is_binary(name) -> decode_full_name(name) || handle
      nil -> handle || "Agent"
      _ -> handle || "Agent"
    end
  end

  defp render_sender(%{sender_type: :agent}), do: "Agent"
  defp render_sender(%{sender_type: :customer}), do: "Customer"
  defp render_sender(%{sender_type: :system}), do: "System"
  defp render_sender(_), do: "Unknown"

  defp render_body(%Samen.Masked{} = m), do: m
  defp render_body(body) when is_binary(body), do: body
  defp render_body(nil), do: "—"
  defp render_body(_), do: "—"

  defp render_agent_name(%Samen.Masked{} = m), do: m
  defp render_agent_name(name) when is_binary(name), do: decode_full_name(name) || name
  defp render_agent_name(nil), do: "—"
  defp render_agent_name(_), do: "—"

  defp render_agent_email(%Samen.Masked{} = m), do: m
  defp render_agent_email(email) when is_binary(email), do: email
  defp render_agent_email(nil), do: "—"
  defp render_agent_email(_), do: "—"

  defp decode_full_name(name) when is_binary(name) do
    case Jason.decode(name) do
      {:ok, %{"first" => first, "last" => last}} -> String.trim("#{first} #{last}")
      _ -> name
    end
  end

  defp format_dt(nil), do: "—"

  defp format_dt(%DateTime{} = dt),
    do: "#{dt.year}-#{pad(dt.month)}-#{pad(dt.day)} #{pad(dt.hour)}:#{pad(dt.minute)} UTC"

  defp format_dt(_), do: "—"

  defp pad(n), do: String.pad_leading(to_string(n), 2, "0")

  defp tags_label([]), do: "—"
  defp tags_label(tags) when is_list(tags), do: Enum.join(tags, ", ")
  defp tags_label(_), do: "—"
end
