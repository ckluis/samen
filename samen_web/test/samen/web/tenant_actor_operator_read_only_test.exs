defmodule Samen.Web.TenantActorOperatorReadOnlyTest do
  @moduledoc """
  A tenant page rendered on the operator plane is read-only: an operator who opens a tenant's pages reads them (masked per
  the plane's masking rules) and does not write through them; acting in a tenant is what impersonation is for.

  Every event here is delivered as the channel delivers it (`RoleHarness.live_event/4`: the lifecycle hooks first, then the
  view), on a socket whose mount is the OPERATOR plane. Each refusal is paired with the same event from a tenant admin,
  which succeeds.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.Automation.BuilderLive
  alias Samen.Web.Billing.{InvoicesLive, PlansLive}
  alias Samen.Web.Chat.{ThreadLive, ThreadsLive}
  alias Samen.Web.Files.UploadLive
  alias Samen.Web.Onboarding.WizardLive
  alias Samen.Web.Settings.{ApiKeysLive, InvitationsLive, RevealApprovalsLive}
  alias Samen.Web.Marketing.{CampaignsLive, SegmentsLive}
  alias Samen.Web.Support.TicketLive
  alias Samen.Web.{Plane, TenantActor}
  alias Samen.WebTest.RoleHarness, as: H

  setup do
    H.setup_accounts()
  end

  # -- seeds (system context) ----------------------------------------------------------------------------------

  defp create!(resource, attrs) do
    resource |> Ash.Changeset.for_create(:create, attrs, authorize?: false) |> Ash.create!()
  end

  defp plan!(org_id, name),
    do: create!(Samen.WebTest.Billing.Plan, %{org_id: org_id, name: name, label: "Plan #{name}", interval: :monthly, enabled: true})

  defp customer!(org_id),
    do: create!(Samen.WebTest.Billing.Customer, %{org_id: org_id, billing_name: "Probe Customer Co", status: :active, provider_customer_ref: "cus_1"})

  defp invoice!(org_id) do
    create!(Samen.WebTest.Billing.Invoice, %{org_id: org_id, customer_id: customer!(org_id).id, status: :open, amount_due_cents: 1_000, currency: "USD"})
  end

  defp campaign!(org_id, name),
    do: create!(Samen.WebTest.Marketing.Campaign, %{org_id: org_id, name: name, description: "wave", status: :draft})

  defp segment!(org_id, name),
    do: create!(Samen.WebTest.Marketing.Segment, %{org_id: org_id, name: name, description: "all", filter_criteria: %{"status" => "active"}, subscriber_count: 1})

  defp ticket!(org_id, subject) do
    Samen.WebTest.Support.Ticket
    |> Ash.Changeset.for_create(:create, %{org_id: org_id, subject: subject, status: :open, priority: :normal}, authorize?: false)
    |> Ash.create!()
  end

  defp live(resource, id), do: Ash.get(resource, id, authorize?: false)
  defp archived(resource, id), do: resource |> Ash.Query.for_read(:archived) |> Ash.read!(authorize?: false) |> Enum.find(&(&1.id == id))

  # -- sockets -------------------------------------------------------------------------------------------------

  defp tenant_socket(ctx, view, path, extra \\ %{}), do: H.open_socket(H.log_in(ctx.admin), view, path, ctx.org_id, extra)

  # The same page, mounted on the OPERATOR plane over this org (an operator opening the tenant's pages).
  defp operator_socket(ctx, view, path, extra \\ %{}) do
    socket = tenant_socket(ctx, view, path, extra)
    mount = socket.assigns.samen_mount
    op = %{mount | plane: Plane.operator("op-1", ctx.org_id, "sess-1")}
    socket = Phoenix.Component.assign(socket, :samen_mount, op)
    socket = H.navigate(view, socket, extra)
    assert socket.assigns.acting_scope.actor.plane == :operator, "the socket is not on the operator plane (vacuous test)"
    socket
  end

  defp flash(socket), do: socket.assigns.flash |> Map.get("error")

  defp refused?(socket), do: is_binary(flash(socket)) and flash(socket) =~ "operator"

  # -- the writes ----------------------------------------------------------------------------------------------

  test "plans: toggle and delete from an operator socket write nothing; a tenant admin's do", ctx do
    keep = plan!(ctx.org_id, "kept-plan")
    gone = plan!(ctx.org_id, "gone-plan")
    path = "/billing/plans"

    op = operator_socket(ctx, PlansLive, path)
    op = H.live_event(PlansLive, "toggle_plan", %{"id" => keep.id}, op)
    assert refused?(op)
    op = H.live_event(PlansLive, "delete", %{"id" => gone.id}, op)
    assert refused?(op)
    assert {:ok, %{enabled: true}} = live(Samen.WebTest.Billing.Plan, keep.id)
    assert {:ok, _} = live(Samen.WebTest.Billing.Plan, gone.id)
    refute archived(Samen.WebTest.Billing.Plan, gone.id)

    # positive control: the same events from the tenant admin
    admin = tenant_socket(ctx, PlansLive, path)
    admin = H.live_event(PlansLive, "toggle_plan", %{"id" => keep.id}, admin)
    H.live_event(PlansLive, "delete", %{"id" => gone.id}, admin)
    assert {:ok, %{enabled: false}} = live(Samen.WebTest.Billing.Plan, keep.id)
    assert archived(Samen.WebTest.Billing.Plan, gone.id)
  end

  test "invoices: delete from an operator socket writes nothing; a tenant admin's does", ctx do
    invoice = invoice!(ctx.org_id)
    path = "/billing/invoices"

    op = H.live_event(InvoicesLive, "delete", %{"id" => invoice.id}, operator_socket(ctx, InvoicesLive, path))
    assert refused?(op)
    assert {:ok, _} = live(Samen.WebTest.Billing.Invoice, invoice.id)

    H.live_event(InvoicesLive, "delete", %{"id" => invoice.id}, tenant_socket(ctx, InvoicesLive, path))
    assert {:error, _} = live(Samen.WebTest.Billing.Invoice, invoice.id)
  end

  test "segments: delete from an operator socket writes nothing; a tenant admin's does", ctx do
    segment = segment!(ctx.org_id, "Zebra Segment")
    path = "/marketing/segments"

    op = H.live_event(SegmentsLive, "delete", %{"id" => segment.id}, operator_socket(ctx, SegmentsLive, path))
    assert refused?(op)
    refute archived(Samen.WebTest.Marketing.Segment, segment.id)

    H.live_event(SegmentsLive, "delete", %{"id" => segment.id}, tenant_socket(ctx, SegmentsLive, path))
    assert archived(Samen.WebTest.Marketing.Segment, segment.id)
  end

  test "campaigns: delete from an operator socket writes nothing; a tenant admin's does", ctx do
    campaign = campaign!(ctx.org_id, "Zebra Campaign")
    path = "/marketing/campaigns"

    op = H.live_event(CampaignsLive, "delete", %{"id" => campaign.id}, operator_socket(ctx, CampaignsLive, path))
    assert refused?(op)
    refute archived(Samen.WebTest.Marketing.Campaign, campaign.id)

    H.live_event(CampaignsLive, "delete", %{"id" => campaign.id}, tenant_socket(ctx, CampaignsLive, path))
    assert archived(Samen.WebTest.Marketing.Campaign, campaign.id)
  end

  test "ticket: a status change from an operator socket writes nothing; a tenant member's does", ctx do
    ticket = ticket!(ctx.org_id, "Probe Ticket")
    path = "/support/tickets/:id"
    extra = %{"id" => ticket.id}

    op = H.live_event(TicketLive, "set_status", %{"status" => "closed"}, operator_socket(ctx, TicketLive, path, extra))
    assert refused?(op)
    assert {:ok, %{status: :open}} = live(Samen.WebTest.Support.Ticket, ticket.id)

    H.live_event(TicketLive, "set_status", %{"status" => "closed"}, tenant_socket(ctx, TicketLive, path, extra))
    assert {:ok, %{status: :closed}} = live(Samen.WebTest.Support.Ticket, ticket.id)
  end

  test "list restore: an operator socket restores nothing; a tenant admin does", ctx do
    plan = plan!(ctx.org_id, "trash-plan")
    Ash.destroy!(plan, authorize?: false)
    assert archived(Samen.WebTest.Billing.Plan, plan.id)
    path = "/billing/plans"

    op = H.live_event(PlansLive, "toggle_archived", %{}, operator_socket(ctx, PlansLive, path))
    assert Enum.any?(op.assigns.page.items, &(&1.id == plan.id)), "the archived plan is listed (read still works on the operator plane)"
    op = H.live_event(PlansLive, "restore", %{"id" => plan.id}, op)
    assert refused?(op)
    assert archived(Samen.WebTest.Billing.Plan, plan.id)

    admin = H.live_event(PlansLive, "toggle_archived", %{}, tenant_socket(ctx, PlansLive, path))
    H.live_event(PlansLive, "restore", %{"id" => plan.id}, admin)
    refute archived(Samen.WebTest.Billing.Plan, plan.id)
  end

  # -- the read side -------------------------------------------------------------------------------------------

  test "an operator socket still reads the page and is offered no write control; the read events still work", ctx do
    plan!(ctx.org_id, "zebra-read")
    op = operator_socket(ctx, PlansLive, "/billing/plans")

    assert render_html(PlansLive, op.assigns) =~ "zebra-read"
    assert op.assigns.can_write == false
    assert op.assigns.can_admin == false

    # a read event is not refused
    op = H.live_event(PlansLive, "sort", %{"field" => "name"}, op)
    assert flash(op) == nil

    # positive control: the tenant admin's page offers the controls
    admin = tenant_socket(ctx, PlansLive, "/billing/plans")
    assert admin.assigns.can_admin == true
  end

  test "an operator ticket page masks the requester's PII as the plane always did (the read is unchanged)", ctx do
    ticket = ticket!(ctx.org_id, "Masked Read Ticket")
    op = operator_socket(ctx, TicketLive, "/support/tickets/:id", %{"id" => ticket.id})
    html = render_html(TicketLive, op.assigns)
    assert html =~ "Masked Read Ticket"
    refute html =~ ~r/vt_[a-z0-9]/
  end

  # -- the typed refusal at the scope --------------------------------------------------------------------------

  test "write_scope/3 on the operator plane is not an admin and says so", ctx do
    op = operator_socket(ctx, PlansLive, "/billing/plans")
    scope = TenantActor.write_scope(op.assigns.samen_mount, ctx.org_id, op.assigns.acting_scope)

    assert scope.actor.read_only == true
    refute Samen.Scope.Role.at_least?(scope.actor.role, :member)
    assert scope.actor.plane == :operator

    # positive control: a tenant admin's write scope is its acting scope, not read-only
    admin = tenant_socket(ctx, PlansLive, "/billing/plans")
    assert TenantActor.write_scope(admin.assigns.samen_mount, ctx.org_id, admin.assigns.acting_scope) == admin.assigns.acting_scope
  end

  # -- the automation, files, settings and onboarding pages ----------------------------------------------------

  test "automation: pause and run-now from an operator socket write nothing; a tenant admin's do", ctx do
    wf =
      Samen.WebTest.Automation.Workflow
      |> Ash.Changeset.for_create(
        :create,
        %{org_id: ctx.org_id, name: "op-probe", status: :active, trigger_kind: :manual, conditions: [], actions: []},
        authorize?: false
      )
      |> Ash.create!()

    status = fn -> Ash.get!(Samen.WebTest.Automation.Workflow, wf.id, authorize?: false).status end

    op = operator_socket(ctx, BuilderLive, "/automation")
    assert op.assigns.can_admin == false
    op = H.live_event(BuilderLive, "toggle_pause", %{"id" => wf.id}, op)
    assert refused?(op)
    op = H.live_event(BuilderLive, "run_now", %{"id" => wf.id}, op)
    assert refused?(op)
    assert op.assigns.run_ok == nil
    op = H.live_event(BuilderLive, "new_workflow", %{}, op)
    assert op.assigns.edit_workflow == nil
    # closing an editor persists nothing: a read event, not refused
    op = H.live_event(BuilderLive, "close_edit", %{}, Phoenix.LiveView.clear_flash(op))
    refute refused?(op)
    assert status.() == :active

    H.live_event(BuilderLive, "toggle_pause", %{"id" => wf.id}, tenant_socket(ctx, BuilderLive, "/automation"))
    assert status.() == :paused
  end

  test "files: an upload from an operator socket is refused; a tenant admin's reaches the upload", ctx do
    op = H.live_event(UploadLive, "upload", %{}, operator_socket(ctx, UploadLive, "/files"))
    assert refused?(op)
    assert op.assigns.upload_error == nil

    admin = H.live_event(UploadLive, "upload", %{}, tenant_socket(ctx, UploadLive, "/files"))
    assert admin.assigns.upload_error == "no file selected", "the admin's event reached the upload (positive control)"
  end

  test "settings: mint, invite and decide from an operator socket do nothing; a tenant admin's reach their handlers", ctx do
    op = H.live_event(ApiKeysLive, "mint", %{"key" => %{"read" => "1"}}, operator_socket(ctx, ApiKeysLive, "/settings/api-keys"))
    assert refused?(op)
    assert op.assigns.keys == [] and op.assigns.minted_key == nil

    admin = H.live_event(ApiKeysLive, "mint", %{"key" => %{"read" => "1"}}, tenant_socket(ctx, ApiKeysLive, "/settings/api-keys"))
    assert admin.assigns.minted_key != nil

    invite = %{"invitation" => %{"email" => "op-probe@example.test", "role" => "member"}}
    op = H.live_event(InvitationsLive, "invite", invite, operator_socket(ctx, InvitationsLive, "/settings/invitations"))
    assert refused?(op)
    assert op.assigns.invited_raw_token == nil

    admin = H.live_event(InvitationsLive, "invite", invite, tenant_socket(ctx, InvitationsLive, "/settings/invitations"))
    refute refused?(admin), "the tenant admin's event is not the operator refusal (positive control)"

    decide = %{"request" => Ash.UUID.generate()}
    path = "/settings/reveal-approvals"
    op = H.live_event(RevealApprovalsLive, "approve", decide, operator_socket(ctx, RevealApprovalsLive, path))
    assert refused?(op)
    assert op.assigns.decision_notice == nil

    admin = H.live_event(RevealApprovalsLive, "approve", decide, tenant_socket(ctx, RevealApprovalsLive, path))
    assert admin.assigns.decision_notice =~ "not in this org's pending queue", "the admin reached the queue check (positive control)"
  end

  test "onboarding: a wizard write from an operator socket is refused; a tenant admin's is accepted", ctx do
    name = %{"org" => %{"name" => "Renamed By An Operator"}}
    op = H.live_event(WizardLive, "name_org", name, operator_socket(ctx, WizardLive, "/onboarding"))
    assert refused?(op)
    refute op.assigns.step == :plan

    admin = H.live_event(WizardLive, "name_org", %{"org" => %{"name" => "Renamed By An Admin"}}, tenant_socket(ctx, WizardLive, "/onboarding"))
    assert admin.assigns.step == :plan
  end

  # -- chat on the operator desk (its own impersonation gate; no membership to resolve) -------------------------

  describe "chat on the operator desk" do
    setup ctx do
      chat = Seeds.seed_chat(ctx.org_id, disclosure_mode: :tenant_wide)
      session = open_impersonation!("op-1", ctx.org_id)
      on_exit(fn -> Samen.Impersonation.close(session.id) end)
      Map.put(ctx, :chat, chat)
    end

    defp chat_socket(view, plane, load_args) do
      mount =
        Samen.Web.Mount.new(:chat, Samen.WebTest.Chat, Samen.WebTest.Repo, plane: plane, labels: %{title: "Blue Ridge Logistics"})

      %Phoenix.LiveView.Socket{}
      |> Phoenix.Component.assign(:samen_mount, mount)
      |> Phoenix.Component.assign(:samen_acting_as, false)
      |> then(&%{&1 | assigns: Map.put(&1.assigns, :flash, %{})})
      |> then(&apply(view, :load, [&1 | load_args]))
    end

    defp chat_threads(org_id) do
      Samen.WebTest.Chat.ChatThread
      |> Ash.Query.ensure_selected([:org_id])
      |> Ash.read!(authorize?: false)
      |> Enum.count(&(&1.org_id == org_id))
    end

    defp chat_messages(thread_id) do
      Samen.WebTest.Chat.ChatMessage
      |> Ash.Query.ensure_selected([:thread_id])
      |> Ash.read!(authorize?: false)
      |> Enum.count(&(&1.thread_id == thread_id))
    end

    test "an operator-desk inbox starts no conversation and an operator-desk room posts no message; the tenant's do", ctx do
      op_plane = Plane.operator("op-1", ctx.org_id, "sess-1")
      threads = chat_threads(ctx.org_id)
      messages = chat_messages(ctx.chat.thread.id)

      inbox = chat_socket(ThreadsLive, op_plane, [ctx.org_id])
      assert inbox.assigns.can_write == false and inbox.assigns.can_admin == false
      {:noreply, inbox} = ThreadsLive.handle_event("new_conversation", %{"subject" => "from the desk"}, inbox)
      {:noreply, _inbox} = ThreadsLive.handle_event("toggle_disclosure", %{"expose_identity" => "off"}, inbox)
      assert chat_threads(ctx.org_id) == threads

      room = chat_socket(ThreadLive, op_plane, [ctx.org_id, ctx.chat.thread.id])
      {:noreply, _room} = ThreadLive.handle_event("send", %{"body" => "from the desk"}, room)
      assert chat_messages(ctx.chat.thread.id) == messages

      # positive control: the same events on the tenant plane
      tenant_inbox = chat_socket(ThreadsLive, Plane.tenant(), [ctx.org_id])
      {:noreply, _} = ThreadsLive.handle_event("new_conversation", %{"subject" => "from the tenant"}, tenant_inbox)
      assert chat_threads(ctx.org_id) == threads + 1

      tenant_room = chat_socket(ThreadLive, Plane.tenant(), [ctx.org_id, ctx.chat.thread.id])
      {:noreply, _} = ThreadLive.handle_event("send", %{"body" => "from the tenant"}, tenant_room)
      assert chat_messages(ctx.chat.thread.id) == messages + 1
    end
  end
end
