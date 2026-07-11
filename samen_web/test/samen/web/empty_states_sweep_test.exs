defmodule Samen.Web.EmptyStatesSweepTest do
  @moduledoc """
  A5 Task 1 — the EMPTY-STATE SWEEP (WS-A design §3.1, AC-G5-1): every mounted list
  surface renders the CONSISTENT kit `empty_state/1` at zero rows — icon + message
  (body) + the surface's primary CREATE action wired into the `:empty_actions` slot
  where a create exists.

  Table-driven over the REAL framework LiveViews via the `render_live` harness (the
  same `load/*` + `render/1` path the mounted route runs). Also covers:

    * detail sub-lists (pipeline, platform billing, aggregate, chat inbox) — the bare
      "muted div" / zero-row-table empties are RETROFITTED to the kit component;
    * the PLANE red path: on the operator/impersonation plane the create CTA (a write
      affordance) is ABSENT while the empty state itself still renders — the empty
      state never becomes a write-affordance leak.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.Mount

  # {module, mount kind, load args (after socket), create-CTA id or nil}
  @tenant_list_surfaces [
    {Samen.Web.CRM.ContactsLive, :crm, "empty-new-contact"},
    {Samen.Web.CRM.CompaniesLive, :crm, "empty-new-company"},
    {Samen.Web.Billing.InvoicesLive, :billing, "empty-new-invoice"},
    {Samen.Web.Billing.PlansLive, :billing, "empty-new-plan"},
    {Samen.Web.Billing.OverviewLive, :billing, "empty-new-customer"},
    {Samen.Web.Marketing.CampaignsLive, :marketing, "empty-new-campaign"},
    {Samen.Web.Marketing.SegmentsLive, :marketing, "empty-new-segment"},
    {Samen.Web.Marketing.LeadsLive, :marketing, nil},
    {Samen.Web.Support.TicketsLive, :support, "empty-new-ticket"},
    {Samen.Web.Notifications.InboxLive, :notifications, nil}
  ]

  # ---------------------------------------------------------------------------
  # AC-G5-1 — every tenant list surface: kit empty_state + icon + body (+ CTA)
  # ---------------------------------------------------------------------------

  for {module, kind, cta} <- @tenant_list_surfaces do
    test "#{inspect(module)} at zero rows renders the kit empty_state (icon + body#{if cta, do: " + create CTA"})" do
      org_id = Ash.UUID.generate()
      html = render_live(unquote(module), build_mount(unquote(kind)), [org_id])

      # The consistent kit component — via list_view's DEFAULT :empty (zero surface code).
      assert html =~ "empty-state", "#{inspect(unquote(module))} lost the kit empty_state"
      assert html =~ ~s(class="empty-icon"), "#{inspect(unquote(module))} empty state has no icon"
      assert html =~ ~s(class="empty-body"), "#{inspect(unquote(module))} empty state has no body copy"
      # Zero rows render NO data table.
      refute html =~ "<table>"

      case unquote(cta) do
        nil -> :ok
        cta -> assert html =~ ~s(id="#{cta}"), "#{inspect(unquote(module))} empty state lost its create CTA"
      end
    end
  end

  # The two OPERATOR-workspace lists (the operator's own book of business — writable).
  test "Operator AccountsLive at zero accounts: kit empty_state + the New account CTA (the operator first-run surface)" do
    html = render_live(Samen.Web.Operator.AccountsLive, build_operator_mount(Ash.UUID.generate()), [])

    assert html =~ "empty-state"
    assert html =~ ~s(class="empty-icon")
    assert html =~ ~s(class="empty-body")
    assert html =~ ~s(id="empty-new-account")
  end

  test "Operator DeskLive at zero tickets: kit empty_state + the New ticket CTA" do
    html = render_live(Samen.Web.Operator.DeskLive, build_operator_mount(Ash.UUID.generate()), [])

    assert html =~ "empty-state"
    assert html =~ ~s(class="empty-icon")
    assert html =~ ~s(id="empty-new-desk-ticket")
  end

  # ---------------------------------------------------------------------------
  # Detail / sub-list surfaces — retrofitted from bare divs / zero-row tables
  # ---------------------------------------------------------------------------

  test "PipelineLive with no stages renders the kit empty_state (was a bare muted div)" do
    html = render_live(Samen.Web.CRM.PipelineLive, build_mount(:crm), [Ash.UUID.generate()])
    assert html =~ "pipeline-empty"
    assert html =~ "empty-state"
  end

  test "Chat ThreadsLive with no threads renders the kit empty_state (was a zero-row table)" do
    mount = Mount.new(:chat, Samen.WebTest.Chat, Samen.WebTest.Repo)
    html = render_live(Samen.Web.Chat.ThreadsLive, mount, [Ash.UUID.generate()])

    assert html =~ "threads-empty"
    assert html =~ "empty-state"
    refute html =~ "thread-row"
  end

  test "Operator PlatformBillingLive with no billing rows renders BOTH kit empty_states (was zero-row tables)" do
    html = render_live(Samen.Web.Operator.PlatformBillingLive, build_operator_mount(Ash.UUID.generate()), [])

    assert html =~ "subscriptions-empty"
    assert html =~ "invoices-empty"
    refute html =~ "<table>"
  end

  test "Operator AggregateLive on a bare mount renders the kit empty_state (was a bare muted div)" do
    html = render_live(Samen.Web.Operator.AggregateLive, build_operator_mount(Ash.UUID.generate()), [])
    assert html =~ "aggregate-empty"
    assert html =~ "empty-state"
  end

  # ---------------------------------------------------------------------------
  # PLANE red path — the empty-state CTA is a WRITE affordance: absent when masked
  # ---------------------------------------------------------------------------

  test "RED PATH: on the operator plane the create CTA is ABSENT from the empty state (contacts + tickets), the empty state itself remains" do
    org_id = Ash.UUID.generate()

    for {module, kind, cta} <- [
          {Samen.Web.CRM.ContactsLive, :crm, "empty-new-contact"},
          {Samen.Web.Support.TicketsLive, :support, "empty-new-ticket"}
        ] do
      html = render_live(module, build_mount(kind, plane: :operator, target_org_id: org_id), [org_id])

      assert html =~ "empty-state", "#{inspect(module)} operator plane lost the empty state"
      refute html =~ ~s(id="#{cta}"), "#{inspect(module)} leaked its create CTA onto the operator plane"
    end
  end
end
