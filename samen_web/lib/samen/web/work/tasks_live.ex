defmodule Samen.Web.Work.TasksLive do
  @moduledoc """
  Framework Work / Task Inbox — the inherited Work domain rendered as real UI,
  host-agnostic (ADR-009), mirroring `Samen.Web.Support.TicketsLive`'s shape.

  No PII (INV-1) — `title` is freeform authored content, unvaulted, and never
  resolved through `PiiResolution`.

  ## ListLive + sanctioned CRUD

  The inbox rides the A2 kit contract: `use Samen.Web.ListLive` + the BOUNDED
  `Reads.tasks_page/3` buys sort/filter/keyset-pagination/empty-state as kit
  defaults. The write side: "New task" opens a `modal/1` hosting an
  `AshPhoenix.Form`-backed `simple_form/1` create; each row carries a
  `delete_confirm/1` (=archive, ADR-040 §5.9 — never a hard delete via this
  surface). Write affordances are offered on the tenant plane only.
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.Work.Live, only: [assign_mount: 2, work_sidebar: 1, work_path: 1, writable?: 1]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount

  alias Samen.Web.Work.Reads

  use Samen.Web.ListLive,
    resource: Task,
    reads: &Samen.Web.Work.Reads.tasks_page/3,
    sortable: [:title, :status, :priority, :due_at],
    filter_fields: [:title],
    default_sort: {:title, :asc}

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
    |> assign(no_org: CurrentOrg.no_org?(socket.assigns[:samen_mount], nil), org_id: nil)
    |> assign(page: %Samen.Web.Page{}, list_state: %Samen.Web.ListState{})
    |> assign(show_new: false, new_form: nil)
    |> assign_new(:delete_error, fn -> nil end)
  end

  def load(socket, org_id) do
    mount = socket.assigns.samen_mount
    scope = Mount.scope(mount, org_id)

    socket
    |> ensure_return_to()
    |> assign(no_org: false, org_id: org_id)
    |> assign_new(:show_new, fn -> false end)
    |> assign_new(:delete_error, fn -> nil end)
    |> assign(new_form: new_task_form(mount, scope))
    |> init_list(mount, scope)
  end

  # -- A3 CRUD events (list events belong to the ListLive hook) -----------------

  @impl true
  def handle_event("new_task", _params, socket) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns
    scope = Mount.scope(mount, org_id)
    {:noreply, assign(socket, show_new: true, new_form: new_task_form(mount, scope))}
  end

  def handle_event("cancel_new", _params, socket) do
    {:noreply, assign(socket, show_new: false)}
  end

  def handle_event("validate_new", %{"form" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.new_form, with_org(params, socket))
    {:noreply, assign(socket, new_form: form)}
  end

  def handle_event("save_new", %{"form" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.new_form, params: with_org(params, socket)) do
      {:ok, _task} ->
        {:noreply, socket |> assign(show_new: false) |> load(socket.assigns.org_id)}

      {:error, form} ->
        {:noreply, assign(socket, new_form: form)}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns

    case Reads.delete_task(mount, Mount.scope(mount, org_id), id) do
      :ok ->
        {:noreply, load(assign(socket, delete_error: nil), org_id)}

      {:error, _reason} ->
        {:noreply, assign(socket, delete_error: "Could not archive this task.")}
    end
  end

  defp new_task_form(mount, scope) do
    Mount.resource(mount, Task)
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
    <div id="work">
      <.app_shell>
        <:sidebar>
          <.work_sidebar mount={@samen_mount} org_id={@org_id} active={:work_tasks} return_to={@return_to} />
        </:sidebar>

        <.topbar title="Work" crumbs={crumbs(@samen_mount, @org_id, "Tasks")}>
          <:actions>
            <.button :if={writable?(@samen_mount) and not @no_org} variant="primary" phx-click="new_task" id="new-task">
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <path d="M12 3v18M3 12h18" />
                </svg>
              </:icon>
              New task
            </.button>
          </:actions>
        </.topbar>

        <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

        <%= if @no_org do %>
          <.no_org_card mount={@samen_mount} />
        <% else %>
          <span id="org-banner" style="display:none">Work org: {@org_id}</span>

          <div :if={@delete_error} class="wrap" style="margin-bottom:0">
            <div class="card form-error" id="delete-error" style="padding:10px 14px;color:var(--bad, #b91c1c);font-size:12px">
              {@delete_error}
            </div>
          </div>

          <div class="wrap">
            <div id="tasks">
              <div class="gtitle">
                <h3>Task Inbox</h3>
                <span class="n">{length(@page.items)}</span>
              </div>
              <.list_view
                id="tasks-list"
                page={@page}
                state={@list_state}
                row_class="task-row"
                filter_placeholder="Filter tasks…"
                empty_text="No tasks yet."
                empty_icon="✓"
                empty_body="Tasks land here with status, priority, and due date."
              >
                <:empty_actions :if={writable?(@samen_mount)}>
                  <.button variant="primary" phx-click="new_task" id="empty-new-task">New task</.button>
                </:empty_actions>
                <:head>
                  <.sort_header field={:title} label="Title" sort={@list_state.sort} width="34%" />
                  <.sort_header field={:status} label="Status" sort={@list_state.sort} width="16%" />
                  <.sort_header field={:priority} label="Priority" sort={@list_state.sort} width="16%" />
                  <.sort_header field={:due_at} label="Due" sort={@list_state.sort} width="20%" />
                  <th :if={writable?(@samen_mount)} scope="col" style="width:10%"><span class="sr-only">Actions</span></th>
                </:head>
                <:row :let={task}>
                  <td class="wk-title">
                    <a href={"#{work_path(@samen_mount)}/tasks/#{task.id}?org=#{@org_id}"} style="font-weight:500;color:#3a3b45;text-decoration:none">
                      {task.title || "(untitled)"}
                    </a>
                  </td>
                  <td class="wk-status">
                    <.pill variant={status_variant(task.status)}>{status_label(task.status)}</.pill>
                  </td>
                  <td class="wk-priority">
                    <.pill variant={priority_variant(task.priority)}>{priority_label(task.priority)}</.pill>
                  </td>
                  <td class="wk-due" style="font-size:12px;color:var(--muted)">
                    {due_cell(task)}
                  </td>
                  <td :if={writable?(@samen_mount)} class="wk-actions">
                    <.delete_confirm phx-click="delete" phx-value-id={task.id} />
                  </td>
                </:row>
              </.list_view>
            </div>
          </div>

          <.modal :if={@show_new and @new_form != nil and writable?(@samen_mount)} id="new-task-modal" title="New task" on_cancel="cancel_new">
            <.simple_form :let={f} for={@new_form} id="new-task-form" phx-change="validate_new" phx-submit="save_new">
              <.form_field field={f[:title]} label="Title" />
              <.form_field
                field={f[:priority]}
                label="Priority"
                type="select"
                options={[{"low", "low"}, {"normal", "normal"}, {"high", "high"}, {"urgent", "urgent"}]}
              />
              <:actions>
                <.button variant="primary" type="submit">Save task</.button>
                <.button type="button" phx-click="cancel_new">Cancel</.button>
              </:actions>
            </.simple_form>
          </.modal>
        <% end %>
      </.app_shell>
    </div>
    """
  end

  # -- helpers ------------------------------------------------------------------

  defp crumbs(mount, org_id, leaf), do: [CurrentOrg.name(mount, org_id), "Work", leaf]

  defp status_variant(:pending), do: "warn"
  defp status_variant(:in_progress), do: "info"
  defp status_variant(:completed), do: "ok"
  defp status_variant(:cancelled), do: "mut"
  defp status_variant(_), do: "mut"

  defp status_label(:pending), do: "pending"
  defp status_label(:in_progress), do: "in progress"
  defp status_label(:completed), do: "completed"
  defp status_label(:cancelled), do: "cancelled"
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

  defp due_cell(%{due_at: %DateTime{} = dt, status: status}) when status not in [:completed, :cancelled] do
    case DateTime.diff(dt, DateTime.utc_now(), :second) do
      secs when secs < 0 -> Phoenix.HTML.raw(~s(<span class="pill bad"><span class="d"></span>overdue</span>))
      secs when secs < 86_400 -> "#{div(secs, 3600)}h left"
      secs -> "#{div(secs, 86_400)}d left"
    end
  end

  defp due_cell(_), do: "—"
end
