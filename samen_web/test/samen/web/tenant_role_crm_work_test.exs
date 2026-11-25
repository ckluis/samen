defmodule Samen.Web.TenantRoleCrmWorkTest do
  @moduledoc """
  ADR-045 §4.4 residual (the `:member` default), CRM remainder + Work: every page of these two families acts with the
  role the signed-in person's ACTIVE membership resolves to (`Samen.Web.TenantActor`), never `Plane.scope/2`'s fixed
  `:member`.

  Driven with a REAL spine login (`POST /login`) and the REAL `Samen.Web.TenantAuthz.on_mount`, the pattern of
  `tenant_role_surfaces_test.exs`. Every refusal is paired with a positive control (a member and an owner keep what
  they could do).

  Policy (read from the blueprints): no READ is role-gated (`OrgScope` only), so for the read-only pages viewer and
  member see the same rows and the acting role is pinned on the scope. The writes are `RoleAtLeast :member` for
  CRM `Company`, Work `Project` and `Task`; Outreach `Enrollment` `:enroll`/`:pause`/`:resume`/`:stop` had NO role
  rule (a viewer enrolled contacts into email sequences) and are `:member` since this round.
  """
  use Samen.WebTest.DataCase, async: false

  import Phoenix.ConnTest

  require Ash.Query

  alias Samen.Mailbox
  alias Samen.Mailbox.{Config, FakeProvider}
  alias Samen.Web.CRM.{CalendarLive, CompanyLive, ContactsGalleryLive, DashboardLive, MailboxLive, PipelineLive, SequencesLive}
  alias Samen.Web.Work.{ProjectsLive, TaskLive, TaskTreeLive, TasksLive, TimelineLive}
  alias Samen.WebTest.SecurityHost
  alias Samen.WebTest.SpineAccounts

  @endpoint Samen.WebTest.SecurityEndpoint

  setup do
    prev = Application.get_env(SecurityHost.otp_app(), :auth_required?)
    prev_delivery = Application.get_env(:samen_core, :delivery_env)
    prev_mailbox = Application.get_env(:samen_core, :mailbox_provider)
    Application.put_env(:samen_core, :delivery_env, :test)
    SecurityHost.arm!()
    FakeProvider.reset()

    on_exit(fn ->
      restore(SecurityHost.otp_app(), :auth_required?, prev)
      restore(:samen_core, :delivery_env, prev_delivery)
      restore(:samen_core, :mailbox_provider, prev_mailbox)
      FakeProvider.reset()
    end)

    owner = SpineAccounts.register!()
    member = SpineAccounts.accept_into!(owner, :member)
    viewer = SpineAccounts.accept_into!(owner, :viewer)
    %{owner: owner, member: member, viewer: viewer, org_id: owner.org.id}
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, v), do: Application.put_env(app, key, v)

  # -- harness ------------------------------------------------------------------------------------------------

  defp log_in(account) do
    conn = post(build_conn(), "/login", %{"login" => %{"email" => account.email, "password" => SpineAccounts.password()}})
    assert redirected_to(conn)
    %{conn: recycle(conn), session: Plug.Conn.get_session(conn)}
  end

  # The socket a REAL route would hand the view: the login's session + the route's mount session, through the real
  # tenant gate, then the view's own `mount/3`.
  defp live_socket(login, view, path, org_id, extra \\ %{}) do
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
    socket = %{socket | assigns: Map.put(socket.assigns, :flash, %{})}
    {:cont, socket} =
      case Samen.Web.TenantAuthz.on_mount(:require_tenant, params, session, socket) do
        {:cont, _} = ok -> ok
        other -> flunk("tenant gate refused #{path}: #{inspect(elem(other, 0))}")
      end

    {:ok, socket} = view.mount(params, session, socket)
    socket
  end

  defp event(view, name, params, socket) do
    {:noreply, socket} = view.handle_event(name, params, socket)
    socket
  end

  defp params(view, socket, extra) do
    {:noreply, socket} = view.handle_params(Map.merge(%{"org" => socket.assigns.org_id}, extra), "http://localhost/x", socket)
    socket
  end

  defp break_identity(socket) do
    mount = socket.assigns.samen_mount
    broken = %{mount | labels: Map.put(mount.labels, :identity_namespace, Samen.WebTest.NoSuchIdentity)}
    Phoenix.Component.assign(socket, :samen_mount, broken)
  end

  defp html(view, socket), do: render_html(view, socket.assigns)

  # -- seeds (system context: authorize?: false) -------------------------------------------------------------

  defp company!(org_id, name) do
    Samen.WebTest.Crm.Company
    |> Ash.Changeset.for_create(:create, %{org_id: org_id, name: name}, authorize?: false)
    |> Ash.create!()
  end

  defp person!(org_id, name) do
    Samen.WebTest.Crm.Person
    |> Ash.Changeset.for_create(:create, %{org_id: org_id, display_name: name}, authorize?: false)
    |> Ash.create!()
  end

  defp open_opp!(org_id, name) do
    stage =
      Samen.WebTest.Crm.Pipeline
      |> Ash.Changeset.for_create(
        :create,
        %{org_id: org_id, name: "role-open", label: "Role Open", stage_order: 0, stage_type: "open"},
        authorize?: false
      )
      |> Ash.create!()

    Samen.WebTest.Crm.Opportunity
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org_id,
        name: name,
        value: Samen.Type.Money.from_cents(100_000, :USD),
        status: :open,
        pipeline_id: stage.id,
        close_date: Date.utc_today()
      },
      authorize?: false
    )
    |> Ash.create!()
  end

  defp project!(org_id, name) do
    Samen.WebTest.Work.Project
    |> Ash.Changeset.for_create(:create, %{org_id: org_id, name: name}, authorize?: false)
    |> Ash.create!()
  end

  defp task!(org_id, title, attrs \\ %{}) do
    Samen.WebTest.Work.Task
    |> Ash.Changeset.for_create(:create, Map.merge(%{org_id: org_id, kind: :task, title: title, due_at: DateTime.utc_now() |> DateTime.truncate(:second)}, attrs), authorize?: false)
    |> Ash.create!()
  end

  defp sequence!(org_id, name) do
    Samen.WebTest.Outreach.Sequence
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org_id, name: name, status: :active, steps: [%{"delay_hours" => 0, "subject" => "Hello", "body" => "First"}]},
      authorize?: false
    )
    |> Ash.create!()
  end

  defp enrollment!(org_id, sequence, person) do
    Samen.WebTest.Outreach.Enrollment
    |> Ash.Changeset.for_create(:enroll, %{org_id: org_id, sequence_id: sequence.id, person_id: person.id}, authorize?: false)
    |> Ash.create!()
  end

  defp connection!(org_id) do
    FakeProvider.set_capabilities([:inbound_sync, :outbound_send])
    Application.put_env(:samen_core, :mailbox_provider, {FakeProvider, %{configured: true}})

    cfg = %Config{
      org_id: org_id,
      repo: Samen.WebTest.Repo,
      provider: FakeProvider,
      provider_config: %{configured: true},
      connection_resource: Samen.WebTest.Mailbox.Connection,
      message_resource: Samen.WebTest.Mailbox.MailMessage
    }

    {:ok, connection} = Mailbox.connect(%{user_id: Ash.UUID.generate(), address: "rep@ourco.test"}, cfg)
    connection
  end

  # -- DB-state readers (system context) ----------------------------------------------------------------------

  defp all(resource, org_id, select) do
    resource
    |> Ash.Query.ensure_selected([:org_id | select])
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&(&1.org_id == org_id))
  end

  defp company_named(org_id, name),
    do: Enum.find(all(Samen.WebTest.Crm.Company, org_id, [:name, :archived_at, :custom]), &(&1.name == name))

  defp archived_company(org_id, name) do
    archived =
      Samen.WebTest.Crm.Company
      |> Samen.Archival.archived_query()
      |> Ash.Query.ensure_selected([:org_id, :name, :archived_at])
      |> Ash.read!(authorize?: false)

    Enum.find(archived, &(&1.org_id == org_id and &1.name == name))
  end

  defp tasks(org_id), do: all(Samen.WebTest.Work.Task, org_id, [:title, :status, :archived_at])
  defp projects(org_id), do: all(Samen.WebTest.Work.Project, org_id, [:name, :archived_at])
  defp enrollments(org_id), do: all(Samen.WebTest.Outreach.Enrollment, org_id, [:status, :person_id])

  defp archived?(resource, org_id, field, value) do
    archived =
      resource
      |> Samen.Archival.archived_query()
      |> Ash.Query.ensure_selected([:org_id, field, :archived_at])
      |> Ash.read!(authorize?: false)

    Enum.any?(archived, &(&1.org_id == org_id and Map.get(&1, field) == value))
  end

  # -- every page acts as the RESOLVED role; a refusal is a state; an outage is an error state --------------------

  # `probe` reads what the page holds: positive while acting, empty once refused. `events` are sent while refused and
  # must be no-ops.
  defp pages(org_id) do
    company = company!(org_id, "Probe Co")
    person!(org_id, "Probe Person")
    open_opp!(org_id, "Probe Deal")
    task = task!(org_id, "Probe Task")
    project!(org_id, "Probe Project")
    connection!(org_id)

    [
      %{name: "CompanyLive", view: CompanyLive, path: "/crm/companies/:id", extra: %{"id" => company.id},
        probe: &(&1.assigns.company != nil), events: [{"delete_company", %{"id" => company.id}}, {"edit_company", %{}}]},
      %{name: "PipelineLive", view: PipelineLive, path: "/crm/pipeline", extra: %{},
        probe: &(&1.assigns.total_opps), events: [{"board_load_more", %{"key" => "x"}}, {"retry_load", %{}}]},
      %{name: "CalendarLive", view: CalendarLive, path: "/crm/calendar", extra: %{},
        probe: &(&1.assigns.total_opps), events: [{"retry_load", %{}}]},
      %{name: "DashboardLive", view: DashboardLive, path: "/crm/dashboard", extra: %{},
        probe: &(&1.assigns.dash.stats.companies), events: [{"retry_load", %{}}]},
      %{name: "ContactsGalleryLive", view: ContactsGalleryLive, path: "/crm/gallery", extra: %{},
        probe: &length(&1.assigns.page.items), events: [{"retry_load", %{}}]},
      %{name: "MailboxLive", view: MailboxLive, path: "/crm/mailbox", extra: %{},
        probe: &length(&1.assigns.connections), events: [{"connect", %{}}, {"retry_load", %{}}]},
      %{name: "SequencesLive", view: SequencesLive, path: "/crm/sequences", extra: %{},
        probe: &(&1.assigns.scope_mounted), events: [{"retry_load", %{}}]},
      %{name: "TasksLive", view: TasksLive, path: "/work", extra: %{},
        probe: &length(&1.assigns.page.items), events: [{"delete", %{"id" => task.id}}, {"new_task", %{}}]},
      %{name: "TaskLive", view: TaskLive, path: "/work/tasks/:id", extra: %{"id" => task.id},
        probe: &(&1.assigns.task != nil), events: [{"update_status", %{"status" => "completed"}}]},
      %{name: "ProjectsLive", view: ProjectsLive, path: "/work/projects", extra: %{},
        probe: &length(&1.assigns.projects), events: [{"new_project", %{}}]},
      %{name: "TimelineLive", view: TimelineLive, path: "/work/timeline", extra: %{},
        probe: &(&1.assigns.total_tasks), events: [{"retry_load", %{}}]},
      %{name: "TaskTreeLive", view: TaskTreeLive, path: "/work/tree", extra: %{},
        probe: &(&1.assigns.total_nodes), events: [{"retry_load", %{}}]}
    ]
  end

  test "every page of the CRM remainder and Work acts with the RESOLVED role, not :member", ctx do
    # one login per person: `POST /login` is rate limited
    logins = for who <- [:viewer, :member, :owner], into: %{}, do: {who, log_in(Map.fetch!(ctx, who))}

    for page <- pages(ctx.org_id), {who, role} <- [viewer: :viewer, member: :member, owner: :owner] do
      socket = live_socket(Map.fetch!(logins, who), page.view, page.path, ctx.org_id, page.extra)
      assert socket.assigns.actor_state == :ok, "#{page.name}"
      assert socket.assigns.acting_scope.actor.role == role, "#{page.name} acted as #{socket.assigns.acting_scope.actor.role}, not #{role}"
      assert socket.assigns.acting_scope.actor.resolved == true
      refute String.starts_with?(socket.assigns.acting_scope.actor.id, "broker:")
    end
  end

  test "a suspended member's open page is the denied state: nothing is read, and no event reads or writes", ctx do
    pages = pages(ctx.org_id)
    login = log_in(ctx.member)
    sockets = for page <- pages, do: {page, live_socket(login, page.view, page.path, ctx.org_id, page.extra)}

    # positive control: while the membership is active every page holds something
    for {page, socket} <- sockets do
      probe = page.probe.(socket)
      assert probe not in [nil, false, 0], "#{page.name}: nothing to read while acting (the control is vacuous)"
    end

    before_tasks = length(tasks(ctx.org_id))
    SpineAccounts.suspend!(ctx.member, ctx.org_id)

    for {page, socket} <- sockets do
      refused = params(page.view, socket, page.extra)
      assert refused.assigns.actor_state == :denied, page.name
      assert refused.assigns.acting_scope == nil, page.name
      assert page.probe.(refused) in [nil, false, 0], "#{page.name} still holds data after the denial"
      out = html(page.view, refused)
      assert out =~ ~s(id="actor-denied"), page.name
      refute out =~ "Probe Co" or out =~ "Probe Deal" or out =~ "Probe Task" or out =~ "Probe Project" or out =~ "Probe Person", page.name

      for {name, p} <- page.events do
        after_event = event(page.view, name, p, refused)
        assert after_event.assigns == refused.assigns, "#{page.name} #{name} changed the refused page"
      end
    end

    assert length(tasks(ctx.org_id)) == before_tasks
    refute archived?(Samen.WebTest.Work.Task, ctx.org_id, :title, "Probe Task")
    refute archived_company(ctx.org_id, "Probe Co")
    assert Enum.all?(tasks(ctx.org_id), &(&1.status != :completed))
  end

  test "a failed membership lookup is the UNAVAILABLE state on every page, never an empty page", ctx do
    pages = pages(ctx.org_id)
    login = log_in(ctx.member)

    for page <- pages do
      socket = live_socket(login, page.view, page.path, ctx.org_id, page.extra) |> break_identity()

      {refused, _log} =
        ExUnit.CaptureLog.with_log(fn -> params(page.view, socket, page.extra) end)

      assert refused.assigns.actor_state == :unavailable, page.name
      assert refused.assigns.acting_scope == nil, page.name
      assert page.probe.(refused) in [nil, false, 0], page.name
      out = html(page.view, refused)
      assert out =~ ~s(id="actor-unavailable"), page.name
      refute out =~ ~s(id="actor-denied")
      refute out =~ "Probe Co"
    end
  end

  # -- writes the policy reserves for member+ ----------------------------------------------------------------

  describe "CompanyLive writes" do
    defp company_socket(account, org_id, id), do: live_socket(log_in(account), CompanyLive, "/crm/companies/:id", org_id, %{"id" => id})

    test "a VIEWER cannot edit, delete, link or log activity on a company; a member and an owner can", ctx do
      company = company!(ctx.org_id, "Detail Co")
      before_tasks = length(tasks(ctx.org_id))

      viewer = company_socket(ctx.viewer, ctx.org_id, company.id)
      assert viewer.assigns.acting_scope.actor.role == :viewer

      viewer = event(CompanyLive, "edit_company", %{}, viewer)
      event(CompanyLive, "save_edit", %{"form" => %{"name" => "Viewer Renamed"}}, viewer)
      assert company_named(ctx.org_id, "Detail Co")
      refute company_named(ctx.org_id, "Viewer Renamed")

      viewer = event(CompanyLive, "link_billing_customer", %{"billing_customer_id" => Ash.UUID.generate()}, viewer)
      assert viewer.assigns.link_error == "Could not update the billing link."
      assert company_named(ctx.org_id, "Detail Co").custom in [nil, %{}]

      event(CompanyLive, "log_activity", %{"activity" => %{"kind" => "call", "title" => "Viewer call"}}, viewer)
      assert length(tasks(ctx.org_id)) == before_tasks

      viewer = event(CompanyLive, "delete_company", %{"id" => company.id}, viewer)
      refute archived_company(ctx.org_id, "Detail Co")
      assert viewer.assigns.delete_error == "Could not delete this company."

      # positive controls: the same calls as a member, then an owner
      member = company_socket(ctx.member, ctx.org_id, company.id)
      member = event(CompanyLive, "edit_company", %{}, member)
      event(CompanyLive, "save_edit", %{"form" => %{"name" => "Member Renamed"}}, member)
      assert company_named(ctx.org_id, "Member Renamed")

      member = company_socket(ctx.member, ctx.org_id, company.id)
      event(CompanyLive, "log_activity", %{"activity" => %{"kind" => "call", "title" => "Member call"}}, member)
      assert length(tasks(ctx.org_id)) == before_tasks + 1

      member = event(CompanyLive, "link_billing_customer", %{"billing_customer_id" => Ash.UUID.generate()}, member)
      assert member.assigns.link_error == nil

      owner = company_socket(ctx.owner, ctx.org_id, company.id)
      event(CompanyLive, "delete_company", %{"id" => company.id}, owner)
      assert archived_company(ctx.org_id, "Member Renamed")
    end
  end

  describe "Work writes" do
    test "a VIEWER cannot create or archive a task through the list; a member and an owner can", ctx do
      target = task!(ctx.org_id, "Existing Task")
      before = length(tasks(ctx.org_id))

      create = fn account, title ->
        socket = live_socket(log_in(account), TasksLive, "/work", ctx.org_id)
        socket = event(TasksLive, "new_task", %{}, socket)
        event(TasksLive, "save_new", %{"form" => %{"title" => title, "kind" => "task"}}, socket)
      end

      create.(ctx.viewer, "Viewer Task")
      assert length(tasks(ctx.org_id)) == before

      viewer = live_socket(log_in(ctx.viewer), TasksLive, "/work", ctx.org_id)
      assert viewer.assigns.acting_scope.actor.role == :viewer
      viewer = event(TasksLive, "delete", %{"id" => target.id}, viewer)
      refute archived?(Samen.WebTest.Work.Task, ctx.org_id, :title, "Existing Task")
      assert viewer.assigns.delete_error == "Could not archive this task."

      create.(ctx.member, "Member Task")
      create.(ctx.owner, "Owner Task")
      assert length(tasks(ctx.org_id)) == before + 2

      member = live_socket(log_in(ctx.member), TasksLive, "/work", ctx.org_id)
      event(TasksLive, "delete", %{"id" => target.id}, member)
      assert archived?(Samen.WebTest.Work.Task, ctx.org_id, :title, "Existing Task")
    end

    test "a VIEWER cannot change a task's status; a member can", ctx do
      task = task!(ctx.org_id, "Status Task")
      path = "/work/tasks/:id"

      viewer = live_socket(log_in(ctx.viewer), TaskLive, path, ctx.org_id, %{"id" => task.id})
      assert viewer.assigns.acting_scope.actor.role == :viewer
      viewer = event(TaskLive, "update_status", %{"status" => "completed"}, viewer)
      assert viewer.assigns.status_error == "Could not update status."
      assert Enum.find(tasks(ctx.org_id), &(&1.id == task.id)).status != :completed

      member = live_socket(log_in(ctx.member), TaskLive, path, ctx.org_id, %{"id" => task.id})
      event(TaskLive, "update_status", %{"status" => "completed"}, member)
      assert Enum.find(tasks(ctx.org_id), &(&1.id == task.id)).status == :completed
    end

    test "a VIEWER cannot create or archive a project; a member and an owner can", ctx do
      target = project!(ctx.org_id, "Existing Project")
      before = length(projects(ctx.org_id))

      create = fn account, name ->
        socket = live_socket(log_in(account), ProjectsLive, "/work/projects", ctx.org_id)
        socket = event(ProjectsLive, "new_project", %{}, socket)
        event(ProjectsLive, "save_new", %{"form" => %{"name" => name}}, socket)
      end

      create.(ctx.viewer, "Viewer Project")
      assert length(projects(ctx.org_id)) == before

      viewer = live_socket(log_in(ctx.viewer), ProjectsLive, "/work/projects", ctx.org_id)
      assert viewer.assigns.acting_scope.actor.role == :viewer
      viewer = event(ProjectsLive, "delete", %{"id" => target.id}, viewer)
      refute archived?(Samen.WebTest.Work.Project, ctx.org_id, :name, "Existing Project")
      assert viewer.assigns.delete_error == "Could not archive this project."

      create.(ctx.member, "Member Project")
      create.(ctx.owner, "Owner Project")
      assert length(projects(ctx.org_id)) == before + 2

      member = live_socket(log_in(ctx.member), ProjectsLive, "/work/projects", ctx.org_id)
      event(ProjectsLive, "delete", %{"id" => target.id}, member)
      assert archived?(Samen.WebTest.Work.Project, ctx.org_id, :name, "Existing Project")
    end
  end

  describe "SequencesLive enroll" do
    test "a VIEWER cannot enroll a contact into a sequence; a member and an owner can", ctx do
      sequence = sequence!(ctx.org_id, "Drip")
      contact = person!(ctx.org_id, "Enrollable")
      enroll = fn account -> fn ->
        socket = live_socket(log_in(account), SequencesLive, "/crm/sequences", ctx.org_id)
        event(SequencesLive, "enroll", %{"sequence_id" => sequence.id, "person_id" => contact.id}, socket)
      end end

      viewer = enroll.(ctx.viewer).()
      assert viewer.assigns.acting_scope.actor.role == :viewer
      assert enrollments(ctx.org_id) == []
      assert {:error, _} = viewer.assigns.enroll_notice

      member = enroll.(ctx.member).()
      assert {:ok, _} = member.assigns.enroll_notice
      assert length(enrollments(ctx.org_id)) == 1
      owner = enroll.(ctx.owner).()
      assert {:ok, _} = owner.assigns.enroll_notice
      assert length(enrollments(ctx.org_id)) == 2
    end

    test "a suspended member's open sequences page enrolls nothing", ctx do
      sequence = sequence!(ctx.org_id, "Drip")
      contact = person!(ctx.org_id, "Enrollable")
      enrollment!(ctx.org_id, sequence, person!(ctx.org_id, "Already"))
      socket = live_socket(log_in(ctx.member), SequencesLive, "/crm/sequences", ctx.org_id)
      assert length(socket.assigns.sequences) == 1 and length(socket.assigns.enrollments) == 1

      SpineAccounts.suspend!(ctx.member, ctx.org_id)
      socket = params(SequencesLive, socket, %{})
      assert socket.assigns.actor_state == :denied
      assert socket.assigns.sequences == [] and socket.assigns.enrollments == []

      socket = event(SequencesLive, "enroll", %{"sequence_id" => sequence.id, "person_id" => contact.id}, socket)
      assert length(enrollments(ctx.org_id)) == 1
      assert socket.assigns.enroll_notice == nil
    end
  end
end
