defmodule Samen.Web.ReadsHonestFailureP2Test do
  @moduledoc """
  WP6 phase 2 — "a failed read never renders as empty", for the rest of the tenant plane
  (Billing, Marketing, Work, Files, Chat, Notifications, Settings, Flags, Automation, AI, KB,
  Tags, ObjectRef, Onboarding, AccountHealth, tenant analytics) and "a failed write tells the
  user".

  Same shape as phase 1 (`Samen.Web.ReadsHonestFailureTest`): the read is made to FAIL through
  the real failure path (`inject_read_faults/1`, `Samen.Web.Reads.Guard`'s seam) and the screen
  must render the kit error state (generic, value-free copy), NOT its empty-state copy or its
  create CTA, stay alive, and recover on retry; paired with a POSITIVE CONTROL (a genuinely
  empty result still renders the real empty state).
  """
  use Samen.WebTest.DataCase, async: false

  import ExUnit.CaptureLog

  alias Samen.Web.ListLive

  # -- harness (same shape as phase 1) -------------------------------------------------------

  defp socket_for(module, mount, load_args, extra \\ []) do
    base =
      %Phoenix.LiveView.Socket{}
      |> Phoenix.Component.assign(:samen_mount, mount)
      |> Phoenix.Component.assign(:samen_acting_as, false)
      |> Phoenix.Component.assign(:return_to, nil)
      |> Phoenix.Component.assign(extra)

    apply(module, :load, [base | load_args])
  end

  defp html(module, socket), do: render_html(module, socket.assigns)

  defp event(module, socket, name, params \\ %{}) do
    {:noreply, socket} = module.handle_event(name, params, socket)
    socket
  end

  defp list_event(socket, name, params \\ %{}) do
    {:noreply, socket} = ListLive.handle_list_event(name, params, socket)
    socket
  end

  # Run `fun` (a screen load/event under an injected fault); the one-line failure log it emits is
  # swallowed (the log contract is asserted in reads_guard_test).
  defp failing(fun), do: fun |> with_log() |> elem(0)

  # The kit error state, value-free: never a vault token, never a field value.
  defp assert_error_state(html) do
    assert html =~ "error-state"
    assert html =~ ~s(role="alert")
    assert html =~ "Nothing was lost"
    refute html =~ "vt_"
  end

  defp refute_error_state(html), do: refute(html =~ "error-state")

  setup do
    seeded = Seeds.seed_all()

    %{
      org_id: seeded.org_id,
      campaign_id: seeded.marketing.campaign.id,
      segment_id: seeded.marketing.segment.id,
      template_id: seeded.marketing.template.id
    }
  end

  # ===========================================================================
  # ListLive default (audit F07, phase 2): an UNWIRED screen is honest at zero lines
  # ===========================================================================

  describe "ListLive default — a failed page shows the error with no per-screen wiring" do
    test "the Billing overview never passes `error=` to list_view, yet shows the error state", %{org_id: org_id} do
      alias Samen.Web.Billing.OverviewLive
      mount = build_mount(:billing)
      inject_read_faults([:billing_subscriptions_page])

      socket = failing(fn -> socket_for(OverviewLive, mount, [org_id]) end)
      rendered = html(OverviewLive, socket)

      assert_error_state(rendered)
      refute rendered =~ "No subscriptions yet."
      refute rendered =~ "empty-new-customer"
      assert socket.assigns.page.error == :unavailable

      clear_read_faults()
      socket = list_event(socket, "list_retry")
      rendered = html(OverviewLive, socket)
      refute_error_state(rendered)
      assert socket.assigns.page.error == nil
      assert rendered =~ "subscription-row"
    end
  end

  # ===========================================================================
  # Billing
  # ===========================================================================

  describe "Billing overview" do
    alias Samen.Web.Billing.OverviewLive

    test "a failed metric is an error tile, not $0.00; the other tiles and the list stay", %{org_id: org_id} do
      mount = build_mount(:billing)
      inject_read_faults([:billing_metric_mrr])

      socket = failing(fn -> socket_for(OverviewLive, mount, [org_id]) end)
      rendered = html(OverviewLive, socket)

      assert socket.assigns.metric_errors == [:mrr_cents]
      assert rendered =~ "metric-error"
      assert rendered =~ "subscription-row"
      refute_error_state(rendered)
    end

    test "masking: on the operator plane the error DOM prints no customer value and no token", %{org_id: org_id} do
      mount = build_mount(:billing, plane: :operator, target_org_id: org_id)
      inject_read_faults([:billing_subscriptions_page, :billing_metric_mrr])

      rendered = html(OverviewLive, failing(fn -> socket_for(OverviewLive, mount, [org_id]) end))

      assert_error_state(rendered)
      refute rendered =~ Seeds.customer_name()
      refute rendered =~ "pii_"
      # Non-vacuous: with the fault cleared the same page renders the masked rows.
      clear_read_faults()
      assert html(OverviewLive, socket_for(OverviewLive, mount, [org_id])) =~ "••••"
    end

    test "POSITIVE CONTROL: a genuinely empty org still renders the real empty state and its CTA" do
      rendered = html(OverviewLive, socket_for(OverviewLive, build_mount(:billing), [Ash.UUID.generate()]))
      assert rendered =~ "No subscriptions yet."
      assert rendered =~ "empty-new-customer"
      refute_error_state(rendered)
    end
  end

  describe "Billing invoices" do
    alias Samen.Web.Billing.InvoicesLive

    test "failed page read + failed metric + failed customer select each say so; retry recovers", %{org_id: org_id} do
      mount = build_mount(:billing)
      inject_read_faults([:billing_invoices_page, :billing_invoice_metric_paid, :billing_customers])

      socket = failing(fn -> socket_for(InvoicesLive, mount, [org_id]) end)
      socket = event(InvoicesLive, socket, "new_invoice")
      rendered = html(InvoicesLive, socket)

      assert_error_state(rendered)
      refute rendered =~ "No invoices yet."
      assert socket.assigns.metric_errors == [:paid]
      assert socket.assigns.customers_failed
      assert rendered =~ "metric-error"

      clear_read_faults()
      socket = event(InvoicesLive, socket, "retry_load")
      assert socket.assigns.metric_errors == []
      refute socket.assigns.customers_failed
    end

    test "POSITIVE CONTROL: no invoices is the real empty state" do
      rendered = html(InvoicesLive, socket_for(InvoicesLive, build_mount(:billing), [Ash.UUID.generate()]))
      assert rendered =~ "No invoices yet."
      refute_error_state(rendered)
    end
  end

  describe "Billing plans" do
    alias Samen.Web.Billing.PlansLive

    test "failed plans page → error state; a failed price read has its own error, the list stays", %{org_id: org_id} do
      mount = build_mount(:billing)
      inject_read_faults([:billing_plans_page])
      socket = failing(fn -> socket_for(PlansLive, mount, [org_id]) end)
      rendered = html(PlansLive, socket)
      assert_error_state(rendered)
      refute rendered =~ "No plans yet."

      clear_read_faults()
      inject_read_faults([:billing_prices_by_plan])
      socket = failing(fn -> socket_for(PlansLive, mount, [org_id]) end)
      rendered = html(PlansLive, socket)
      assert socket.assigns.section_errors == [:prices]
      assert rendered =~ "prices-error"
      assert rendered =~ "plan-row"
    end

    test "failed subscriptions/entitlements read → the entitlements modal says so, not 'No subscriptions'", %{org_id: org_id} do
      mount = build_mount(:billing)
      inject_read_faults([:billing_subscriptions])
      socket = failing(fn -> socket_for(PlansLive, mount, [org_id]) end)
      socket = event(PlansLive, socket, "open_ents")
      rendered = html(PlansLive, socket)

      assert rendered =~ "entitlements-error"
      refute rendered =~ "No subscriptions to entitle yet."
      clear_read_faults()
      rendered = html(PlansLive, event(PlansLive, socket, "retry_load"))
      refute rendered =~ "entitlements-error"
    end

    test "POSITIVE CONTROL: no plans is the real empty state" do
      rendered = html(PlansLive, socket_for(PlansLive, build_mount(:billing), [Ash.UUID.generate()]))
      assert rendered =~ "No plans yet."
      refute_error_state(rendered)
    end
  end

  describe "Billing usage and dunning" do
    alias Samen.Web.Billing.{DunningLive, UsageLive}

    test "usage: a failed read is the error state, not 'No metered usage yet.'; retry recovers", %{org_id: org_id} do
      mount = build_mount(:billing)
      inject_read_faults([:billing_usage])
      socket = failing(fn -> socket_for(UsageLive, mount, [org_id]) end)
      rendered = html(UsageLive, socket)

      assert_error_state(rendered)
      refute rendered =~ "No metered usage yet."

      clear_read_faults()
      rendered = html(UsageLive, event(UsageLive, socket, "retry_load"))
      refute_error_state(rendered)
      assert rendered =~ "No metered usage yet."
    end

    test "dunning: a failed input read is the error state with error tiles, not 'Nobody is behind'", %{org_id: org_id} do
      mount = build_mount(:billing)
      inject_read_faults([:billing_invoices])
      socket = failing(fn -> socket_for(DunningLive, mount, [org_id]) end)
      rendered = html(DunningLive, socket)

      assert_error_state(rendered)
      refute rendered =~ "Nobody is behind on payment."
      assert rendered =~ "metric-error"

      clear_read_faults()
      rendered = html(DunningLive, event(DunningLive, socket, "retry_load"))
      refute_error_state(rendered)
    end

    test "dunning masking: the operator-plane error DOM carries no customer value", %{org_id: org_id} do
      mount = build_mount(:billing, plane: :operator, target_org_id: org_id)
      inject_read_faults([:billing_invoices])
      rendered = html(DunningLive, failing(fn -> socket_for(DunningLive, mount, [org_id]) end))
      assert_error_state(rendered)
      refute rendered =~ Seeds.customer_name()
      refute rendered =~ "pii_"
    end
  end

  describe "Billing settings" do
    alias Samen.Web.Billing.SettingsLive

    defmodule ConfiguredProvider do
      @moduledoc false
      def configured?(_config), do: true
    end

    setup do
      Application.put_env(:samen_core, :billing_provider, {ConfiguredProvider, %{}})
      on_exit(fn -> Application.delete_env(:samen_core, :billing_provider) end)
      :ok
    end

    test "each section fails on its own: plans, customer, invoices", %{org_id: org_id} do
      mount = build_mount(:billing)
      inject_read_faults([:billing_plans_with_prices, :billing_customers, :billing_invoices_page])
      socket = failing(fn -> socket_for(SettingsLive, mount, [org_id]) end)
      rendered = html(SettingsLive, socket)

      assert Enum.sort(socket.assigns.section_errors) == [:customer, :invoices, :plans]
      assert_error_state(rendered)
      refute rendered =~ "No plans yet"
      refute rendered =~ "No invoices yet"
      refute rendered =~ "Available after your first subscription."

      clear_read_faults()
      socket = event(SettingsLive, socket, "retry_load")
      assert socket.assigns.section_errors == []
    end
  end

  # ===========================================================================
  # Marketing
  # ===========================================================================

  describe "Marketing campaigns / segments / leads (ListLive)" do
    alias Samen.Web.Marketing.{CampaignsLive, LeadsLive, SegmentsLive}

    test "campaigns: failed page → error state, not 'No campaigns yet.'; retry recovers; empty stays empty", %{org_id: org_id} do
      mount = build_mount(:marketing)
      assert html(CampaignsLive, socket_for(CampaignsLive, mount, [Ash.UUID.generate()])) =~ "No campaigns yet."

      inject_read_faults([:marketing_campaigns_page])
      socket = failing(fn -> socket_for(CampaignsLive, mount, [org_id]) end)
      rendered = html(CampaignsLive, socket)

      assert_error_state(rendered)
      refute rendered =~ "No campaigns yet."
      refute rendered =~ "empty-new-campaign"

      clear_read_faults()
      rendered = html(CampaignsLive, list_event(socket, "list_retry"))
      refute_error_state(rendered)
      assert rendered =~ Seeds.campaign_name()
    end

    test "segments: a failed page, a failed subscribers panel and failed suppression flags each say so", %{org_id: org_id} do
      mount = build_mount(:marketing)
      inject_read_faults([:marketing_segments_page])
      socket = failing(fn -> socket_for(SegmentsLive, mount, [org_id]) end)
      rendered = html(SegmentsLive, socket)
      assert_error_state(rendered)
      refute rendered =~ "No segments yet."
      assert rendered =~ "subscriber-row"

      clear_read_faults()
      inject_read_faults([:marketing_subscribers_page])
      socket = failing(fn -> socket_for(SegmentsLive, mount, [org_id]) end)
      rendered = html(SegmentsLive, socket)
      assert rendered =~ "subscribers-error"
      refute rendered =~ "No subscribers yet."
      refute rendered =~ "subscriber-row"

      # A failed suppression read must not paint every subscriber "not suppressed".
      clear_read_faults()
      inject_read_faults([:marketing_suppressed_ids])
      socket = failing(fn -> socket_for(SegmentsLive, mount, [org_id]) end)
      rendered = html(SegmentsLive, socket)
      assert rendered =~ "suppressions-error"
      assert rendered =~ "suppressed-unknown"
      assert rendered =~ "subscriber-row"

      clear_read_faults()
      rendered = html(SegmentsLive, event(SegmentsLive, socket, "retry_load"))
      refute rendered =~ "suppressions-error"
    end

    test "segments POSITIVE CONTROL: empty org → real empty states" do
      rendered = html(SegmentsLive, socket_for(SegmentsLive, build_mount(:marketing), [Ash.UUID.generate()]))
      assert rendered =~ "No segments yet."
      assert rendered =~ "No subscribers yet."
      refute_error_state(rendered)
    end

    test "masking: the operator-plane subscribers error DOM prints no email and no token", %{org_id: org_id} do
      mount = build_mount(:marketing, plane: :operator, target_org_id: org_id)
      inject_read_faults([:marketing_subscribers_page, :marketing_segments_page])
      rendered = html(SegmentsLive, failing(fn -> socket_for(SegmentsLive, mount, [org_id]) end))
      assert_error_state(rendered)
      refute rendered =~ "pii_"
      clear_read_faults()
      assert html(SegmentsLive, socket_for(SegmentsLive, mount, [org_id])) =~ "••••"
    end

    test "leads (never wired to :list_error): a failed first read shows the error, not the empty lens", %{org_id: org_id} do
      mount = build_mount(:marketing)
      inject_read_faults([:crm_leads_page])
      socket = failing(fn -> socket_for(LeadsLive, mount, [org_id]) end)
      rendered = html(LeadsLive, socket)

      assert_error_state(rendered)
      refute rendered =~ "No leads in the early funnel yet."

      clear_read_faults()
      refute_error_state(html(LeadsLive, list_event(socket, "list_retry")))
    end
  end

  describe "Marketing campaign detail" do
    alias Samen.Web.Marketing.CampaignLive

    test "a FAILED campaign read is the error state — not 'Campaign not found.'; 404 survives", %{org_id: org_id, campaign_id: campaign_id} do
      mount = build_mount(:marketing)
      inject_read_faults([:marketing_get_campaign])
      socket = failing(fn -> socket_for(CampaignLive, mount, [org_id, campaign_id]) end)
      rendered = html(CampaignLive, socket)

      assert_error_state(rendered)
      refute rendered =~ "Campaign not found."
      refute rendered =~ "campaign-header"

      clear_read_faults()
      rendered = html(CampaignLive, event(CampaignLive, socket, "retry_load"))
      refute_error_state(rendered)
      assert rendered =~ "campaign-header"

      for id <- [Ash.UUID.generate(), "not-a-uuid"] do
        rendered = html(CampaignLive, socket_for(CampaignLive, mount, [org_id, id]))
        assert rendered =~ "Campaign not found."
        refute_error_state(rendered)
      end
    end

    test "each pane fails on its own: compose selects, recipients, delivery", %{org_id: org_id, campaign_id: campaign_id} do
      mount = build_mount(:marketing)

      inject_read_faults([:marketing_templates])
      rendered = html(CampaignLive, failing(fn -> socket_for(CampaignLive, mount, [org_id, campaign_id]) end))
      assert rendered =~ "compose-error"
      assert rendered =~ "campaign-header"

      clear_read_faults()
      inject_read_faults([:marketing_segment_audience])
      rendered = html(CampaignLive, failing(fn -> socket_for(CampaignLive, mount, [org_id, campaign_id]) end))
      assert rendered =~ "audience-error"
      refute rendered =~ "No subscribers in the first segment yet."
      refute rendered =~ "recipient-row"

      clear_read_faults()
      inject_read_faults([:marketing_sends_for_campaign])
      rendered = html(CampaignLive, failing(fn -> socket_for(CampaignLive, mount, [org_id, campaign_id]) end))
      assert rendered =~ "delivery-error"
      refute rendered =~ "No sends yet."
    end

    test "masking: the operator-plane audience error DOM prints no email", %{org_id: org_id, campaign_id: campaign_id} do
      mount = build_mount(:marketing, plane: :operator, target_org_id: org_id)
      inject_read_faults([:marketing_segment_audience])
      rendered = html(CampaignLive, failing(fn -> socket_for(CampaignLive, mount, [org_id, campaign_id]) end))
      assert rendered =~ "audience-error"
      refute rendered =~ "pii_"
    end

    test "a send whose audience read fails tells the user, without printing an exception or a value",
         %{org_id: org_id, campaign_id: campaign_id, segment_id: segment_id, template_id: template_id} do
      mount = build_mount(:marketing)
      socket = socket_for(CampaignLive, mount, [org_id, campaign_id], org_id: org_id, send_results: nil, notice: nil)
      inject_read_faults([:marketing_get_segment])

      socket =
        failing(fn ->
          event(CampaignLive, socket, "send_campaign", %{"send" => %{"template_id" => template_id, "segment_id" => segment_id}})
        end)

      assert socket.assigns.notice =~ "Send failed: the segment could not be read"
      refute socket.assigns.notice =~ "not found"
      refute socket.assigns.notice =~ "InjectedFault"
      refute socket.assigns.notice =~ "injected read fault"
      assert socket.assigns.send_results == nil
    end
  end

  # ===========================================================================
  # Work
  # ===========================================================================

  describe "Work" do
    alias Samen.Web.Work.{ProjectsLive, TaskLive, TaskTreeLive, TasksLive, TimelineLive}
    alias Samen.WebTest.Work.{Project, Task}

    defp seed_work do
      org_id = Ash.UUID.generate()

      project =
        Project
        |> Ash.Changeset.for_create(:create, %{org_id: org_id, name: "Q3 Launch"})
        |> Ash.create!(authorize?: false)

      task =
        Task
        |> Ash.Changeset.for_create(:create, %{org_id: org_id, title: "Draft the launch brief", status: :in_progress, priority: :high, project_id: project.id})
        |> Ash.create!(authorize?: false)

      Task
      |> Ash.Changeset.for_create(:create, %{org_id: org_id, title: "Get stakeholder sign-off", status: :pending, parent_id: task.id})
      |> Ash.create!(authorize?: false)

      %{org_id: org_id, task: task}
    end

    test "tasks list: failed page → error state, not 'No tasks yet'; retry recovers; empty stays empty" do
      %{org_id: org_id} = seed_work()
      mount = build_mount(:work)
      assert html(TasksLive, socket_for(TasksLive, mount, [Ash.UUID.generate()])) =~ "empty-new-task"

      inject_read_faults([:work_tasks_page])
      socket = failing(fn -> socket_for(TasksLive, mount, [org_id]) end)
      rendered = html(TasksLive, socket)
      assert_error_state(rendered)
      refute rendered =~ "empty-new-task"
      refute rendered =~ "task-row"

      clear_read_faults()
      rendered = html(TasksLive, list_event(socket, "list_retry"))
      refute_error_state(rendered)
      assert rendered =~ "task-row"
    end

    test "task detail: a FAILED read is the error state, not 'Task not found.'; 404 survives; subtasks fail alone" do
      %{org_id: org_id, task: task} = seed_work()
      mount = build_mount(:work)

      inject_read_faults([:work_get_task])
      socket = failing(fn -> socket_for(TaskLive, mount, [org_id, task.id], org_id: org_id, task_id: task.id) end)
      rendered = html(TaskLive, socket)
      assert_error_state(rendered)
      refute rendered =~ "Task not found."
      refute rendered =~ "task-detail"

      clear_read_faults()
      rendered = html(TaskLive, event(TaskLive, socket, "retry_load"))
      refute_error_state(rendered)
      assert rendered =~ "task-detail"

      for id <- [Ash.UUID.generate(), "not-a-uuid"] do
        rendered = html(TaskLive, socket_for(TaskLive, mount, [org_id, id], org_id: org_id, task_id: id))
        assert rendered =~ "Task not found."
        refute_error_state(rendered)
      end

      inject_read_faults([:work_subtasks])
      rendered = html(TaskLive, failing(fn -> socket_for(TaskLive, mount, [org_id, task.id], org_id: org_id, task_id: task.id) end))
      assert rendered =~ "subtasks-error"
      assert rendered =~ "task-detail"
      refute rendered =~ "No subtasks."
    end

    test "projects: failed read → error state, not 'No projects yet.'" do
      %{org_id: org_id} = seed_work()
      mount = build_mount(:work)
      assert html(ProjectsLive, socket_for(ProjectsLive, mount, [Ash.UUID.generate()])) =~ "No projects yet."

      inject_read_faults([:work_projects])
      socket = failing(fn -> socket_for(ProjectsLive, mount, [org_id], org_id: org_id) end)
      rendered = html(ProjectsLive, socket)
      assert_error_state(rendered)
      refute rendered =~ "No projects yet."
      refute rendered =~ "new-project-modal"

      clear_read_faults()
      rendered = html(ProjectsLive, event(ProjectsLive, socket, "retry_load"))
      refute_error_state(rendered)
      assert rendered =~ "project-row"
    end

    test "timeline and tree: a failed board / walk is the error state with an error tile, not 'No tasks'" do
      %{org_id: org_id} = seed_work()
      mount = build_mount(:work)

      inject_read_faults([:work_tasks_timeline, :work_tasks_tree])
      tl = failing(fn -> socket_for(TimelineLive, mount, [org_id]) end)
      tr = failing(fn -> socket_for(TaskTreeLive, mount, [org_id]) end)

      for {mod, socket} <- [{TimelineLive, tl}, {TaskTreeLive, tr}] do
        rendered = html(mod, socket)
        assert_error_state(rendered)
        assert rendered =~ "metric-error"
        refute rendered =~ "No tasks"
      end

      clear_read_faults()
      refute_error_state(html(TimelineLive, event(TimelineLive, tl, "retry_load")))
      refute_error_state(html(TaskTreeLive, event(TaskTreeLive, tr, "retry_load")))
    end
  end

  # ===========================================================================
  # Files
  # ===========================================================================

  describe "Files" do
    alias Samen.Web.Files.{PreviewLive, UploadLive}

    defp seed_file!(org_id) do
      root = Path.join(System.tmp_dir!(), "p2_files_#{System.unique_integer([:positive])}")
      on_exit(fn -> Elixir.File.rm_rf!(root) end)

      {:ok, file} =
        Samen.Files.upload(
          %{org_id: org_id},
          %{filename: "secret-plan.txt", content_type: "text/plain", binary: "hello"},
          file_module: Samen.WebTest.Primitives.File,
          repo: Samen.WebTest.Repo,
          storage: Samen.Files.Storage.Local,
          storage_config: %{root: root},
          allowed_content_types: ~w(text/plain),
          max_bytes: 1_048_576
        )

      file
    end

    defp upload_stub(socket), do: %{socket | assigns: Map.put(socket.assigns, :uploads, %{file_upload: %{entries: [], errors: [], ref: "file_upload"}})}

    test "list: a failed page read is the error state, not 'No files yet.'; retry recovers" do
      org_id = Ash.UUID.generate()
      seed_file!(org_id)
      # The operator plane hides the upload form (which needs a real LiveView upload config).
      mount = build_mount(:files, plane: :operator, target_org_id: org_id)
      base = fn ->
        %Phoenix.LiveView.Socket{}
        |> Phoenix.Component.assign(:samen_mount, mount)
        |> Phoenix.Component.assign(:samen_acting_as, false)
        |> Phoenix.Component.assign(:return_to, nil)
        |> Phoenix.Component.assign(:org_id, org_id)
        |> Phoenix.Component.assign(upload_ref: :file_upload, upload_result: nil, upload_error: nil)
        |> upload_stub()
        |> UploadLive.load(org_id)
      end

      inject_read_faults([:files_page])
      socket = failing(base)
      rendered = html(UploadLive, socket)
      assert_error_state(rendered)
      refute rendered =~ "No files yet."
      # the error DOM prints no row value
      refute rendered =~ "secret-plan"

      clear_read_faults()
      socket = list_event(socket, "list_retry")
      rendered = html(UploadLive, socket)
      refute_error_state(rendered)
      assert rendered =~ "file-row"
    end

    test "preview: a FAILED read is the error state, not 'File not found'; 404 survives; retry recovers" do
      org_id = Ash.UUID.generate()
      file = seed_file!(org_id)
      mount = build_mount(:files)

      load = fn id ->
        %Phoenix.LiveView.Socket{}
        |> Phoenix.Component.assign(:samen_mount, mount)
        |> Phoenix.Component.assign(:samen_acting_as, false)
        |> Phoenix.Component.assign(:return_to, nil)
        |> Phoenix.Component.assign(:org_id, org_id)
        |> Phoenix.Component.assign(:file_id, id)
        |> Phoenix.Component.assign(:file, nil)
        |> Phoenix.Component.assign(:not_found, false)
        |> PreviewLive.load(org_id, id)
      end

      inject_read_faults([:files_get_file])
      socket = failing(fn -> load.(file.id) end)
      rendered = html(PreviewLive, socket)
      assert_error_state(rendered)
      refute rendered =~ "File not found"
      refute rendered =~ "file-preview-panel"

      clear_read_faults()
      rendered = html(PreviewLive, event(PreviewLive, socket, "retry_load"))
      refute_error_state(rendered)
      assert rendered =~ "file-metadata"

      for id <- [Ash.UUID.generate(), "not-a-uuid"] do
        rendered = html(PreviewLive, load.(id))
        assert rendered =~ "File not found"
        refute_error_state(rendered)
      end
    end
  end

  # ===========================================================================
  # Chat
  # ===========================================================================

  describe "Chat" do
    alias Samen.Web.Chat.{ThreadLive, ThreadsLive}

    setup %{org_id: org_id} do
      %{chat: Seeds.seed_chat(org_id, disclosure_mode: :tenant_wide)}
    end

    test "inbox: a failed threads read and a failed disclosure read each say so; empty stays empty", %{org_id: org_id, chat: chat} do
      mount = build_mount(:chat)
      assert html(ThreadsLive, socket_for(ThreadsLive, mount, [Ash.UUID.generate()], flash_note: nil)) =~ "No conversations yet."

      inject_read_faults([:chat_threads])
      socket = failing(fn -> socket_for(ThreadsLive, mount, [org_id], flash_note: nil) end)
      rendered = html(ThreadsLive, socket)
      assert_error_state(rendered)
      refute rendered =~ "No conversations yet."
      refute rendered =~ chat.thread.subject

      clear_read_faults()
      inject_read_faults([:chat_disclosure_setting])
      socket = failing(fn -> socket_for(ThreadsLive, mount, [org_id], flash_note: nil) end)
      rendered = html(ThreadsLive, socket)
      assert rendered =~ "disclosure-error"
      refute rendered =~ "expose-identity-toggle"
      assert rendered =~ chat.thread.subject

      clear_read_faults()
      rendered = html(ThreadsLive, event(ThreadsLive, socket, "retry_load"))
      assert rendered =~ "expose-identity-toggle"
    end

    test "room: a FAILED thread read is the error state, not 'Conversation not available.'; 404 survives", %{org_id: org_id, chat: chat} do
      mount = build_mount(:chat)
      inject_read_faults([:chat_get_thread])
      socket = failing(fn -> socket_for(ThreadLive, mount, [org_id, chat.thread.id], org_id: org_id, thread_id: chat.thread.id) end)
      rendered = html(ThreadLive, socket)
      assert_error_state(rendered)
      refute rendered =~ "Conversation not available."
      refute rendered =~ "CHAT-BODY-SENTINEL"

      clear_read_faults()
      rendered = html(ThreadLive, event(ThreadLive, socket, "retry_load"))
      refute_error_state(rendered)
      assert rendered =~ "CHAT-BODY-SENTINEL"

      for id <- [Ash.UUID.generate(), "not-a-uuid"] do
        rendered = html(ThreadLive, socket_for(ThreadLive, mount, [org_id, id], org_id: org_id, thread_id: id))
        assert rendered =~ "Conversation not available."
        refute_error_state(rendered)
      end
    end

    test "room: messages and participants fail on their own; the operator-plane error prints no body or name", %{org_id: org_id, chat: chat} do
      mount = build_mount(:chat)
      inject_read_faults([:chat_messages_window])
      rendered = html(ThreadLive, failing(fn -> socket_for(ThreadLive, mount, [org_id, chat.thread.id], org_id: org_id, thread_id: chat.thread.id) end))
      assert rendered =~ "messages-error"
      refute rendered =~ "CHAT-BODY-SENTINEL"
      assert rendered =~ "chat-composer"

      clear_read_faults()
      inject_read_faults([:chat_participants])
      rendered = html(ThreadLive, failing(fn -> socket_for(ThreadLive, mount, [org_id, chat.thread.id], org_id: org_id, thread_id: chat.thread.id) end))
      assert rendered =~ "participants-error"
      assert rendered =~ "CHAT-BODY-SENTINEL"
    end

    test "send: a refused post (no self participant) tells the sender instead of silently dropping it", %{org_id: org_id, chat: chat} do
      mount = build_mount(:chat)
      inject_read_faults([:chat_participants])
      socket = failing(fn -> socket_for(ThreadLive, mount, [org_id, chat.thread.id], org_id: org_id, thread_id: chat.thread.id) end)
      # `:flash` is a reserved assign: a real mounted socket carries it, a bare test socket does not.
      socket = %{socket | assigns: Map.put(socket.assigns, :flash, %{})}
      socket = failing(fn -> event(ThreadLive, socket, "send", %{"body" => "hello"}) end)
      assert socket.assigns.flash["error"] =~ "can't post"
      refute socket.assigns.flash["error"] =~ "Injected"
    end
  end

  # ===========================================================================
  # Notifications (PII-bearing: rendered_body is vault-routed)
  # ===========================================================================

  describe "Notifications" do
    alias Samen.Notifications.Engine
    alias Samen.Web.Notifications.{InboxLive, PreferencesLive}

    @body "P2-BODY-SENTINEL please review the attached contact record."

    setup %{org_id: org_id} do
      {:ok, notification} =
        Engine.notify(
          %{
            org_id: org_id,
            recipient_id: Ash.UUID.generate(),
            event_type: "crm.person.flagged",
            channel: :in_app,
            rendered_body: @body
          },
          notification_module: Samen.WebTest.Primitives.Notification,
          preference_module: Samen.WebTest.Primitives.NotificationPreference,
          repo: Samen.WebTest.Repo
        )

      %{notification: notification}
    end

    defp flashed(socket), do: %{socket | assigns: Map.put(socket.assigns, :flash, %{})}

    test "inbox: a failed page read is the error state, not 'No notifications yet.'; retry recovers; empty stays empty", %{org_id: org_id} do
      mount = build_mount(:notifications)
      assert html(InboxLive, socket_for(InboxLive, mount, [Ash.UUID.generate()])) =~ "No notifications yet."

      inject_read_faults([:notifications_page])
      socket = failing(fn -> socket_for(InboxLive, mount, [org_id]) end)
      rendered = html(InboxLive, socket)
      assert_error_state(rendered)
      refute rendered =~ "No notifications yet."
      refute rendered =~ "P2-BODY-SENTINEL"

      clear_read_faults()
      rendered = html(InboxLive, list_event(socket, "list_retry"))
      refute_error_state(rendered)
      assert rendered =~ "P2-BODY-SENTINEL"
    end

    test "inbox: a failed unread count is 'unavailable', never '0 unread'", %{org_id: org_id} do
      mount = build_mount(:notifications)
      inject_read_faults([:notifications_unread_count])
      socket = failing(fn -> socket_for(InboxLive, mount, [org_id]) end)
      rendered = html(InboxLive, socket)
      assert socket.assigns.unread_failed
      assert rendered =~ "notifications-unread-unavailable"
      assert rendered =~ "unread count unavailable"
      refute rendered =~ ~s(id="notifications-unread")
    end

    test "masking: the operator-plane error DOM prints no body, no person value and no token", %{org_id: org_id} do
      mount = build_mount(:notifications, plane: :operator, target_org_id: org_id)
      inject_read_faults([:notifications_page, :notifications_unread_count])
      rendered = html(InboxLive, failing(fn -> socket_for(InboxLive, mount, [org_id]) end))

      assert_error_state(rendered)
      refute rendered =~ "P2-BODY-SENTINEL"
      refute rendered =~ Seeds.contact_full_name()
      refute rendered =~ Seeds.contact_email()
      refute rendered =~ "pii_"
      # Non-vacuous: the same page, healthy, renders the masked row.
      clear_read_faults()
      healthy = html(InboxLive, socket_for(InboxLive, mount, [org_id]))
      assert healthy =~ "••••"
      refute healthy =~ "P2-BODY-SENTINEL"
    end

    test "mark_read / mark_all_read: a failed write tells the user, prints no error term, and applies nothing", %{org_id: org_id, notification: n} do
      mount = build_mount(:notifications)
      socket = socket_for(InboxLive, mount, [org_id]) |> flashed()
      assert socket.assigns.unread_count == 1

      inject_read_faults([:notifications_mark_read, :notifications_mark_all_read])
      failed = failing(fn -> event(InboxLive, socket, "mark_read", %{"id" => n.id}) end)
      assert failed.assigns.flash["error"] =~ "Couldn't mark that notification read."
      assert failed.assigns.flash["error"] =~ "Nothing was changed"
      refute failed.assigns.flash["error"] =~ "Injected"
      # nothing half-applied: the list re-read still shows it unread
      assert failed.assigns.unread_count == 1

      failed = failing(fn -> event(InboxLive, socket, "mark_all_read") end)
      assert failed.assigns.flash["error"] =~ "Couldn't mark all notifications read."
      assert failed.assigns.unread_count == 1

      clear_read_faults()
      ok = event(InboxLive, socket, "mark_read", %{"id" => n.id})
      assert ok.assigns.flash == %{}
      assert ok.assigns.unread_count == 0
    end

    test "preferences: a failed read is the error state, not the engine defaults; retry recovers", %{org_id: org_id} do
      mount = build_mount(:notifications)
      recipient = Ash.UUID.generate()
      healthy = html(PreferencesLive, socket_for(PreferencesLive, mount, [org_id, recipient]))
      assert healthy =~ "preferences-grid"

      inject_read_faults([:notifications_preferences])
      socket = failing(fn -> socket_for(PreferencesLive, mount, [org_id, recipient], org_id: org_id) end)
      rendered = html(PreferencesLive, socket)
      assert_error_state(rendered)
      refute rendered =~ "preferences-grid"

      clear_read_faults()
      rendered = html(PreferencesLive, event(PreferencesLive, socket, "retry_load"))
      refute_error_state(rendered)
      assert rendered =~ "preferences-grid"
    end

    test "preferences: a failed save tells the user and the grid shows what is really stored", %{org_id: org_id} do
      mount = build_mount(:notifications)
      recipient = Ash.UUID.generate()
      socket = socket_for(PreferencesLive, mount, [org_id, recipient], org_id: org_id, recipient_id: recipient) |> flashed()

      inject_read_faults([:notifications_set_preference])

      failed =
        failing(fn ->
          event(PreferencesLive, socket, "save", %{"_target" => ["prefs", "chat_mention__email"], "prefs" => %{"chat_mention__email" => "on"}})
        end)

      assert failed.assigns.flash["error"] =~ "Couldn't save that preference."
      row = Enum.find(failed.assigns.rows, &(&1.event_type == "chat_mention"))
      refute row.email
      refute row.explicit
    end
  end

  # ===========================================================================
  # Settings (profile, API keys, invitations, security, reveal approvals)
  # ===========================================================================

  describe "Settings" do
    alias Samen.Web.Settings.{ApiKeys, ApiKeysLive, InvitationsLive, ProfileLive, RevealApprovalsLive, SecurityLive}
    alias Samen.WebTest.Operator.{Membership, User}

    defp seed_member!(org_id, role) do
      user =
        User
        |> Ash.Changeset.for_create(:create, %{org_id: org_id, handle: "p2-#{role}", full_name: %Samen.Type.FullName{first: "P2Secret", last: "Person"}})
        |> Ash.create!(authorize?: false)

      Membership
      |> Ash.Changeset.for_create(:create, %{org_id: org_id, user_id: user.id, role: role})
      |> Ash.create!(authorize?: false)

      user
    end

    test "api keys: a failed list is the error state, not 'No API keys yet.'; retry recovers; empty stays empty" do
      org_id = Ash.UUID.generate()
      user = seed_member!(org_id, :admin)
      mount = build_mount(:settings)
      assert html(ApiKeysLive, socket_for(ApiKeysLive, mount, [org_id, user.id])) =~ "No API keys yet."

      inject_read_faults([:settings_api_keys])
      socket = failing(fn -> socket_for(ApiKeysLive, mount, [org_id, user.id]) end)
      rendered = html(ApiKeysLive, socket)
      assert_error_state(rendered)
      refute rendered =~ "No API keys yet."

      clear_read_faults()
      rendered = html(ApiKeysLive, event(ApiKeysLive, socket, "retry_load"))
      refute_error_state(rendered)
      assert rendered =~ "No API keys yet."
    end

    test "api keys: a failed REVOKE tells the user, the key stays active, nothing is half-applied" do
      org_id = Ash.UUID.generate()
      user = seed_member!(org_id, :admin)
      mount = build_mount(:settings)
      scope = %Samen.Scope{actor: %{id: user.id, org_id: org_id, role: :admin, kind: :tenant, plane: :tenant}}
      {:ok, membership} = Samen.Web.Settings.Reads.current_membership(mount, scope, user.id, org_id)

      {:ok, _raw, row} =
        ApiKeys.mint(mount, scope, membership_id: membership.id, minter_role: :admin, plane: :tenant, scopes: %{all: [:read]})

      socket = socket_for(ApiKeysLive, mount, [org_id, user.id]) |> Map.update!(:assigns, &Map.merge(&1, %{minted_key: nil}))

      inject_read_faults([:settings_api_key_revoke])
      failed = failing(fn -> event(ApiKeysLive, socket, "revoke", %{"id" => row.id}) end)
      rendered = html(ApiKeysLive, failed)
      assert rendered =~ "Couldn&#39;t revoke that key"
      assert rendered =~ "still active"
      refute rendered =~ "Injected"
      assert [%{revoked?: false}] = Enum.filter(failed.assigns.keys, &(&1.id == row.id))

      clear_read_faults()
      ok = event(ApiKeysLive, socket, "revoke", %{"id" => row.id})
      assert [%{revoked?: true}] = Enum.filter(ok.assigns.keys, &(&1.id == row.id))
      refute html(ApiKeysLive, ok) =~ "Couldn&#39;t revoke"
    end

    test "api keys: a failed MINT says nothing was created and never prints a key or an error term" do
      org_id = Ash.UUID.generate()
      user = seed_member!(org_id, :admin)
      mount = build_mount(:settings)
      socket = socket_for(ApiKeysLive, mount, [org_id, user.id])

      inject_read_faults([:settings_api_key_mint])
      failed = failing(fn -> event(ApiKeysLive, socket, "mint", %{"key" => %{}}) end)
      rendered = html(ApiKeysLive, failed)
      assert rendered =~ "Couldn&#39;t mint a key right now. Nothing was created"
      assert failed.assigns[:minted_key] == nil
      assert failed.assigns.keys == []
    end

    test "invitations: failed list is the error state; a failed revoke tells the user" do
      org_id = Ash.UUID.generate()
      user = seed_member!(org_id, :admin)
      mount = build_mount(:settings)
      base = fn -> socket_for(InvitationsLive, mount, [org_id, user.id]) |> Map.update!(:assigns, &Map.merge(&1, %{invite_error: nil, invited_raw_token: nil, samen_session: %{}})) end
      assert html(InvitationsLive, base.()) =~ "No invitations yet."

      inject_read_faults([:settings_invitations])
      socket = failing(base)
      rendered = html(InvitationsLive, socket)
      assert_error_state(rendered)
      refute rendered =~ "No invitations yet."

      clear_read_faults()
      inject_read_faults([:settings_invitation_revoke])
      failed = failing(fn -> event(InvitationsLive, base.(), "revoke", %{"id" => Ash.UUID.generate()}) end)
      assert html(InvitationsLive, failed) =~ "Couldn&#39;t revoke that invitation"
    end

    test "profile: a FAILED user read is the error state, not 'No user in context'; a failed save says so" do
      org_id = Ash.UUID.generate()
      user = seed_member!(org_id, :admin)
      mount = build_mount(:settings)

      inject_read_faults([:settings_get_user])
      socket = failing(fn -> socket_for(ProfileLive, mount, [org_id, user.id]) end)
      rendered = html(ProfileLive, socket)
      assert_error_state(rendered)
      refute rendered =~ "No user in context"
      refute rendered =~ "P2Secret"

      clear_read_faults()
      socket = event(ProfileLive, socket, "retry_load")
      rendered = html(ProfileLive, socket)
      refute_error_state(rendered)
      assert rendered =~ "settings-profile-form"

      socket = %{socket | assigns: Map.merge(socket.assigns, %{flash_ok: nil})}
      inject_read_faults([:settings_profile_update])
      failed = failing(fn -> event(ProfileLive, socket, "save", %{"profile" => %{"handle" => "renamed"}}) end)
      assert html(ProfileLive, failed) =~ "Couldn&#39;t save your profile. Nothing was changed"
    end

    test "security: failed impersonation-session and login-session reads are 'unavailable', never a clean record" do
      org_id = Ash.UUID.generate()
      user = seed_member!(org_id, :admin)
      mount = build_mount(:settings)

      inject_read_faults([:settings_security_sessions])
      rendered = html(SecurityLive, failing(fn -> socket_for(SecurityLive, mount, [org_id, user.id]) end))
      assert rendered =~ "security-sessions-unavailable"
      refute rendered =~ "No impersonation sessions recorded."
      refute rendered =~ "vt_"

      clear_read_faults()
      rendered = html(SecurityLive, socket_for(SecurityLive, mount, [org_id, user.id]))
      refute rendered =~ "security-sessions-unavailable"
      assert rendered =~ "No impersonation sessions recorded."
    end

    test "reveal approvals: a failed pending read / role lookup is the error state, not 'No pending reveal requests'" do
      org_id = Ash.UUID.generate()
      user = seed_member!(org_id, :admin)
      mount = build_mount(:settings)
      healthy = html(RevealApprovalsLive, socket_for(RevealApprovalsLive, mount, [org_id, user.id]))
      assert healthy =~ "No pending reveal requests for this org."

      inject_read_faults([:settings_reveal_pending])
      socket = failing(fn -> socket_for(RevealApprovalsLive, mount, [org_id, user.id]) end)
      rendered = html(RevealApprovalsLive, socket)
      assert_error_state(rendered)
      refute rendered =~ "No pending reveal requests"

      clear_read_faults()
      inject_read_faults([:settings_current_membership])
      rendered = html(RevealApprovalsLive, failing(fn -> socket_for(RevealApprovalsLive, mount, [org_id, user.id]) end))
      assert rendered =~ "role-error"
      refute rendered =~ "requires an admin role"

      clear_read_faults()
      rendered = html(RevealApprovalsLive, event(RevealApprovalsLive, socket, "retry_load"))
      refute_error_state(rendered)
    end
  end

  # ===========================================================================
  # Flags settings
  # ===========================================================================

  describe "Flags settings" do
    alias Samen.Web.Flags.SettingsLive
    alias Samen.WebTest.Primitives.FeatureFlag

    defp seed_flag!(org_id) do
      FeatureFlag
      |> Ash.Changeset.for_create(:create, %{org_id: org_id, name: "p2.checkout", enabled: true, rollout_pct: 100}, authorize?: false)
      |> Ash.create!()
    end

    test "a failed page read is the error state, not 'No feature flags yet.'; retry recovers; empty stays empty" do
      org_id = Ash.UUID.generate()
      seed_flag!(org_id)
      mount = build_mount(:flags)
      assert html(SettingsLive, socket_for(SettingsLive, mount, [Ash.UUID.generate()])) =~ "No feature flags yet."

      inject_read_faults([:flags_page])
      socket = failing(fn -> socket_for(SettingsLive, mount, [org_id]) end)
      rendered = html(SettingsLive, socket)
      assert_error_state(rendered)
      refute rendered =~ "No feature flags yet."

      clear_read_faults()
      rendered = html(SettingsLive, list_event(socket, "list_retry"))
      refute_error_state(rendered)
      assert rendered =~ "p2.checkout"
    end

    test "a failed WRITE (toggle) tells the user with value-free copy and changes nothing" do
      org_id = Ash.UUID.generate()
      flag = seed_flag!(org_id)
      mount = build_mount(:flags)
      socket = socket_for(SettingsLive, mount, [org_id])

      inject_read_faults([:flags_update])
      failed = failing(fn -> event(SettingsLive, socket, "toggle_flag", %{"id" => flag.id}) end)
      rendered = html(SettingsLive, failed)
      assert rendered =~ "couldn&#39;t save this flag change right now"
      refute rendered =~ "InjectedFault"
      refute rendered =~ "injected read fault"
      assert Ash.get!(FeatureFlag, flag.id, authorize?: false).enabled

      clear_read_faults()
      _ = event(SettingsLive, socket, "toggle_flag", %{"id" => flag.id})
      refute Ash.get!(FeatureFlag, flag.id, authorize?: false).enabled
    end

    test "a failed single-flag read while opening the editor is an error, not a silently absent modal" do
      org_id = Ash.UUID.generate()
      flag = seed_flag!(org_id)
      mount = build_mount(:flags)
      socket = socket_for(SettingsLive, mount, [org_id])

      inject_read_faults([:flags_get_flag])
      failed = failing(fn -> event(SettingsLive, socket, "edit_flag", %{"id" => flag.id}) end)
      assert failed.assigns.edit_flag == nil
      assert html(SettingsLive, failed) =~ "Nothing was lost"
    end
  end

  # ===========================================================================
  # Automation builder
  # ===========================================================================

  describe "Automation builder" do
    alias Samen.Web.Automation.BuilderLive
    alias Samen.WebTest.Automation.Workflow

    defp seed_workflow!(org_id) do
      Workflow
      |> Ash.Changeset.for_create(:create, %{org_id: org_id, name: "p2-flow", status: :active, trigger_kind: :manual, conditions: [], actions: []})
      |> Ash.create!(authorize?: false)
    end

    test "a failed page read is the error state, not the empty builder; retry recovers; empty stays empty" do
      org_id = Ash.UUID.generate()
      seed_workflow!(org_id)
      mount = build_mount(:automation)
      assert html(BuilderLive, socket_for(BuilderLive, mount, [Ash.UUID.generate()])) =~ "No workflows yet."

      inject_read_faults([:automation_workflows_page])
      socket = failing(fn -> socket_for(BuilderLive, mount, [org_id]) end)
      rendered = html(BuilderLive, socket)
      assert_error_state(rendered)
      refute rendered =~ "No workflows yet."
      refute rendered =~ "p2-flow"

      clear_read_faults()
      rendered = html(BuilderLive, list_event(socket, "list_retry"))
      refute_error_state(rendered)
      assert rendered =~ "p2-flow"
    end

    test "a failed single-workflow read is an error, never 'Workflow not found.'; nothing is written" do
      org_id = Ash.UUID.generate()
      wf = seed_workflow!(org_id)
      mount = build_mount(:automation)
      socket = socket_for(BuilderLive, mount, [org_id])

      inject_read_faults([:automation_get_workflow])
      paused = failing(fn -> event(BuilderLive, socket, "toggle_pause", %{"id" => wf.id}) end)
      rendered = html(BuilderLive, paused)
      assert rendered =~ "couldn&#39;t load this workflow right now"
      refute rendered =~ "Workflow not found."
      assert Ash.get!(Workflow, wf.id, authorize?: false).status == :active

      ran = failing(fn -> event(BuilderLive, socket, "run_now", %{"id" => wf.id}) end)
      assert ran.assigns.run_error =~ "Nothing was run"
      refute ran.assigns.run_error =~ "not found"

      clear_read_faults()
      gone = event(BuilderLive, socket, "run_now", %{"id" => Ash.UUID.generate()})
      assert gone.assigns.run_error == "Workflow not found."
    end
  end

  # ===========================================================================
  # AI screens
  # ===========================================================================

  describe "AI" do
    alias Samen.Web.AI.{AgentLive, CrmLive, SupportDraftLive}
    alias Samen.WebTest.AgentFixture

    defp ai_mount do
      Samen.Web.Mount.new(:ai, Samen.WebTest.Crm, Samen.WebTest.Repo,
        plane: Samen.Web.Plane.tenant(),
        labels: %{ai_crm_resource: Samen.WebTest.Crm.Person}
      )
    end

    test "agent runs: a failed list is the error state, not 'No agent runs yet'; retry recovers; empty stays empty" do
      org_id = Ash.UUID.generate()
      run = AgentFixture.run!(org_id, agent: "p2_triage", state: :running)
      mount = ai_mount()
      assert html(AgentLive, socket_for(AgentLive, mount, [Ash.UUID.generate()])) =~ "No agent runs yet"

      inject_read_faults([:ai_agent_runs])
      socket = failing(fn -> socket_for(AgentLive, mount, [org_id]) end)
      rendered = html(AgentLive, socket)
      assert_error_state(rendered)
      refute rendered =~ "No agent runs yet"

      clear_read_faults()
      rendered = html(AgentLive, event(AgentLive, socket, "retry_load"))
      refute_error_state(rendered)
      assert rendered =~ "agent-run-#{run.id}"
    end

    test "agent run detail: a FAILED read is the error state, not a silently absent run; a failed turn log fails alone" do
      org_id = Ash.UUID.generate()
      run = AgentFixture.run!(org_id, agent: "p2_triage", state: :running)
      mount = ai_mount()

      inject_read_faults([:ai_agent_get_run])
      socket = failing(fn -> socket_for(AgentLive, mount, [org_id, [run_id: run.id]]) end)
      rendered = html(AgentLive, socket)
      assert_error_state(rendered)
      refute rendered =~ "agent-run-detail"

      clear_read_faults()
      inject_read_faults([:ai_agent_turns])
      rendered = html(AgentLive, failing(fn -> socket_for(AgentLive, mount, [org_id, [run_id: run.id]]) end))
      assert rendered =~ "agent-turns-error"
      assert rendered =~ "agent-run-detail"
      refute rendered =~ "No turns yet"
    end

    test "agent run cancel: a failed write tells the user the run is still running" do
      org_id = Ash.UUID.generate()
      run = AgentFixture.run!(org_id, agent: "p2_triage", state: :running)
      socket = socket_for(AgentLive, ai_mount(), [org_id, [run_id: run.id]])

      inject_read_faults([:ai_agent_cancel])
      failed = failing(fn -> event(AgentLive, socket, "cancel", %{"id" => run.id}) end)
      assert {:error, "That run could not be cancelled right now" <> _} = failed.assigns.outcome
    end

    test "CRM preview: a FAILED read is the error state, not 'Record not found in this org'; 404 survives" do
      %{org_id: org_id, crm: %{person: %{id: person_id}}} = Seeds.seed_all()
      mount = ai_mount()

      inject_read_faults([:ai_crm_preview])
      socket = failing(fn -> socket_for(CrmLive, mount, [org_id, [id: person_id]]) end)
      rendered = html(CrmLive, socket)
      assert_error_state(rendered)
      refute rendered =~ "Record not found in this org"

      clear_read_faults()
      rendered = html(CrmLive, socket_for(CrmLive, mount, [org_id, [id: person_id]]))
      refute_error_state(rendered)
      assert rendered =~ ~s(data-state="ok")

      for id <- [Ash.UUID.generate(), "not-a-uuid"] do
        rendered = html(CrmLive, socket_for(CrmLive, mount, [org_id, [id: id]]))
        assert rendered =~ "Record not found in this org"
        refute_error_state(rendered)
      end
    end

    test "support drafts: a failed list is the error state, not 'No drafts yet'; an un-adopted host stays the honest empty" do
      org_id = Ash.UUID.generate()
      mount = ai_mount()
      # The test host has not adopted the AI draft domain: the documented honest empty.
      healthy = html(SupportDraftLive, socket_for(SupportDraftLive, mount, [org_id]))
      assert healthy =~ "No drafts yet"
      refute_error_state(healthy)

      inject_read_faults([:ai_list_drafts])
      rendered = html(SupportDraftLive, failing(fn -> socket_for(SupportDraftLive, mount, [org_id]) end))
      assert_error_state(rendered)
      refute rendered =~ "No drafts yet"
    end
  end
end
