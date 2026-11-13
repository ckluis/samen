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
    %{org_id: seeded.org_id}
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
end
