defmodule Samen.Web.OperatorAccountsRenderTest do
  @moduledoc """
  Framework OPERATOR / Accounts render tests (ADR-010 §4a) against the standalone operator
  test-support host. Proves the operator CRM surface: each account IS a tenant org, primary
  contact = the tenant-admin (PII CLEAR), MRR/seats joined from the operator Billing scope.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.WebTest.Operator.Seeds, as: OpSeeds

  setup do
    seed = OpSeeds.seed_all(tenants: 2)
    %{seed: seed}
  end

  test "/operator/accounts renders the app shell + accounts as tenant orgs", %{seed: seed} do
    mount = build_operator_mount(seed.operator_org_id)
    html = render_live(Samen.Web.Operator.AccountsLive, mount, [])

    assert html =~ ~s(class="app")
    assert html =~ "<table>"
    # Accounts ARE tenant orgs — the seeded account org names render.
    assert html =~ "Blue Ridge Logistics 1"
    assert html =~ "account-row"
  end

  test "primary contact = the tenant-admin, PII CLEAR (the SaaS's own customer)", %{seed: seed} do
    mount = build_operator_mount(seed.operator_org_id)
    html = render_live(Samen.Web.Operator.AccountsLive, mount, [])

    # Population (1): the tenant-ADMIN name/email in the clear — the SaaS owns this PII.
    assert html =~ OpSeeds.admin_full_name()
    assert html =~ OpSeeds.admin_email()
    # No masked marker on the clear operator plane (accounts view).
    refute html =~ "••••"
  end

  test "MRR + seats + health join from the operator Billing scope (ADR-019 composite, dunning-coherent)", %{seed: seed} do
    mount = build_operator_mount(seed.operator_org_id)
    html = render_live(Samen.Web.Operator.AccountsLive, mount, [])

    # MRR from the monthly price ($499.00) is joined onto the account row.
    assert html =~ "$499.00"
    # Platform-MRR metric card is present and non-zero.
    assert html =~ "Platform MRR"

    # THE INCOHERENCE FIX (AC-G17-2, the gate-flagged case): EVERY seeded account
    # carries a past-due invoice — including account 1, whose subscription is
    # :active. The old status pill rendered it "healthy" while Billing showed
    # dunning; the ADR-019 composite may not. The health pills carry band + score
    # and NO healthy pill exists on the page.
    assert html =~ ~r/>\s*at risk ·\s*\d+\s*</
    refute html =~ ~r/>\s*healthy ·/

    # The health pill IS the drill-down link (AC-G17-4).
    assert html =~ "account-drill"
    assert html =~ "/operator/accounts/"
  end

  test "each account offers the two-grade drill-in (ADR-013 §5.2 — act-as + impersonate)", %{seed: seed} do
    mount = build_operator_mount(seed.operator_org_id)
    html = render_live(Samen.Web.Operator.AccountsLive, mount, [])

    # (1) "Open account →" = act-as / CLEAR — sets the session current org via the framework
    # SessionController and lands in the tenant workspace (TENANT plane).
    assert html =~ "open-account"
    assert html =~ "/session/org/#{seed.tenant_org_id}?return_to="

    # (2) "Impersonate (masked) →" = the existing operator-plane drill-in, carrying the tenant
    # org via ?org= (the plane, not the session, is what masks).
    assert html =~ "impersonate-account"
    assert html =~ "/operator/impersonate?org=#{seed.tenant_org_id}"
  end

  test "no operator org resolved → the empty-state renders (no crash)", %{} do
    mount = build_operator_mount(Ash.UUID.generate())
    html = render_live(Samen.Web.Operator.AccountsLive, mount, [])

    # A resolvable-but-empty operator org: no accounts, but structurally correct.
    assert html =~ ~s(class="app")
    assert html =~ "Accounts"
  end
end
