defmodule Samen.Web.MountSmokeTest do
  @moduledoc """
  WS-F4 QA — the THIN mount smoke sweep for the framework LiveView fleet (ADR-009).

  ONE mount assertion per framework LiveView, driven through the REAL `mount/3` +
  `handle_params/3` + `render/1` lifecycle a mounted `live_session` route runs
  (`Samen.WebTest.DataCase.mount_smoke/3` — the signed-session round-trip +
  `CurrentOrg.resolve/3` + the initial load + render). This guards the class of a
  documented past production 500: a page that renders fine in an isolated component
  test but 500s on mount through the router (session deserialization, current-org
  resolution, the initial keyset read). It is deliberately NOT an event sweep — no
  `handle_event/3` is driven here (that scope was declined; thin smoke only).

  The sweep is data-driven so every LiveView gets its own assertion and ALL mount
  failures surface in one run (a raise is captured per-entry, then the whole set is
  asserted green) — a new framework LiveView that forgets its mount path is caught
  the moment it is added to `Samen.Web.Router.__routes__/2`.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.Billing
  alias Samen.Web.Chat
  alias Samen.Web.CRM
  alias Samen.Web.Csv
  alias Samen.Web.Files
  alias Samen.Web.Flags
  alias Samen.Web.Marketing
  alias Samen.Web.Notifications
  alias Samen.Web.Operator
  alias Samen.Web.Search
  alias Samen.Web.Settings
  alias Samen.Web.Support

  setup do
    tenant = Seeds.seed_all()
    chat = Seeds.seed_chat(tenant.org_id)
    op = Samen.WebTest.Operator.Seeds.seed_all(tenants: 1)
    %{tenant: tenant, chat: chat, op: op, org: tenant.org_id}
  end

  test "every framework LiveView mounts through the real router/live_session path (no 500)", ctx do
    %{tenant: t, chat: chat, op: op, org: org} = ctx

    # {label, module, mount, params} — ONE mount smoke per framework LiveView.
    tenant_surfaces = [
      # CRM (ADR-009) — lists + details
      {"crm/companies", CRM.CompaniesLive, build_mount(:crm), %{"org" => org}},
      {"crm/contacts", CRM.ContactsLive, build_mount(:crm), %{"org" => org}},
      {"crm/pipeline", CRM.PipelineLive, build_mount(:crm), %{"org" => org}},
      {"crm/company", CRM.CompanyLive, build_mount(:crm), %{"org" => org, "id" => t.crm.company.id}},
      {"crm/contact", CRM.ContactLive, build_mount(:crm), %{"org" => org, "id" => t.crm.person.id}},
      # Billing
      {"billing/overview", Billing.OverviewLive, build_mount(:billing), %{"org" => org}},
      {"billing/invoices", Billing.InvoicesLive, build_mount(:billing), %{"org" => org}},
      {"billing/plans", Billing.PlansLive, build_mount(:billing), %{"org" => org}},
      # Support
      {"support/tickets", Support.TicketsLive, build_mount(:support), %{"org" => org}},
      {"support/ticket", Support.TicketLive, build_mount(:support), %{"org" => org, "id" => t.support.ticket.id}},
      # T78 (spec §I5) — the agent-facing KB (`:kb_namespace` sibling-mount seam) and
      # the UNAUTHENTICATED portal (`:kb`-kind mount, no session-derived actor at all).
      {"support/kb", Support.KbLive, build_mount(:support), %{"org" => org}},
      {"portal/kb", Support.PortalKbLive, build_mount(:kb), %{"org" => org}},
      # Marketing (ADR-011)
      {"marketing/campaigns", Marketing.CampaignsLive, build_mount(:marketing), %{"org" => org}},
      {"marketing/segments", Marketing.SegmentsLive, build_mount(:marketing), %{"org" => org}},
      {"marketing/leads", Marketing.LeadsLive, build_mount(:marketing), %{"org" => org}},
      {"marketing/campaign", Marketing.CampaignLive, build_mount(:marketing), %{"org" => org, "id" => t.marketing.campaign.id}},
      # Chat (ADR-012)
      {"chat/threads", Chat.ThreadsLive, build_mount(:chat), %{"org" => org}},
      {"chat/thread", Chat.ThreadLive, build_mount(:chat), %{"org" => org, "id" => chat.thread.id}},
      # Notifications (ADR-016)
      {"notifications/inbox", Notifications.InboxLive, build_mount(:notifications), %{"org" => org}},
      {"notifications/prefs", Notifications.PreferencesLive, build_mount(:notifications), %{"org" => org}},
      # Flags (ADR-020)
      {"flags/settings", Flags.SettingsLive, build_mount(:flags), %{"org" => org}},
      # Files (ADR-026) — the preview id is a fresh uuid (the not-found render path also mounts)
      {"files/upload", Files.UploadLive, build_mount(:files), %{"org" => org}},
      {"files/preview", Files.PreviewLive, build_mount(:files), %{"org" => org, "id" => Ash.UUID.generate()}},
      # CSV import (ADR-028) — a resolvable resource on the mount's domain
      {"csv/import", Csv.ImportLive, build_mount(:csv), %{"org" => org, "resource" => "person"}},
      # Search (ADR-027)
      {"search", Search.SearchLive, build_mount(:search), %{"org" => org}},
      # Self-serve settings (ADR-029) — Identity/operator namespace; nil-user branch also mounts
      {"settings/profile", Settings.ProfileLive, build_mount(:settings), %{"org" => op.operator_org_id}},
      {"settings/api-keys", Settings.ApiKeysLive, build_mount(:settings), %{"org" => op.operator_org_id}},
      {"settings/security", Settings.SecurityLive, build_mount(:settings), %{"org" => op.operator_org_id}}
    ]

    # Operator cockpit (ADR-010) — the operator seat over its own book of business.
    op_mount = build_operator_mount(op.operator_org_id)
    op_flags_mount = build_operator_mount(op.operator_org_id, labels: %{flags_namespace: Samen.WebTest.Primitives})

    operator_surfaces = [
      {"operator/accounts", Operator.AccountsLive, op_mount, %{}},
      {"operator/account_detail", Operator.AccountDetailLive, op_mount, %{"id" => op.tenant_org_id}},
      {"operator/platform_billing", Operator.PlatformBillingLive, op_mount, %{}},
      {"operator/revenue", Operator.RevenueLive, op_mount, %{}},
      {"operator/analytics", Operator.AnalyticsLive, op_mount, %{}},
      {"operator/desk", Operator.DeskLive, op_mount, %{}},
      {"operator/flag_admin", Operator.FlagAdminLive, op_flags_mount, %{}},
      {"operator/aggregate", Operator.AggregateLive, op_mount, %{}}
    ]

    surfaces = tenant_surfaces ++ operator_surfaces

    # UploadLive reads live-upload assigns in render/1 that only a connected socket
    # supplies; the smoke drives the real mount, then stubs those render-only assigns.
    extra = %{
      {"files/upload", Files.UploadLive} => %{upload_ref: :file_upload}
    }

    failures =
      Enum.reduce(surfaces, [], fn {label, module, mount, params}, acc ->
        try do
          html = mount_smoke(module, mount, params, Map.get(extra, {label, module}, %{}))
          if is_binary(html) and byte_size(html) > 0, do: acc, else: [{label, "empty render"} | acc]
        rescue
          e -> [{label, Exception.format(:error, e, __STACKTRACE__) |> String.slice(0, 400)} | acc]
        catch
          kind, reason -> [{label, "#{kind}: #{inspect(reason)}"} | acc]
        end
      end)

    assert failures == [],
           "the following framework LiveViews failed to mount:\n" <>
             Enum.map_join(Enum.reverse(failures), "\n\n", fn {l, e} -> "  * #{l}: #{e}" end)

    # Non-vacuity: the sweep actually covered the whole fleet (guards an empty table).
    assert length(surfaces) >= 30
  end
end
