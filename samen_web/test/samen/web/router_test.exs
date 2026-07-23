defmodule Samen.Web.RouterTest do
  @moduledoc """
  Tests the router macro's route table + plane building. A full `Phoenix.Router` that `import
  Samen.Web.Router` and calls `samen_module_routes/3` compiles below — proving the macro
  expands into real `live` routes threaded through a `live_session` carrying the mount.
  """
  use ExUnit.Case, async: true

  # A real host router that mounts all three modules via the macro — if the macro is broken,
  # THIS MODULE FAILS TO COMPILE, which is the strongest possible test of expansion.
  defmodule HostRouter do
    use Phoenix.Router
    # A real host gets this via `use MyAppWeb, :router`; a bare Phoenix.Router needs it
    # explicitly (the macro expands `live_session` + `live`, both from this module).
    import Phoenix.LiveView.Router
    import Samen.Web.Router

    scope "/" do
      samen_module_routes(:crm, Some.Host.Crm, repo: Some.Host.Repo)
      samen_module_routes(:billing, Some.Host.Billing, repo: Some.Host.Repo)
      samen_module_routes(:support, Some.Host.Support, repo: Some.Host.Repo)
      samen_module_routes(:marketing, Some.Host.Marketing, repo: Some.Host.Repo)
    end
  end

  test "the CRM route table maps the three CRM pages to the framework LiveViews" do
    routes = Samen.Web.Router.__routes__(:crm, "/crm")

    assert {"/crm/companies", Samen.Web.CRM.CompaniesLive} in routes
    assert {"/crm/companies/:id", Samen.Web.CRM.CompanyLive} in routes
    assert {"/crm/contacts", Samen.Web.CRM.ContactsLive} in routes
    assert {"/crm/contacts/:id", Samen.Web.CRM.ContactLive} in routes
    assert {"/crm/pipeline", Samen.Web.CRM.PipelineLive} in routes
  end

  test "the Billing + Support route tables map their pages" do
    billing = Samen.Web.Router.__routes__(:billing, "/billing")
    assert {"/billing", Samen.Web.Billing.OverviewLive} in billing
    assert {"/billing/invoices", Samen.Web.Billing.InvoicesLive} in billing
    assert {"/billing/plans", Samen.Web.Billing.PlansLive} in billing
    assert {"/billing/settings", Samen.Web.Billing.SettingsLive} in billing

    support = Samen.Web.Router.__routes__(:support, "/support")
    assert {"/support", Samen.Web.Support.TicketsLive} in support
    assert {"/support/tickets/:id", Samen.Web.Support.TicketLive} in support
  end

  test "the Marketing route table maps the campaigns/segments/leads pages (ADR-011 §7)" do
    marketing = Samen.Web.Router.__routes__(:marketing, "/marketing")
    assert {"/marketing/campaigns", Samen.Web.Marketing.CampaignsLive} in marketing
    assert {"/marketing/campaigns/:id", Samen.Web.Marketing.CampaignLive} in marketing
    assert {"/marketing/segments", Samen.Web.Marketing.SegmentsLive} in marketing
    assert {"/marketing/leads", Samen.Web.Marketing.LeadsLive} in marketing
  end

  test "__plane__/1 defaults to tenant and honors :operator" do
    assert Samen.Web.Router.__plane__([]).kind == :tenant

    op = Samen.Web.Router.__plane__(plane: :operator, operator_id: "op", target_org_id: "t")
    assert op.kind == :operator
    assert op.operator_id == "op"
    assert op.target_org_id == "t"
  end

  test "the host router compiled and registered the mounted live routes" do
    paths = HostRouter.__routes__() |> Enum.map(& &1.path)

    assert "/crm/companies" in paths
    assert "/crm/companies/:id" in paths
    assert "/crm/contacts" in paths
    assert "/crm/contacts/:id" in paths
    assert "/billing" in paths
    assert "/support/tickets/:id" in paths
    assert "/marketing/campaigns" in paths
    assert "/marketing/campaigns/:id" in paths
    assert "/marketing/segments" in paths
    assert "/marketing/leads" in paths
  end
end
