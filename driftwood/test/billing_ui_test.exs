defmodule Driftwood.BillingUiTest do
  @moduledoc """
  Billing UI smoke tests — the inherited Billing module rendered by the FRAMEWORK (ADR-009).

  The Billing pages are `Samen.Web.Billing.{Overview,Invoices,Plans}Live`, MOUNTED by
  `DriftwoodWeb.Router` (`samen_module_routes :billing, Driftwood.Billing, repo:
  Driftwood.Repo`) over Driftwood's materialized `Driftwood.Billing.*` resources. Deep
  render/masking coverage lives in samen_web (`web/billing_render_test.exs`); these tests
  prove Driftwood's OWN MOUNT renders Driftwood's rows on both planes.

    1. Each mounted Billing page renders with Driftwood's seeded rows (non-vacuous).
    2. MASKING (tenant-owner rule, kept over the driftwood mount):
       a. TENANT plane — a customer's billing_name renders IN THE CLEAR.
       b. OPERATOR plane — the SAME customer renders •••• and plaintext is ABSENT.
  """
  use Driftwood.DataCase, async: false

  alias Driftwood.Seeds
  alias Samen.Web.Billing

  setup do
    org_id = Ecto.UUID.generate()
    :ok = Seeds.run(org_id)
    assert Seeds.demo_all(org_id) == org_id
    %{org_id: org_id}
  end

  # ==========================================================================
  # MOUNTED ROUTES render Driftwood's seeded rows
  # ==========================================================================

  test "the mounted /billing (overview) renders metrics + Driftwood's subscriptions", %{org_id: org_id} do
    mount = driftwood_mount(:billing)
    html = render_framework(Billing.OverviewLive, mount, [org_id])

    assert html =~ ~s(class="app")
    assert html =~ "<table>"

    # Non-PII metric cards.
    assert html =~ "MRR"
    assert html =~ "Active subscriptions"
    assert html =~ "Outstanding"
    assert html =~ "Collected this month"

    # 6 customers seeded → 6 subscription rows.
    assert html =~ "subscription-row"

    refute html =~ "vt_"
  end

  test "the mounted /billing/invoices renders Driftwood's invoices", %{org_id: org_id} do
    mount = driftwood_mount(:billing)
    html = render_framework(Billing.InvoicesLive, mount, [org_id])

    assert html =~ "Total outstanding"
    assert html =~ "Invoices"
    assert html =~ "Paid"
    assert html =~ "Overdue"
    assert html =~ "INV-"
    assert html =~ "invoice-row"

    refute html =~ "vt_"
  end

  test "the mounted /billing/plans renders Driftwood's plans", %{org_id: org_id} do
    mount = driftwood_mount(:billing)
    html = render_framework(Billing.PlansLive, mount, [org_id])

    assert html =~ "Billing Plans"
    assert html =~ "monthly"
    assert html =~ "$"
    assert html =~ "plan-row"

    # Plans are non-PII.
    refute html =~ "vt_"
    refute html =~ "••••"
  end

  # ==========================================================================
  # MASKING over the driftwood mount — tenant clear / operator ••••
  # ==========================================================================

  describe "Billing customer PII masking over the Driftwood mount (tenant-owner rule)" do
    test "TENANT plane: customer billing_name renders IN THE CLEAR", %{org_id: org_id} do
      mount = driftwood_mount(:billing, plane: :tenant)
      html = render_framework(Billing.OverviewLive, mount, [org_id])

      # Non-vacuous: subscription rows present.
      assert html =~ "subscription-row"

      # "Acme Manufacturing Inc" is the first billing customer seeded.
      assert html =~ "Acme", "tenant plane did not render billing_name in the clear"
      refute html =~ "vt_"
    end

    test "OPERATOR/impersonation plane: customer billing_name renders •••• (no plaintext leak)", %{org_id: org_id} do
      mount = driftwood_mount(:billing, plane: :operator, target_org_id: org_id)
      html = render_framework(Billing.OverviewLive, mount, [org_id])

      # Non-vacuous: the SAME subscription rows present.
      assert html =~ "subscription-row"

      # MUST render •••• (the %Masked{} sentinel on the impersonation plane).
      assert html =~ "••••", "operator/impersonation plane did not mask customer billing_name"

      # MUST NOT render any seeded plaintext billing names.
      refute html =~ "Acme Manufacturing Inc", "operator plane leaked customer billing_name in plaintext"
      refute html =~ "Harbor Foods", "operator plane leaked customer billing_name in plaintext"

      refute html =~ "vt_"
    end

    test "CROSS-ORG: a tenant mount for a DIFFERENT org sees ZERO billing rows (org-scope isolation)", %{org_id: _org_id} do
      other_org = Ecto.UUID.generate()
      mount = driftwood_mount(:billing, plane: :tenant)
      html = render_framework(Billing.OverviewLive, mount, [other_org])

      refute html =~ "Acme"
      refute html =~ "Harbor Foods"
      refute html =~ "vt_"
    end
  end
end
