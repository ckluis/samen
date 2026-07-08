defmodule Samen.Web.BillingRenderTest do
  @moduledoc """
  Framework Billing render tests against the test-support host. The two-plane guarantee on the
  Billing customer PII (`billing_name` / `billing_email`): tenant clear vs operator ••••.
  """
  use Samen.WebTest.DataCase, async: false

  setup do
    %{org_id: org_id} = Seeds.seed_all()
    %{org_id: org_id}
  end

  test "/billing renders the app shell + seeded subscription with the customer", %{org_id: org_id} do
    mount = build_mount(:billing)
    html = render_live(Samen.Web.Billing.OverviewLive, mount, [org_id])

    assert html =~ ~s(class="app")
    assert html =~ "subscription-row"
    assert html =~ Seeds.customer_name()
  end

  test "/billing/plans renders the seeded plan (non-PII config rows)", %{org_id: org_id} do
    mount = build_mount(:billing)
    html = render_live(Samen.Web.Billing.PlansLive, mount, [org_id])

    assert html =~ "plan-row"
    assert html =~ "Growth"
  end

  test "TENANT plane: /billing/invoices shows the customer billing_name in the clear", %{org_id: org_id} do
    mount = build_mount(:billing, plane: :tenant)
    html = render_live(Samen.Web.Billing.InvoicesLive, mount, [org_id])

    assert html =~ "invoice-row"
    assert html =~ Seeds.customer_name()
  end

  test "OPERATOR plane: /billing/invoices masks billing_name ••••, plaintext absent", %{org_id: org_id} do
    mount = build_mount(:billing, plane: :operator, target_org_id: org_id)
    html = render_live(Samen.Web.Billing.InvoicesLive, mount, [org_id])

    assert html =~ "invoice-row"
    assert html =~ "••••"
    refute html =~ Seeds.customer_name()
  end

  test "OPERATOR plane: /billing overview masks customer name/email, no token leak", %{org_id: org_id} do
    mount = build_mount(:billing, plane: :operator, target_org_id: org_id)
    html = render_live(Samen.Web.Billing.OverviewLive, mount, [org_id])

    assert html =~ "••••"
    refute html =~ Seeds.customer_name()
    refute html =~ Seeds.customer_email()
    refute html =~ "vt_"
  end
end
