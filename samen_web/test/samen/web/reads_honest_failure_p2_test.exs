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
end
