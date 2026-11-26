defmodule Samen.Web.TenantActorOpenPageTest.ProbeLive do
  @moduledoc false
  # A view with NO `refuse_events/1` of its own: whatever reaches its `handle_event/3` is what the guard let through.
  use Phoenix.LiveView

  def mount(params, session, socket) do
    socket = Samen.Web.Work.Live.assign_mount(socket, session)
    org_id = Samen.Web.CurrentOrg.resolve(socket.assigns[:samen_mount], params, session)
    {_status, socket} = Samen.Web.TenantActor.assign_actor(socket, org_id)
    {:ok, socket}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  def handle_event(event, _params, socket) do
    send(self(), {:reached, event, socket.assigns.acting_scope.actor.role})
    {:noreply, socket}
  end

  def render(assigns), do: ~H""
end

defmodule Samen.Web.TenantActorOpenPageTest do
  @moduledoc """
  authz-6 review, SHOULD-FIX 1 (and 2): an OPEN page must not keep the role it resolved at its last navigation.

  Every converted LiveView resolves who acts in `handle_params`. A member suspended or demoted WHILE a page is open
  sends events on the same socket, with no navigation between: those events must be judged by the membership as it is
  NOW. `Samen.Web.TenantActor.assign_actor/2` attaches a `:handle_event` lifecycle hook that re-resolves the actor
  before every event (before the ListLive hook and before the view's own `handle_event/3`).

  Driven with a real `POST /login`, the real `Samen.Web.TenantAuthz.on_mount` and the view's own `mount/3` on a socket
  that carries a real LiveView lifecycle (`Phoenix.LiveView.Lifecycle`), and every event is dispatched the way the
  channel does it: the `:handle_event` hooks first, the view's `handle_event/3` only if no hook halted. (`live/2` needs
  `lazy_html`, which this app does not depend on.) NO `handle_params` runs between the membership change and the
  events, and every assertion reads the database. Every refusal is paired with the positive control (an unchanged
  member's events apply).
  """
  use Samen.WebTest.DataCase, async: false

  import Phoenix.ConnTest

  require Ash.Query

  alias Samen.Notifications.Engine
  alias Samen.Web.Notifications.{InboxLive, PreferencesLive}
  alias Samen.WebTest.Primitives.{Notification, NotificationPreference}
  alias Samen.WebTest.SecurityHost
  alias Samen.WebTest.SpineAccounts

  @endpoint Samen.WebTest.SecurityEndpoint

  setup do
    prev = Application.get_env(SecurityHost.otp_app(), :auth_required?)
    prev_delivery = Application.get_env(:samen_core, :delivery_env)
    Application.put_env(:samen_core, :delivery_env, :test)
    SecurityHost.arm!()

    on_exit(fn ->
      restore(SecurityHost.otp_app(), :auth_required?, prev)
      restore(:samen_core, :delivery_env, prev_delivery)
    end)

    owner = SpineAccounts.register!()
    member = SpineAccounts.accept_into!(owner, :member)
    viewer = SpineAccounts.accept_into!(owner, :viewer)
    %{owner: owner, member: member, viewer: viewer, org_id: owner.org.id}
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, v), do: Application.put_env(app, key, v)

  defp log_in(account) do
    conn = post(build_conn(), "/login", %{"login" => %{"email" => account.email, "password" => SpineAccounts.password()}})
    assert redirected_to(conn)
    %{session: Plug.Conn.get_session(conn)}
  end

  # A mounted socket: the login's session + the route's mount session through the real tenant gate and the view's own
  # `mount/3` + `handle_params/3`, on a socket whose private state is a real (empty) LiveView lifecycle, so
  # `attach_hook/4` attaches for real.
  defp open(login, view, path, org_id, extra \\ %{}, routed? \\ true) do
    {_path, mount_session} =
      Samen.WebTest.SecurityRouter
      |> Phoenix.Router.routes()
      |> Enum.filter(&Map.has_key?(&1.metadata, :phoenix_live_view))
      |> Enum.map(fn r ->
        {_v, _a, _o, ls} = r.metadata.phoenix_live_view
        {r.path, get_in(ls, [:extra, :session])}
      end)
      |> Enum.find(fn {p, _} -> p == path end)

    session = Map.merge(login.session, mount_session)
    params = Map.merge(%{"org" => org_id}, extra)
    socket = %Phoenix.LiveView.Socket{} |> Phoenix.Component.assign(:__changed__, %{})
    socket = %{
      socket
      | assigns: Map.put(socket.assigns, :flash, %{}),
        private: Map.put(socket.private, :lifecycle, %Phoenix.LiveView.Lifecycle{}),
        view: view,
        router: if(routed?, do: Samen.WebTest.SecurityRouter)
    }

    {:cont, socket} = Samen.Web.TenantAuthz.on_mount(:require_tenant, params, session, socket)
    {:ok, socket} = view.mount(params, session, socket)
    uri = "http://localhost#{String.replace(path, ":id", extra["id"] || ":id")}?org=#{org_id}"
    {:cont, socket} = Phoenix.LiveView.Lifecycle.handle_params(params, uri, socket)
    {:noreply, socket} = view.handle_params(params, uri, socket)
    {view, socket}
  end

  # One event, dispatched like `Phoenix.LiveView.Channel`: the lifecycle hooks, then the view's `handle_event/3` unless
  # a hook halted. Returns the new `{view, socket}`.
  defp send_event({view, socket}, name, params) do
    case Phoenix.LiveView.Lifecycle.handle_event(name, params, socket) do
      {:halt, socket} ->
        {view, socket}

      {:cont, socket} ->
        {:noreply, socket} = view.handle_event(name, params, socket)
        {view, socket}
    end
  end

  defp html({view, socket}), do: render_html(view, socket.assigns)

  # -- seeds / DB readers (system context) ----------------------------------------------------------------------

  defp read_all(resource, org_id, select) do
    resource
    |> Ash.Query.ensure_selected([:org_id | select])
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&(&1.org_id == org_id))
  end

  defp archived_rows(resource, org_id, select) do
    resource
    |> Samen.Archival.archived_query()
    |> Ash.Query.ensure_selected([:org_id, :archived_at | select])
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&(&1.org_id == org_id))
  end

  defp system_scope(org_id), do: Samen.Web.Plane.scope(Samen.Web.Plane.tenant(), org_id)

  defp archive!(record, org_id), do: {:ok, _} = Samen.Archival.archive(record, scope: system_scope(org_id))

  defp create!(resource, attrs) do
    resource |> Ash.Changeset.for_create(:create, attrs, authorize?: false) |> Ash.create!()
  end

  defp tasks(org_id), do: read_all(Samen.WebTest.Work.Task, org_id, [:title, :status])
  defp projects(org_id), do: read_all(Samen.WebTest.Work.Project, org_id, [:name])
  defp companies(org_id), do: read_all(Samen.WebTest.Crm.Company, org_id, [:name])
  defp people(org_id), do: read_all(Samen.WebTest.Crm.Person, org_id, [:display_name])
  defp enrollments(org_id), do: read_all(Samen.WebTest.Outreach.Enrollment, org_id, [:status])

  defp names(rows, field), do: Enum.map(rows, &Map.fetch!(&1, field))
  defp archived_names(resource, org_id, field), do: archived_rows(resource, org_id, [field]) |> names(field)

  # -- the scenario: open every converted write page as the member, change the membership, send the events --------

  # `mutate` is applied to the membership AFTER every page is open and BEFORE any event; nothing navigates in between.
  # `expect` is `:applied` (the control: an unchanged member's events work) or `:refused`.
  defp scenario(ctx, mutate, expect) do
    org = ctx.org_id
    login = log_in(ctx.member)

    task = create!(Samen.WebTest.Work.Task, %{org_id: org, kind: :task, title: "Target Task"})
    project = create!(Samen.WebTest.Work.Project, %{org_id: org, name: "Target Project"})
    edit_co = create!(Samen.WebTest.Crm.Company, %{org_id: org, name: "Edit Co"})
    drop_co = create!(Samen.WebTest.Crm.Company, %{org_id: org, name: "Drop Co"})
    contact = create!(Samen.WebTest.Crm.Person, %{org_id: org, display_name: "Archived Person"})
    archive!(contact, org)

    sequence =
      create!(Samen.WebTest.Outreach.Sequence, %{
        org_id: org,
        name: "Drip",
        status: :active,
        steps: [%{"delay_hours" => 0, "subject" => "Hello", "body" => "First"}]
      })

    lead = create!(Samen.WebTest.Crm.Person, %{org_id: org, display_name: "Enrollable"})

    tasks_v = open(login, Samen.Web.Work.TasksLive, "/work", org)
    projects_v = open(login, Samen.Web.Work.ProjectsLive, "/work/projects", org)
    edit_v = open(login, Samen.Web.CRM.CompanyLive, "/crm/companies/:id", org, %{"id" => edit_co.id})
    drop_v = open(login, Samen.Web.CRM.CompanyLive, "/crm/companies/:id", org, %{"id" => drop_co.id})
    seq_v = open(login, Samen.Web.CRM.SequencesLive, "/crm/sequences", org)
    contacts_v = open(login, Samen.Web.CRM.ContactsLive, "/crm/contacts", org)
    csv_v = open(login, Samen.Web.Csv.ImportLive, "/csv/import/:resource", org, %{"resource" => "Person"})

    # the page reads its archived rows now, while the member may still read them
    contacts_v = send_event(contacts_v, "toggle_archived", %{})

    mutate.()

    tasks_v = send_event(tasks_v, "save_new", %{"form" => %{"title" => "Ghost Task", "kind" => "task"}})
    tasks_v = send_event(tasks_v, "delete", %{"id" => task.id})
    projects_v = send_event(projects_v, "save_new", %{"form" => %{"name" => "Ghost Project"}})
    projects_v = send_event(projects_v, "delete", %{"id" => project.id})
    edit_v = send_event(edit_v, "save_edit", %{"form" => %{"name" => "Ghost Renamed"}})
    edit_v = send_event(edit_v, "log_activity", %{"activity" => %{"kind" => "call", "title" => "Ghost call"}})
    drop_v = send_event(drop_v, "delete_company", %{"id" => drop_co.id})
    seq_v = send_event(seq_v, "enroll", %{"sequence_id" => sequence.id, "person_id" => lead.id})
    contacts_v = send_event(contacts_v, "restore", %{"id" => contact.id})
    # the upload cannot be driven without `lazy_html`: any event settles the page's actor, and the page's write path
    # (`import_rows/2`, what the `import` event runs on the consumed bytes) then runs with the scope the page now holds
    {csv_view, csv_socket} = send_event(csv_v, "validate", %{})
    csv_socket = csv_view.import_rows(csv_socket, "display_name\nCsv Ghost\n")
    csv_v = {csv_view, csv_socket}

    views = %{tasks: tasks_v, projects: projects_v, edit: edit_v, drop: drop_v, seq: seq_v, contacts: contacts_v, csv: csv_v}

    case expect do
      :applied ->
        assert "Ghost Task" in names(tasks(org), :title)
        assert "Target Task" in archived_names(Samen.WebTest.Work.Task, org, :title)
        assert "Ghost Project" in names(projects(org), :name)
        assert "Target Project" in archived_names(Samen.WebTest.Work.Project, org, :name)
        assert "Ghost Renamed" in names(companies(org), :name)
        assert "Drop Co" in archived_names(Samen.WebTest.Crm.Company, org, :name)
        assert length(enrollments(org)) == 1
        assert "Archived Person" in names(people(org), :display_name)
        assert "Csv Ghost" in names(people(org), :display_name)

      :refused ->
        refute "Ghost Task" in names(tasks(org), :title)
        refute "Target Task" in archived_names(Samen.WebTest.Work.Task, org, :title)
        refute "Ghost Project" in names(projects(org), :name)
        refute "Target Project" in archived_names(Samen.WebTest.Work.Project, org, :name)
        assert "Edit Co" in names(companies(org), :name)
        refute "Ghost Renamed" in names(companies(org), :name)
        refute "Drop Co" in archived_names(Samen.WebTest.Crm.Company, org, :name)
        # `log_activity` writes a task: only the seeded one exists
        assert names(tasks(org), :title) == ["Target Task"]
        assert enrollments(org) == []
        assert "Archived Person" in archived_names(Samen.WebTest.Crm.Person, org, :display_name)
        refute "Archived Person" in names(people(org), :display_name)
        refute "Csv Ghost" in names(people(org), :display_name)
    end

    views
  end

  test "control: an unchanged member's events on the open pages all apply", ctx do
    scenario(ctx, fn -> :ok end, :applied)
  end

  test "a member suspended while the pages are open: every write event is refused and the page is the denied state", ctx do
    views = scenario(ctx, fn -> SpineAccounts.suspend!(ctx.member, ctx.org_id) end, :refused)

    for {name, v} <- views do
      assert html(v) =~ ~s(id="actor-denied"), "#{name} is not the denied state"
    end
  end

  test "a member demoted to viewer while the pages are open: the same write events are refused", ctx do
    scenario(ctx, fn -> SpineAccounts.set_role!(ctx.member, ctx.org_id, :viewer) end, :refused)
  end

  test "a demotion takes effect on the very next event and a promotion back restores the member's writes", ctx do
    org = ctx.org_id
    v = open(log_in(ctx.member), Samen.Web.Work.TasksLive, "/work", org)

    SpineAccounts.set_role!(ctx.member, org, :viewer)
    v = send_event(v, "save_new", %{"form" => %{"title" => "While Viewer", "kind" => "task"}})
    refute "While Viewer" in names(tasks(org), :title)

    SpineAccounts.set_role!(ctx.member, org, :member)
    v = send_event(v, "save_new", %{"form" => %{"title" => "Member Again", "kind" => "task"}})
    assert "Member Again" in names(tasks(org), :title)
    assert elem(v, 1).assigns.acting_scope.actor.role == :member
  end

  test "an unavailable lookup halts the event and shows the unavailable state", ctx do
    org = ctx.org_id
    {view, socket} = v = open(log_in(ctx.member), Samen.Web.Work.TasksLive, "/work", org)
    task = create!(Samen.WebTest.Work.Task, %{org_id: org, kind: :task, title: "Outage Task"})

    mount = socket.assigns.samen_mount
    broken = %{mount | labels: Map.put(mount.labels, :identity_namespace, Samen.WebTest.NoSuchIdentity)}
    v = {view, Phoenix.Component.assign(elem(v, 1), :samen_mount, broken)}

    {v, _log} = ExUnit.CaptureLog.with_log(fn -> send_event(v, "delete", %{"id" => task.id}) end)

    refute "Outage Task" in archived_names(Samen.WebTest.Work.Task, org, :title)
    assert elem(v, 1).assigns.actor_state == :unavailable
    assert html(v) =~ ~s(id="actor-unavailable")
  end

  test "an open page's list context follows the person: a demoted member's list restore is refused", ctx do
    org = ctx.org_id
    person = create!(Samen.WebTest.Crm.Person, %{org_id: org, display_name: "Archived Contact"})
    archive!(person, org)

    # the contacts list is a ListLive that surfaces archived rows (the Work lists never do, so a `restore` there reaches nothing)
    v = open(log_in(ctx.member), Samen.Web.CRM.ContactsLive, "/crm/contacts", org)
    v = send_event(v, "toggle_archived", %{})
    assert Enum.map(elem(v, 1).assigns.page.items, & &1.display_name) == ["Archived Contact"]

    SpineAccounts.set_role!(ctx.member, org, :viewer)
    v = send_event(v, "restore", %{"id" => person.id})
    assert "Archived Contact" in archived_names(Samen.WebTest.Crm.Person, org, :display_name)
    assert elem(v, 1).assigns.samen_list_ctx.scope.actor.role == :viewer

    # control: the same page, promoted back, restores through the very same list event
    SpineAccounts.set_role!(ctx.member, org, :member)
    send_event(v, "restore", %{"id" => person.id})
    assert "Archived Contact" in names(people(org), :display_name)
  end

  # -- the refused state carries NO record data (authz-6 review 2, A3) ------------------------------------------------

  # Every converted page, opened as the member with a record whose name the page renders. The positive control: the name
  # IS on the open page. Then the membership changes, ANY event is sent (the guard judges it before the view does), and
  # the page renders the refused card with none of those names in the HTML (the topbar included).
  defp refusal_pages(org) do
    task = create!(Samen.WebTest.Work.Task, %{org_id: org, kind: :task, title: "Zephyr Task Title"})
    create!(Samen.WebTest.Work.Task, %{org_id: org, kind: :task, title: "Zephyr Child Subtask", parent_id: task.id})
    create!(Samen.WebTest.Work.Project, %{org_id: org, name: "Zephyr Project Name"})
    company = create!(Samen.WebTest.Crm.Company, %{org_id: org, name: "Zephyr Company Name"})
    person = create!(Samen.WebTest.Crm.Person, %{org_id: org, display_name: "Zephyr Person Name", company_id: company.id})
    {:ok, _} =
      Samen.CustomFields.define_field(
        %{org_id: org, table_name: "swp_person", field_name: "lifecycle_stage", type: :string},
        Samen.WebTest.Repo
      )

    create!(Samen.WebTest.Crm.Person, %{org_id: org, display_name: "Zephyr Lead Name", custom: %{"lifecycle_stage" => "lead"}})
    stage = create!(Samen.WebTest.Crm.Pipeline, %{org_id: org, name: "Zephyr Stage"})

    create!(Samen.WebTest.Crm.Opportunity, %{
      org_id: org,
      name: "Zephyr Deal Name",
      pipeline_id: stage.id,
      close_date: Date.utc_today()
    })

    create!(Samen.WebTest.Outreach.Sequence, %{
      org_id: org,
      name: "Zephyr Sequence Name",
      status: :active,
      steps: [%{"delay_hours" => 0, "subject" => "Hello", "body" => "First"}]
    })

    [
      {"tasks", Samen.Web.Work.TasksLive, "/work", %{}, ["Zephyr Task Title"]},
      {"task", Samen.Web.Work.TaskLive, "/work/tasks/:id", %{"id" => task.id}, ["Zephyr Task Title", "Zephyr Child Subtask"]},
      {"projects", Samen.Web.Work.ProjectsLive, "/work/projects", %{}, ["Zephyr Project Name"]},
      {"timeline", Samen.Web.Work.TimelineLive, "/work/timeline", %{}, []},
      {"task tree", Samen.Web.Work.TaskTreeLive, "/work/tree", %{}, ["Zephyr Child Subtask"]},
      {"companies", Samen.Web.CRM.CompaniesLive, "/crm/companies", %{}, ["Zephyr Company Name"]},
      {"company", Samen.Web.CRM.CompanyLive, "/crm/companies/:id", %{"id" => company.id}, ["Zephyr Company Name", "Zephyr Person Name"]},
      {"contacts", Samen.Web.CRM.ContactsLive, "/crm/contacts", %{}, ["Zephyr Person Name"]},
      {"contact", Samen.Web.CRM.ContactLive, "/crm/contacts/:id", %{"id" => person.id}, ["Zephyr Person Name"]},
      {"contacts gallery", Samen.Web.CRM.ContactsGalleryLive, "/crm/gallery", %{}, ["Zephyr Person Name"]},
      {"pipeline", Samen.Web.CRM.PipelineLive, "/crm/pipeline", %{}, ["Zephyr Deal Name"]},
      {"calendar", Samen.Web.CRM.CalendarLive, "/crm/calendar", %{}, ["Zephyr Deal Name"]},
      {"sequences", Samen.Web.CRM.SequencesLive, "/crm/sequences", %{}, ["Zephyr Sequence Name"]},
      {"leads", Samen.Web.Marketing.LeadsLive, "/marketing/leads", %{}, ["Zephyr Lead Name"]},
      {"import", Samen.Web.Csv.ImportLive, "/csv/import/:resource", %{"resource" => "Person"}, ["csv-import-report"]},
      {"profile", Samen.Web.Settings.ProfileLive, "/settings/profile", %{}, ["zephyrhandle", "Profilesson", "zephyr@example.test"]}
    ]
  end

  # The member's own profile starts blank: save one, so the open page holds a name and an email to leak.
  defp prepare("profile", v) do
    send_event(v, "save", %{
      "profile" => %{"handle" => "zephyrhandle", "first" => "Zephyr", "last" => "Profilesson", "email" => "zephyr@example.test"}
    })
  end

  # An earlier import's report is what the import page holds.
  defp prepare("import", {view, socket}), do: {view, view.import_rows(socket, "display_name\nZephyr Imported Row\n")}

  defp prepare(_name, v), do: v

  defp assert_no_data(pages, v, marks, what) do
    for mark <- marks do
      refute html(v) =~ mark, "#{pages} still renders #{inspect(mark)} #{what}"
    end
  end

  test "a suspended member's open pages render the denied card and none of the records they loaded", ctx do
    org = ctx.org_id
    login = log_in(ctx.member)

    opened =
      for {name, view, path, extra, marks} <- refusal_pages(org) do
        v = open(login, view, path, org, extra)
        v = prepare(name, v)

        for mark <- marks do
          assert html(v) =~ mark, "control: #{name} does not render #{inspect(mark)} while the member acts"
        end

        {name, v, marks}
      end

    SpineAccounts.suspend!(ctx.member, org)

    for {name, v, marks} <- opened do
      v = send_event(v, "cancel_new", %{})
      assert html(v) =~ ~s(id="actor-denied"), "#{name} is not the denied state"
      assert_no_data(name, v, marks, "in the denied state")
    end
  end

  test "an open page whose actor lookup fails renders the unavailable card and none of its records", ctx do
    org = ctx.org_id
    login = log_in(ctx.member)

    opened =
      for {name, view, path, extra, marks} <- refusal_pages(org), name in ["company", "contact", "task", "profile"] do
        {view, socket} = v = prepare(name, open(login, view, path, org, extra))
        mount = socket.assigns.samen_mount
        broken = %{mount | labels: Map.put(mount.labels, :identity_namespace, Samen.WebTest.NoSuchIdentity)}
        {name, {view, Phoenix.Component.assign(elem(v, 1), :samen_mount, broken)}, marks}
      end

    for {name, v, marks} <- opened do
      {v, _log} = ExUnit.CaptureLog.with_log(fn -> send_event(v, "cancel_new", %{}) end)
      assert html(v) =~ ~s(id="actor-unavailable"), "#{name} is not the unavailable state"
      assert_no_data(name, v, marks, "in the unavailable state")
    end
  end

  # -- the notification pages resolve the recipient their own way, and guard their events the same way ----------------

  defp notify!(org_id, recipient_id, body) do
    {:ok, n} =
      Engine.notify(
        %{org_id: org_id, recipient_id: recipient_id, event_type: "invoice.created", channel: :in_app, rendered_body: body},
        notification_module: Notification,
        preference_module: NotificationPreference,
        repo: Samen.WebTest.Repo
      )

    n
  end

  defp read_at(id), do: Ash.get!(Notification, id, authorize?: false).read_at

  test "an open inbox of a suspended member marks nothing read and reads nothing on a realtime envelope", ctx do
    org = ctx.org_id
    own = notify!(org, SpineAccounts.user_id(ctx.member, org), "OWN-ROW")
    v = open(log_in(ctx.member), InboxLive, "/notifications", org)
    assert html(v) =~ "OWN-ROW"

    SpineAccounts.suspend!(ctx.member, org)

    {_view, socket} = v = send_event(v, "mark_all_read", %{})
    assert read_at(own.id) == nil
    assert socket.assigns.recipient_state == :denied
    assert socket.assigns.samen_list_ctx == nil
    refute html(v) =~ "OWN-ROW"
  end

  test "an open inbox's realtime message re-resolves the person before it reads", ctx do
    org = ctx.org_id
    own = notify!(org, SpineAccounts.user_id(ctx.member, org), "OWN-ROW")
    {view, socket} = open(log_in(ctx.member), InboxLive, "/notifications", org)
    SpineAccounts.suspend!(ctx.member, org)

    assert {:halt, socket} = Phoenix.LiveView.Lifecycle.handle_info({:notification_created, %{id: own.id}}, socket)
    assert socket.assigns.recipient_state == :denied
    refute render_html(view, socket.assigns) =~ "OWN-ROW"
  end

  test "an open preferences grid of a suspended member saves nothing", ctx do
    org = ctx.org_id
    v = open(log_in(ctx.member), PreferencesLive, "/notifications/settings", org)
    assert elem(v, 1).assigns.access == :ok
    recipient = SpineAccounts.user_id(ctx.member, org)
    assert html(v) =~ recipient
    SpineAccounts.suspend!(ctx.member, org)

    v = send_event(v, "save", %{"_target" => ["prefs", "chat_mention__in_app"], "prefs" => %{"chat_mention__in_app" => "off"}})
    assert elem(v, 1).assigns.access == :denied
    assert Ash.read!(NotificationPreference, authorize?: false) == []

    # the refused page carries no grid and not the recipient it resolved
    refute html(v) =~ "preferences-grid"
    refute html(v) =~ recipient
    assert html(v) =~ "preferences-denied"
  end

  # -- the guard is attached once, and the refused state can ask again ----------------------------------------------

  test "assign_actor attaches the guard once however many times a page navigates, and it runs before the ListLive hook", ctx do
    {view, socket} = open(log_in(ctx.member), Samen.Web.Work.TasksLive, "/work", ctx.org_id)
    uri = "http://localhost/work?org=#{ctx.org_id}"

    {:noreply, socket} = view.handle_params(%{"org" => ctx.org_id}, uri, socket)
    {:noreply, socket} = view.handle_params(%{"org" => ctx.org_id}, uri, socket)

    ids = Enum.map(socket.private.lifecycle.handle_event, & &1.id)
    assert Enum.count(ids, &(&1 == :samen_tenant_actor_guard)) == 1
    assert ids == [:samen_tenant_actor_guard, :samen_list_live]
    assert Enum.count(socket.private.lifecycle.handle_params, &(&1.id == :samen_tenant_actor_uri)) == 1
  end

  test "retry_actor: a refused page asks again; it patches to its own URL once the person acts, and stays refused while not", ctx do
    org = ctx.org_id
    {view, _socket} = v = open(log_in(ctx.member), Samen.Web.Work.TasksLive, "/work", org)
    SpineAccounts.suspend!(ctx.member, org)
    {_view, denied} = v = send_event(v, "delete", %{"id" => Ash.UUID.generate()})
    assert denied.assigns.actor_state == :denied
    assert html(v) =~ ~s(id="actor-retry")

    # still suspended: the retry stays the denied state and goes nowhere
    {_view, still} = v = send_event(v, "retry_actor", %{})
    assert still.assigns.actor_state == :denied
    assert still.redirected == nil

    # reinstated: the retry patches to the page's own URL, where `handle_params` loads it fresh
    reinstate!(ctx.member, org)
    {_view, patched} = send_event(v, "retry_actor", %{})
    assert {:live, :patch, %{to: "/work?org=" <> _}} = patched.redirected

    {:noreply, fresh} = view.handle_params(%{"org" => org}, "http://localhost/work?org=#{org}", patched)
    assert fresh.assigns.actor_state == :ok
    assert fresh.assigns.acting_scope.actor.role == :member
  end

  test "retry_actor on a view that recorded no URI (no router, or the org resolved late) re-resolves in place and loads again", ctx do
    org = ctx.org_id
    create!(Samen.WebTest.Work.Task, %{org_id: org, kind: :task, title: "Retry Task Title"})
    company = create!(Samen.WebTest.Crm.Company, %{org_id: org, name: "Retry Company Name"})

    pages = [
      {Samen.Web.Work.TasksLive, "/work", %{}, "Retry Task Title"},
      {Samen.Web.CRM.CompanyLive, "/crm/companies/:id", %{"id" => company.id}, "Retry Company Name"}
    ]

    for {view, path, extra, mark} <- pages do
      v = open(log_in(ctx.member), view, path, org, extra, false)
      assert html(v) =~ mark
      assert elem(v, 1).assigns[:acting_uri] == nil

      SpineAccounts.suspend!(ctx.member, org)
      v = send_event(v, "cancel_new", %{})
      assert html(v) =~ ~s(id="actor-denied")
      refute html(v) =~ mark

      # still suspended: the page stays refused, honestly
      v = send_event(v, "retry_actor", %{})
      assert html(v) =~ ~s(id="actor-denied")

      # reinstated: the click acts again, right here, and the page loads what it shows
      reinstate!(ctx.member, org)
      {_view, back} = v = send_event(v, "retry_actor", %{})
      assert back.redirected == nil
      assert back.assigns.actor_state == :ok
      assert html(v) =~ mark, "#{inspect(view)} did not load again after a retry with no URI"
      refute html(v) =~ ~s(id="actor-denied")
    end
  end

  defp reinstate!(account, org_id) do
    user = Samen.WebTest.Operator.User |> Ash.Query.filter(credential_id == ^account.credential.id and org_id == ^org_id) |> Ash.read!(authorize?: false) |> hd()
    [m] = Samen.WebTest.Operator.Membership |> Ash.Query.filter(user_id == ^user.id and org_id == ^org_id) |> Ash.read!(authorize?: false)
    m |> Ash.Changeset.for_update(:update, %{status: "active"}, authorize?: false) |> Ash.update!()
  end

  test "the guard HALTS a refused event: it never reaches the view's own handle_event (refuse_events is only the second line)", ctx do
    alias Samen.Web.TenantActorOpenPageTest.ProbeLive
    org = ctx.org_id
    v = open(log_in(ctx.member), ProbeLive, "/work", org)

    # control: while the member acts, the event reaches the view, carrying the role the guard just resolved
    v = send_event(v, "write", %{})
    assert_received {:reached, "write", :member}

    SpineAccounts.set_role!(ctx.member, org, :viewer)
    v = send_event(v, "write", %{})
    assert_received {:reached, "write", :viewer}

    SpineAccounts.suspend!(ctx.member, org)
    {_view, socket} = send_event(v, "write", %{})
    refute_received {:reached, "write", _}
    assert socket.assigns.actor_state == :denied
    assert socket.assigns.acting_scope == nil
  end

  # -- cost: one resolver lookup per event ----------------------------------------------------------------------

  # Queries the repo ran while `fun` ran, by SQL text (the sandbox runs them in this process).
  defp queries(fun) do
    ref = make_ref()
    me = self()
    id = {__MODULE__, ref}

    :telemetry.attach(id, [:samen, :web_test, :repo, :query], &__MODULE__.handle_query/4, {me, ref})

    try do
      fun.()
    after
      :telemetry.detach(id)
    end

    collect(ref, [])
  end

  @doc false
  def handle_query(_event, _measurements, meta, {pid, ref}), do: send(pid, {ref, meta.query})

  defp collect(ref, acc) do
    receive do
      {^ref, query} -> collect(ref, [query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "the guard costs at most two identity lookups per event, never a cache across events", ctx do
    org = ctx.org_id
    v = {view, socket} = open(log_in(ctx.member), Samen.Web.Work.TasksLive, "/work", org)
    params = %{"form" => %{"title" => "Counted", "kind" => "task"}}

    bare = queries(fn -> view.handle_event("cancel_new", %{}, socket) end)
    guarded = queries(fn -> send_event(v, "cancel_new", %{}) end)
    assert bare == []

    # `cancel_new` reads nothing itself: every query the guarded event ran is the actor lookup
    assert length(guarded) in 1..2, "the guard ran #{length(guarded)} queries: #{inspect(guarded)}"
    assert Enum.all?(guarded, &(&1 =~ ~r/"wou_user"|"wom_membership"/))

    # and it is per event: a second event resolves again (suspending between them is seen)
    again = queries(fn -> send_event(v, "cancel_new", %{}) end)
    assert length(again) == length(guarded)

    # a write event: the lookup is the same size on top of the write
    write = queries(fn -> send_event(v, "save_new", params) end)
    # (the guard's lookup, plus the page's own reload after a successful save)
    assert Enum.count(write, &(&1 =~ ~r/"wom_membership"/)) <= 2
  end
end
