defmodule Samen.Web.Work.ProjectsLive do
  @moduledoc """
  Framework Work / Projects — the container-noun list, host-agnostic (ADR-009).
  No PII (INV-1). A plain bounded list (not `ListLive` — Projects is a smaller,
  Tier-0-shaped surface, same posture as `Samen.Web.Support.Live`'s Sla/Macro
  config rows) + sanctioned create/archive.
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.Work.Live, only: [assign_mount: 2, work_sidebar: 1]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Web.CurrentOrg
  alias Samen.Web.Reads.Guard
  alias Samen.Web.Mount
  alias Samen.Web.TenantActor
  require TenantActor
  import Samen.Web.TenantActor, only: [writable?: 2]
  import Samen.Web.TenantActor.Components, only: [actor_refused: 1]

  alias Samen.Web.Work.Reads

  @impl true
  def mount(params, session, socket) do
    socket = assign_mount(socket, session)
    org_id = CurrentOrg.resolve(socket.assigns[:samen_mount], params, session)
    {:ok, load(assign(socket, org_id: org_id, return_to: nil), org_id)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    org_id = Samen.Web.CurrentOrg.reresolve(socket, params)
    {:noreply, load(assign(socket, org_id: org_id, return_to: return_path(uri)), org_id)}
  end

  @doc false
  def load(socket, nil) do
    assign(socket,
      no_org: CurrentOrg.no_org?(socket.assigns[:samen_mount], nil),
      org_id: nil,
      projects: [],
      load_error: nil,
      show_new: false,
      new_form: nil
    )
    |> assign(acting_scope: nil, actor_state: :ok)
    |> assign_new(:delete_error, fn -> nil end)
  end

  # ADR-045 §4.4 - WHO acts: the signed-in person's resolved membership role (`Samen.Web.TenantActor`), never
  # `Mount.scope/2`'s fixed `:member`. A denial or a failed lookup is a STATE of the page: nothing is read, nothing
  # can be written, and the page is re-resolved on every `handle_params`.
  def load(socket, org_id) do
    case TenantActor.assign_actor(socket, org_id) do
      {:ok, socket} -> load_for(socket, org_id, socket.assigns.acting_scope)
      {:refused, socket} -> load_refused(socket, org_id)
    end
  end

  defp load_refused(socket, org_id) do
    socket
    |> assign(no_org: false, org_id: org_id, projects: [], load_error: nil, show_new: false, new_form: nil)
    |> assign_new(:delete_error, fn -> nil end)
  end

  defp load_for(socket, org_id, scope) do
    mount = socket.assigns.samen_mount

    socket
    |> assign_projects(Reads.projects_result(mount, scope))
    |> assign(no_org: false, org_id: org_id)
    |> assign_new(:show_new, fn -> false end)
    |> assign_new(:delete_error, fn -> nil end)
    |> assign(new_form: new_project_form(mount, scope))
  end

  # A failed read is the kit error state (retry), never "No projects yet."; a denial stays empty.
  defp assign_projects(socket, {:ok, projects}), do: assign(socket, projects: projects, load_error: nil)
  defp assign_projects(socket, {:error, :forbidden}), do: assign(socket, projects: [], load_error: nil)

  defp assign_projects(socket, {:error, :unavailable}),
    do: assign(socket, projects: [], load_error: Samen.Web.Reads.Guard.message())

  @impl true
  TenantActor.refuse_events()

  def handle_event("retry_load", _params, socket), do: {:noreply, load(socket, socket.assigns.org_id)}

  def handle_event("new_project", _params, socket) do
    %{samen_mount: mount, acting_scope: scope} = socket.assigns
    {:noreply, assign(socket, show_new: true, new_form: new_project_form(mount, scope))}
  end

  def handle_event("cancel_new", _params, socket) do
    {:noreply, assign(socket, show_new: false)}
  end

  def handle_event("validate_new", %{"form" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.new_form, with_org(params, socket))
    {:noreply, assign(socket, new_form: form)}
  end

  def handle_event("save_new", %{"form" => params}, socket) do
    case Guard.submit_form(:work_save_project, socket.assigns[:org_id], socket.assigns.new_form, with_org(params, socket)) do
      {:ok, _project} -> {:noreply, socket |> assign(show_new: false) |> load(socket.assigns.org_id)}
      {:error, kind} when is_atom(kind) ->
        {:noreply, put_flash(socket, :error, Guard.write_copy(kind, "save that project"))}

      {:error, form} -> {:noreply, assign(socket, new_form: form)}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    %{samen_mount: mount, org_id: org_id, acting_scope: scope} = socket.assigns

    case Reads.delete_project(mount, scope, id) do
      :ok -> {:noreply, load(assign(socket, delete_error: nil), org_id)}
      {:error, _reason} -> {:noreply, assign(socket, delete_error: "Could not archive this project.")}
    end
  end

  # The person's role or id changed while the page was open (`Samen.Web.TenantActor.recheck_event/3`): a form built at
  # load holds the scope it was built with, so it is built again with the fresh one.
  @doc false
  def actor_changed(%{assigns: %{samen_mount: mount, acting_scope: scope}} = socket),
    do: assign(socket, new_form: new_project_form(mount, scope))

  defp new_project_form(mount, scope) do
    Mount.resource(mount, Project) |> AshPhoenix.Form.for_create(:create, scope: scope) |> to_form()
  end

  defp with_org(params, socket), do: Map.put(params, "org_id", socket.assigns.org_id)

  @impl true
  def render(assigns) do
    ~H"""
    <div id="work-projects">
      <.app_shell>
        <:sidebar>
          <.work_sidebar mount={@samen_mount} org_id={@org_id} active={:work_projects} return_to={@return_to} />
        </:sidebar>

        <.topbar title="Projects" crumbs={[CurrentOrg.name(@samen_mount, @org_id), "Work", "Projects"]}>
          <:actions>
            <.button :if={writable?(@samen_mount, @acting_scope) and not @no_org} variant="primary" phx-click="new_project" id="new-project">
              New project
            </.button>
          </:actions>
        </.topbar>

        <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

        <%= cond do %>
        <% @no_org -> %>
          <.no_org_card mount={@samen_mount} />
        <% @actor_state in [:denied, :unavailable] -> %>
          <.actor_refused state={@actor_state} title="Projects" nothing="there are no projects to show" />
        <% true -> %>
          <div :if={@delete_error} class="wrap" style="margin-bottom:0">
            <div class="card form-error" id="delete-error" style="padding:10px 14px;color:var(--bad,#b91c1c);font-size:12px">
              {@delete_error}
            </div>
          </div>

          <div class="wrap">
            <div id="projects-list">
              <.error_state :if={@load_error} class="projects-error" body={@load_error} retry_event="retry_load" />
              <p :if={@projects == [] and is_nil(@load_error)} id="projects-empty" style="color:var(--muted)">No projects yet.</p>
              <ul :if={@projects != []} style="list-style:none;padding:0;margin:0">
                <li :for={p <- @projects} class="project-row" style="padding:10px 0;border-top:1px solid var(--line,#eee);display:flex;justify-content:space-between;align-items:center">
                  <span style="font-weight:500">{p.name}</span>
                  <.pill variant="info">{p.status}</.pill>
                  <.delete_confirm :if={writable?(@samen_mount, @acting_scope)} phx-click="delete" phx-value-id={p.id} />
                </li>
              </ul>
            </div>
          </div>

          <.modal :if={@show_new and @new_form != nil and writable?(@samen_mount, @acting_scope)} id="new-project-modal" title="New project" on_cancel="cancel_new">
            <.simple_form :let={f} for={@new_form} id="new-project-form" phx-change="validate_new" phx-submit="save_new">
              <.form_field field={f[:name]} label="Name" />
              <:actions>
                <.button variant="primary" type="submit">Save project</.button>
                <.button type="button" phx-click="cancel_new">Cancel</.button>
              </:actions>
            </.simple_form>
          </.modal>
        <% end %>
      </.app_shell>
    </div>
    """
  end
end
