defmodule Samen.Web.Work.TaskLive do
  @moduledoc """
  Framework Work / Task Detail — task metadata + its direct Subtask children,
  host-agnostic (ADR-009), mirroring `Samen.Web.Support.TicketLive`'s shape but
  simpler (no PII, no conversation thread).

  No PII (INV-1). NEVER calls the vault; there is nothing vault-routed to resolve.

  ## A3 write side — status only (the sanctioned "task status" write)

  The status select's submitted value is matched against the BOUNDED enum in
  `Reads.update_task_status/4` (client input never mints an atom; garbage is
  refused). Write affordances are offered on the tenant plane only.
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.Work.Live, only: [assign_mount: 2, work_sidebar: 1, work_path: 1, writable?: 1]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount

  alias Samen.Web.Work.Reads

  @impl true
  def mount(params, session, socket) do
    socket = assign_mount(socket, session)
    org_id = CurrentOrg.resolve(socket.assigns[:samen_mount], params, session)
    task_id = Map.get(params, "id")

    {:ok, load(assign(socket, org_id: org_id, task_id: task_id, return_to: nil), org_id, task_id)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    org_id = Samen.Web.CurrentOrg.reresolve(socket, params)
    task_id = Map.get(params, "id") || socket.assigns.task_id
    {:noreply, load(assign(socket, org_id: org_id, task_id: task_id, return_to: return_path(uri)), org_id, task_id)}
  end

  @doc false
  def load(socket, nil, _task_id) do
    assign(socket, no_org: CurrentOrg.no_org?(socket.assigns[:samen_mount], nil), task: nil, subtasks: [])
  end

  def load(socket, org_id, task_id) do
    mount = socket.assigns.samen_mount
    scope = Mount.scope(mount, org_id)

    case Reads.get_task(mount, scope, task_id) do
      {:ok, task} ->
        assign(socket,
          no_org: false,
          task: task,
          subtasks: Reads.subtasks(mount, scope, task.id),
          status_error: nil
        )

      :error ->
        assign(socket, no_org: false, task: nil, subtasks: [], status_error: nil)
    end
  end

  @impl true
  def handle_event("update_status", %{"status" => status}, socket) do
    %{samen_mount: mount, org_id: org_id, task_id: task_id} = socket.assigns
    scope = Mount.scope(mount, org_id)

    case Reads.update_task_status(mount, scope, task_id, status) do
      {:ok, _task} -> {:noreply, load(socket, org_id, task_id)}
      {:error, _reason} -> {:noreply, assign(socket, status_error: "Could not update status.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="work-task">
      <.app_shell>
        <:sidebar>
          <.work_sidebar mount={@samen_mount} org_id={@org_id} active={:work_tasks} return_to={@return_to} />
        </:sidebar>

        <.topbar title="Task" crumbs={crumbs(@samen_mount, @org_id, @task)}>
          <:actions>
            <.button href={"#{work_path(@samen_mount)}?org=#{@org_id}"}>← Back to tasks</.button>
          </:actions>
        </.topbar>

        <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

        <%= cond do %>
          <% @no_org -> %>
            <.no_org_card mount={@samen_mount} />
          <% is_nil(@task) -> %>
            <div class="wrap">
              <div class="card" id="task-not-found" style="padding:20px">Task not found.</div>
            </div>
          <% true -> %>
            <div class="wrap">
              <div class="card" id="task-detail" style="padding:20px">
                <h2 style="margin-top:0">{@task.title || "(untitled)"}</h2>
                <p :if={@task.body} style="color:var(--muted)">{@task.body}</p>

                <div :if={@status_error} class="form-error" style="color:var(--bad,#b91c1c);font-size:12px;margin-bottom:8px">
                  {@status_error}
                </div>

                <div class="meta" style="display:flex;gap:16px;flex-wrap:wrap;margin-bottom:16px">
                  <div>
                    <span style="font-size:11px;color:var(--muted);display:block">Kind</span>
                    <.pill variant="mut">{@task.kind}</.pill>
                  </div>
                  <div>
                    <span style="font-size:11px;color:var(--muted);display:block">Status</span>
                    <%= if writable?(@samen_mount) do %>
                      <form phx-change="update_status" id="status-form">
                        <select name="status">
                          <option :for={s <- Reads.task_statuses()} value={s} selected={s == @task.status}>
                            {s}
                          </option>
                        </select>
                      </form>
                    <% else %>
                      <.pill variant="info">{@task.status}</.pill>
                    <% end %>
                  </div>
                  <div>
                    <span style="font-size:11px;color:var(--muted);display:block">Priority</span>
                    <.pill variant="info">{@task.priority}</.pill>
                  </div>
                  <div :if={@task.due_at}>
                    <span style="font-size:11px;color:var(--muted);display:block">Due</span>
                    {@task.due_at}
                  </div>
                </div>

                <h3 id="subtasks-heading" style="font-size:14px;margin-bottom:8px">
                  Subtasks <span class="n">{length(@subtasks)}</span>
                </h3>
                <ul :if={@subtasks != []} id="subtasks-list" style="list-style:none;padding:0;margin:0">
                  <li :for={sub <- @subtasks} class="subtask-row" style="padding:8px 0;border-top:1px solid var(--line,#eee)">
                    <a href={"#{work_path(@samen_mount)}/tasks/#{sub.id}?org=#{@org_id}"} style="text-decoration:none;color:#3a3b45;font-weight:500">
                      {sub.title || "(untitled)"}
                    </a>
                    <.pill variant={if sub.status == :completed, do: "ok", else: "mut"}>{sub.status}</.pill>
                  </li>
                </ul>
                <p :if={@subtasks == []} id="subtasks-empty" style="color:var(--muted);font-size:13px">No subtasks.</p>
              </div>
            </div>
        <% end %>
      </.app_shell>
    </div>
    """
  end

  defp crumbs(_mount, _org_id, nil), do: ["Work", "Task"]
  defp crumbs(mount, org_id, task), do: [CurrentOrg.name(mount, org_id), "Work", task.title || "Task"]
end
