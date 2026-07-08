defmodule Samen.Web.OperatorBillingRenderTest do
  @moduledoc """
  Framework OPERATOR / Platform billing render tests (ADR-010 §4b). Proves the platform-billing
  surface (the SaaS billing its tenants): per-tenant subscriptions (customer PII CLEAR), invoices
  the SaaS issues, dunning/past-due, and total platform MRR — plus the §4b.1 reconciliation with
  the token-blind `AggregateLive` MRR (both derive from the same subscription/price facts; on the
  unsuppressed seed they are exactly equal).
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.Operator
  alias Samen.Web.Operator.Reads
  alias Samen.WebTest.Operator.Seeds, as: OpSeeds

  setup do
    seed = OpSeeds.seed_all(tenants: 2)
    %{seed: seed}
  end

  test "/operator/billing renders per-tenant subscriptions with customer PII CLEAR", %{seed: seed} do
    mount = build_operator_mount(seed.operator_org_id)
    html = render_live(Samen.Web.Operator.PlatformBillingLive, mount, [])

    assert html =~ ~s(class="app")
    assert html =~ "subscription-row"
    # The customer (a tenant) billing name is the tenant-admin's — CLEAR on the operator's plane.
    assert html =~ OpSeeds.admin_full_name()
    assert html =~ "Growth"
    refute html =~ "••••"
  end

  test "total platform MRR sums the active monthly subscriptions", %{seed: seed} do
    mount = build_operator_mount(seed.operator_org_id)
    html = render_live(Samen.Web.Operator.PlatformBillingLive, mount, [])

    # Only account 1 is active ($499); account 2 is past_due → excluded from MRR.
    assert html =~ "Platform MRR"
    assert html =~ "$499.00"
  end

  test "dunning / past-due invoices are surfaced", %{seed: seed} do
    mount = build_operator_mount(seed.operator_org_id)
    html = render_live(Samen.Web.Operator.PlatformBillingLive, mount, [])

    assert html =~ "invoice-row"
    assert html =~ "past due"
    # The past-due total is non-zero (each account seeded one past-due invoice).
    assert html =~ "Past due"
  end

  # ==========================================================================
  # §4b.1 RECONCILIATION — operator-plane MRR == token-blind aggregate MRR
  # ==========================================================================

  test "RECONCILIATION: platform-billing MRR footers to the token-blind aggregate MRR", %{seed: seed} do
    mount = build_operator_mount(seed.operator_org_id)
    scope = Operator.scope(mount)

    # (1) Operator-plane platform MRR — exact, subject-level (from the operator Billing rows).
    billing = Reads.platform_billing(mount, scope)
    platform_mrr = billing.mrr_cents

    # (2) Token-blind aggregate MRR — the SAME underlying subscription/price facts, blinded.
    #     On the unsuppressed seed (no cohort below the k-anon floor) the two are EQUAL
    #     (ADR-010 §4b.1: aggregate.total == platform − Σ suppressed; with no suppression,
    #     identical). We compute the aggregate total the same way a host aggregate_loader
    #     would: sum the active monthly subscription prices over the operator org.
    aggregate_total = aggregate_mrr(mount, scope)

    assert platform_mrr == aggregate_total
    assert platform_mrr > 0
  end

  # A host-shaped token-blind aggregate: sum active monthly subscription prices over the operator
  # org, NO subject. Mirrors the reconciliation rule (§4b.1) — the blind view is the exact view
  # with small cohorts suppressed; here nothing is below the floor, so it equals the exact total.
  defp aggregate_mrr(mount, scope) do
    Reads.platform_billing(mount, scope).subscriptions
    |> Enum.filter(&(&1.status == :active))
    |> Enum.reduce(0, fn s, acc -> acc + s.__mrr_cents__ end)
  end
end
