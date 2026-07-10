defmodule Samen.Web.Support.TicketsLive do
  @moduledoc """
  Framework Support / Ticket Inbox — the inherited Support domain rendered as real UI,
  host-agnostic (ADR-009).

  Agent `full_name` / `email` are PII:

    * TENANT plane — CLEAR.
    * OPERATOR plane — `%Masked{}` → •••• via `Phoenix.HTML.Safe`.

  Metric cards (open tickets, breaching SLA, solved this week, CSAT avg) are non-PII
  DB aggregates. NEVER calls the vault; renders whatever the resolver returned.

  ## A3 retrofit — ListLive + sanctioned CRUD

  The inbox rides the A2 kit contract: `use Samen.Web.ListLive` + the BOUNDED
  `Reads.tickets_page/3` buys sort/filter/keyset-pagination/empty-state as kit
  defaults (no unbounded `read!`, no list `handle_event/3` of its own). The write side
  (AC-G1-1/2): "New ticket" opens a `modal/1` hosting an `AshPhoenix.Form`-backed
  `simple_form/1` create (`subject` is required — the inline-error path is real); each
  row carries a `delete_confirm/1` (FAIL-HONEST: a ticket with linked conversations is
  refused by the DB FK and the refusal is surfaced). Write affordances are offered on
  the tenant plane only (`Samen.Web.Support.Live.writable?/1`); enforcement stays in
  the kernel (OrgScope + RoleAtLeast(:member) on every ticket write).
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.Support.Live, only: [assign_mount: 2, support_sidebar: 1, writable?: 1]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount

  alias Samen.Web.Support.Reads

  use Samen.Web.ListLive,
    resource: Ticket,
    reads: &Samen.Web.Support.Reads.tickets_page/3,
    sortable: [:subject, :status, :priority],
    filter_fields: [:subject],
    default_sort: {:subject, :asc}

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
    |> assign(no_org: CurrentOrg.no_org?(socket.assigns[:samen_mount], nil), org_id: nil, agents_by_id: %{}, metrics: nil)
    |> assign(page: %Samen.Web.Page{}, list_state: %Samen.Web.ListState{})
    |> assign(show_new: false, new_form: nil)
    |> assign_new(:delete_error, fn -> nil end)
  end

  def load(socket, org_id) do
    mount = socket.assigns.samen_mount
    scope = Mount.scope(mount, org_id)

    socket
    |> ensure_return_to()
    |> assign(
      no_org: false,
      org_id: org_id,
      agents_by_id: Reads.agents_by_id(mount, scope),
      metrics: Reads.metrics(mount, scope)
    )
    |> assign_new(:show_new, fn -> false end)
    |> assign_new(:delete_error, fn -> nil end)
    |> assign(new_form: new_ticket_form(mount, scope))
    |> init_list(mount, scope)
  end

  # -- A3 CRUD events (list events belong to the ListLive hook) -----------------

  @impl true
  def handle_event("new_ticket", _params, socket) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns
    scope = Mount.scope(mount, org_id)
    {:noreply, assign(socket, show_new: true, new_form: new_ticket_form(mount, scope))}
  end

  def handle_event("cancel_new", _params, socket) do
    {:noreply, assign(socket, show_new: false)}
  end

  def handle_event("validate_new", %{"form" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.new_form, with_org(params, socket))
    {:noreply, assign(socket, new_form: form)}
  end

  # `org_id` is the server-side fact, never client input. The ticket header is
  # non-PII; the kernel's OrgScope + RoleAtLeast(:member) gate the write — no
  # LiveView policy.
  def handle_event("save_new", %{"form" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.new_form, params: with_org(params, socket)) do
      {:ok, _ticket} ->
        {:noreply, socket |> assign(show_new: false) |> load(socket.assigns.org_id)}

      {:error, form} ->
        {:noreply, assign(socket, new_form: form)}
    end
  end

  # FAIL-HONEST delete: the kernel defines no cascade — a ticket with linked
  # conversations is refused by the DB (FK) and the refusal is SURFACED.
  def handle_event("delete", %{"id" => id}, socket) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns
    scope = Mount.scope(mount, org_id)

    case Reads.delete_ticket(mount, scope, id) do
      :ok ->
        {:noreply, load(assign(socket, delete_error: nil), org_id)}

      {:error, _reason} ->
        {:noreply,
         assign(socket,
           delete_error: "Could not delete this ticket — it still has linked records (conversations)."
         )}
    end
  end

  defp new_ticket_form(mount, scope) do
    Mount.resource(mount, Ticket)
    |> AshPhoenix.Form.for_create(:create, scope: scope)
    |> to_form()
  end

  defp with_org(params, socket), do: Map.put(params, "org_id", socket.assigns.org_id)

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
            <.button :if={writable?(@samen_mount) and not @no_org} variant="primary" phx-click="new_ticket" id="new-ticket">
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

          <div :if={@delete_error} class="wrap" style="margin-bottom:0">
            <div class="card form-error" id="delete-error" style="padding:10px 14px;color:var(--bad, #b91c1c);font-size:12px">
              {@delete_error}
            </div>
          </div>

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
            <.metric label="CSAT avg" value={csat_display(@metrics && @metrics.csat_avg)} sub="/ 5">
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
                <span class="n">{length(@page.items)}</span>
                <span class="lane">· agent PII via PiiResolution · {plane_note(@samen_mount)}</span>
              </div>
              <.list_view
                id="tickets-list"
                page={@page}
                state={@list_state}
                row_class="ticket-row"
                filter_placeholder="Filter tickets…"
                empty_text="No tickets yet."
              >
                <:head>
                  <.sort_header field={:subject} label="Subject" sort={@list_state.sort} width="30%" />
                  <.sort_header field={:status} label="Status" sort={@list_state.sort} width="12%" />
                  <.sort_header field={:priority} label="Priority" sort={@list_state.sort} width="12%" />
                  <th scope="col" style="width:20%">SLA</th>
                  <th scope="col" style="width:16%">Assignee</th>
                  <th :if={writable?(@samen_mount)} scope="col" style="width:10%"><span class="sr-only">Actions</span></th>
                </:head>
                <:row :let={ticket}>
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
                  <td :if={writable?(@samen_mount)} class="tk-actions">
                    <.delete_confirm phx-click="delete" phx-value-id={ticket.id} />
                  </td>
                </:row>
              </.list_view>
            </div>
          </div>

          <.modal :if={@show_new and @new_form != nil and writable?(@samen_mount)} id="new-ticket-modal" title="New ticket" on_cancel="cancel_new">
            <.simple_form :let={f} for={@new_form} id="new-ticket-form" phx-change="validate_new" phx-submit="save_new">
              <.form_field field={f[:subject]} label="Subject" />
              <.form_field
                field={f[:priority]}
                label="Priority"
                type="select"
                options={[{"low", "low"}, {"normal", "normal"}, {"high", "high"}, {"urgent", "urgent"}]}
              />
              <:actions>
                <.button variant="primary" type="submit">Save ticket</.button>
                <.button type="button" phx-click="cancel_new">Cancel</.button>
              </:actions>
            </.simple_form>
          </.modal>
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
