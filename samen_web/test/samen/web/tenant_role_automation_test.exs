defmodule Samen.Web.TenantRoleAutomationTest do
  @moduledoc """
  ADR-045 §4.4 residual (the `:member` default), the automation builder: it acts with the role the signed-in person's ACTIVE
  membership resolves to (`Samen.Web.TenantActor`), never `Plane.scope/2`'s fixed `:member`, and every write runs as that
  person.

  Driven with a REAL spine login (`POST /login`) and the REAL tenant gate (`Samen.WebTest.RoleHarness`); every refusal is
  paired with a positive control.

  Role choice: reading the workflows is open to every active member; every write (author, edit, pause or resume, run now, add
  or remove a condition or an action) is an admin's: a workflow acts on the organisation's behalf. The handler checks it itself
  and the controls are offered to an admin only.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.Automation.BuilderLive
  alias Samen.WebTest.Automation.Workflow
  alias Samen.WebTest.RoleHarness, as: H
  alias Samen.WebTest.SpineAccounts

  @path "/automation"

  setup do
    ctx = H.setup_accounts()

    wf =
      Workflow
      |> Ash.Changeset.for_create(
        :create,
        %{org_id: ctx.org_id, name: "zebra-workflow", status: :active, trigger_kind: :manual, conditions: [], actions: []},
        authorize?: false
      )
      |> Ash.create!()

    Map.put(ctx, :wf, wf)
  end

  defp html(socket), do: render_html(BuilderLive, socket.assigns)
  defp status(wf), do: Ash.get!(Workflow, wf.id, authorize?: false).status

  defp workflows(org_id) do
    Workflow
    |> Ash.Query.ensure_selected([:org_id, :name])
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&(&1.org_id == org_id))
  end

  defp page(ctx, role) do
    socket = H.live_socket(H.log_in(Map.fetch!(ctx, role)), BuilderLive, @path, ctx.org_id)
    H.params(BuilderLive, socket, %{})
  end

  test "the page acts with the RESOLVED role, not :member, and every role reads", ctx do
    for role <- [:viewer, :member, :admin, :owner] do
      socket = page(ctx, role)
      assert socket.assigns.actor_state == :ok
      assert socket.assigns.acting_scope.actor.role == role
      assert socket.assigns.acting_scope.actor.resolved == true
      assert html(socket) =~ "zebra-workflow", "#{role}: reads are open to every active member"
    end
  end

  test "only an admin is offered the controls; a viewer's and a member's crafted writes change nothing, an admin's do", ctx do
    for role <- [:viewer, :member] do
      socket = page(ctx, role)
      assert socket.assigns.can_admin == false
      out = html(socket)
      refute out =~ ~s(phx-click="toggle_pause")
      refute out =~ ~s(id="new-workflow-btn")

      socket = H.event(BuilderLive, "toggle_pause", %{"id" => ctx.wf.id}, socket)
      assert socket.assigns.wf_error =~ "admin"
      assert status(ctx.wf) == :active, "#{role} paused a workflow"

      socket = H.event(BuilderLive, "run_now", %{"id" => ctx.wf.id}, socket)
      assert socket.assigns.run_error =~ "admin"
      assert socket.assigns.run_ok == nil

      socket = H.event(BuilderLive, "new_workflow", %{}, socket)
      assert socket.assigns.edit_workflow == nil

      socket = H.event(BuilderLive, "save_workflow", %{"workflow" => %{"name" => "sneaky", "trigger_kind" => "manual"}}, socket)
      refute Enum.any?(workflows(ctx.org_id), &(&1.name == "sneaky")), "#{role} created a workflow"
      assert socket.assigns.edit_workflow == nil
    end

    admin = page(ctx, :admin)
    assert admin.assigns.can_admin == true
    assert html(admin) =~ ~s(phx-click="toggle_pause")
    admin = H.event(BuilderLive, "toggle_pause", %{"id" => ctx.wf.id}, admin)
    assert admin.assigns.wf_error == nil
    assert status(ctx.wf) == :paused

    admin = H.event(BuilderLive, "new_workflow", %{}, admin)
    assert admin.assigns.edit_workflow == :new
    H.event(BuilderLive, "save_workflow", %{"workflow" => %{"name" => "made by an admin", "trigger_kind" => "manual"}}, admin)
    assert Enum.any?(workflows(ctx.org_id), &(&1.name == "made by an admin"))
  end

  test "NAVIGATION: a suspended admin's page is the denied state: nothing is read, no event writes", ctx do
    socket = page(ctx, :admin)
    assert html(socket) =~ "zebra-workflow", "nothing to read while acting (vacuous control)"

    SpineAccounts.suspend!(ctx.admin, ctx.org_id)
    refused = H.params(BuilderLive, socket, %{})
    assert refused.assigns.actor_state == :denied
    assert refused.assigns.acting_scope == nil
    out = html(refused)
    assert out =~ ~s(id="actor-denied")
    refute out =~ "zebra-workflow"

    assert H.event(BuilderLive, "toggle_pause", %{"id" => ctx.wf.id}, refused).assigns == refused.assigns
    assert status(ctx.wf) == :active
  end

  test "a failed membership lookup is the UNAVAILABLE state, never an empty page", ctx do
    socket = H.live_socket(H.log_in(ctx.member), BuilderLive, @path, ctx.org_id) |> H.break_identity()
    {refused, _log} = ExUnit.CaptureLog.with_log(fn -> H.params(BuilderLive, socket, %{}) end)
    assert refused.assigns.actor_state == :unavailable
    assert html(refused) =~ ~s(id="actor-unavailable")
    refute html(refused) =~ "zebra-workflow"
  end

  test "OPEN PAGE: an admin demoted while the page is open writes nothing at the next event and the editor closes; an unchanged admin does", ctx do
    open = H.open_socket(H.log_in(ctx.admin), BuilderLive, @path, ctx.org_id)
    open = H.live_event(BuilderLive, "edit_workflow", %{"id" => ctx.wf.id}, open)
    assert open.assigns.edit_workflow != nil

    SpineAccounts.set_role!(ctx.admin, ctx.org_id, :member)
    demoted = H.live_event(BuilderLive, "toggle_pause", %{"id" => ctx.wf.id}, open)
    assert demoted.assigns.acting_scope.actor.role == :member
    refute demoted.assigns.can_admin
    assert demoted.assigns.edit_workflow == nil, "the editor opened as an admin is still open"
    assert status(ctx.wf) == :active

    # positive control: an unchanged admin's event on a fresh page
    SpineAccounts.set_role!(ctx.admin, ctx.org_id, :admin)
    fresh = H.open_socket(H.log_in(ctx.admin), BuilderLive, @path, ctx.org_id)
    H.live_event(BuilderLive, "toggle_pause", %{"id" => ctx.wf.id}, fresh)
    assert status(ctx.wf) == :paused
  end
end
