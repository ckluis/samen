defmodule Samen.Revenue.MetricsTest do
  @moduledoc """
  AC-G7-8 (U): the PURE revenue-metric compute (`Samen.Revenue.Metrics`) — MRR
  waterfall, NRR, gross/net/logo churn, and the cohort-retention grid — computed
  correctly over a seeded lifecycle fixture, in isolation from any DB.

  The waterfall's structural invariant (`closing == opening + net_change` where
  `net_change = Σ(signed deltas)`) is the compute-side half of the reconciliation
  invariant R1 (the DB-integration half — reconciling to an independent snapshot MRR
  delta — lives in the demo suite, `Demo.RevenueReconciliationTest`).
  """
  use ExUnit.Case, async: true

  alias Samen.Revenue.Metrics
  alias Samen.Revenue.Metrics.Waterfall

  # A seeded lifecycle's by-kind movement sums for one period (cents). The ledger
  # stores contraction/churn SIGNED NEGATIVE (as the classifier emits them).
  #   opening 100_000 ($1000)
  #   + new        30_000   (+3 logos)
  #   + expansion  10_000
  #   - contraction 4_000  (stored -4_000)
  #   - churn      20_000   (stored -20_000, 2 logos)
  #   + reactivation 5_000
  #   = closing   121_000
  defp fixture_sums do
    %{
      opening_cents: 100_000,
      new: 30_000,
      expansion: 10_000,
      contraction: -4_000,
      churn: -20_000,
      reactivation: 5_000,
      noop: 0,
      opening_logos: 20,
      new_logos: 3,
      churn_logos: 2
    }
  end

  describe "waterfall/1 — the MRR movement waterfall" do
    test "closing == opening + Σ(signed deltas) (R1 structural invariant)" do
      w = Metrics.waterfall(fixture_sums())

      assert %Waterfall{} = w
      assert w.opening_cents == 100_000
      assert w.new_cents == 30_000
      assert w.expansion_cents == 10_000
      assert w.contraction_cents == -4_000
      assert w.churn_cents == -20_000
      assert w.reactivation_cents == 5_000

      # net = 30_000 + 10_000 - 4_000 - 20_000 + 5_000 = 21_000
      assert w.net_change_cents == 21_000
      assert w.closing_cents == 121_000
      assert w.closing_cents == w.opening_cents + w.net_change_cents
    end

    test ":noop contributes nothing to the net" do
      base = fixture_sums()
      with_noop = Map.put(base, :noop, 999_999)

      assert Metrics.waterfall(base).net_change_cents ==
               Metrics.waterfall(with_noop).net_change_cents
    end

    test "an all-zero period reconciles to a flat closing" do
      w = Metrics.waterfall(%{opening_cents: 50_000})
      assert w.net_change_cents == 0
      assert w.closing_cents == 50_000
    end

    test "waterfall_display/1 exposes contraction/churn as positive magnitudes" do
      d = Metrics.waterfall_display(fixture_sums())

      assert d.contraction_magnitude_cents == 4_000
      assert d.churn_magnitude_cents == 20_000
      # The display magnitudes reconcile the same closing:
      # opening + new + expansion − |contraction| − |churn| + reactivation
      recomputed =
        d.opening_cents + d.new_cents + d.expansion_cents -
          d.contraction_magnitude_cents - d.churn_magnitude_cents + d.reactivation_cents

      assert recomputed == d.closing_cents
    end
  end

  describe "movement_sums_from_rollup_rows/1 — building sums from raw rollup rows" do
    test "folds by kind, threads opening, tallies new/churn logos" do
      rows = [
        %{kind: "new", delta_cents: 30_000, count: 3},
        %{kind: "expansion", delta_cents: 10_000, count: 1},
        %{kind: "contraction", delta_cents: -4_000, count: 1},
        %{kind: "churn", delta_cents: -20_000, count: 2},
        %{kind: "reactivation", delta_cents: 5_000, count: 1}
      ]

      sums = Metrics.movement_sums_from_rollup_rows(rows, opening_cents: 100_000)

      assert sums[:new] == 30_000
      assert sums[:contraction] == -4_000
      assert sums[:churn] == -20_000
      assert sums[:opening_cents] == 100_000
      assert sums[:new_logos] == 3
      assert sums[:churn_logos] == 2

      # It drives the SAME waterfall as the hand-built fixture.
      assert Metrics.waterfall(sums).closing_cents == 121_000
    end

    test "accepts {kind, delta, count} tuples and atom-keyed maps" do
      rows = [
        {:new, 1_000, 1},
        %{mrr_kind: "expansion", mrr_delta_cents: 500, mrr_count: 1}
      ]

      sums = Metrics.movement_sums_from_rollup_rows(rows, opening_cents: 0)
      assert sums[:new] == 1_000
      assert sums[:expansion] == 500
    end

    test "an unknown kind in a rollup row fails closed (raises)" do
      assert_raise ArgumentError, ~r/unknown mov_kind/, fn ->
        Metrics.movement_sums_from_rollup_rows([%{kind: "bogus", delta_cents: 1, count: 1}])
      end
    end
  end

  describe "nrr/1 — net revenue retention" do
    test "excludes new logos; retained+expanded fraction of the opening book" do
      # (opening + expansion + contraction + churn) / opening
      # = (100_000 + 10_000 - 4_000 - 20_000) / 100_000 = 86_000/100_000 = 0.86
      assert_in_delta Metrics.nrr(fixture_sums()), 0.86, 1.0e-9
    end

    test "flat book (no expansion/contraction/churn) is 1.0" do
      assert Metrics.nrr(%{opening_cents: 100_000}) == 1.0
    end

    test "net-negative retention below 1.0; net expansion above 1.0" do
      shrinking = %{opening_cents: 100_000, churn: -30_000}
      growing = %{opening_cents: 100_000, expansion: 30_000}
      assert Metrics.nrr(shrinking) < 1.0
      assert Metrics.nrr(growing) > 1.0
    end

    test "undefined (nil) when opening is 0 — no book to retain" do
      assert Metrics.nrr(%{opening_cents: 0, new: 50_000}) == nil
    end
  end

  describe "gross_churn_rate/1 / net_churn_rate/1" do
    test "gross = (|contraction| + |churn|) / opening, ignores expansion" do
      # (4_000 + 20_000) / 100_000 = 0.24
      assert_in_delta Metrics.gross_churn_rate(fixture_sums()), 0.24, 1.0e-9
    end

    test "net = gross offset by expansion" do
      # (4_000 + 20_000 - 10_000) / 100_000 = 0.14
      assert_in_delta Metrics.net_churn_rate(fixture_sums()), 0.14, 1.0e-9
    end

    test "net churn can go negative under strong expansion (net growth)" do
      sums = %{opening_cents: 100_000, churn: -5_000, expansion: 30_000}
      assert Metrics.net_churn_rate(sums) < 0.0
    end

    test "nil when opening is 0" do
      assert Metrics.gross_churn_rate(%{opening_cents: 0}) == nil
      assert Metrics.net_churn_rate(%{opening_cents: 0}) == nil
    end
  end

  describe "logo_churn_rate/1" do
    test "count(:churn) / opening_logos" do
      # 2 / 20 = 0.1
      assert_in_delta Metrics.logo_churn_rate(fixture_sums()), 0.1, 1.0e-9
    end

    test "nil when opening_logos is 0" do
      assert Metrics.logo_churn_rate(%{opening_logos: 0, churn_logos: 3}) == nil
    end
  end

  describe "cohort_retention/1 — retention grid over the mov timeline" do
    # Two cohorts.
    # Jan cohort: cust A (new Jan, churn Mar), cust B (new Jan, still active).
    # Feb cohort: cust C (new Feb, still active).
    # Data spans Jan..Mar.
    defp cohort_rows do
      [
        # A — Jan new, Mar churn
        %{customer_id: "A", kind: :new, mrr_delta_cents: 10_000, occurred_at: ~D[2026-01-10]},
        %{customer_id: "A", kind: :churn, mrr_delta_cents: -10_000, occurred_at: ~D[2026-03-05]},
        # B — Jan new, never churns
        %{customer_id: "B", kind: :new, mrr_delta_cents: 20_000, occurred_at: ~D[2026-01-20]},
        # C — Feb new
        %{customer_id: "C", kind: :new, mrr_delta_cents: 15_000, occurred_at: ~D[2026-02-14]}
      ]
    end

    test "groups by signup month, computes retained % per subsequent month" do
      %{cohorts: cohorts, max_offset: max_offset} = Metrics.cohort_retention(cohort_rows())

      jan = Enum.find(cohorts, &(&1.cohort_month == ~D[2026-01-01]))
      feb = Enum.find(cohorts, &(&1.cohort_month == ~D[2026-02-01]))

      assert jan.size == 2
      assert feb.size == 1

      # Jan cohort spans offsets 0..2 (Jan..Mar). Month 0 = 100%, month 1 (Feb) both
      # retained, month 2 (Mar) A churned → 1 of 2 retained.
      jan_rates = Map.new(jan.retention, &{&1.month_offset, &1})
      assert jan_rates[0].rate == 1.0
      assert jan_rates[1].retained == 2
      assert jan_rates[2].retained == 1
      assert_in_delta jan_rates[2].rate, 0.5, 1.0e-9

      # Feb cohort spans offsets 0..1 (Feb..Mar); C stays retained.
      feb_rates = Map.new(feb.retention, &{&1.month_offset, &1})
      assert feb_rates[0].rate == 1.0
      assert feb_rates[1].rate == 1.0

      assert max_offset == 2
    end

    test "signup month is always 100% retained" do
      %{cohorts: cohorts} = Metrics.cohort_retention(cohort_rows())

      for c <- cohorts do
        month0 = Enum.find(c.retention, &(&1.month_offset == 0))
        assert month0.rate == 1.0
      end
    end

    test "a horizon caps the retention offsets" do
      %{cohorts: cohorts} = Metrics.cohort_retention(cohort_rows(), horizon: 1)
      jan = Enum.find(cohorts, &(&1.cohort_month == ~D[2026-01-01]))
      assert Enum.map(jan.retention, & &1.month_offset) == [0, 1]
    end

    test "customers with no :new row are excluded from cohorts" do
      rows = [
        %{customer_id: "X", kind: :noop, mrr_delta_cents: 0, occurred_at: ~D[2026-01-01]}
      ]

      assert %{cohorts: []} = Metrics.cohort_retention(rows)
    end

    test "empty input yields an empty grid" do
      assert %{cohorts: [], max_offset: 0} = Metrics.cohort_retention([])
    end
  end
end
