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
      # T142: mounting WITH an :actor_resolver compiles (the safe-by-construction happy path).
      samen_mcp_route(actor_resolver: {Some.Host.KeyAuthPlug, :resolve_scope, []})
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
    # T142: the MCP route mounted WITH a resolver (in HostRouter above) registered its forward.
    assert "/mcp" in paths
  end

  # T142 — samen_mcp_route is safe-by-construction: no :actor_resolver ⇒ compile-time refusal.
  describe "T142: samen_mcp_route requires an :actor_resolver (no insecure default)" do
    test "the guard refuses opts with no :actor_resolver and accepts opts with one" do
      assert_raise ArgumentError, ~r/actor_resolver/, fn ->
        Samen.Web.Router.__require_actor_resolver__!([])
      end

      assert_raise ArgumentError, ~r/actor_resolver/, fn ->
        Samen.Web.Router.__require_actor_resolver__!(path: "/mcp", tool_opts: [])
      end

      assert :ok =
               Samen.Web.Router.__require_actor_resolver__!(
                 actor_resolver: {Some.Host.KeyAuthPlug, :resolve_scope, []}
               )
    end

    test "mounting samen_mcp_route/1 with NO :actor_resolver RAISES at macro expansion (won't compile)" do
      assert_raise ArgumentError, ~r/actor_resolver/, fn ->
        defmodule McpNoResolverProbeRouter do
          use Phoenix.Router
          import Samen.Web.Router

          scope "/" do
            samen_mcp_route()
          end
        end
      end
    end
  end

  # T118 (ADR-039 §12 done-criterion 4) — the tenant automation builder macro.
  # A real host router that mounts it via ONE macro call — if the macro is broken,
  # THIS MODULE FAILS TO COMPILE, the same expansion proof `HostRouter` gives crm/
  # billing/support/marketing above.
  defmodule AutomationHostRouter do
    use Phoenix.Router
    import Phoenix.LiveView.Router
    import Samen.Web.Router

    scope "/" do
      samen_automation_routes(:automation, Some.Host.Automation, repo: Some.Host.Repo)
    end
  end

  test "the automation route table maps ONE builder page (list + author/edit modal)" do
    routes = Samen.Web.Router.__routes__(:automation, "/automation")
    assert routes == [{"/automation", Samen.Web.Automation.BuilderLive}]
  end

  test "the automation host router compiled and registered the builder route" do
    paths = AutomationHostRouter.__routes__() |> Enum.map(& &1.path)
    assert "/automation" in paths
  end

  test "samen_automation_routes/3 accepts NO :plane option — the mount is always tenant (INV-2)" do
    # Unlike samen_flags_routes/samen_files_routes/etc, this macro's expansion (see
    # its definition) hardcodes `plane: Samen.Web.Plane.tenant()` — it never reads a
    # `:plane` opt at all. Passing one is simply ignored (no compile error, no
    # runtime branch reads it), which is itself the INV-2 proof: there is no code
    # path in this macro that could ever produce an operator-plane mount.
    defmodule AutomationOperatorAttemptRouter do
      use Phoenix.Router
      import Phoenix.LiveView.Router
      import Samen.Web.Router

      scope "/" do
        samen_automation_routes(:automation, Some.Host.Automation,
          repo: Some.Host.Repo,
          plane: :operator,
          target_org_id: "ignored"
        )
      end
    end

    paths = AutomationOperatorAttemptRouter.__routes__() |> Enum.map(& &1.path)
    assert "/automation" in paths
  end
end
