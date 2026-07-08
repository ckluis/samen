defmodule Samen.QueryBudgetEnforcementTest do
  @moduledoc """
  T6.6 — the query-budget promoted from ACCOUNTING-ONLY (T4.5) to **ENFORCING**.

  Proves the cross-query defence the doc names ("a global, per-cohort query budget") is
  now real when opted in:

    * a cohort whose per-cohort budget is spent is DENIED (`check/2` → `{:deny, …}`);
    * enforcement is per-COHORT (not per-actor — the doc names per-actor as the wrong
      unit against collusion), so two coordinating actors querying the SAME cohort spend
      ONE shared budget and the second past the limit is denied;
    * a global budget denies past a cross-cohort read cap;
    * enforcement is OPT-IN — off by default (T4.5 accounting-only behaviour preserved);
    * the enforcement check fails OPEN (a ledger error does not take down the plane — the
      floors, which fail closed, are the independent single-query defence).

  Plus the ANTI-TAUTOLOGY probe: the SAME budget both DENIES (past limit) and ALLOWS
  (under limit) — it is a discriminator on the read count, not an always-deny.
  """
  use ExUnit.Case, async: false

  alias Samen.Aggregate.QueryBudget

  @repo SamenCore.TestRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    Ecto.Adapters.SQL.Sandbox.mode(@repo, {:shared, self()})

    # Snapshot the enforcement config and restore after each test (async: false).
    saved =
      for k <- [
            :query_budget_enforce,
            :query_budget_per_cohort,
            :query_budget_global,
            :query_budget_warn_threshold
          ],
          into: %{},
          do: {k, Application.get_env(:samen_core, k)}

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> Application.delete_env(:samen_core, k)
        {k, v} -> Application.put_env(:samen_core, k, v)
      end)
    end)

    :ok
  end

  defp enforce!(per_cohort, opts \\ []) do
    Application.put_env(:samen_core, :query_budget_enforce, true)
    Application.put_env(:samen_core, :query_budget_per_cohort, per_cohort)

    case Keyword.fetch(opts, :global) do
      {:ok, g} -> Application.put_env(:samen_core, :query_budget_global, g)
      :error -> Application.delete_env(:samen_core, :query_budget_global)
    end
  end

  # A read = record the cohort then check whether the budget is now spent (the read_all
  # pipeline order: record first so the count reflects this read, then check).
  defp read(cohort, resource \\ "R") do
    QueryBudget.record(%{resource: resource, cohort_key: cohort})
    QueryBudget.check(%{resource: resource, cohort_key: cohort})
  end

  # ==========================================================================
  # (a) BUDGET ENFORCEMENT — a spent cohort budget DENIES further reads
  # ==========================================================================

  test "enforce OFF (default): no read is ever denied (T4.5 accounting-only preserved)" do
    refute QueryBudget.enforce?()

    # Even far past any budget, check returns :ok when enforcement is off.
    for _ <- 1..10, do: QueryBudget.record(%{resource: "R", cohort_key: "c"})
    assert QueryBudget.check(%{resource: "R", cohort_key: "c"}) == :ok
  end

  test "RED (budget exhausted): a cohort whose per-cohort budget is SPENT suppresses further reads" do
    enforce!(2)

    # Budget of 2: the first two reads are served, the THIRD (past budget) is denied.
    assert read("c") == :ok
    assert read("c") == :ok

    assert {:deny, %{limit: 2, observed: 3, scope: :per_cohort}} = read("c")
    # And it STAYS denied for every further read of that cohort.
    assert {:deny, %{scope: :per_cohort}} = read("c")
  end

  test "a DIFFERENT cohort keeps its OWN budget (per-cohort, not global-by-accident)" do
    enforce!(1)

    # Cohort "a" spends its budget of 1.
    assert read("a") == :ok
    assert {:deny, %{scope: :per_cohort}} = read("a")

    # Cohort "b" is untouched — its own budget is fresh.
    assert read("b") == :ok
  end

  # ==========================================================================
  # (b) COLLUSION — two actors, SAME cohort, ONE shared budget
  # ==========================================================================

  test "RED (collusion): two distinct actors querying the SAME cohort spend ONE shared per-cohort budget; the second past the limit is DENIED" do
    enforce!(1)

    # attacker-1 reads the cohort (budget of 1 — served).
    QueryBudget.record(%{resource: "R", cohort_key: "tier=Pro", actor_id: "attacker-1"})
    assert QueryBudget.check(%{resource: "R", cohort_key: "tier=Pro"}) == :ok

    # attacker-2 (a coordinating account) reads the SAME cohort. A PER-ACTOR budget would
    # give attacker-2 a fresh budget of 1 and serve it. It does NOT: the accounting unit
    # is the cohort, so attacker-2's read finds the shared budget SPENT and is DENIED.
    QueryBudget.record(%{resource: "R", cohort_key: "tier=Pro", actor_id: "attacker-2"})

    assert {:deny, %{scope: :per_cohort, observed: 2}} =
             QueryBudget.check(%{resource: "R", cohort_key: "tier=Pro"})

    # Both actors' reads are on ONE per-cohort count (the collusion-resistant unit).
    assert QueryBudget.count(%{resource: "R", cohort_key: "tier=Pro"}) == 2
  end

  # ==========================================================================
  # (c) GLOBAL budget — a cross-cohort read cap
  # ==========================================================================

  test "the GLOBAL budget denies past a cross-cohort read cap (the doc's 'global' arm)" do
    # Per-cohort budget high (never hit); global budget of 2 across ALL cohorts.
    enforce!(1000, global: 2)

    # Two reads across two different cohorts — the global count reaches 2.
    assert read("a") == :ok
    assert read("b") == :ok

    # A third read on ANY cohort trips the global cap (global count 3 > 2), even though
    # each per-cohort count is only 1 (< the per-cohort budget of 1000).
    assert {:deny, %{scope: :global, limit: 2, observed: 3}} = read("c")
  end

  # ==========================================================================
  # (d) FAIL-OPEN — the enforcement check does not take down the plane on a ledger error
  # ==========================================================================

  test "check/2 fails OPEN on a ledger error (the floors, not the budget, fail closed)" do
    enforce!(1)

    # Point the ledger repo at a module that raises on aggregate/2 — simulating a ledger
    # outage. check/2 must rescue to :ok (fail open), never raise the caller.
    prev = Application.get_env(:samen_core, :query_budget_ledger_repo)

    try do
      Application.put_env(:samen_core, :query_budget_ledger_repo, __MODULE__.BrokenRepo)
      assert QueryBudget.check(%{resource: "R", cohort_key: "c"}) == :ok
    after
      if prev,
        do: Application.put_env(:samen_core, :query_budget_ledger_repo, prev),
        else: Application.delete_env(:samen_core, :query_budget_ledger_repo)
    end
  end

  defmodule BrokenRepo do
    def aggregate(_query, _kind), do: raise("ledger down")
  end

  # ==========================================================================
  # ANTI-TAUTOLOGY: the same budget both DENIES and ALLOWS — a discriminator, not
  # an always-deny.
  # ==========================================================================

  test "anti-tautology: the SAME enforcing budget ALLOWS a cohort under limit and DENIES one over limit" do
    enforce!(2)

    # Cohort "under" stays at 1 read (< budget) → allowed.
    assert read("under") == :ok

    # Cohort "over" is read 3 times (> budget) → denied. Same config, opposite outcome
    # depending ONLY on the read count — the budget is a non-vacuous discriminator.
    read("over")
    read("over")
    assert {:deny, _} = read("over")

    # "under" is STILL allowed (proving the deny is cohort-specific, not global state).
    assert QueryBudget.check(%{resource: "R", cohort_key: "under"}) == :ok
  end
end
