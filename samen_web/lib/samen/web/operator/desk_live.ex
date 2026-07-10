defmodule Samen.Web.Operator.DeskLive do
  @moduledoc """
  Framework OPERATOR / Desk page (ADR-010 §4c) — the SaaS company's OWN help desk. Each row is a
  ticket a TENANT filed WITH the SaaS: the requester is a tenant-org admin (`Identity.User`, PII
  CLEAR — the SaaS's own customer), with SLA/priority and the handling SaaS support agent.

  Reads the operator org's OWN `Support` rows on the TENANT plane — both parties (the tenant-admin
  requester and the SaaS agent) are the SaaS's own, so their PII is CLEAR by the own-org resolver
  branch. The tenant's DOWNSTREAM support (its end-customers' message bodies) is the impersonation
  path, NOT read here. NEVER unwraps a `%Masked{}`; NO plaintext branch.

  ## A3 retrofit — ListLive + sanctioned CRUD

  The desk rides the A2 kit contract: `use Samen.Web.ListLive` + the BOUNDED
  `Reads.desk_page/3` buys sort/filter/keyset-pagination/empty-state as kit defaults (no
  unbounded `read!`, no list `handle_event/3` of its own); header metrics are DB
  aggregates (`Reads.desk_metrics/2`). The write side (AC-G1-1/2) exposes ONLY the
  support blueprint's domain actions: "New ticket" opens a `modal/1` hosting an
  `AshPhoenix.Form`-backed `simple_form/1` create (`subject` required — the inline-error
  path is real; the ticket header is non-PII), and each row carries a `delete_confirm/1`
  (FAIL-HONEST: a ticket with linked conversations is refused by the DB FK and the
  refusal is surfaced). Write affordances are offered on the operator workspace's tenant
  plane only (`Samen.Web.Operator.Live.writable?/1`); enforcement stays in the kernel
  (OrgScope + `RoleAtLeast(:member)` on every ticket write).
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.Operator.Live

  alias Samen.Web.Mount
  alias Samen.Web.Operator
  alias Samen.Web.Operator.Reads

  use Samen.Web.ListLive,
    resource: Ticket,
    reads: &Samen.Web.Operator.Reads.desk_page/3,
    sortable: [:subject, :status, :priority],
    filter_fields: [:subject],
    default_sort: {:subject, :asc}

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
        socket
        |> assign(no_org: true, operator_org_id: nil, metrics: nil)
        |> assign(page: %Samen.Web.Page{}, list_state: %Samen.Web.ListState{})
        |> assign(show_new: false, new_form: nil)
        |> assign_new(:delete_error, fn -> nil end)

      org_id ->
        scope = Operator.scope(mount)

        socket
        |> assign(
          no_org: false,
          operator_org_id: org_id,
          metrics: Reads.desk_metrics(mount, scope)
        )
        |> assign_new(:show_new, fn -> false end)
        |> assign_new(:delete_error, fn -> nil end)
        |> assign(new_form: new_ticket_form(mount, scope))
        |> init_list(mount, scope)
    end
  end

  # -- A3 CRUD events (list events belong to the ListLive hook) -----------------

  @impl true
  def handle_event("new_ticket", _params, socket) do
    mount = socket.assigns.samen_mount
    {:noreply, assign(socket, show_new: true, new_form: new_ticket_form(mount, Operator.scope(mount)))}
  end

  def handle_event("cancel_new", _params, socket) do
    {:noreply, assign(socket, show_new: false)}
  end

  def handle_event("validate_new", %{"form" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.new_form, with_org(params, socket))
    {:noreply, assign(socket, new_form: form)}
  end

  # The desk ticket create. `org_id` (the operator org — this is the SaaS's own desk) is
  # the server-side fact, never client input. The ticket header is non-PII; the kernel's
  # OrgScope + RoleAtLeast(:member) gate the write — no LiveView policy.
  def handle_event("save_new", %{"form" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.new_form, params: with_org(params, socket)) do
      {:ok, _ticket} ->
        {:noreply, socket |> assign(show_new: false) |> load()}

      {:error, form} ->
        {:noreply, assign(socket, new_form: form)}
    end
  end

  # FAIL-HONEST delete: the kernel defines no cascade — a ticket with linked
  # conversations is refused by the DB (FK) and the refusal is SURFACED.
  def handle_event("delete", %{"id" => id}, socket) do
    mount = socket.assigns.samen_mount
    scope = Operator.scope(mount)

    case Reads.delete_ticket(mount, scope, id) do
      :ok ->
        {:noreply, load(assign(socket, delete_error: nil))}

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

  defp with_org(params, socket), do: Map.put(params, "org_id", socket.assigns.operator_org_id)

  @impl true
  def render(assigns) do
    ~H"""
    <div id="operator-desk">
      <.app_shell>
        <:sidebar>
          <.operator_sidebar mount={@samen_mount} active={:desk} />
        </:sidebar>

        <.topbar title="Desk" crumbs={["Operator plane", "Desk"]}>
          <:actions>
            <.button :if={writable?(@samen_mount) and not @no_org} variant="primary" phx-click="new_ticket" id="new-desk-ticket">
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
              No operator org resolved.
            </div>
          </div>
        <% else %>
          <div :if={@delete_error} class="wrap" style="margin-bottom:0">
            <div class="card form-error" id="delete-error" style="padding:10px 14px;color:var(--bad, #b91c1c);font-size:12px">
              {@delete_error}
            </div>
          </div>

          <div class="metrics">
            <.metric label="Open tickets" value={(@metrics && @metrics.open) || 0} sub="filed by tenants">
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z" />
                </svg>
              </:icon>
            </.metric>
            <.metric label="Breaching SLA" value={(@metrics && @metrics.breaching) || 0} sub="past the deadline">
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <circle cx="12" cy="12" r="9" /><path d="M12 7v5l3 2" />
                </svg>
              </:icon>
            </.metric>
            <.metric label="Urgent / high" value={(@metrics && @metrics.high) || 0} sub="priority">
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
                <span class="n">{length(@page.items)}</span>
                <span class="lane">· requester = a tenant-admin (in the clear) · assigned to SaaS staff</span>
              </div>
              <.list_view
                id="desk-list"
                page={@page}
                state={@list_state}
                row_class="desk-ticket-row"
                filter_placeholder="Filter tickets…"
                empty_text="No tickets yet."
              >
                <:head>
                  <.sort_header field={:subject} label="Subject" sort={@list_state.sort} width="28%" />
                  <th scope="col" style="width:20%">Requester (tenant-admin)</th>
                  <th scope="col" style="width:18%">Assignee (SaaS staff)</th>
                  <.sort_header field={:priority} label="Priority" sort={@list_state.sort} width="12%" />
                  <.sort_header field={:status} label="SLA / status" sort={@list_state.sort} width="14%" />
                  <th :if={writable?(@samen_mount)} scope="col" style="width:8%"><span class="sr-only">Actions</span></th>
                </:head>
                <:row :let={t}>
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
                  <td :if={writable?(@samen_mount)} class="t-actions">
                    <.delete_confirm phx-click="delete" phx-value-id={t.id} />
                  </td>
                </:row>
              </.list_view>
            </div>
          </div>

          <.modal :if={@show_new and @new_form != nil and writable?(@samen_mount)} id="new-desk-ticket-modal" title="New ticket" on_cancel="cancel_new">
            <.simple_form :let={f} for={@new_form} id="new-desk-ticket-form" phx-change="validate_new" phx-submit="save_new">
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

  # -- helpers (MASKING INVARIANT: render resolved values, never unwrap) --------

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
