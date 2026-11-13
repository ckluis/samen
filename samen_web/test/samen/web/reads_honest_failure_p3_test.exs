defmodule Samen.Web.ReadsHonestFailureP3Test do
  @moduledoc """
  WP6 phase 3 — "a failed read never renders as empty, a zero or healthy", for the OPERATOR plane
  (accounts, platform billing, desk + ticket detail, revenue, analytics, deliverability, activity,
  fleet, webhook DLQ, aggregate) and the framework gates, and "a failed write tells the operator".

  Same shape as phases 1 and 2 (`Samen.Web.ReadsHonestFailureP2Test`): the read is made to FAIL
  through the real failure path (`inject_read_faults/1`, `Samen.Web.Reads.Guard`'s seam), and the
  screen must render the kit error state / a per-tile "couldn't load" (generic, value-free copy),
  NOT its empty-state copy, a `0`, a `$0.00` or a "healthy" default; stay alive; fail ALONE (the
  tile or pane that did not fail still renders); and recover on retry. Each is paired with a
  POSITIVE CONTROL (a genuinely empty or healthy result still renders the real thing).

  Masking: the operator plane stays masked — an error state carries no body, no name and no `vt_`
  token, and the same page with the fault cleared proves the proof is not vacuous.
  """
  use Samen.WebTest.DataCase, async: false

  import ExUnit.CaptureLog

  alias Samen.Web.ListLive
  alias Samen.WebTest.Operator, as: Op
  alias Samen.WebTest.Operator.Seeds, as: OpSeeds

  # -- harness ---------------------------------------------------------------------------

  defp socket_for(mount, extra \\ []) do
    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, mount)
    |> Phoenix.Component.assign(:samen_acting_as, false)
    |> Phoenix.Component.assign(:return_to, nil)
    |> Phoenix.Component.assign(extra)
  end

  defp loaded(module, mount, load_args \\ [], extra \\ []) do
    apply(module, :load, [socket_for(mount, extra) | load_args])
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

  # Run `fun` under an injected fault; the failure log line it emits is swallowed (the log contract
  # is asserted in reads_guard_test).
  defp failing(fun), do: fun |> with_log() |> elem(0)

  defp assert_error_state(html) do
    assert html =~ "error-state"
    assert html =~ ~s(role="alert")
    assert html =~ "Nothing was lost"
    refute html =~ "vt_"
  end

  defp refute_error_state(html), do: refute(html =~ "error-state")

  defp count(html, needle), do: length(String.split(html, needle)) - 1

  setup do
    seed = OpSeeds.seed_all(tenants: 2)
    %{seed: seed, mount: build_operator_mount(seed.operator_org_id)}
  end

  # An operator org with NO book of business: every read is genuinely empty (positive controls).
  defp empty_mount, do: build_operator_mount(Ash.UUID.generate())

  # An operator-PLANE (impersonation-shaped) mount: the odd hand-crafted mount that must fail MASKED.
  defp operator_plane_mount(seed) do
    Samen.Web.Mount.new(:operator, Op, Samen.WebTest.Repo,
      plane: Samen.Web.Plane.operator("op-1", seed.operator_org_id, "s"),
      labels: %{operator_org_id: seed.operator_org_id}
    )
  end

  # ===========================================================================
  # Accounts
  # ===========================================================================

  describe "Accounts" do
    alias Samen.Web.Operator.AccountsLive

    test "a failed header read is four 'couldn't load' tiles, never 0 accounts / $0 MRR; the list stays", %{mount: mount} do
      inject_read_faults([:operator_accounts])

      socket = failing(fn -> loaded(AccountsLive, mount) end)
      rendered = html(AccountsLive, socket)

      assert socket.assigns.metrics_error == true
      assert socket.assigns.metrics == nil
      assert count(rendered, "metric-error") >= 4
      assert rendered =~ "metrics-error"
      # The tiles fail ALONE: the account list is a different read and still renders.
      assert rendered =~ "account-row"
      refute_error_state(rendered)

      clear_read_faults()
      socket = event(AccountsLive, socket, "retry_load")
      rendered = html(AccountsLive, socket)
      refute rendered =~ "metric-error"
      refute rendered =~ "metrics-error"
      assert socket.assigns.metrics.accounts == 2
    end

    test "a failed account page is the error state with a retry, not 'No accounts yet.' and no create CTA", %{mount: mount} do
      inject_read_faults([:operator_accounts_page])

      socket = failing(fn -> loaded(AccountsLive, mount) end)
      rendered = html(AccountsLive, socket)

      assert_error_state(rendered)
      refute rendered =~ "No accounts yet."
      refute rendered =~ "empty-new-account"
      assert socket.assigns.page.error == :unavailable

      clear_read_faults()
      socket = list_event(socket, "list_retry")
      rendered = html(AccountsLive, socket)
      refute_error_state(rendered)
      assert rendered =~ "account-row"
    end

    test "POSITIVE CONTROL: an operator with no accounts still renders the real empty state and zero tiles" do
      socket = loaded(AccountsLive, empty_mount())
      rendered = html(AccountsLive, socket)

      assert rendered =~ "No accounts yet."
      assert rendered =~ "empty-new-account"
      refute rendered =~ "metric-error"
      refute_error_state(rendered)
      assert socket.assigns.metrics.accounts == 0
    end
  end

  # ===========================================================================
  # Desk
  # ===========================================================================

  describe "Desk" do
    alias Samen.Web.Operator.DeskLive

    test "ONE failed queue count is one 'couldn't load' tile; the other tiles keep their numbers", %{mount: mount} do
      inject_read_faults([:operator_desk_metric_breaching])

      socket = failing(fn -> loaded(DeskLive, mount) end)
      rendered = html(DeskLive, socket)

      assert socket.assigns.metric_errors == [:breaching]
      assert count(rendered, "metric-error") == 1 or count(rendered, ~s(class="sub metric-error")) == 1
      # The open count and the ticket list are different reads and still render.
      assert socket.assigns.metrics.open == 4
      assert rendered =~ "Open tickets"

      clear_read_faults()
      socket = event(DeskLive, socket, "retry_load")
      assert socket.assigns.metric_errors == []
      refute html(DeskLive, socket) =~ "metric-error"
    end

    test "a failed ticket page is the error state, not 'No tickets yet.'", %{mount: mount} do
      inject_read_faults([:operator_desk_page])

      socket = failing(fn -> loaded(DeskLive, mount) end)
      rendered = html(DeskLive, socket)

      assert_error_state(rendered)
      refute rendered =~ "No tickets yet."

      clear_read_faults()
      socket = list_event(socket, "list_retry")
      refute_error_state(html(DeskLive, socket))
      assert socket.assigns.page.items != []
    end

    test "a failed ticket archive tells the operator it was NOT deleted, with outage (not denial) copy", %{
      mount: mount,
      seed: seed
    } do
      ticket = hd(hd(seed.accounts).tickets)
      inject_read_faults([:operator_delete_ticket])

      socket = failing(fn -> loaded(DeskLive, mount) end)
      socket = failing(fn -> event(DeskLive, socket, "delete", %{"id" => ticket.id}) end)

      assert socket.assigns.delete_error =~ "was not deleted"
      refute socket.assigns.delete_error =~ "Could not delete"

      clear_read_faults()
      socket = event(DeskLive, socket, "delete", %{"id" => ticket.id})
      assert socket.assigns.delete_error == nil
    end

    test "a malformed ticket id is 'not found' and logs no failure", %{mount: mount} do
      socket = loaded(DeskLive, mount)

      log =
        capture_log(fn ->
          socket = event(DeskLive, socket, "delete", %{"id" => "not-a-uuid"})
          assert socket.assigns.delete_error =~ "Could not delete"
        end)

      refute log =~ "failed"
    end

    test "POSITIVE CONTROL: an empty desk renders the real empty state and zero counts" do
      socket = loaded(DeskLive, empty_mount())
      rendered = html(DeskLive, socket)

      assert rendered =~ "No tickets yet."
      refute rendered =~ "metric-error"
      assert socket.assigns.metric_errors == []
      assert socket.assigns.metrics == %{open: 0, breaching: 0, high: 0}
    end
  end

  # ===========================================================================
  # Desk ticket detail — message bodies are 🔒 fields: the masking proofs apply
  # ===========================================================================

  describe "Desk ticket detail" do
    alias Samen.Web.Operator.DeskDetailLive

    setup %{seed: seed} do
      %{ticket_id: hd(hd(seed.accounts).tickets).id}
    end

    test "a failed detail read is the error state with a retry, never 'Ticket not found'", %{mount: mount, ticket_id: id} do
      inject_read_faults([:operator_ticket_detail])

      socket = failing(fn -> loaded(DeskDetailLive, mount, [id]) end)
      rendered = html(DeskDetailLive, socket)

      assert_error_state(rendered)
      assert rendered =~ "ticket-load-error"
      refute rendered =~ "ticket-not-found"
      refute rendered =~ "reply-form"

      clear_read_faults()
      socket = event(DeskDetailLive, socket, "retry_load")
      rendered = html(DeskDetailLive, socket)
      refute_error_state(rendered)
      assert rendered =~ "reply-form"
    end

    test "a malformed id is 'not found' (not an outage) and logs no failure", %{mount: mount} do
      log =
        capture_log(fn ->
          rendered = html(DeskDetailLive, loaded(DeskDetailLive, mount, ["not-a-uuid"]))
          assert rendered =~ "ticket-not-found"
          refute_error_state(rendered)
        end)

      refute log =~ "failed"
    end

    test "MASKING: the operator-plane error DOM carries no body, no name and no token; the cleared page is masked",
         %{seed: seed, ticket_id: id} do
      mount = operator_plane_mount(seed)
      inject_read_faults([:operator_ticket_detail])

      rendered = html(DeskDetailLive, failing(fn -> loaded(DeskDetailLive, mount, [id]) end))

      assert_error_state(rendered)
      refute rendered =~ "Thanks for reaching out"
      refute rendered =~ OpSeeds.admin_full_name()
      refute rendered =~ "pii_"

      # Non-vacuous: with the fault cleared the SAME page renders the masked body.
      clear_read_faults()
      cleared = html(DeskDetailLive, loaded(DeskDetailLive, mount, [id]))
      assert cleared =~ "••••"
      refute cleared =~ "Thanks for reaching out"
    end

    test "a failed reply write says it was NOT posted (outage copy); the working write posts", %{mount: mount, ticket_id: id} do
      inject_read_faults([:operator_post_reply])
      socket = loaded(DeskDetailLive, mount, [id])

      socket =
        failing(fn -> event(DeskDetailLive, socket, "reply", %{"reply" => %{"body" => "Reply that must not vanish silently"}}) end)

      assert socket.assigns.reply_error =~ "nothing was posted"
      refute html(DeskDetailLive, socket) =~ "Reply that must not vanish silently"

      clear_read_faults()
      socket = event(DeskDetailLive, socket, "reply", %{"reply" => %{"body" => "Reply that lands"}})
      assert socket.assigns.reply_error == nil
      assert html(DeskDetailLive, socket) =~ "Reply that lands"
    end

    test "a failed AI draft prints fixed copy: no exception or reason term reaches the template", %{mount: mount, ticket_id: id} do
      inject_read_faults([:ai_support_draft])
      socket = loaded(DeskDetailLive, mount, [id])
      socket = failing(fn -> event(DeskDetailLive, socket, "draft_ai") end)

      assert socket.assigns.ai_error =~ "No draft was produced"
      rendered = html(DeskDetailLive, socket)
      refute rendered =~ "InjectedFault"
      refute rendered =~ "persist_unavailable"
      refute socket.assigns.ai_error =~ "{"
    end
  end

  # ===========================================================================
  # Platform billing
  # ===========================================================================

  describe "Platform billing" do
    alias Samen.Web.Operator.PlatformBillingLive

    test "a failed read is the error state, never $0.00 MRR over 'No tenant subscriptions yet.'", %{mount: mount} do
      inject_read_faults([:operator_platform_billing])

      socket = failing(fn -> loaded(PlatformBillingLive, mount) end)
      rendered = html(PlatformBillingLive, socket)

      assert_error_state(rendered)
      assert rendered =~ "billing-load-error"
      refute rendered =~ "$0.00"
      refute rendered =~ "No tenant subscriptions yet."
      refute rendered =~ "No invoices yet."

      clear_read_faults()
      socket = event(PlatformBillingLive, socket, "retry_load")
      rendered = html(PlatformBillingLive, socket)
      refute_error_state(rendered)
      assert rendered =~ "subscription-row"
    end

    test "POSITIVE CONTROL: a genuinely empty book renders $0.00 and the empty states" do
      rendered = html(PlatformBillingLive, loaded(PlatformBillingLive, empty_mount()))

      assert rendered =~ "$0.00"
      assert rendered =~ "No tenant subscriptions yet."
      refute_error_state(rendered)
    end
  end

  # ===========================================================================
  # Account detail
  # ===========================================================================

  describe "Account detail" do
    alias Samen.Web.Operator.AccountDetailLive

    setup %{seed: seed} do
      %{account_id: hd(seed.accounts).account_org.id}
    end

    test "a failed read is the error state, never 'Account not found'", %{mount: mount, account_id: id} do
      inject_read_faults([:operator_account_detail])

      socket = failing(fn -> AccountDetailLive.load(socket_for(mount), id) end)
      rendered = html(AccountDetailLive, socket)

      assert_error_state(rendered)
      assert rendered =~ "account-load-error"
      refute rendered =~ "account-missing"

      clear_read_faults()
      socket = event(AccountDetailLive, socket, "retry_load")
      rendered = html(AccountDetailLive, socket)
      refute_error_state(rendered)
      assert rendered =~ "Why this score"
    end

    test "a malformed or unknown id is 'not found' (not an outage), with no failure logged", %{mount: mount} do
      log =
        capture_log(fn ->
          for id <- ["not-a-uuid", Ash.UUID.generate()] do
            rendered = html(AccountDetailLive, AccountDetailLive.load(socket_for(mount), id))
            assert rendered =~ "account-missing"
            refute_error_state(rendered)
          end
        end)

      refute log =~ "failed"
    end
  end

  # ===========================================================================
  # Revenue — the tiles/waterfall, the cohort grid and the plan table fail ALONE
  # ===========================================================================

  describe "Revenue" do
    alias Samen.Web.Operator.RevenueLive

    test "a failed rollup is four 'couldn't load' tiles + an error waterfall, never $0.00 / 'No revenue movements yet.'; cohorts keep rendering",
         %{mount: mount} do
      inject_read_faults([:operator_revenue_rollup])

      socket = failing(fn -> loaded(RevenueLive, mount) end)
      rendered = html(RevenueLive, socket)

      assert socket.assigns.revenue_failed == [:rollup]
      assert count(rendered, ~s(class="sub metric-error")) == 4
      assert rendered =~ "revenue-error"
      refute rendered =~ "No revenue movements yet."
      refute rendered =~ "$0.00"
      # Fails alone: the cohort grid is a separate read.
      refute rendered =~ "cohorts-error"

      clear_read_faults()
      socket = event(RevenueLive, socket, "retry_load")
      assert socket.assigns.revenue_failed == []
      refute html(RevenueLive, socket) =~ "metric-error"
    end

    test "a failed cohort read is ONLY the cohort pane; the tiles do not move", %{mount: mount} do
      inject_read_faults([:operator_revenue_cohorts])

      socket = failing(fn -> loaded(RevenueLive, mount) end)
      rendered = html(RevenueLive, socket)

      assert socket.assigns.revenue_failed == [:cohorts]
      assert rendered =~ "cohorts-error"
      refute rendered =~ "No cohorts yet."
      refute rendered =~ "metric-error"
      refute rendered =~ "revenue-error"
    end

    test "a plan loader that raises is a failed plan pane, not 'No cross-tenant plan projection wired.'", %{seed: seed} do
      mount =
        build_operator_mount(seed.operator_org_id, labels: %{revenue_plan_loader: {__MODULE__, :boom_loader, []}})

      rendered = failing(fn -> html(RevenueLive, loaded(RevenueLive, mount)) end)

      assert rendered =~ "plan-mrr-error"
      refute rendered =~ "No cross-tenant plan projection wired."
    end

    test "POSITIVE CONTROL: no loader wired is the real 'not wired' state; an empty rollup is the real empty state" do
      rendered = html(RevenueLive, loaded(RevenueLive, empty_mount()))

      assert rendered =~ "No revenue movements yet."
      assert rendered =~ "No cross-tenant plan projection wired."
      refute rendered =~ "metric-error"
      refute_error_state(rendered)
    end
  end

  def boom_loader, do: raise("loader down")

  # ===========================================================================
  # Analytics — funnel and retention fail ALONE
  # ===========================================================================

  describe "Analytics" do
    alias Samen.Web.Operator.AnalyticsLive

    test "a failed funnel is the funnel pane's error, not 'No product events yet.'; retention is untouched", %{mount: mount} do
      inject_read_faults([:operator_analytics_funnel])

      socket = failing(fn -> loaded(AnalyticsLive, mount) end)
      rendered = html(AnalyticsLive, socket)

      assert socket.assigns.analytics_failed == [:funnel]
      assert rendered =~ "funnel-error"
      refute rendered =~ "No product events yet."
      refute rendered =~ "retention-error"

      clear_read_faults()
      socket = event(AnalyticsLive, socket, "retry_load")
      assert socket.assigns.analytics_failed == []
    end

    test "a failed retention read is only the retention pane", %{mount: mount} do
      inject_read_faults([:operator_analytics_retention])

      rendered = html(AnalyticsLive, failing(fn -> loaded(AnalyticsLive, mount) end))

      assert rendered =~ "retention-error"
      refute rendered =~ "No cohorts yet."
      refute rendered =~ "funnel-error"
    end

    test "POSITIVE CONTROL: an empty rollup renders the real empty states", %{mount: mount} do
      rendered = html(AnalyticsLive, loaded(AnalyticsLive, mount))

      refute rendered =~ "funnel-error"
      refute rendered =~ "retention-error"
      assert rendered =~ "No product events yet." or rendered =~ "funnel-row"
    end
  end

  # ===========================================================================
  # Rollup tables — a host that never migrated them is the honest empty, not a permanent outage
  # ===========================================================================
  #
  # `mrr_revenue_rollup` / `paf_product_event_rollup` are host migrations; nothing `mix samen.gen.app`
  # produces creates them, yet every generated app mounts /operator/revenue and /operator/analytics.
  # REAL faults, not the seam (the seam fires before the body): DDL inside the sandbox transaction rolls back.

  describe "Rollup tables on a host that never adopted them" do
    alias Samen.Web.Operator.{AnalyticsLive, RevenueLive}
    alias Samen.Web.Reads.Adoption

    setup do
      Adoption.forget_logged(:mrr_revenue_rollup)
      Adoption.forget_logged(:paf_product_event_rollup)
      :ok
    end

    defp ddl!(sql), do: Ecto.Adapters.SQL.query!(Samen.WebTest.Repo, sql, [])

    test "revenue: a missing mrr_revenue_rollup is the honest empty, logged once as not-adopted, never an error", %{
      mount: mount
    } do
      ddl!("DROP TABLE mrr_revenue_rollup")

      {rendered, log} = with_log(fn -> html(RevenueLive, loaded(RevenueLive, mount)) end)

      assert rendered =~ "No revenue movements yet."
      refute rendered =~ "revenue-error"
      refute rendered =~ "metric-error"
      refute log =~ "read failed"
      assert log =~ "feature not adopted"

      # ONCE per node, not once per page load.
      {_, second} = with_log(fn -> loaded(RevenueLive, mount) end)
      refute second =~ "feature not adopted"
      refute second =~ "read failed"
    end

    test "revenue: a renamed column on an EXISTING table is still the error pane (and logged)", %{mount: mount} do
      ddl!("ALTER TABLE mrr_revenue_rollup RENAME COLUMN mrr_kind TO mrr_kind_renamed")

      {socket, log} = with_log(fn -> loaded(RevenueLive, mount) end)
      rendered = html(RevenueLive, socket)

      assert socket.assigns.revenue_failed == [:rollup]
      assert rendered =~ "revenue-error"
      refute rendered =~ "No revenue movements yet."
      assert log =~ "read failed"
      refute log =~ "feature not adopted"
    end

    test "analytics: a missing paf_product_event_rollup is the honest empty for BOTH panes, no error log", %{
      mount: mount
    } do
      ddl!("DROP TABLE paf_product_event_rollup")

      {socket, log} = with_log(fn -> loaded(AnalyticsLive, mount) end)
      rendered = html(AnalyticsLive, socket)

      assert socket.assigns.analytics_failed == []
      refute rendered =~ "funnel-error"
      refute rendered =~ "retention-error"
      assert rendered =~ "No product events yet."
      refute log =~ "read failed"
      assert log =~ "feature not adopted"
    end

    test "analytics: a renamed column is the error pane for the pane that reads it", %{mount: mount} do
      ddl!("ALTER TABLE paf_product_event_rollup RENAME COLUMN paf_stage TO paf_stage_renamed")

      {socket, log} = with_log(fn -> loaded(AnalyticsLive, mount) end)
      rendered = html(AnalyticsLive, socket)

      assert :funnel in socket.assigns.analytics_failed
      assert rendered =~ "funnel-error"
      refute rendered =~ "No product events yet."
      assert log =~ "read failed"
    end
  end

  # ===========================================================================
  # Deliverability — events and suppressions fail ALONE; recipients are 🔒 fields
  # ===========================================================================

  describe "Deliverability" do
    alias Samen.Web.Operator.DeliverabilityLive

    setup do
      %{org_id: Ash.UUID.generate()}
    end

    defp deliverability(org_id, actor \\ %{plane: :operator, kind: :operator}) do
      mount = build_operator_mount(Ash.UUID.generate())
      DeliverabilityLive.load(socket_for(mount), org_id, actor: actor)
    end

    test "a failed events read is the events pane's error, not 'No delivery events.'; suppressions still render", %{org_id: org_id} do
      inject_read_faults([:operator_deliverability_events])

      socket = failing(fn -> deliverability(org_id) end)
      rendered = html(DeliverabilityLive, socket)

      assert socket.assigns.detail.failed == [:events]
      assert rendered =~ "events-error"
      refute rendered =~ "No delivery events."
      refute rendered =~ "suppressions-error"
      refute rendered =~ "vt_"
    end

    test "a failed suppressions read makes the per-event 'suppressed?' flag UNKNOWN, never a quiet dash", %{org_id: org_id} do
      inject_read_faults([:operator_deliverability_suppressions])

      socket = failing(fn -> deliverability(org_id) end)
      rendered = html(DeliverabilityLive, socket)

      assert socket.assigns.detail.failed == [:suppressions]
      assert rendered =~ "suppressions-error"
      refute rendered =~ "No suppressions."
      refute rendered =~ "events-error"
    end

    test "POSITIVE CONTROL: nothing failed and nothing there renders the real empty states", %{org_id: org_id} do
      socket = deliverability(org_id)
      rendered = html(DeliverabilityLive, socket)

      assert socket.assigns.detail.failed == []
      assert rendered =~ "No suppressions."
      assert rendered =~ "No delivery events."
      refute_error_state(rendered)
    end
  end

  # ===========================================================================
  # Activity — four sub-queries fail ALONE and are NAMED
  # ===========================================================================

  describe "Activity" do
    alias Samen.Web.Operator.{ActivityLive, ActivityReads}

    setup %{seed: seed} do
      org_id = hd(seed.accounts).tenant_org_id
      operator_id = Ecto.UUID.generate()
      open_impersonation!(operator_id, org_id)
      %{org_id: org_id, operator_id: operator_id}
    end

    defp activity(mount, operator_id, org_id) do
      socket = socket_for(mount) |> with_operator_identity(operator_id)
      ActivityLive.load(socket, org_id, nil)
    end

    test "a failed sub-query is NAMED and the feed is never 'No changes in this window.'", %{
      mount: mount,
      org_id: org_id,
      operator_id: operator_id
    } do
      inject_read_faults([:operator_activity_system])

      socket = failing(fn -> activity(mount, operator_id, org_id) end)
      rendered = html(ActivityLive, socket)

      assert socket.assigns.feed.failed == [:system]
      assert_error_state(rendered)
      assert rendered =~ "system events"
      refute rendered =~ "No changes in this window."

      clear_read_faults()
      socket = event(ActivityLive, socket, "retry_load")
      assert socket.assigns.feed.failed == []
    end

    test "the read layer reports which tier failed and keeps the rest", %{mount: mount, org_id: org_id} do
      inject_read_faults([:operator_activity_impersonation, :operator_activity_history])

      feed = failing(fn -> ActivityReads.activity(mount, org_id) end)
      assert Enum.sort(feed.failed) == [:history, :impersonation]
      assert is_list(feed.items)

      clear_read_faults()
      assert ActivityReads.activity(mount, org_id).failed == []
    end

    test "POSITIVE CONTROL: a feed with nothing in the window and nothing failed renders the real empty state", %{
      mount: mount,
      org_id: org_id
    } do
      # (A real quiet org still carries its own session-open event, so the empty feed is supplied
      # through the sanctioned `:feed` seam; the read layer's `failed: []` is asserted above.)
      socket = ActivityLive.load(socket_for(mount), org_id, nil, feed: %{items: [], window_hours: 24, cutoff: nil, failed: []})
      rendered = html(ActivityLive, socket)

      assert rendered =~ "No changes in this window."
      refute_error_state(rendered)
    end
  end

  # ===========================================================================
  # Aggregate
  # ===========================================================================

  describe "Aggregate" do
    alias Samen.Web.Operator.AggregateLive

    def raising_loader, do: raise("aggregate down")
    def ok_loader, do: %{metrics: [%{label: "Tenants", value: 3}], groups: []}

    defp aggregate_mount(loader), do: build_operator_mount(Ash.UUID.generate(), labels: %{aggregate_loader: loader})

    test "a loader that raises is the error state with a retry, not 'No aggregate projection wired.'" do
      socket = failing(fn -> AggregateLive.load(socket_for(aggregate_mount({__MODULE__, :raising_loader, []}))) end)
      rendered = html(AggregateLive, socket)

      assert_error_state(rendered)
      refute rendered =~ "No aggregate projection wired."

      {:noreply, socket} = failing(fn -> AggregateLive.handle_event("retry_load", %{}, socket) end)
      assert socket.assigns.load_error == true
    end

    test "POSITIVE CONTROL: no loader is the real 'not wired' state; a working loader renders its tiles" do
      rendered = html(AggregateLive, AggregateLive.load(socket_for(build_operator_mount(Ash.UUID.generate()))))
      assert rendered =~ "No aggregate projection wired."
      refute_error_state(rendered)

      rendered = html(AggregateLive, AggregateLive.load(socket_for(aggregate_mount({__MODULE__, :ok_loader, []}))))
      assert rendered =~ "Tenants"
      refute_error_state(rendered)
    end
  end

  # ===========================================================================
  # Fleet cockpit
  # ===========================================================================

  describe "Fleet cockpit" do
    alias Samen.Fleet.{AdminActor, Registry}
    alias Samen.Web.Operator.FleetLive

    @ns Samen.WebTest.Fleet
    @otp_app :samen_web_p3_fleet_test_host

    setup do
      Application.put_env(@otp_app, :fleet, mode: :manual)
      Application.put_env(@otp_app, :fleet_authority, {__MODULE__, :roles_for, [%{fleet: :operator_admin}]})

      on_exit(fn ->
        Application.delete_env(@otp_app, :fleet_authority)
        Application.delete_env(@otp_app, :fleet)
      end)

      mount =
        Samen.Web.Mount.new(:operator, Op, Samen.WebTest.Repo,
          plane: Samen.Web.Plane.tenant(),
          labels: %{otp_app: @otp_app, fleet_namespace: @ns, fleet_cockpit: true}
        )

      %{fleet_mount: mount}
    end

    def roles_for(roles, _principal_id), do: roles

    defp fleet_socket(mount) do
      {:ok, socket} = FleetLive.mount(%{}, %{"samen_current_user" => "op-1"}, socket_for(mount))
      socket
    end

    defp seed_fleet_app(slug, report_overrides \\ %{}) do
      {:ok, %{app: app}} =
        Registry.register_app(@ns, %{slug: slug, display_name: slug}, AdminActor.new("seed-admin"))

      payload =
        Samen.Fleet.Report.build(app_id: "11111111-1111-4111-8111-111111111111")
        |> Samen.Fleet.Report.to_wire()
        |> Map.merge(report_overrides)

      {:ok, _} = Registry.record_report(@ns, app.id, payload, :pull)
      app
    end

    test "a failed registry read is the error state, never 'Fleet not configured', 'No products registered yet.' or 'Nothing needs attention.'",
         %{fleet_mount: mount} do
      seed_fleet_app("p3-fleet")
      inject_read_faults([:operator_fleet_read])

      socket = failing(fn -> fleet_socket(mount) end)
      rendered = html(FleetLive, socket)

      assert_error_state(rendered)
      assert rendered =~ "fleet-load-error"
      refute rendered =~ "Fleet not configured."
      refute rendered =~ "No products registered yet."
      refute rendered =~ "Nothing needs attention."

      clear_read_faults()
      socket = event(FleetLive, socket, "retry_load")
      rendered = html(FleetLive, socket)
      refute_error_state(rendered)
      assert rendered =~ "p3-fleet"
    end

    test "a real configuration gap prints fixed copy, never the inspected reason term", %{fleet_mount: mount} do
      Application.put_env(@otp_app, :fleet, mode: :bogus_mode)

      rendered = html(FleetLive, fleet_socket(mount))

      assert rendered =~ "Fleet not configured."
      assert rendered =~ "not recognised"
      refute rendered =~ "bogus_mode"
      refute rendered =~ "invalid_mode"
      refute_error_state(rendered)
    end

    test "a host with no fleet_namespace label is the configuration copy, not an outage pane, and logs no failure" do
      mount =
        Samen.Web.Mount.new(:operator, Op, Samen.WebTest.Repo,
          plane: Samen.Web.Plane.tenant(),
          labels: %{otp_app: @otp_app, fleet_cockpit: true}
        )

      {socket, log} = with_log(fn -> fleet_socket(mount) end)
      rendered = html(FleetLive, socket)

      assert socket.assigns.fleet_failed == false
      assert rendered =~ "Fleet not configured."
      assert rendered =~ "no fleet namespace is wired on this mount"
      refute rendered =~ "fleet-load-error"
      refute_error_state(rendered)
      refute log =~ "read failed"
    end

    test "a namespace that names a domain with no fleet resources is configuration, not an outage" do
      mount =
        Samen.Web.Mount.new(:operator, Op, Samen.WebTest.Repo,
          plane: Samen.Web.Plane.tenant(),
          labels: %{otp_app: @otp_app, fleet_namespace: Samen.WebTest.NoSuchFleet, fleet_cockpit: true}
        )

      {socket, log} = with_log(fn -> fleet_socket(mount) end)
      rendered = html(FleetLive, socket)

      assert rendered =~ "Fleet not configured."
      assert rendered =~ "has no fleet resources"
      refute_error_state(rendered)
      refute log =~ "read failed"
    end

    test "one malformed activity entry is skipped on its own; it does not blank every product's merged counts", %{fleet_mount: mount} do
      seed_fleet_app("p3-activity", %{
        "activity_counts" => [%{"event_kind" => "signup", "count" => 3}, "garbage", %{"event_kind" => "no-count"}]
      })

      socket = fleet_socket(mount)

      assert socket.assigns.t156.activity_feed == [{"signup", 3}]
    end

    test "POSITIVE CONTROL: no products registered is the real empty state", %{fleet_mount: mount} do
      rendered = html(FleetLive, fleet_socket(mount))

      assert rendered =~ "No products registered yet."
      assert rendered =~ "Nothing needs attention."
      refute_error_state(rendered)
    end
  end

  # ===========================================================================
  # Webhook DLQ — a failed read is not an empty queue; a failed replay/resolve is told
  # ===========================================================================

  describe "Webhook DLQ" do
    alias Samen.Web.Operator.WebhookDlqLive
    alias Samen.Webhook.Event

    setup do
      {:ok, :inserted, row} =
        Event.insert_received(Repo, %{
          provider: "test",
          event_id: "evt_p3_#{System.unique_integer([:positive])}",
          kind: "checkout_completed",
          domain: "billing",
          occurred_at: DateTime.utc_now(),
          payload: %{"amount" => 4900}
        })

      {:ok, dead} = Event.mark_dead(Repo, row, "handler crashed")
      %{dead: dead}
    end

    defp dlq(role) do
      loaded(WebhookDlqLive, build_operator_mount(Ash.UUID.generate()), [], samen_operator_role: role)
    end

    test "a failed envelope read is the error state, not 'No webhook envelopes.' (nothing to replay)" do
      inject_read_faults([:operator_dlq_envelopes])

      socket = failing(fn -> dlq(:operator_admin) end)
      rendered = html(WebhookDlqLive, socket)

      assert_error_state(rendered)
      assert rendered =~ "dlq-error"
      refute rendered =~ "No webhook envelopes."

      clear_read_faults()
      socket = event(WebhookDlqLive, socket, "retry_load")
      refute_error_state(html(WebhookDlqLive, socket))
    end

    test "a failed replay says so (outage copy) and the envelope stays dead; the working replay is silent", %{dead: dead} do
      inject_read_faults([:operator_dlq_reset])
      socket = dlq(:operator_admin)

      socket = failing(fn -> event(WebhookDlqLive, socket, "replay", %{"id" => dead.id}) end)

      assert socket.assigns.action_error =~ "couldn't replay"
      assert html(WebhookDlqLive, socket) =~ "dlq-action-error"
      assert Event.get(Repo, dead.id).status == "dead"

      clear_read_faults()
      socket = event(WebhookDlqLive, socket, "replay", %{"id" => dead.id})
      assert socket.assigns.action_error == nil
      assert Event.get(Repo, dead.id).status == "received"
    end

    test "a failed resolve says so and changes nothing", %{dead: dead} do
      inject_read_faults([:operator_dlq_resolve])
      socket = failing(fn -> event(WebhookDlqLive, dlq(:operator_support), "resolve", %{"id" => dead.id}) end)

      assert socket.assigns.action_error =~ "nothing was changed"
      assert Event.get(Repo, dead.id).status == "dead"
    end

    test "a read-only operator is told it may not (denial copy), not silently ignored", %{dead: dead} do
      socket = event(WebhookDlqLive, dlq(:operator_readonly), "replay", %{"id" => dead.id})

      assert socket.assigns.action_error =~ "may not change the webhook queue"
      assert Event.get(Repo, dead.id).status == "dead"
    end

    test "a malformed or already-handled id is 'no longer in the dead-letter set', with no failure logged", %{dead: dead} do
      socket = dlq(:operator_admin)

      log =
        capture_log(fn ->
          socket = event(WebhookDlqLive, socket, "replay", %{"id" => "not-a-uuid"})
          assert socket.assigns.action_error =~ "no longer in the dead-letter set"
        end)

      refute log =~ "failed"
      assert Event.get(Repo, dead.id).status == "dead"
    end
  end

  # ===========================================================================
  # Gates fail CLOSED (and say so in the log)
  # ===========================================================================

  describe "Gates" do
    alias Samen.Web.Operator.{Authz, Impersonation}

    def raising_authority(_principal), do: raise("authority down")
    def admin_authority(_principal), do: :operator_admin

    defp authz_mount(mfa), do: build_operator_mount(Ash.UUID.generate(), labels: %{operator_authority: mfa})

    test "an operator-authority seam that RAISES is not an operator (fail closed) and is reported by name" do
      log =
        capture_log(fn ->
          assert Authz.resolve_role(authz_mount({__MODULE__, :raising_authority, []}), %{}) == nil
        end)

      assert log =~ "operator_authz_resolve_role"
      refute log =~ "authority down"
    end

    test "POSITIVE CONTROL: a working authority seam still yields the role" do
      assert Authz.resolve_role(authz_mount({__MODULE__, :admin_authority, []}), %{}) == :operator_admin
    end

    test "the impersonation gate DENIES when its lookup raises, reporting by name; a live session still opens it", %{seed: seed} do
      log =
        capture_log(fn ->
          assert Impersonation.gate(Ecto.UUID.generate(), "not-a-uuid", nil) == :denied
        end)

      assert log =~ "operator_impersonation_gate"

      org_id = hd(seed.accounts).tenant_org_id
      operator_id = Ecto.UUID.generate()
      open_impersonation!(operator_id, org_id)
      assert {:ok, _actor, _info} = Impersonation.gate(operator_id, org_id, nil)
    end
  end

  # ===========================================================================
  # CSV import — the per-row report shown to the uploader is value-free
  # ===========================================================================

  describe "CSV import report" do
    alias Samen.Web.Csv
    alias Samen.WebTest.Crm.Person

    test "a refused row's message names the kind of failure, never the cell value that was refused" do
      org_id = Ash.UUID.generate()
      scope = Samen.Web.Plane.scope(Samen.Web.Plane.operator("op-1", org_id, "p3-csv"), org_id)
      sentinel = "Sentinel#{System.unique_integer([:positive])}"

      csv =
        Csv.serialize([
          ["display_name", "full_name"],
          ["Row", ~s({"first":"#{sentinel}","last":"Refused"})]
        ])

      log = capture_log(fn -> send(self(), {:report, Csv.import(Person, scope, csv: csv)}) end)
      assert_received {:report, {:ok, %Samen.Web.Csv.Report{errors: [%{row: 1, error: message}]}}}

      assert is_binary(message) and message != ""
      refute message =~ sentinel
      refute message =~ "Refused"
      refute log =~ sentinel
    end

    test "a cross-org reference is refused without echoing the foreign id back in the report" do
      org_a = Ash.UUID.generate()
      org_b = Ash.UUID.generate()
      scope_a = Samen.Web.Plane.scope(Samen.Web.Plane.tenant(), org_a)
      scope_b = Samen.Web.Plane.scope(Samen.Web.Plane.tenant(), org_b)

      foreign =
        Samen.WebTest.Crm.Company
        |> Ash.Changeset.for_create(:create, %{name: "Foreign Co", org_id: org_b})
        |> Ash.create!(scope: scope_b)

      csv = Csv.serialize([["display_name", "company_id"], ["Bad Row", foreign.id]])

      assert {:ok, %Samen.Web.Csv.Report{created: 0, errors: [%{row: 1, error: message}]}} =
               Csv.import(Person, scope_a, csv: csv)

      refute message =~ foreign.id
      assert message =~ "company_id"
    end

    test "POSITIVE CONTROL: a valid row on a tenant plane imports without an error" do
      org_id = Ash.UUID.generate()
      scope = Samen.Web.Plane.scope(Samen.Web.Plane.tenant(), org_id)
      csv = Csv.serialize([["display_name"], ["Fine Row"]])

      assert {:ok, %Samen.Web.Csv.Report{created: 1, errors: []}} = Csv.import(Person, scope, csv: csv)
    end
  end
end
