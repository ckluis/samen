defmodule Demo.OperatorRevenuePlanFloorTest do
  @moduledoc """
  WS-B / B3 — AC-G7-9 (M/RP): the CROSS-TENANT MRR-by-plan view goes through the
  token-blind `operator_aggregate` path UNDER the k-anon floor, proven against the
  REAL aggregate plane on the exact loader the framework `RevenueLive` consumes
  (`Demo.OperatorDashboard.revenue_plan_cohorts/0`, wired as `revenue_plan_loader:`).

  Demo floor config: k=2 (small dogfood datasets; production keeps k=5 — the SAME
  `Samen.Aggregate.Privacy` floor either way, only the config differs).

    * **Below-floor suppresses** — a plan cohort with tenant_count < k reaches the
      loader with `mrr_cents` = `%Suppressed{}`; the exact revenue NEVER leaves the
      chokepoint.
    * **Positive control** — a cohort at/above the floor is released with its exact
      value (the suppression is not an always-⊘).
    * **SABOTAGE / anti-tautology flip** — the SAME read with the floor sabotaged
      (`k: 1` at the chokepoint, i.e. the floor effectively removed) RELEASES the
      below-floor cohort's exact value. That flips the suppression assertion above:
      the value demonstrably exists and is withheld ONLY by the floor — the
      suppression test is load-bearing, not vacuous.
  """
  use Demo.DataCase, async: false

  alias Demo.Aggregate.MrrByTier
  alias Samen.Aggregate.Suppressed

  # The below-floor sentinel: one tenant's exact revenue. If this number is ever
  # released through the floored path, the floor is broken.
  @solo_cents 777_777

  # -- seeding (the floors-test billing helpers, minimal) -----------------------

  defp mk_org(name) do
    {:ok, org} =
      Demo.Identity.Org
      |> Ash.Changeset.for_create(:create, %{name: name})
      |> Ash.create(authorize?: false)

    org
  end

  defp one_tenant_on_plan!(plan_name, cents) do
    org = mk_org("Rev-#{System.unique_integer([:positive])}")

    {:ok, plan} =
      Demo.BillingScope.Plan
      |> Ash.Changeset.for_create(:create, %{name: plan_name, org_id: org.id})
      |> Ash.create(authorize?: false)

    {:ok, _price} =
      Demo.BillingScope.Price
      |> Ash.Changeset.for_create(:create, %{
        org_id: org.id,
        plan_id: plan.id,
        unit_amount_cents: cents,
        active: true
      })
      |> Ash.create(authorize?: false)

    {:ok, cust} =
      Demo.BillingScope.Customer
      |> Ash.Changeset.for_create(:create, %{
        org_id: org.id,
        billing_name: %{first: "Bill", last: "Payer"},
        billing_email: "billing@example.com"
      })
      |> Ash.create(authorize?: false)

    {:ok, _sub} =
      Demo.BillingScope.Subscription
      |> Ash.Changeset.for_create(:create, %{
        org_id: org.id,
        customer_id: cust.id,
        plan_id: plan.id,
        status: :active
      })
      |> Ash.create(authorize?: false)

    org
  end

  defp seed_cohorts! do
    # Below the k=2 floor: ONE tenant on "Bespoke" — its exact revenue must suppress.
    one_tenant_on_plan!("Bespoke", @solo_cents)
    # At the floor: TWO tenants on "Pro" — the positive control, released.
    one_tenant_on_plan!("Pro", 5_000)
    one_tenant_on_plan!("Pro", 5_000)
    {:ok, _} = Demo.Aggregate.Rebuild.run(Demo.Repo)
    :ok
  end

  test "AC-G7-9: a below-floor plan cohort reaches the RevenueLive loader SUPPRESSED; an at-floor cohort is released" do
    seed_cohorts!()

    cohorts = Demo.OperatorDashboard.revenue_plan_cohorts()
    by_plan = Map.new(cohorts, &{&1.plan, &1})

    # Below floor (1 < k=2): the loader — and therefore RevenueLive — gets ⊘-material,
    # never the exact 777_777.
    assert %Suppressed{reason: :k_anonymity, observed: 1} = by_plan["Bespoke"].mrr_cents

    # Positive control: the at-floor cohort's value is released (not an always-⊘).
    refute Suppressed.suppressed?(by_plan["Pro"].mrr_cents)
    assert by_plan["Pro"].mrr_cents == 10_000
    assert by_plan["Pro"].tenant_count == 2
  end

  test "AC-G7-9 RED-PATH (anti-tautology flip): sabotaging the floor (k: 1) RELEASES the below-floor value — the suppression above is the floor's doing" do
    seed_cohorts!()

    # The floored read (as the loader performs it): Bespoke is suppressed.
    {:ok, floored} = Samen.Aggregate.read_all(MrrByTier)
    floored_bespoke = Enum.find(floored, &(&1.tier == "Bespoke"))
    assert Suppressed.suppressed?(floored_bespoke.mrr_cents)

    # SABOTAGE: the same chokepoint read with the k-anon floor gutted (k: 1 admits a
    # count-of-one cohort). The exact solo-tenant revenue IS released — proving (a) the
    # value exists in the projection (the suppression test is not vacuous) and (b) a
    # broken floor flips that test red, exactly the AC-G7-9 sabotage contract.
    {:ok, sabotaged} = Samen.Aggregate.read_all(MrrByTier, k: 1)
    sabotaged_bespoke = Enum.find(sabotaged, &(&1.tier == "Bespoke"))

    refute Suppressed.suppressed?(sabotaged_bespoke.mrr_cents)
    assert sabotaged_bespoke.mrr_cents == @solo_cents
  end
end
