defmodule Samen.Web.TenantActorNavigationTest.ProbeLive do
  @moduledoc false
  # Resolves who acts in `handle_params`, like every converted page, and says when `actor_changed/1` runs.
  use Phoenix.LiveView

  def mount(params, session, socket) do
    socket = Samen.Web.Work.Live.assign_mount(socket, session)
    org_id = Samen.Web.CurrentOrg.resolve(socket.assigns[:samen_mount], params, session)
    {:ok, assign(socket, org_id: org_id)}
  end

  def handle_params(params, _uri, socket) do
    org_id = Samen.Web.CurrentOrg.reresolve(socket, params)
    {_status, socket} = Samen.Web.TenantActor.assign_actor(assign(socket, org_id: org_id), org_id)
    {:noreply, socket}
  end

  def actor_changed(socket) do
    send(self(), {:actor_changed, socket.assigns.acting_scope.actor.role})
    socket
  end

  def render(assigns), do: ~H""
end

defmodule Samen.Web.TenantActorNavigationTest do
  @moduledoc """
  authz-8 review, BLOCKER B1: a form built before a demotion or an organisation switch must never be submitted with the
  authority it was built with.

  The event guard (`Samen.Web.TenantActor.recheck_event/3`) compares the scope an event finds with the scope the page held.
  A `handle_params` between the demotion and the submit (a `live_patch`, back/forward, an `?org=` switch) used to replace
  the held scope with the fresh one WITHOUT telling the page, so the next event saw no change and the forms built with the
  old scope (and the Plans edit form, which was kept across loads) went out with it.

  Driven with a real `POST /login`, the real tenant gate, and `RoleHarness.navigate/3`, which delivers the navigation the
  way the channel does (the page's own `:handle_params` lifecycle hooks, then the view's `handle_params/3`). Every
  refusal is paired with a positive control; every assertion reads the database.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.Billing.PlansLive
  alias Samen.Web.Support.TicketsLive
  alias Samen.Web.Work.ProjectsLive
  alias Samen.WebTest.RoleHarness, as: H
  alias Samen.WebTest.SpineAccounts

  setup do
    H.setup_accounts()
  end

  defp plan!(org_id, name) do
    Samen.WebTest.Billing.Plan
    |> Ash.Changeset.for_create(:create, %{org_id: org_id, name: name, label: "Plan #{name}", interval: :monthly, enabled: true}, authorize?: false)
    |> Ash.create!()
  end

  defp rows(resource, org_id, select) do
    resource |> Ash.Query.ensure_selected([:org_id | select]) |> Ash.read!(authorize?: false) |> Enum.filter(&(&1.org_id == org_id))
  end

  defp plans(org_id), do: rows(Samen.WebTest.Billing.Plan, org_id, [:name, :label])
  defp names(org_id), do: org_id |> plans() |> Enum.map(& &1.name) |> Enum.sort()
  defp projects(org_id), do: rows(Samen.WebTest.Work.Project, org_id, [:name]) |> Enum.map(& &1.name)
  defp tickets(org_id), do: rows(Samen.WebTest.Support.Ticket, org_id, [:subject]) |> Enum.map(& &1.subject)

  defp edit_params(name), do: %{"form" => %{"name" => name, "label" => "Renamed", "interval" => "monthly"}}

  describe "the shared layer" do
    alias Samen.Web.TenantActorNavigationTest.ProbeLive

    test "a navigation that finds another role or another organisation runs actor_changed/1; an unchanged person does not", ctx do
      login = H.log_in(ctx.admin)
      open = H.open_socket(login, ProbeLive, "/work", ctx.org_id)
      refute_received {:actor_changed, _}

      # positive control the other way: nothing changed, nothing rebuilt
      open = H.navigate(ProbeLive, open)
      refute_received {:actor_changed, _}

      SpineAccounts.set_role!(ctx.admin, ctx.org_id, :member)
      open = H.navigate(ProbeLive, open)
      assert_received {:actor_changed, :member}
      assert open.assigns.acting_scope.actor.role == :member

      # and again with no change: the held scope is the fresh one, so there is nothing to follow
      H.navigate(ProbeLive, open)
      refute_received {:actor_changed, _}
    end

    test "an ?org= switch runs actor_changed/1 even when the role is the same", ctx do
      owner_b = SpineAccounts.register!()
      SpineAccounts.also_accept_into!(owner_b, ctx.admin, :admin)
      open = H.open_socket(H.log_in(ctx.admin), ProbeLive, "/work", ctx.org_id)
      refute_received {:actor_changed, _}

      switched = H.navigate(ProbeLive, open, %{"org" => owner_b.org.id})
      assert switched.assigns.org_id == owner_b.org.id
      assert_received {:actor_changed, :admin}
    end
  end

  describe "Plans: the edit form" do
    test "an admin demoted while the edit form is open cannot save it after a navigation; an unchanged admin can", ctx do
      keep = plan!(ctx.org_id, "keep")
      lose = plan!(ctx.org_id, "lose")
      login = H.log_in(ctx.admin)

      # positive control: still an admin, open the form, navigate, save
      open = H.open_socket(login, PlansLive, "/billing/plans", ctx.org_id)
      open = H.live_event(PlansLive, "edit_plan", %{"id" => lose.id}, open)
      open = H.navigate(PlansLive, open)
      assert open.assigns.show_edit
      H.live_event(PlansLive, "save_edit", edit_params("lose-renamed"), open)
      assert "lose-renamed" in names(ctx.org_id)

      # the demotion: the form is open, the role changes, a navigation happens, THEN the form is submitted
      open = H.open_socket(login, PlansLive, "/billing/plans", ctx.org_id)
      open = H.live_event(PlansLive, "edit_plan", %{"id" => keep.id}, open)
      assert open.assigns.can_admin
      SpineAccounts.set_role!(ctx.admin, ctx.org_id, :member)
      navigated = H.navigate(PlansLive, open)
      assert navigated.assigns.acting_scope.actor.role == :member
      refute navigated.assigns.can_admin

      after_save = H.live_event(PlansLive, "save_edit", edit_params("sneaky"), navigated)
      assert "keep" in names(ctx.org_id)
      refute "sneaky" in names(ctx.org_id)
      assert after_save.assigns.acting_scope.actor.role == :member
    end

    test "the edit form is built again from the page on every load, with the scope of the person acting now", ctx do
      keep = plan!(ctx.org_id, "keep")
      login = H.log_in(ctx.admin)
      open = H.open_socket(login, PlansLive, "/billing/plans", ctx.org_id)
      open = H.live_event(PlansLive, "edit_plan", %{"id" => keep.id}, open)
      stale = open.assigns.edit_form

      SpineAccounts.set_role!(ctx.admin, ctx.org_id, :member)
      navigated = H.navigate(PlansLive, open)
      refute navigated.assigns.edit_form == stale
      refute navigated.assigns.edit_form.source.opts[:scope] == stale.source.opts[:scope]
    end
  end

  describe "Plans: toggle_feature" do
    # The race itself (the role changing between the event guard's recheck and the handler's own load) cannot be driven
    # from a test. What is driven is its precondition: the handler is dispatched raw (`H.event/4`, no event guard) on a
    # socket still holding the admin scope after the person was demoted, so the handler's own load is the first thing to
    # see the new role. The invariant asserted: whatever the handler leaves open is built with the scope of the person
    # the page acts for NOW (`socket.assigns.acting_scope`), never the one it held when the handler began.
    test "the edit form it leaves open is built with the scope the page acts with after its own load", ctx do
      keep = plan!(ctx.org_id, "keep")
      login = H.log_in(ctx.admin)
      open = H.open_socket(login, PlansLive, "/billing/plans", ctx.org_id)
      open = H.live_event(PlansLive, "edit_plan", %{"id" => keep.id}, open)
      assert open.assigns.acting_scope.actor.role == :admin

      SpineAccounts.set_role!(ctx.admin, ctx.org_id, :member)
      toggled = H.event(PlansLive, "toggle_feature", %{"id" => keep.id, "feature" => "sso"}, open)

      assert toggled.assigns.acting_scope.actor.role == :member
      assert toggled.assigns.edit_plan_id == keep.id
      form_scope = toggled.assigns.edit_form.source.opts[:scope]
      assert form_scope.actor.role == :member
      assert form_scope == Samen.Web.TenantActor.write_scope(toggled.assigns.samen_mount, ctx.org_id, toggled.assigns.acting_scope)

      # positive control: nobody demoted -> the form is still there, built with the admin scope, and the toggle persisted
      admin = H.open_socket(login, PlansLive, "/billing/plans", ctx.org_id)
      SpineAccounts.set_role!(ctx.admin, ctx.org_id, :admin)
      admin = H.navigate(PlansLive, admin)
      admin = H.live_event(PlansLive, "edit_plan", %{"id" => keep.id}, admin)
      admin = H.live_event(PlansLive, "toggle_feature", %{"id" => keep.id, "feature" => "sso"}, admin)
      assert admin.assigns.edit_form.source.opts[:scope].actor.role == :admin
      assert admin.assigns.edit_plan_id == keep.id
    end
  end

  describe "two organisations" do
    test "an edit form opened in org A and submitted after an ?org=B switch writes nothing, in A or in B", ctx do
      org_a = ctx.org_id
      owner_b = SpineAccounts.register!()
      org_b = owner_b.org.id
      SpineAccounts.also_accept_into!(owner_b, ctx.admin, :member)
      plan_a = plan!(org_a, "plan-a")
      plan_b = plan!(org_b, "plan-b")
      login = H.log_in(ctx.admin)

      open = H.open_socket(login, PlansLive, "/billing/plans", org_a)
      assert open.assigns.can_admin
      open = H.live_event(PlansLive, "edit_plan", %{"id" => plan_a.id}, open)
      assert open.assigns.show_edit

      switched = H.navigate(PlansLive, open, %{"org" => org_b})
      assert switched.assigns.org_id == org_b
      assert switched.assigns.acting_scope.actor.role == :member

      H.live_event(PlansLive, "save_edit", edit_params("sneaky"), switched)
      assert names(org_a) == ["plan-a"]
      assert names(org_b) == ["plan-b"]
      assert switched.assigns.edit_form == nil

      # positive control: an admin in B (the same person promoted there) saves a form opened in B
      SpineAccounts.set_role!(ctx.admin, org_b, :admin)
      open_b = H.open_socket(H.log_in(ctx.admin), PlansLive, "/billing/plans", org_b)
      open_b = H.live_event(PlansLive, "edit_plan", %{"id" => plan_b.id}, open_b)
      H.live_event(PlansLive, "save_edit", edit_params("plan-b-renamed"), open_b)
      assert names(org_b) == ["plan-b-renamed"]
      assert names(org_a) == ["plan-a"]
    end
  end

  describe "other pages through the shared layer" do
    test "Work (projects): a member demoted to viewer with the create form open cannot save it after a navigation", ctx do
      login = H.log_in(ctx.member)

      open = H.open_socket(login, ProjectsLive, "/work/projects", ctx.org_id)
      open = H.live_event(ProjectsLive, "new_project", %{}, open)
      open = H.navigate(ProjectsLive, open)
      H.live_event(ProjectsLive, "save_new", %{"form" => %{"name" => "control"}}, open)
      assert "control" in projects(ctx.org_id)

      open = H.open_socket(login, ProjectsLive, "/work/projects", ctx.org_id)
      open = H.live_event(ProjectsLive, "new_project", %{}, open)
      SpineAccounts.set_role!(ctx.member, ctx.org_id, :viewer)
      navigated = H.navigate(ProjectsLive, open)
      assert navigated.assigns.acting_scope.actor.role == :viewer
      H.live_event(ProjectsLive, "save_new", %{"form" => %{"name" => "sneaky"}}, navigated)
      refute "sneaky" in projects(ctx.org_id)
    end

    test "Support (tickets): a member demoted to viewer with the create form open cannot save it after a navigation", ctx do
      login = H.log_in(ctx.member)
      params = fn subject -> %{"form" => %{"subject" => subject, "priority" => "normal"}} end

      open = H.open_socket(login, TicketsLive, "/support", ctx.org_id)
      open = H.live_event(TicketsLive, "new_ticket", %{}, open)
      open = H.navigate(TicketsLive, open)
      H.live_event(TicketsLive, "save_new", params.("control"), open)
      assert "control" in tickets(ctx.org_id)

      open = H.open_socket(login, TicketsLive, "/support", ctx.org_id)
      open = H.live_event(TicketsLive, "new_ticket", %{}, open)
      SpineAccounts.set_role!(ctx.member, ctx.org_id, :viewer)
      navigated = H.navigate(TicketsLive, open)
      assert navigated.assigns.acting_scope.actor.role == :viewer
      H.live_event(TicketsLive, "save_new", params.("sneaky"), navigated)
      refute "sneaky" in tickets(ctx.org_id)
    end
  end
end
