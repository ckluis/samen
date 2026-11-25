defmodule Samen.Web.TenantRoleSurfacesTest do
  @moduledoc """
  ADR-045 §4.4 residual (the `:member` default): a tenant surface acts with the role the signed-in
  person's ACTIVE membership resolves to, through ONE resolver (`Samen.Web.TenantActor`), never with
  `Plane.scope/2`'s fixed `:member`.

  Driven with a REAL spine login (`POST /login`), as `notifications_spine_session_test.exs` does.
  Every refusal is paired with a positive control (a member and an owner keep what they could do).

  Policy note (the map): across the blueprints no READ is role-gated (`OrgScope` only); the writes
  of CRM/Work/Tags/Docs/Locations are `RoleAtLeast :member`, billing/marketing/cms mostly `:admin`.
  So for the CSV and file-bytes surfaces viewer and member read identically; their role is pinned
  through the `:samen_acting_role` assign the controllers set.
  """
  use Samen.WebTest.DataCase, async: false

  import Phoenix.ConnTest

  require Ash.Query

  alias Samen.Auth.OrgActor
  alias Samen.Identity.Invite
  alias Samen.Identity.Register
  alias Samen.Web.CRM.CompaniesLive
  alias Samen.Web.CRM.ContactsLive
  alias Samen.Web.{Mount, TenantActor}
  alias Samen.Web.Settings.Reads
  alias Samen.WebTest.Operator, as: Op
  alias Samen.WebTest.SecurityHost

  @endpoint Samen.WebTest.SecurityEndpoint
  @password "correct horse battery staple"

  @labels %{
    otp_app: :samen_web_security_test_host,
    title: "Security Probe",
    authn: {:app_env, :samen_web_security_test_host, :auth_required?},
    authorized_orgs: {Samen.WebTest.SecurityHost, :authorized_org_ids, []},
    identity_namespace: Samen.WebTest.Operator
  }

  setup do
    prev = Application.get_env(SecurityHost.otp_app(), :auth_required?)
    prev_delivery = Application.get_env(:samen_core, :delivery_env)
    Application.put_env(:samen_core, :delivery_env, :test)
    SecurityHost.arm!()

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(SecurityHost.otp_app(), :auth_required?)
        v -> Application.put_env(SecurityHost.otp_app(), :auth_required?, v)
      end

      case prev_delivery do
        nil -> Application.delete_env(:samen_core, :delivery_env)
        v -> Application.put_env(:samen_core, :delivery_env, v)
      end
    end)

    owner = register!()
    member = accept_into!(owner, :member)
    viewer = accept_into!(owner, :viewer)
    %{owner: owner, member: member, viewer: viewer, org_id: owner.org.id}
  end

  # -- harness (the notifications_spine_session_test.exs pattern) ----------------------------

  defp register_mods,
    do: %{org: Op.Org, credential: Op.Credential, user: Op.User, membership: Op.Membership, auth_token: Op.AuthToken, repo: Samen.WebTest.Repo}

  defp invite_mods,
    do: %{invitation: Op.Invitation, credential: Op.Credential, user: Op.User, membership: Op.Membership, repo: Samen.WebTest.Repo}

  defp register! do
    attrs = %{
      org_name: "Role Co #{System.unique_integer([:positive])}",
      first_name: "Ada",
      last_name: "Lovelace",
      email: "role-#{System.unique_integer([:positive])}@example.test",
      password: @password
    }

    {:ok, result} = Register.register(attrs, register_mods())
    Map.put(result, :email, attrs.email)
  end

  defp accept_into!(host, role) do
    invitee = register!()

    owner_scope = %Samen.Scope{
      actor: %{id: host.user.id, org_id: host.org.id, role: :owner, verified?: true, kind: :tenant, plane: :tenant}
    }

    {:ok, _inv, raw_token} = Invite.create(invite_mods(), owner_scope, %{email: invitee.email, role: role})
    {:ok, _joined} = Invite.accept(invite_mods(), raw_token)
    invitee
  end

  defp log_in(account) do
    conn = post(build_conn(), "/login", %{"login" => %{"email" => account.email, "password" => @password}})
    assert redirected_to(conn)
    %{conn: recycle(conn), session: Plug.Conn.get_session(conn)}
  end

  defp live_socket(login, view, path, org_id, extra_params \\ %{})

  defp live_socket(%{session: login_session}, view, path, org_id, extra_params) do
    {_path, mount_session} =
      Samen.WebTest.SecurityRouter
      |> Phoenix.Router.routes()
      |> Enum.filter(&Map.has_key?(&1.metadata, :phoenix_live_view))
      |> Enum.map(fn r ->
        {_v, _a, _o, ls} = r.metadata.phoenix_live_view
        {r.path, get_in(ls, [:extra, :session])}
      end)
      |> Enum.find(fn {p, _} -> p == path end)

    session = Map.merge(login_session, mount_session)
    params = Map.merge(%{"org" => org_id}, extra_params)
    socket = %Phoenix.LiveView.Socket{} |> Phoenix.Component.assign(:__changed__, %{})
    socket = %{socket | assigns: Map.put(socket.assigns, :flash, %{})}
    {:cont, socket} = Samen.Web.TenantAuthz.on_mount(:require_tenant, params, session, socket)
    {:ok, socket} = view.mount(params, session, socket)
    socket
  end

  defp suspend!(account, org_id) do
    {:ok, %{user_id: user_id}} =
      OrgActor.resolve(%{user: Op.User, membership: Op.Membership}, account.credential.id, org_id)

    [m] = Op.Membership |> Ash.Query.filter(user_id == ^user_id and org_id == ^org_id) |> Ash.read!(authorize?: false)
    m |> Ash.Changeset.for_update(:update, %{status: "suspended"}, authorize?: false) |> Ash.update!()
  end

  defp person_count(org_id) do
    Samen.WebTest.Crm.Person
    |> Ash.Query.ensure_selected([:org_id])
    |> Ash.read!(authorize?: false)
    |> Enum.count(&(&1.org_id == org_id))
  end

  defp company_count(org_id) do
    Samen.WebTest.Crm.Company
    |> Ash.Query.ensure_selected([:org_id])
    |> Ash.read!(authorize?: false)
    |> Enum.count(&(&1.org_id == org_id))
  end

  # `Company` and `Person` writes are `RoleAtLeast :member` (the CRM blueprint).
  defp create_company(login, org_id) do
    socket = live_socket(login, CompaniesLive, "/crm/companies", org_id)
    {:noreply, socket} = CompaniesLive.handle_event("new_company", %{}, socket)
    {:noreply, socket} = CompaniesLive.handle_event("save_new", %{"form" => %{"name" => "Acme"}}, socket)
    socket
  end

  # -- (a) a write the policy reserves for member+ ----------------------------------------------

  test "a VIEWER cannot create a company through the list surface; a member and an owner can", ctx do
    before = company_count(ctx.org_id)

    create_company(log_in(ctx.viewer), ctx.org_id)
    assert company_count(ctx.org_id) == before

    # positive controls: the same surface, the same call, a member and an owner
    create_company(log_in(ctx.member), ctx.org_id)
    assert company_count(ctx.org_id) == before + 1
    create_company(log_in(ctx.owner), ctx.org_id)
    assert company_count(ctx.org_id) == before + 2
  end

  # `Person` writes are `RoleAtLeast :member` since authz-5 (they were OrgScope only: a viewer could create and delete contacts).
  defp create_contact(login, org_id, name) do
    socket = live_socket(login, ContactsLive, "/crm/contacts", org_id)
    {:noreply, socket} = ContactsLive.handle_event("new_contact", %{}, socket)
    {:noreply, socket} = ContactsLive.handle_event("save_new", %{"form" => %{"display_name" => name}}, socket)
    socket
  end

  test "a VIEWER cannot create or delete a contact through the list surface; a member and an owner can", ctx do
    before = person_count(ctx.org_id)

    create_contact(log_in(ctx.viewer), ctx.org_id, "Viewer Made")
    assert person_count(ctx.org_id) == before

    # positive controls: the same surface, the same calls, a member and an owner
    create_contact(log_in(ctx.member), ctx.org_id, "Member Made")
    create_contact(log_in(ctx.owner), ctx.org_id, "Owner Made")
    assert person_count(ctx.org_id) == before + 2

    target = person!(ctx.org_id, "Member Made")
    viewer_socket = live_socket(log_in(ctx.viewer), ContactsLive, "/crm/contacts", ctx.org_id)
    {:noreply, viewer_socket} = ContactsLive.handle_event("delete", %{"id" => target.id}, viewer_socket)
    refute person_archived?(ctx.org_id, "Member Made")
    assert viewer_socket.assigns.delete_error == "Could not delete this contact."

    member_socket = live_socket(log_in(ctx.member), ContactsLive, "/crm/contacts", ctx.org_id)
    {:noreply, _} = ContactsLive.handle_event("delete", %{"id" => target.id}, member_socket)
    assert person_archived?(ctx.org_id, "Member Made")
  end

  test "a VIEWER cannot restore an archived contact; a member can", ctx do
    seed_archived_person!(log_in(ctx.member), ctx.org_id, "Archived One")
    seed_archived_person!(log_in(ctx.member), ctx.org_id, "Archived Two")

    viewer = live_socket(log_in(ctx.viewer), ContactsLive, "/crm/contacts", ctx.org_id)
    viewer = list_event(viewer, "toggle_archived", %{})
    assert "Archived One" in archived_names(viewer)
    list_event(viewer, "restore", %{"id" => person!(ctx.org_id, "Archived One").id})
    assert person_archived?(ctx.org_id, "Archived One")

    member = live_socket(log_in(ctx.member), ContactsLive, "/crm/contacts", ctx.org_id)
    member = list_event(member, "toggle_archived", %{})
    list_event(member, "restore", %{"id" => person!(ctx.org_id, "Archived Two").id})
    refute person_archived?(ctx.org_id, "Archived Two")
  end

  # `SampleData.load/2` seeds through the system scope (a fixed `:member`): the person's own role is the gate, in ContactsLive.
  test "the sample-data offer is member+ only: a viewer's load_sample_data seeds nothing, a member's does", ctx do
    prev = Application.get_env(:samen_web, Samen.Web.SampleData)
    Application.put_env(:samen_web, Samen.Web.SampleData, env: :test)
    on_exit(fn -> if prev, do: Application.put_env(:samen_web, Samen.Web.SampleData, prev), else: Application.delete_env(:samen_web, Samen.Web.SampleData) end)
    assert Samen.Web.SampleData.enabled?()

    before = person_count(ctx.org_id)
    viewer = live_socket(log_in(ctx.viewer), ContactsLive, "/crm/contacts", ctx.org_id)
    {:noreply, viewer} = ContactsLive.handle_event("load_sample_data", %{}, viewer)
    assert viewer.assigns.sample_error == "Sample data is not available here."
    assert person_count(ctx.org_id) == before
    assert company_count(ctx.org_id) == 0

    member = live_socket(log_in(ctx.member), ContactsLive, "/crm/contacts", ctx.org_id)
    {:noreply, member} = ContactsLive.handle_event("load_sample_data", %{}, member)
    assert member.assigns.sample_error == nil
    assert person_count(ctx.org_id) == before + 3
    assert company_count(ctx.org_id) == 2
  end

  test "the list surface acts with the RESOLVED role, not :member", ctx do
    for {who, role} <- [viewer: :viewer, member: :member, owner: :owner] do
      socket = live_socket(log_in(Map.fetch!(ctx, who)), ContactsLive, "/crm/contacts", ctx.org_id)
      assert socket.assigns.acting_scope.actor.role == role
      assert socket.assigns.acting_scope.actor.resolved == true
    end
  end

  test "ARMED + no active membership: the list surface shows the honest denied state, never a default role", ctx do
    login = log_in(ctx.member)
    socket = live_socket(login, ContactsLive, "/crm/contacts", ctx.org_id)
    assert socket.assigns.actor_state == :ok

    suspend!(ctx.member, ctx.org_id)
    {:noreply, socket} = ContactsLive.handle_params(%{"org" => ctx.org_id}, "http://localhost/crm/contacts", socket)

    assert socket.assigns.actor_state == :denied
    html = Samen.WebTest.DataCase.render_html(ContactsLive, socket.assigns)
    assert html =~ ~s(id="actor-denied")
    refute html =~ "No contacts yet."
    before = person_count(ctx.org_id)
    {:noreply, _} = ContactsLive.handle_event("new_contact", %{}, socket)

    {:noreply, _} =
      ContactsLive.handle_event("save_new", %{"form" => %{"display_name" => "Ghost"}}, socket)

    assert person_count(ctx.org_id) == before
  end

  test "ARMED + a failed membership lookup is an ERROR state, never an empty page", ctx do
    login = log_in(ctx.member)

    socket = live_socket(login, ContactsLive, "/crm/contacts", ctx.org_id)
    broken = %{socket.assigns.samen_mount | labels: Map.put(socket.assigns.samen_mount.labels, :identity_namespace, Samen.WebTest.NoSuchIdentity)}
    socket = Phoenix.Component.assign(socket, :samen_mount, broken)
    {:noreply, socket} = ContactsLive.handle_params(%{"org" => ctx.org_id}, "http://localhost/crm/contacts", socket)

    assert socket.assigns.actor_state == :unavailable
    html = Samen.WebTest.DataCase.render_html(ContactsLive, socket.assigns)
    assert html =~ ~s(id="actor-unavailable")
    refute html =~ "No contacts yet."
  end

  # -- a denial leaves no stale list scope behind (authz-5 item 1) --------------------------------

  # Archived rows are hidden by the default read: look in the live set and in the `:archived` one.
  defp person!(org_id, name) do
    sel = [:org_id, :display_name, :archived_at]
    live = Samen.WebTest.Crm.Person |> Ash.Query.ensure_selected(sel) |> Ash.read!(authorize?: false)

    archived =
      Samen.WebTest.Crm.Person |> Samen.Archival.archived_query() |> Ash.Query.ensure_selected(sel) |> Ash.read!(authorize?: false)

    Enum.find(live ++ archived, &(&1.org_id == org_id and &1.display_name == name))
  end

  defp person_archived?(org_id, name), do: person!(org_id, name).archived_at != nil

  defp seed_archived_person!(login, org_id, name) do
    socket = live_socket(login, ContactsLive, "/crm/contacts", org_id)
    {:noreply, socket} = ContactsLive.handle_event("new_contact", %{}, socket)
    {:noreply, _} = ContactsLive.handle_event("save_new", %{"form" => %{"display_name" => name}}, socket)
    {:ok, _} = Samen.Archival.archive(person!(org_id, name), scope: socket.assigns.acting_scope)
    assert person_archived?(org_id, name)
  end

  # The `ListLive` hook, as the lifecycle runs it on a mounted socket (a harness socket has none).
  defp list_event(socket, event, params) do
    {:halt, socket} = Samen.Web.ListLive.on_event(event, params, socket)
    socket
  end

  defp archived_names(socket), do: Enum.map(socket.assigns.page.items, & &1.display_name)

  describe "ListLive after a denial" do
    test "a suspended member's open contacts page reads nothing and writes nothing", ctx do
      login = log_in(ctx.member)
      seed_archived_person!(login, ctx.org_id, "Open Person")
      seed_archived_person!(login, ctx.org_id, "Control Person")

      # positive control: while the membership is active the same two events DO read and write
      live = live_socket(login, ContactsLive, "/crm/contacts", ctx.org_id)
      live = list_event(live, "toggle_archived", %{})
      assert "Open Person" in archived_names(live) and "Control Person" in archived_names(live)
      list_event(live, "restore", %{"id" => person!(ctx.org_id, "Control Person").id})
      refute person_archived?(ctx.org_id, "Control Person")

      socket = live_socket(login, ContactsLive, "/crm/contacts", ctx.org_id)
      suspend!(ctx.member, ctx.org_id)
      {:noreply, socket} = ContactsLive.handle_params(%{"org" => ctx.org_id}, "http://localhost/crm/contacts", socket)
      assert socket.assigns.actor_state == :denied

      socket = list_event(socket, "toggle_archived", %{})
      assert socket.assigns.page.items == []
      socket = list_event(socket, "restore", %{"id" => person!(ctx.org_id, "Open Person").id})
      assert socket.assigns.page.items == []
      assert person_archived?(ctx.org_id, "Open Person")
    end

    test "a suspended member's open companies page reads nothing", ctx do
      login = log_in(ctx.member)
      create_company(login, ctx.org_id)

      live = live_socket(login, CompaniesLive, "/crm/companies", ctx.org_id)
      assert Enum.map(live.assigns.page.items, & &1.name) == ["Acme"]
      assert Enum.map(list_event(live, "list_retry", %{}).assigns.page.items, & &1.name) == ["Acme"]

      suspend!(ctx.member, ctx.org_id)
      {:noreply, live} = CompaniesLive.handle_params(%{"org" => ctx.org_id}, "http://localhost/crm/companies", live)
      assert live.assigns.actor_state == :denied

      for event <- ["toggle_archived", "list_retry", "filter", "sort", "paginate"] do
        refused = list_event(live, event, %{"filter" => "Acme", "field" => "name", "dir" => "next"})
        assert refused.assigns.page.items == [], "#{event} read after the denial"
      end
    end

    test "every list event on a denied page is a no-op", ctx do
      login = log_in(ctx.member)
      socket = live_socket(login, ContactsLive, "/crm/contacts", ctx.org_id)
      assert socket.assigns.samen_list_ctx.scope.actor.role == :member
      suspend!(ctx.member, ctx.org_id)
      {:noreply, socket} = ContactsLive.handle_params(%{"org" => ctx.org_id}, "http://localhost/crm/contacts", socket)
      assert socket.assigns.actor_state == :denied

      for event <- Samen.Web.ListLive.events() do
        refused = list_event(socket, event, %{"id" => Ash.UUID.generate(), "field" => "display_name", "dir" => "next", "action" => "x", "filter" => "a"})
        assert refused.assigns.page == socket.assigns.page
        assert refused.assigns.list_state == socket.assigns.list_state
      end
    end

    test "org A -> org B (denied): no further reads or writes of org A", ctx do
      uid = user_id(ctx.member, ctx.org_id)
      other = register!()
      SecurityHost.grant!(uid, [ctx.org_id, other.org.id])
      on_exit(&SecurityHost.revoke_all!/0)
      login = %{session: %{"samen_current_user" => uid}}

      seed_archived_person!(log_in(ctx.member), ctx.org_id, "Org A Person")
      socket = live_socket(login, ContactsLive, "/crm/contacts", ctx.org_id)
      assert socket.assigns.actor_state == :ok

      {:noreply, socket} = ContactsLive.handle_params(%{"org" => other.org.id}, "http://localhost/crm/contacts", socket)
      assert socket.assigns.org_id == other.org.id
      assert socket.assigns.actor_state == :denied

      socket = list_event(socket, "toggle_archived", %{})
      assert socket.assigns.page.items == []
      list_event(socket, "restore", %{"id" => person!(ctx.org_id, "Org A Person").id})
      assert person_archived?(ctx.org_id, "Org A Person")
    end
  end

  # -- every other surface that writes a Person (authz-5 round 3, item 1) -------------------------

  describe "Person writes through ContactLive, ImportLive and LeadsLive" do
    test "a VIEWER cannot edit or delete a contact on its detail page; a member can", ctx do
      create_contact(log_in(ctx.member), ctx.org_id, "Detail Target")
      id = person!(ctx.org_id, "Detail Target").id
      path = "/crm/contacts/:id"

      viewer = live_socket(log_in(ctx.viewer), Samen.Web.CRM.ContactLive, path, ctx.org_id, %{"id" => id})
      assert viewer.assigns.acting_scope.actor.role == :viewer
      {:noreply, viewer} = Samen.Web.CRM.ContactLive.handle_event("edit_contact", %{}, viewer)
      {:noreply, _} = Samen.Web.CRM.ContactLive.handle_event("save_edit", %{"form" => %{"display_name" => "Viewer Renamed"}}, viewer)
      assert person!(ctx.org_id, "Detail Target")
      refute person!(ctx.org_id, "Viewer Renamed")

      {:noreply, viewer} = Samen.Web.CRM.ContactLive.handle_event("delete_contact", %{"id" => id}, viewer)
      refute person_archived?(ctx.org_id, "Detail Target")
      assert viewer.assigns.delete_error == "Could not delete this contact."

      # positive controls: the same calls as a member
      member = live_socket(log_in(ctx.member), Samen.Web.CRM.ContactLive, path, ctx.org_id, %{"id" => id})
      {:noreply, member} = Samen.Web.CRM.ContactLive.handle_event("edit_contact", %{}, member)
      {:noreply, _} = Samen.Web.CRM.ContactLive.handle_event("save_edit", %{"form" => %{"display_name" => "Member Renamed"}}, member)
      assert person!(ctx.org_id, "Member Renamed")
      member = live_socket(log_in(ctx.member), Samen.Web.CRM.ContactLive, path, ctx.org_id, %{"id" => id})
      {:noreply, _} = Samen.Web.CRM.ContactLive.handle_event("delete_contact", %{"id" => id}, member)
      assert person_archived?(ctx.org_id, "Member Renamed")
    end

    test "a suspended member's open contact page reads nothing and writes nothing", ctx do
      create_contact(log_in(ctx.member), ctx.org_id, "Open Detail")
      id = person!(ctx.org_id, "Open Detail").id
      path = "/crm/contacts/:id"
      socket = live_socket(log_in(ctx.member), Samen.Web.CRM.ContactLive, path, ctx.org_id, %{"id" => id})
      assert socket.assigns.contact.id == id

      suspend!(ctx.member, ctx.org_id)

      {:noreply, socket} =
        Samen.Web.CRM.ContactLive.handle_params(%{"org" => ctx.org_id, "id" => id}, "http://localhost/crm/contacts/#{id}", socket)

      assert socket.assigns.actor_state == :denied
      assert socket.assigns.contact == nil
      html = Samen.WebTest.DataCase.render_html(Samen.Web.CRM.ContactLive, socket.assigns)
      assert html =~ ~s(id="actor-denied")
      {:noreply, socket} = Samen.Web.CRM.ContactLive.handle_event("delete_contact", %{"id" => id}, socket)
      refute person_archived?(ctx.org_id, "Open Detail")
      assert socket.assigns.acting_scope == nil
    end

    # `ImportLive.import_rows/2` is what the `import` event runs on the consumed upload (a harness socket has no upload).
    defp import_csv(account, resource, csv, org_id) do
      socket = live_socket(log_in(account), Samen.Web.Csv.ImportLive, "/csv/import/:resource", org_id, %{"resource" => resource})
      {:noreply, socket} = Samen.Web.Csv.ImportLive.handle_params(%{"org" => org_id, "resource" => resource}, "http://localhost/csv/import/#{resource}", socket)
      Samen.Web.Csv.ImportLive.import_rows(socket, csv)
    end

    test "a VIEWER cannot import Person rows or Company rows; a member can", ctx do
      org_id = ctx.org_id
      before_p = person_count(org_id)
      before_c = company_count(org_id)

      viewer_p = import_csv(ctx.viewer, "Person", "display_name\nCsv Viewer Person\n", org_id)
      assert person_count(org_id) == before_p
      assert viewer_p.assigns.report == nil or viewer_p.assigns.report.created == 0
      viewer_c = import_csv(ctx.viewer, "Company", "name\nCsv Viewer Co\n", org_id)
      assert company_count(org_id) == before_c
      assert viewer_c.assigns.report == nil or viewer_c.assigns.report.created == 0

      # positive controls: a member through the same two imports
      member_p = import_csv(ctx.member, "Person", "display_name\nCsv Member Person\n", org_id)
      assert member_p.assigns.report.created == 1
      assert person_count(org_id) == before_p + 1
      member_c = import_csv(ctx.member, "Company", "name\nCsv Member Co\n", org_id)
      assert member_c.assigns.report.created == 1
      assert company_count(org_id) == before_c + 1
    end

    test "the import page of a suspended member is the denied state and imports nothing", ctx do
      org_id = ctx.org_id
      login = log_in(ctx.member)
      socket = live_socket(login, Samen.Web.Csv.ImportLive, "/csv/import/:resource", org_id, %{"resource" => "Person"})
      assert socket.assigns.actor_state == :ok
      suspend!(ctx.member, org_id)
      path = "http://localhost/csv/import/Person"
      {:noreply, socket} = Samen.Web.Csv.ImportLive.handle_params(%{"org" => org_id, "resource" => "Person"}, path, socket)
      assert socket.assigns.actor_state == :denied
      html = Samen.WebTest.DataCase.render_html(Samen.Web.Csv.ImportLive, socket.assigns)
      assert html =~ ~s(id="actor-denied")
      refute html =~ ~s(id="csv-import-form")

      before = person_count(org_id)
      socket = Samen.Web.Csv.ImportLive.import_rows(socket, "display_name\nGhost\n")
      assert person_count(org_id) == before
      assert socket.assigns.report == nil
    end

    # The leads lens surfaces only LIVE Person rows, so its `restore` event can reach no archived row and a DB-state
    # check cannot tell a viewer from a member (restoring a live row is a no-op write). What decides who the event
    # acts as is the scope in the list context: the one every `restore`/`bulk` runs under. It must be the person's own.
    defp seed_lead!(org_id, name) do
      # the Tier-1 custom field must be registered before a value writes (re-defining it is fine)
      Samen.CustomFields.define_field(
        %{org_id: org_id, table_name: "swp_person", field_name: "lifecycle_stage", type: :string},
        Samen.WebTest.Repo
      )

      {:ok, person} =
        Samen.WebTest.Crm.Person
        |> Ash.Changeset.for_create(:create, %{org_id: org_id, display_name: name, custom: %{"lifecycle_stage" => "lead"}}, authorize?: false)
        |> Ash.create()

      {:ok, _} = Samen.Archival.archive(person, authorize?: false)
      person!(org_id, name)
    end

    defp leads_socket(account, org_id),
      do: live_socket(log_in(account), Samen.Web.Marketing.LeadsLive, "/marketing/leads", org_id)

    test "the leads lens writes as the person's own role: a viewer's list scope cannot restore, a member's can", ctx do
      archived = seed_lead!(ctx.org_id, "Lead One")
      assert archived.archived_at

      viewer = leads_socket(ctx.viewer, ctx.org_id)
      assert viewer.assigns.acting_scope.actor.role == :viewer
      assert viewer.assigns.samen_list_ctx.scope.actor.role == :viewer
      assert {:error, _} = Samen.Archival.restore(archived, scope: viewer.assigns.samen_list_ctx.scope)
      assert person_archived?(ctx.org_id, "Lead One")

      # positive control: the member's list scope restores the same row
      member = leads_socket(ctx.member, ctx.org_id)
      assert member.assigns.samen_list_ctx.scope.actor.role == :member
      assert {:ok, _} = Samen.Archival.restore(archived, scope: member.assigns.samen_list_ctx.scope)
      refute person_archived?(ctx.org_id, "Lead One")
    end

    test "a suspended member's open leads page reads nothing and keeps no list scope", ctx do
      seed_lead!(ctx.org_id, "Lead Open")
      socket = leads_socket(ctx.member, ctx.org_id)
      assert socket.assigns.samen_list_ctx.scope.actor.role == :member
      suspend!(ctx.member, ctx.org_id)

      {:noreply, socket} =
        Samen.Web.Marketing.LeadsLive.handle_params(%{"org" => ctx.org_id}, "http://localhost/marketing/leads", socket)

      assert socket.assigns.actor_state == :denied
      assert socket.assigns.acting_scope == nil
      assert socket.assigns.samen_list_ctx == nil
      assert socket.assigns.page.items == []
      html = Samen.WebTest.DataCase.render_html(Samen.Web.Marketing.LeadsLive, socket.assigns)
      assert html =~ ~s(id="actor-denied")
    end
  end

  # -- the shared resolver, in every posture ---------------------------------------------------

  describe "TenantActor.scope/3" do
    test "armed: viewer/member/owner resolve to their membership role and per-org user", ctx do
      for {who, role} <- [viewer: :viewer, member: :member, owner: :owner] do
        mount = Mount.new(:crm, Samen.WebTest.Crm, Samen.WebTest.Repo, labels: @labels)
        acct = Map.fetch!(ctx, who)
        assert {:ok, %Samen.Scope{actor: actor}} = TenantActor.scope(mount, ctx.org_id, {:credential, acct.credential.id})
        assert actor.role == role
        assert actor.org_id == ctx.org_id
        assert actor.plane == :tenant
        refute String.starts_with?(actor.id, "broker:")
      end
    end

    test "armed: legacy-session user resolves through the same membership lookup", ctx do
      mount = Mount.new(:crm, Samen.WebTest.Crm, Samen.WebTest.Repo, labels: @labels)
      {:ok, %{user_id: uid}} = OrgActor.resolve(%{user: Op.User, membership: Op.Membership}, ctx.viewer.credential.id, ctx.org_id)
      assert {:ok, %{actor: %{role: :viewer, id: ^uid}}} = TenantActor.scope(mount, ctx.org_id, {:user, uid})
    end

    test "armed: no principal, or no active membership -> :denied (never a default role)", ctx do
      mount = Mount.new(:crm, Samen.WebTest.Crm, Samen.WebTest.Repo, labels: @labels)
      assert TenantActor.scope(mount, ctx.org_id, :none) == :denied
      assert TenantActor.scope(mount, ctx.org_id, nil) == :denied
      assert TenantActor.scope(mount, ctx.org_id, {:credential, Ash.UUID.generate()}) == :denied
      suspend!(ctx.member, ctx.org_id)
      assert TenantActor.scope(mount, ctx.org_id, {:credential, ctx.member.credential.id}) == :denied
      # positive control: an active member still resolves
      assert {:ok, _} = TenantActor.scope(mount, ctx.org_id, {:credential, ctx.viewer.credential.id})
    end

    test "armed: a failed lookup is {:error, :unavailable}, never :denied nor a scope", ctx do
      mount = Mount.new(:crm, Samen.WebTest.Crm, Samen.WebTest.Repo, labels: Map.put(@labels, :identity_namespace, Samen.WebTest.NoSuchIdentity))
      assert TenantActor.scope(mount, ctx.org_id, {:credential, ctx.member.credential.id}) == {:error, :unavailable}
    end

    test "disarmed dev posture keeps the synthetic :member scope, exactly", ctx do
      SecurityHost.disarm!()
      mount = Mount.new(:crm, Samen.WebTest.Crm, Samen.WebTest.Repo, labels: @labels)
      assert {:ok, scope} = TenantActor.scope(mount, ctx.org_id, :none)
      assert scope == Mount.scope(mount, ctx.org_id)
      assert scope.actor.role == :member
      assert scope.actor.id == "broker:#{ctx.org_id}"
    end

    test "armed: a {:dev, id} principal is :denied (the dev leg is a disarmed-only posture)", ctx do
      mount = Mount.new(:crm, Samen.WebTest.Crm, Samen.WebTest.Repo, labels: @labels)
      uid = user_id(ctx.viewer, ctx.org_id)

      assert TenantActor.scope(mount, ctx.org_id, {:dev, uid}) == :denied
      assert TenantActor.access(mount, ctx.org_id, {:dev, uid}, :admin) == {:refused, :denied}

      # positive control: the same person as a real principal resolves; disarmed, the dev leg still acts
      assert {:ok, %{actor: %{role: :viewer}}} = TenantActor.scope(mount, ctx.org_id, {:user, uid})
      SecurityHost.disarm!()
      assert {:ok, %{actor: %{role: :member}}} = TenantActor.scope(mount, ctx.org_id, {:dev, uid})
    end

    test "armed: a socket that never ran the tenant gate (no pinned ref) is :denied, never the fixed :member", ctx do
      mount = Mount.new(:crm, Samen.WebTest.Crm, Samen.WebTest.Repo, labels: @labels)
      assert TenantActor.socket_scope(%{assigns: %{samen_mount: mount}}, ctx.org_id) == :denied

      # positive controls: a pinned principal resolves; a pinned :none is denied; disarmed keeps the dev posture
      pinned = %{assigns: %{samen_mount: mount, samen_principal_ref: {:credential, ctx.viewer.credential.id}}}
      assert {:ok, %{actor: %{role: :viewer}}} = TenantActor.socket_scope(pinned, ctx.org_id)
      assert TenantActor.socket_scope(%{assigns: %{samen_mount: mount, samen_principal_ref: :none}}, ctx.org_id) == :denied

      SecurityHost.disarm!()
      assert {:ok, %{actor: %{role: :member}}} = TenantActor.socket_scope(%{assigns: %{samen_mount: mount}}, ctx.org_id)
    end

    test "a session with BOTH keys: the org and the role come from the SAME key (the legacy key, as authorized_orgs orders them)", ctx do
      mount = Mount.new(:crm, Samen.WebTest.Crm, Samen.WebTest.Repo, labels: @labels)
      legacy_uid = user_id(ctx.member, ctx.org_id)
      %{session: spine} = log_in(ctx.viewer)
      both = Map.put(spine, "samen_current_user", legacy_uid)

      # the legacy seam authorizes the org: it supplies the org AND the principal (a member), not the viewer's credential
      SecurityHost.grant!(legacy_uid, [ctx.org_id])
      on_exit(&SecurityHost.revoke_all!/0)
      assert Samen.Web.CurrentOrg.authorized_orgs(mount, both) == [ctx.org_id]
      assert Reads.principal_ref(mount, %{}, both) == {:user, legacy_uid}
      assert TenantActor.conn_ref(mount, %{}, both) == {:user, legacy_uid}

      # the legacy seam authorizes NOTHING: the org comes from the spine, so does the principal (the viewer)
      SecurityHost.revoke_all!()
      assert ctx.org_id in Samen.Web.CurrentOrg.authorized_orgs(mount, both)
      assert {:credential, cred} = Reads.principal_ref(mount, %{}, both)
      assert cred == ctx.viewer.credential.id
    end

    test "ProfileLive with BOTH keys acts as one person: the user id and the role agree", ctx do
      legacy_uid = user_id(ctx.member, ctx.org_id)
      SecurityHost.grant!(legacy_uid, [ctx.org_id])
      on_exit(&SecurityHost.revoke_all!/0)
      %{session: spine} = log_in(ctx.viewer)
      both = %{session: Map.put(spine, "samen_current_user", legacy_uid)}

      socket = live_socket(both, Samen.Web.Settings.ProfileLive, "/settings/profile", ctx.org_id)
      assert socket.assigns.user_id == legacy_uid
      assert socket.assigns.acting_role == :member

      # the legacy key authorizes nothing: the spine supplies the org, so the viewer is the person AND the role
      SecurityHost.revoke_all!()
      socket = live_socket(both, Samen.Web.Settings.ProfileLive, "/settings/profile", ctx.org_id)
      assert socket.assigns.user_id == user_id(ctx.viewer, ctx.org_id)
      assert socket.assigns.acting_role == :viewer
    end

    test "assign_actor/2 sets acting_scope and actor_state for every outcome, and nothing else decides them", ctx do
      mount = Mount.new(:crm, Samen.WebTest.Crm, Samen.WebTest.Repo, labels: @labels)

      socket = fn ref ->
        %Phoenix.LiveView.Socket{} |> Phoenix.Component.assign(samen_mount: mount, samen_principal_ref: ref)
      end

      # ok: the resolved scope, state :ok
      assert {:ok, ok} = TenantActor.assign_actor(socket.({:credential, ctx.viewer.credential.id}), ctx.org_id)
      assert ok.assigns.actor_state == :ok
      assert ok.assigns.acting_scope.actor.role == :viewer

      # denied: no scope, state :denied
      assert {:refused, denied} = TenantActor.assign_actor(socket.({:credential, Ash.UUID.generate()}), ctx.org_id)
      assert denied.assigns.actor_state == :denied
      assert denied.assigns.acting_scope == nil

      # a previous scope does not survive a refusal
      stale = Phoenix.Component.assign(ok, samen_principal_ref: :none)
      assert {:refused, refused} = TenantActor.assign_actor(stale, ctx.org_id)
      assert refused.assigns.acting_scope == nil

      # unavailable: no scope, state :unavailable
      broken = Mount.new(:crm, Samen.WebTest.Crm, Samen.WebTest.Repo, labels: Map.put(@labels, :identity_namespace, Samen.WebTest.NoSuchIdentity))
      sock = %Phoenix.LiveView.Socket{} |> Phoenix.Component.assign(samen_mount: broken, samen_principal_ref: {:credential, ctx.viewer.credential.id})
      assert {:refused, unavailable} = ExUnit.CaptureLog.with_log(fn -> TenantActor.assign_actor(sock, ctx.org_id) end) |> elem(0)
      assert unavailable.assigns.actor_state == :unavailable
      assert unavailable.assigns.acting_scope == nil
    end

    test "operator plane is unchanged", ctx do
      mount = Mount.new(:crm, Samen.WebTest.Crm, Samen.WebTest.Repo, labels: @labels, plane: Samen.Web.Plane.operator("op-1", ctx.org_id, "sess-1"))
      assert {:ok, scope} = TenantActor.scope(mount, ctx.org_id, :none)
      assert scope == Mount.scope(mount, ctx.org_id)
      assert scope.actor.plane == :operator
      assert scope.actor.role == :member
    end
  end

  # -- (c) CSV export + file bytes, called directly -------------------------------------------
  # These call the controllers with the mount set by hand: they prove the resolver the controllers use, not
  # the route. `files_csv_router_test.exs` drives the same requests through the real router and a real login.

  defp controller_conn(login, mount, org_id) do
    build_conn(:get, "/x?org=#{org_id}")
    |> Plug.Test.init_test_session(login.session)
    |> Map.put(:assigns, %{samen_mount: mount})
  end

  defp csv_mount(labels \\ @labels), do: Mount.new(:csv, Samen.WebTest.Crm, Samen.WebTest.Repo, labels: labels)

  # A LEGACY-session principal (`samen_current_user`) the host's `:authorized_orgs` seam grants the org:
  # the org resolves, so it is the membership lookup alone that decides the role (a suspended
  # spine member would simply fall back to its own org and never reach the surface).
  defp legacy_login(user_id, org_id) do
    SecurityHost.grant!(user_id, [org_id])
    on_exit(&SecurityHost.revoke_all!/0)
    %{session: %{"samen_current_user" => user_id}}
  end

  defp user_id(account, org_id) do
    {:ok, %{user_id: id}} = OrgActor.resolve(%{user: Op.User, membership: Op.Membership}, account.credential.id, org_id)
    id
  end

  defp csv(login, mount, org_id) do
    controller_conn(login, mount, org_id)
    |> Samen.Web.Csv.ExportController.export(%{"resource" => "Person", "org" => org_id})
  end

  defp bytes(login, mount, org_id, file_id) do
    controller_conn(login, mount, org_id)
    |> Samen.Web.Files.BytesController.serve(%{"id" => file_id, "org" => org_id})
  end

  # A REAL active file in `org_id` (uploaded through the chokepoint, promoted), so the controller reads a row
  # and serves its bytes: the role assertion is made on a served file, not on a 404 for a random id.
  defp active_file!(org_id) do
    root = Path.join(System.tmp_dir!(), "role_surfaces_files_#{System.unique_integer([:positive])}")
    prev = Application.get_env(:samen_core, Samen.Files, [])
    Application.put_env(:samen_core, Samen.Files, storage: Samen.Files.Storage.Local, storage_config: %{root: root})

    on_exit(fn ->
      File.rm_rf!(root)
      Application.put_env(:samen_core, Samen.Files, prev)
    end)

    {:ok, file} =
      Samen.Files.upload(
        %{org_id: org_id},
        %{filename: "role.txt", content_type: "text/plain", binary: "ROLE-BYTES"},
        file_module: Samen.WebTest.Primitives.File,
        repo: Samen.WebTest.Repo,
        storage: Samen.Files.Storage.Local,
        storage_config: %{root: root},
        allowed_content_types: ~w(text/plain),
        max_bytes: 1_048_576
      )

    {:ok, active} = file |> Ash.Changeset.for_update(:promote, %{}) |> Ash.update(authorize?: false)
    active
  end

  defp files_mount(labels \\ @labels), do: Mount.new(:files, Samen.WebTest.Primitives, Samen.WebTest.Repo, labels: labels)

  test "CSV export acts as the RESOLVED role (a viewer is a viewer, not a member)", ctx do
    for {who, role} <- [viewer: :viewer, member: :member, owner: :owner] do
      conn = csv(log_in(Map.fetch!(ctx, who)), csv_mount(), ctx.org_id)
      assert conn.status == 200
      assert conn.assigns[:samen_acting_role] == role
    end
  end

  test "CSV export: no active membership -> 403 (nothing exported); a failed lookup -> 503", ctx do
    uid = user_id(ctx.member, ctx.org_id)

    # positive control: the same legacy session while the membership is ACTIVE
    assert csv(legacy_login(uid, ctx.org_id), csv_mount(), ctx.org_id).assigns[:samen_acting_role] == :member

    suspend!(ctx.member, ctx.org_id)
    conn = csv(legacy_login(uid, ctx.org_id), csv_mount(), ctx.org_id)
    assert conn.status == 403
    refute conn.resp_body =~ "display_name"

    broken = csv_mount(Map.put(@labels, :identity_namespace, Samen.WebTest.NoSuchIdentity))
    conn = ExUnit.CaptureLog.with_log(fn -> csv(legacy_login(user_id(ctx.viewer, ctx.org_id), ctx.org_id), broken, ctx.org_id) end) |> elem(0)
    assert conn.status == 503
    refute conn.resp_body =~ "display_name"
  end

  test "file bytes act as the RESOLVED role and refuse no-membership / failed lookups", ctx do
    file = active_file!(ctx.org_id)

    for {who, role} <- [viewer: :viewer, member: :member, owner: :owner] do
      conn = bytes(log_in(Map.fetch!(ctx, who)), files_mount(), ctx.org_id, file.id)
      assert conn.assigns[:samen_acting_role] == role
      assert conn.status == 200
      assert conn.resp_body == "ROLE-BYTES"
    end

    uid = user_id(ctx.member, ctx.org_id)
    suspend!(ctx.member, ctx.org_id)
    conn = bytes(legacy_login(uid, ctx.org_id), files_mount(), ctx.org_id, file.id)
    assert conn.status == 403
    refute conn.resp_body =~ "ROLE-BYTES"
    refute Map.has_key?(conn.assigns, :samen_acting_role)

    broken = files_mount(Map.put(@labels, :identity_namespace, Samen.WebTest.NoSuchIdentity))
    conn = ExUnit.CaptureLog.with_log(fn -> bytes(legacy_login(user_id(ctx.viewer, ctx.org_id), ctx.org_id), broken, ctx.org_id, file.id) end) |> elem(0)
    assert conn.status == 503
    refute conn.resp_body =~ "ROLE-BYTES"
  end

  # -- profile ---------------------------------------------------------------------------------

  test "the profile surface acts with the resolved role", ctx do
    socket = live_socket(log_in(ctx.viewer), Samen.Web.Settings.ProfileLive, "/settings/profile", ctx.org_id)
    assert socket.assigns.acting_role == :viewer
    socket = live_socket(log_in(ctx.member), Samen.Web.Settings.ProfileLive, "/settings/profile", ctx.org_id)
    assert socket.assigns.acting_role == :member
    assert Reads.user_scope(socket.assigns.samen_mount, ctx.org_id, socket.assigns.user_id, :viewer).actor.role == :viewer
  end
end
