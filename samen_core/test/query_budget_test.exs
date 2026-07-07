defmodule Samen.QueryBudgetTest do
  @moduledoc """
  T4.5 clause (c) — the query-budget SCAFFOLD ledger.

  Proves the ledger accounts per COHORT (not per actor — the doc names per-actor as the
  wrong unit against collusion), records every read, WARNs (never enforces) at a
  configurable threshold, and never denies a read.

  The load-bearing property: a two-actor collusion on the SAME cohort accrues against
  ONE growing per-cohort count — NOT two independent per-actor budgets.
  """
  use ExUnit.Case, async: false

  alias Samen.Aggregate.{QueryBudget, QueryLedgerRow}

  @repo SamenCore.TestRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    Ecto.Adapters.SQL.Sandbox.mode(@repo, {:shared, self()})
    :ok
  end

  defp count_all do
    @repo.aggregate(QueryLedgerRow, :count)
  end

  # ==========================================================================
  # Recording: every aggregate read is accounted (never denied)
  # ==========================================================================

  test "record/1 writes one ledger row per read, keyed by cohort, and never denies" do
    assert {:ok, %{count: 1, warned: false}} =
             QueryBudget.record(%{resource: "R", cohort_key: "tier=Pro"})

    assert count_all() == 1

    assert {:ok, %{count: 2}} =
             QueryBudget.record(%{resource: "R", cohort_key: "tier=Pro"})

    assert count_all() == 2
  end

  test "reads on DIFFERENT cohorts accrue against SEPARATE counts" do
    QueryBudget.record(%{resource: "R", cohort_key: "tier=Pro"})
    QueryBudget.record(%{resource: "R", cohort_key: "tier=Enterprise"})

    assert QueryBudget.count(%{resource: "R", cohort_key: "tier=Pro"}) == 1
    assert QueryBudget.count(%{resource: "R", cohort_key: "tier=Enterprise"}) == 1
  end

  # ==========================================================================
  # THE COLLUSION TEST (red-path-shaped): per-cohort, NOT per-actor
  # ==========================================================================

  test "COLLUSION: two distinct actors reading the SAME cohort accrue against the SAME per-cohort count (not two per-actor budgets)" do
    # Two coordinating accounts. If the budget were per-ACTOR, each would spend a
    # fresh budget and the cohort count would be 1 for each. It is NOT: the accounting
    # unit is the cohort being queried, so BOTH reads land on the same count.
    QueryBudget.record(%{resource: "R", cohort_key: "tier=Pro", actor_id: "attacker-1"})
    QueryBudget.record(%{resource: "R", cohort_key: "tier=Pro", actor_id: "attacker-2"})

    # The per-cohort count is 2 (both reads), regardless of the two distinct actors.
    assert QueryBudget.count(%{resource: "R", cohort_key: "tier=Pro"}) == 2

    # And there is no per-actor accounting surface at all — count/2 takes no actor.
    # The actor_id is recorded for FORENSICS only (both rows exist, distinct actors):
    actors =
      @repo.all(QueryLedgerRow)
      |> Enum.map(& &1.actor_id)
      |> Enum.sort()

    assert actors == ["attacker-1", "attacker-2"]

    # The count that a (future) budget would gate on is the COHORT count (2), the
    # collusion-resistant unit — proving the doc's "per-actor is the wrong unit" claim.
  end

  # ==========================================================================
  # WARN, not enforce (posture under construction)
  # ==========================================================================

  test "crossing the threshold WARNs (returns warned: true) but STILL returns — never enforces" do
    prev = Application.get_env(:samen_core, :query_budget_warn_threshold)

    try do
      Application.put_env(:samen_core, :query_budget_warn_threshold, 3)

      r1 = QueryBudget.record(%{resource: "R", cohort_key: "c"})
      r2 = QueryBudget.record(%{resource: "R", cohort_key: "c"})
      assert {:ok, %{warned: false}} = r1
      assert {:ok, %{warned: false}} = r2

      # The 3rd read hits the threshold → WARN. But it is STILL recorded (count 3) and
      # the call STILL returns {:ok, …} — the scaffold does not deny.
      assert {:ok, %{count: 3, warned: true}} = QueryBudget.record(%{resource: "R", cohort_key: "c"})
      assert count_all() == 3
    after
      restore(:query_budget_warn_threshold, prev)
    end
  end

  test "threshold WARN fires a telemetry event (the scaffold's teeth for a human monitor)" do
    prev = Application.get_env(:samen_core, :query_budget_warn_threshold)
    ref = make_ref()
    parent = self()

    :telemetry.attach(
      "qb-test-#{inspect(ref)}",
      [:samen, :query_budget, :threshold_exceeded],
      fn _event, measures, meta, _cfg -> send(parent, {:warned, measures, meta}) end,
      nil
    )

    try do
      Application.put_env(:samen_core, :query_budget_warn_threshold, 1)
      QueryBudget.record(%{resource: "R", cohort_key: "hot"})
      assert_receive {:warned, %{count: 1}, %{cohort_key: "hot"}}
    after
      :telemetry.detach("qb-test-#{inspect(ref)}")
      restore(:query_budget_warn_threshold, prev)
    end
  end

  test "recording can be disabled; then no rows are written and nothing warns" do
    prev = Application.get_env(:samen_core, :query_budget_enabled)

    try do
      Application.put_env(:samen_core, :query_budget_enabled, false)
      assert {:ok, %{count: 0, warned: false}} = QueryBudget.record(%{resource: "R", cohort_key: "c"})
      assert count_all() == 0
    after
      restore(:query_budget_enabled, prev)
    end
  end

  test "tenant_scope defaults to __aggregate__ (the cross-tenant plane)" do
    QueryBudget.record(%{resource: "R", cohort_key: "c"})
    [row] = @repo.all(QueryLedgerRow)
    assert row.tenant_scope == "__aggregate__"
  end

  defp restore(key, nil), do: Application.delete_env(:samen_core, key)
  defp restore(key, val), do: Application.put_env(:samen_core, key, val)
end
