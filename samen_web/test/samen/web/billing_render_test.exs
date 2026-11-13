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

  describe "subscription MRR column (eval 2026-11-13 tenant-b F06)" do
    defp add_subscription!(org_id, plan_name, price_cents, interval) do
      admin = %{org_id: org_id, role: :admin}

      plan =
        Samen.WebTest.Billing.Plan
        |> Ash.Changeset.for_create(
          :create,
          %{org_id: org_id, name: plan_name, label: String.capitalize(plan_name), interval: :monthly, enabled: true},
          actor: admin,
          authorize?: false
        )
        |> Ash.create!()

      if price_cents do
        Samen.WebTest.Billing.Price
        |> Ash.Changeset.for_create(
          :create,
          %{
            org_id: org_id,
            plan_id: plan.id,
            unit_amount: Samen.Type.Money.from_cents(price_cents, :USD),
            interval: interval,
            active: true
          },
          actor: admin,
          authorize?: false
        )
        |> Ash.create!()
      end

      customer =
        Samen.WebTest.Billing.Customer
        |> Ash.Changeset.for_create(
          :create,
          %{org_id: org_id, billing_name: "Cust #{plan_name}", billing_email: "#{plan_name}@example.test", status: :active, currency: "USD"},
          authorize?: false
        )
        |> Ash.create!()

      Samen.WebTest.Billing.Subscription
      |> Ash.Changeset.for_create(
        :create,
        %{org_id: org_id, customer_id: customer.id, plan_id: plan.id, status: :active},
        actor: %{org_id: org_id, role: :member},
        authorize?: false
      )
      |> Ash.create!()
    end

    test "the MRR cell is the plan's real price, whatever the plan is called", %{org_id: org_id} do
      # Plan NAMES that the old code priced at $99 / $799 — their real prices differ.
      add_subscription!(org_id, "starter", 1_250, :monthly)
      add_subscription!(org_id, "scale", 120_000, :annual)

      html = render_live(Samen.Web.Billing.OverviewLive, build_mount(:billing), [org_id])

      assert html =~ "$12.50/mo"
      # An annual $1,200.00 price is $100.00 a month.
      assert html =~ "$100.00/mo"
      refute html =~ "$99/mo"
      refute html =~ "$799/mo"
      # The seeded growth plan's real price still shows (not a name lookup).
      assert html =~ "$299.00/mo"
    end

    test "a plan with no price shows an em dash, not an invented amount", %{org_id: org_id} do
      add_subscription!(org_id, "scale", nil, nil)

      html = render_live(Samen.Web.Billing.OverviewLive, build_mount(:billing), [org_id])

      refute html =~ "$799"
      assert Regex.match?(~r/sub-mrr[^>]*>\s*—\s*</, html)
    end
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
