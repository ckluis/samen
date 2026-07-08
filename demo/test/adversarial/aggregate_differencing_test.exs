defmodule Demo.Adversarial.AggregateDifferencingTest do
  @moduledoc """
  T4.6 — ADVERSARIAL suite, category 3: AGGREGATE DIFFERENCING + K-ANON / L-DIVERSITY
  BYPASS ATTEMPTS.

  Consolidated Phase-4 attack surface (plan §6.3 "Aggregate differencing"), driven
  against the REAL `Demo.Aggregate` token-blind projections read ONLY through the
  `Samen.Aggregate.read_all/2` chokepoint (which routes every row set through
  `Samen.Aggregate.Privacy` — the k-anon + l-diversity floors). Demo floor: k=2 / l=2.

  Bypass vectors attacked (the operator tries to route AROUND the suppression):

    (1) FILTER bypass — an `Ash.Query.filter` narrowing the aggregate read to a
        count-of-one cohort. The filter runs at the DB, but the suppression rides the
        chokepoint's post-read pass, so the isolated cohort is STILL suppressed.
    (2) INCLUDE / raw-read bypass — reading the projection resource directly with
        `Ash.read` (skipping `read_all`) is DENIED by `AggregateActorOnly` for a
        non-aggregate actor; and even the aggregate actor's direct `Ash.read` returns
        the RAW projection rows WITHOUT the floor — which is precisely why the operator
        surface (dashboard) reads ONLY through `read_all`. This test proves the
        chokepoint is the only floor-applying path AND that the domain read is
        default-deny for everyone else.
    (3) REPEATED / DIFFERENCING queries — two overlapping cohort reads isolating one
        subject. The k-anon floor catches the isolating (count-of-one) side; the
        per-cohort ledger records BOTH reads (collusion-resistant granularity — not
        per-actor). With enforcement OFF (the default) the subtler above-floor
        differencing residue is documented HONESTLY (the ledger observes, it does not
        block).
    (4) L-DIVERSITY homogeneity bypass — a homogeneous cohort (>= k but 1 distinct
        sensitive value) is SUPPRESSED under l-diversity, so an operator cannot read a
        big-but-uniform cohort to learn every member's sensitive value.
    (5) T6.6 BUDGET ENFORCEMENT (opt-in) — with the enforcing per-cohort budget ON, the
        above-floor differencing residue from (3) is now BLOCKED: a repeated read of an
        above-k cohort past its budget is SUPPRESSED (`reason: :query_budget`), and two
        colluding actors share ONE cohort budget. This is the cross-query defence
        promoted from accounting-only (T4.5) to enforcing (T6.6). The FORMAL DP
        composition guarantee remains posture — see the T6.6 report.

  POSITIVE CONTROL throughout: a >=k, l-diverse cohort in the SAME read IS released —
  so every suppression is the floor firing on cohort shape, not an always-suppress.

  Tag: `@moduletag :adversarial`.
  """
  use Demo.DataCase, async: false

  @moduletag :adversarial

  require Ash.Query

  alias Demo.Aggregate.{MrrByTier, TicketQueueDepth}
  alias Samen.Aggregate.{Actor, QueryBudget, Suppressed}

  # --- seeding helpers -------------------------------------------------------

  defp mk_org(name) do
    {:ok, org} =
      Demo.Identity.Org |> Ash.Changeset.for_create(:create, %{name: name}) |> Ash.create(authorize?: false)

    org
  end

  defp mk_plan(org_id, name) do
    {:ok, plan} =
      Demo.BillingScope.Plan
      |> Ash.Changeset.for_create(:create, %{name: name, org_id: org_id})
      |> Ash.create(authorize?: false)

    plan
  end

  defp mk_price(org_id, plan_id, cents) do
    {:ok, price} =
      Demo.BillingScope.Price
      |> Ash.Changeset.for_create(:create, %{org_id: org_id, plan_id: plan_id, unit_amount_cents: cents, active: true})
      |> Ash.create(authorize?: false)

    price
  end

  defp mk_customer(org_id) do
    {:ok, cust} =
      Demo.BillingScope.Customer
      |> Ash.Changeset.for_create(:create, %{
        org_id: org_id,
        billing_name: %{first: "Bill", last: "Payer"},
        billing_email: "billing@example.com"
      })
      |> Ash.create(authorize?: false)

    cust
  end

  defp mk_subscription(org_id, customer_id, plan_id) do
    {:ok, sub} =
      Demo.BillingScope.Subscription
      |> Ash.Changeset.for_create(:create, %{org_id: org_id, customer_id: customer_id, plan_id: plan_id, status: :active})
      |> Ash.create(authorize?: false)

    sub
  end

  defp mk_ticket(org_id, status, priority) do
    {:ok, t} =
      Demo.SupportScope.Ticket
      |> Ash.Changeset.for_create(:create, %{
        subject: "Ticket #{System.unique_integer([:positive])}",
        status: status,
        priority: priority,
        org_id: org_id
      })
      |> Ash.create(authorize?: false)

    t
  end

  defp one_tenant_on_tier!(tier_name, cents) do
    org = mk_org("Solo-#{System.unique_integer([:positive])}")
    plan = mk_plan(org.id, tier_name)
    mk_price(org.id, plan.id, cents)
    cust = mk_customer(org.id)
    mk_subscription(org.id, cust.id, plan.id)
    org
  end

  defp two_tenants_on_tier!(tier_name, cents) do
    for _ <- 1..2, do: one_tenant_on_tier!(tier_name, cents)
    :ok
  end

  # ==========================================================================
  # (1) FILTER bypass — narrowing to a count-of-one cohort STILL suppresses
  # ==========================================================================

  test "RED (filter bypass): filtering the aggregate read down to a count-of-one tier STILL suppresses" do
    one_tenant_on_tier!("Bespoke", 777_777)
    two_tenants_on_tier!("Pro", 5000)
    {:ok, _} = Demo.Aggregate.Rebuild.run(Demo.Repo)

    # The attacker narrows the read to the isolating cohort via a query filter, hoping
    # the DB-level narrowing dodges the suppression. It does not — the floor rides the
    # read_all chokepoint's post-read pass (the filter is passed via the :query option,
    # the only way a filtered read reaches the plane).
    query = MrrByTier |> Ash.Query.filter(tier == "Bespoke")
    {:ok, rows} = Samen.Aggregate.read_all(MrrByTier, query: query)

    bespoke = Enum.find(rows, &(&1.tier == "Bespoke"))
    assert %Suppressed{reason: :k_anonymity, observed: 1} = bespoke.mrr_cents

    # POSITIVE CONTROL: the SAME filtered path on a >=k cohort releases.
    query2 = MrrByTier |> Ash.Query.filter(tier == "Pro")
    {:ok, rows2} = Samen.Aggregate.read_all(MrrByTier, query: query2)
    pro = Enum.find(rows2, &(&1.tier == "Pro"))
    refute Suppressed.suppressed?(pro.mrr_cents)
    assert pro.mrr_cents == 10_000
  end

  # ==========================================================================
  # (2) INCLUDE / raw-read bypass — the chokepoint is the ONLY floor-applying path,
  #     and the domain is default-deny for non-aggregate actors
  # ==========================================================================

  test "RED (raw-read bypass): a non-aggregate actor reading the projection directly is DENIED" do
    one_tenant_on_tier!("Bespoke", 999)
    {:ok, _} = Demo.Aggregate.Rebuild.run(Demo.Repo)

    tenant_actor = %{id: "tenant-user", org_id: Ash.UUID.generate(), role: :admin}
    op_actor = %{id: "op-1", kind: :operator}

    for actor <- [tenant_actor, op_actor] do
      result = Ash.read(MrrByTier, actor: actor, authorize?: true)

      case result do
        {:ok, rows} -> assert rows == [], "a non-aggregate actor must read ZERO aggregate rows"
        {:error, _forbidden} -> assert true
      end
    end
  end

  test "the read_all chokepoint is the ONLY path that applies the floor (raw aggregate-actor read is unfloored)" do
    one_tenant_on_tier!("Bespoke", 424_242)
    {:ok, _} = Demo.Aggregate.Rebuild.run(Demo.Repo)

    agg = Actor.new()

    # A DIRECT Ash.read as the aggregate actor returns the RAW projection rows WITHOUT
    # the floor (the floor lives in read_all, not the resource policy). This is exactly
    # why the operator surface reads ONLY through read_all — proven below.
    {:ok, raw_rows} = Ash.read(MrrByTier, actor: agg, authorize?: true)
    raw_bespoke = Enum.find(raw_rows, &(&1.tier == "Bespoke"))
    # The raw row's value is NOT a Suppressed sentinel (it is the unfloored count).
    refute Suppressed.suppressed?(raw_bespoke.mrr_cents)

    # The floor-applying chokepoint suppresses the SAME count-of-one cohort.
    {:ok, floored} = Samen.Aggregate.read_all(MrrByTier)
    floored_bespoke = Enum.find(floored, &(&1.tier == "Bespoke"))
    assert %Suppressed{} = floored_bespoke.mrr_cents

    # AND the operator dashboard (the real egress) reads ONLY through read_all, so the
    # value never leaves the plane — the raw path is not reachable by the operator UI.
    {:ok, %{suppressed_tiers: suppressed}} = Demo.OperatorDashboard.mrr()
    assert "Bespoke" in suppressed
  end

  # ==========================================================================
  # (3) REPEATED / DIFFERENCING queries — the isolating side is caught; the ledger
  #     accounts per COHORT (not per actor); the above-floor residue is honest
  # ==========================================================================

  test "RED (differencing): two overlapping reads isolating one subject — the isolating (count-of-one) side is SUPPRESSED" do
    for _ <- 1..3, do: one_tenant_on_tier!("Team", 3000)
    one_tenant_on_tier!("Bespoke", 999_000)
    {:ok, _} = Demo.Aggregate.Rebuild.run(Demo.Repo)

    ledger_before = Demo.Repo.aggregate(Samen.Aggregate.QueryLedgerRow, :count)

    # QUERY 1 (larger cohort) and QUERY 2 (isolating cohort) — the differencing pattern.
    {:ok, rows} = Samen.Aggregate.read_all(MrrByTier)
    by_tier = Map.new(rows, &{&1.tier, &1})

    # The differencing payoff (one subject's exact revenue) is DENIED by k-anon.
    assert %Suppressed{reason: :k_anonymity, observed: 1} = by_tier["Bespoke"].mrr_cents
    # The larger cohort releases (it does not isolate a subject on its own).
    assert by_tier["Team"].mrr_cents == 9000

    # The ledger accounts BOTH cohorts per-cohort (collusion-resistant granularity).
    ledger_after = Demo.Repo.aggregate(Samen.Aggregate.QueryLedgerRow, :count)
    assert ledger_after > ledger_before
    assert QueryBudget.count(%{resource: MrrByTier, cohort_key: "tier=Bespoke"}) >= 1
    assert QueryBudget.count(%{resource: MrrByTier, cohort_key: "tier=Team"}) >= 1

    # HONEST RESIDUE (T6.6): the ledger does NOT block the second overlapping query;
    # there is no cross-query suppression / DP noise / t-closeness yet. We assert the
    # honest state — NO read was blocked by the budget (the scaffold never enforces).
    assert QueryBudget.over_threshold?(%{resource: MrrByTier, cohort_key: "tier=Team"}) == false
  end

  test "COLLUSION: two distinct actors querying the SAME cohort accrue against ONE per-cohort count" do
    two_tenants_on_tier!("Pro", 5000)
    {:ok, _} = Demo.Aggregate.Rebuild.run(Demo.Repo)

    actor_1 = %{id: "colluder-1", kind: :operator_aggregate}
    actor_2 = %{id: "colluder-2", kind: :operator_aggregate}

    {:ok, _} = Samen.Aggregate.read_all(MrrByTier, actor: actor_1)
    {:ok, _} = Samen.Aggregate.read_all(MrrByTier, actor: actor_2)

    # Per-cohort accounting means the count reflects BOTH reads (2) — a per-actor
    # budget would have given each a fresh count of 1 (the wrong unit the doc names).
    assert QueryBudget.count(%{resource: MrrByTier, cohort_key: "tier=Pro"}) == 2
  end

  # ==========================================================================
  # (5) T6.6 — BUDGET ENFORCEMENT (opt-in): the cross-query defence, now REAL.
  #     T4.5 could only RECORD the repeated/differencing pattern. With the enforcing
  #     budget on (per-cohort, collusion-resistant), the OVER-BUDGET read of a cohort is
  #     now SUPPRESSED — the isolation the differencing attacker builds on is blocked.
  # ==========================================================================

  # Turn on the enforcing budget with a per-cohort budget of `n` for ONE test body, then
  # restore. Enforcement is OPT-IN and OFF by default (so all the T4.5 tests above see
  # the accounting-only behaviour) — this helper scopes it to the T6.6 tests.
  defp with_budget_enforcement(per_cohort, fun) do
    keys = [:query_budget_enforce, :query_budget_per_cohort, :query_budget_global]
    saved = for k <- keys, into: %{}, do: {k, Application.get_env(:samen_core, k)}

    Application.put_env(:samen_core, :query_budget_enforce, true)
    Application.put_env(:samen_core, :query_budget_per_cohort, per_cohort)
    Application.delete_env(:samen_core, :query_budget_global)

    try do
      fun.()
    after
      Enum.each(saved, fn
        {k, nil} -> Application.delete_env(:samen_core, k)
        {k, v} -> Application.put_env(:samen_core, k, v)
      end)
    end
  end

  test "T6.6 RED (budget blocks differencing): with the enforcing budget on, a REPEATED read of the same cohort is SUPPRESSED — the isolation T4.5 could only record is now blocked" do
    # A large cohort (Team: 3 tenants) that CLEARS the k-anon floor — so under T4.5 it
    # released on every read, and a differencing attacker could re-read it (and its N-1
    # variant) freely to isolate a subject. The k-anon floor does NOT stop this cohort
    # (it is above k). The BUDGET does.
    for _ <- 1..3, do: one_tenant_on_tier!("Team", 3000)
    {:ok, _} = Demo.Aggregate.Rebuild.run(Demo.Repo)

    with_budget_enforcement(1, fn ->
      # READ 1: the Team cohort (above k) is RELEASED — budget of 1 not yet spent.
      {:ok, rows1} = Samen.Aggregate.read_all(MrrByTier)
      team1 = Enum.find(rows1, &(&1.tier == "Team"))
      refute Suppressed.suppressed?(team1.mrr_cents)
      assert team1.mrr_cents == 9000

      # READ 2: the differencing attacker's second overlapping read of the SAME cohort.
      # T4.5 would have RELEASED this again (the ledger only recorded it). Now the
      # per-cohort budget of 1 is SPENT → the cohort is SUPPRESSED with reason
      # :query_budget. The repeated-read lever the differencing attack needs is blocked.
      {:ok, rows2} = Samen.Aggregate.read_all(MrrByTier)
      team2 = Enum.find(rows2, &(&1.tier == "Team"))
      assert %Suppressed{reason: :query_budget, limit: 1} = team2.mrr_cents
    end)
  end

  test "T6.6 RED (collusion hits the shared budget): two actors reading the SAME cohort spend ONE budget — the second is SUPPRESSED, not served a fresh budget" do
    for _ <- 1..3, do: one_tenant_on_tier!("Growth", 8000)
    {:ok, _} = Demo.Aggregate.Rebuild.run(Demo.Repo)

    with_budget_enforcement(1, fn ->
      actor_1 = %{id: "colluder-A", kind: :operator_aggregate}
      actor_2 = %{id: "colluder-B", kind: :operator_aggregate}

      # colluder-A reads (budget of 1 — served).
      {:ok, rows_a} = Samen.Aggregate.read_all(MrrByTier, actor: actor_1)
      assert Enum.find(rows_a, &(&1.tier == "Growth")).mrr_cents == 24_000

      # colluder-B (a coordinating account) reads the SAME cohort. A PER-ACTOR budget
      # would give B a fresh budget and serve it — the collusion the doc names. It does
      # NOT: the shared per-cohort budget is spent, so B's read is SUPPRESSED.
      {:ok, rows_b} = Samen.Aggregate.read_all(MrrByTier, actor: actor_2)
      assert %Suppressed{reason: :query_budget} = Enum.find(rows_b, &(&1.tier == "Growth")).mrr_cents
    end)
  end

  test "T6.6 anti-tautology (budget is a discriminator): under the budget the cohort RELEASES; over the budget the SAME cohort SUPPRESSES" do
    for _ <- 1..3, do: one_tenant_on_tier!("Scale", 6000)
    {:ok, _} = Demo.Aggregate.Rebuild.run(Demo.Repo)

    with_budget_enforcement(2, fn ->
      # Budget of 2: reads 1 and 2 RELEASE (under/at budget); read 3 SUPPRESSES (over).
      {:ok, r1} = Samen.Aggregate.read_all(MrrByTier)
      {:ok, r2} = Samen.Aggregate.read_all(MrrByTier)
      refute Suppressed.suppressed?(Enum.find(r1, &(&1.tier == "Scale")).mrr_cents)
      refute Suppressed.suppressed?(Enum.find(r2, &(&1.tier == "Scale")).mrr_cents)

      {:ok, r3} = Samen.Aggregate.read_all(MrrByTier)
      assert %Suppressed{reason: :query_budget} = Enum.find(r3, &(&1.tier == "Scale")).mrr_cents
    end)
  end

  test "T6.6: with enforcement OFF (default) the differencing residue is UNCHANGED — the same repeated read still RELEASES (T4.5 honesty preserved)" do
    for _ <- 1..3, do: one_tenant_on_tier!("Legacy", 4000)
    {:ok, _} = Demo.Aggregate.Rebuild.run(Demo.Repo)

    # No with_budget_enforcement — enforcement is OFF (the demo default).
    refute Samen.Aggregate.QueryBudget.enforce?()

    {:ok, r1} = Samen.Aggregate.read_all(MrrByTier)
    {:ok, r2} = Samen.Aggregate.read_all(MrrByTier)

    # Both reads release — the budget does NOT deny when enforcement is off. This is the
    # honest T4.5 residue: the ledger records, it does not block. The enforcing budget is
    # opt-in; a host must turn it on to get the cross-query defence.
    refute Suppressed.suppressed?(Enum.find(r1, &(&1.tier == "Legacy")).mrr_cents)
    refute Suppressed.suppressed?(Enum.find(r2, &(&1.tier == "Legacy")).mrr_cents)
  end

  # ==========================================================================
  # (4) L-DIVERSITY homogeneity bypass — a big-but-uniform cohort STILL suppresses
  # ==========================================================================

  test "RED (l-div bypass): a homogeneous cohort (>= k, 1 distinct priority) is SUPPRESSED" do
    org = mk_org("Homo-#{System.unique_integer([:positive])}")
    # "pending": 4 tickets, ALL :urgent → depth 4 >= k=2 but distinct_priorities=1 < l=2.
    for _ <- 1..4, do: mk_ticket(org.id, :pending, :urgent)
    # "open": 3 tickets spanning 2 priorities → clears k AND l (positive control).
    mk_ticket(org.id, :open, :normal)
    mk_ticket(org.id, :open, :high)
    mk_ticket(org.id, :open, :normal)
    {:ok, _} = Demo.Aggregate.Rebuild.run(Demo.Repo)

    {:ok, rows} = Samen.Aggregate.read_all(TicketQueueDepth)
    by_status = Map.new(rows, &{&1.status, &1})

    # An operator cannot read a large-but-uniform cohort to learn every member's value.
    assert %Suppressed{reason: :l_diversity, observed: 1} = by_status["pending"].depth

    # POSITIVE CONTROL: the diverse cohort releases in the SAME read.
    refute Suppressed.suppressed?(by_status["open"].depth)
    assert by_status["open"].depth == 3
  end
end
