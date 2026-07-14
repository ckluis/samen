defmodule Samen.Web.OperatorHealthScoreTest do
  @moduledoc """
  The composite health score (WS-B / B4; ADR-019) — pure-compute unit + property
  tests. AC-G17-1 (breakdown sums to the composite, bands correct), AC-G17-2 (the
  gate-flagged health/dunning incoherence, as a MUST-FAIL: an active-but-past-due
  account scores below an active-current one and can NEVER rate a healthy billing
  dimension or a healthy composite band — with the positive control that keeps the
  assertion non-tautological), AC-G17-3 (explainable by construction), AC-G17-7
  (graceful `:unknown` activity — G17 ships independent of G12), plus the
  determinism / bounds / sum-consistency PROPERTY over the whole input space.

  No DB, no mount — `score/1` is a pure fold over the assembled row, which is the
  ADR-019 placement claim itself.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Samen.Web.Operator.HealthScore
  alias Samen.Web.Operator.HealthScore.{Factor, HealthBreakdown}

  # A current, quiet, well-adopted account — every dimension at its best.
  defp row(overrides \\ %{}) do
    Map.merge(
      %{
        __subscription__: %{status: :active},
        __past_due__: %{count: 0, amount_cents: 0, max_days_overdue: 0},
        __open_tickets__: 0,
        __breaching_tickets__: 0,
        __seats__: 5,
        __activity_days__: nil
      },
      overrides
    )
  end

  defp factor(%HealthBreakdown{factors: factors}, name), do: Enum.find(factors, &(&1.name == name))

  # -- AC-G17-1: shape, weights, sum-to-composite, bands --------------------------

  test "the breakdown carries the four weighted factors and their contributions sum to the composite" do
    b = HealthScore.score(row())

    assert %HealthBreakdown{} = b
    assert Enum.map(b.factors, & &1.name) == [:billing, :activity, :support, :adoption]
    assert Enum.map(b.factors, & &1.weight) == [40, 25, 20, 15]
    assert Enum.all?(b.factors, &match?(%Factor{}, &1))

    # The composite IS the (rounded) sum of the per-factor contributions — no
    # second computation, no hidden term.
    assert b.score == round(Enum.reduce(b.factors, 0.0, &(&1.contribution + &2)))
  end

  test "band thresholds: a perfect account is :healthy, a churned loaded account is :critical" do
    perfect = HealthScore.score(row(%{__activity_days__: 1}))
    assert perfect.score == 100
    assert perfect.band == :healthy

    churned =
      HealthScore.score(
        row(%{
          __subscription__: %{status: :cancelled},
          __open_tickets__: 8,
          __breaching_tickets__: 4,
          __seats__: 0,
          __activity_days__: 300
        })
      )

    assert churned.band == :critical
    assert churned.score < 40
  end

  # -- AC-G17-2: the health/dunning incoherence, as a must-fail --------------------

  test "MUST-FAIL: an ACTIVE-but-past-due account scores below an active-current one (the gate-flagged incoherence)" do
    current = HealthScore.score(row())

    dunning =
      HealthScore.score(
        row(%{
          __subscription__: %{status: :active},
          __past_due__: %{count: 2, amount_cents: 99_800, max_days_overdue: 30}
        })
      )

    # The OLD pill mapped both to :healthy (status == :active). The composite must not.
    assert dunning.score < current.score
    assert HealthScore.dunning?(row(%{__past_due__: %{count: 1, amount_cents: 1, max_days_overdue: 1}}))
  end

  test "MUST-FAIL: a dunning account can NEVER rate a healthy billing dimension or a healthy band — even with every other input perfect" do
    dunning_row =
      row(%{
        __subscription__: %{status: :active},
        __past_due__: %{count: 1, amount_cents: 100, max_days_overdue: 0},
        __open_tickets__: 0,
        __breaching_tickets__: 0,
        __seats__: 50,
        __activity_days__: 0
      })

    b = HealthScore.score(dunning_row)
    billing = factor(b, :billing)

    # The structural dunning ceiling: billing value capped at 0.5, strictly below
    # the factor's healthy threshold — and the composite band is capped too.
    assert billing.value <= 0.5
    assert HealthScore.factor_band(billing) != :healthy
    assert b.band != :healthy

    # POSITIVE CONTROL (anti-tautology): the identical account WITHOUT the past-due
    # invoice rates a healthy billing dimension AND a healthy band — so the two
    # assertions above are refutable, not vacuously true.
    control = HealthScore.score(%{dunning_row | __past_due__: %{count: 0, amount_cents: 0, max_days_overdue: 0}})
    assert HealthScore.factor_band(factor(control, :billing)) == :healthy
    assert control.band == :healthy
  end

  test "a :past_due subscription status alone (no invoice rows visible) is ALSO dunning — the two signals can never disagree with the pill" do
    b = HealthScore.score(row(%{__subscription__: %{status: :past_due}}))

    assert HealthScore.factor_band(factor(b, :billing)) != :healthy
    assert b.band != :healthy
  end

  test "RED-PATH (B9 carry B4-P2-2): an :unpaid subscription is DUNNING-adjacent — capped billing, an explanation that says so, never 'unrecognized state'" do
    unpaid_row = row(%{__subscription__: %{status: :unpaid}})
    b = HealthScore.score(unpaid_row)
    billing = factor(b, :billing)

    # :unpaid (dunning exhausted, the state PAST :past_due) is dunning, encoded.
    assert HealthScore.dunning?(unpaid_row)
    assert billing.value <= 0.5
    assert HealthScore.factor_band(billing) != :healthy
    assert b.band != :healthy

    # The explanation FLAGS the dunning-adjacent status (the carried gap: the band
    # was capped, but the string called it an unrecognized state).
    assert billing.explanation =~ "in dunning"
    assert billing.explanation =~ "subscription unpaid"
    refute billing.explanation =~ "unrecognized"

    # POSITIVE CONTROL (anti-tautology): a genuinely unmapped state still lands in
    # the honest catch-all — the fold is for :unpaid, not a blanket rewording.
    paused = factor(HealthScore.score(row(%{__subscription__: %{status: :paused}})), :billing)
    assert paused.explanation =~ "unrecognized state"
    refute paused.explanation =~ "in dunning"
  end

  # -- AC-G17-3: explainable by construction ---------------------------------------

  test "every factor carries value / weight / contribution / non-empty explanation — no second computation needed" do
    b =
      HealthScore.score(
        row(%{
          __past_due__: %{count: 3, amount_cents: 149_700, max_days_overdue: 45},
          __open_tickets__: 2,
          __breaching_tickets__: 1
        })
      )

    for f <- b.factors do
      assert is_integer(f.weight) and f.weight > 0
      assert f.value == :unknown or (is_float(f.value) and f.value >= 0.0 and f.value <= 1.0)
      assert is_float(f.contribution)
      assert is_binary(f.explanation) and String.trim(f.explanation) != ""
    end

    # The billing explanation names its bounded dunning inputs (count / amount / days).
    billing = factor(b, :billing)
    assert billing.explanation =~ "3 past-due invoice(s)"
    assert billing.explanation =~ "$1497.00"
    assert billing.explanation =~ "45 day(s)"

    # The support explanation names the load.
    assert factor(b, :support).explanation =~ "2 open desk ticket(s), 1 breaching SLA"
  end

  # -- AC-G17-7: graceful :unknown activity ----------------------------------------

  test "absent activity signal → :unknown factor, zero contribution, weights renormalize, score still computes" do
    b = HealthScore.score(row(%{__activity_days__: nil}))
    activity = factor(b, :activity)

    assert activity.value == :unknown
    assert activity.contribution == 0.0
    assert activity.explanation =~ "G12"

    # Renormalization: a perfect row with NO activity signal still scores 100 —
    # the unknown factor is excluded, never counted as zero health.
    assert b.score == 100
    assert b.band == :healthy

    # And a KNOWN activity signal changes the composite (the factor is real).
    stale = HealthScore.score(row(%{__activity_days__: 200}))
    assert stale.score < b.score
    assert factor(stale, :activity).value == 0.1
  end

  # -- the property: determinism / bounds / sum-consistency / dunning coherence ----

  property "over the whole input space: score in 0..100, band bounded, breakdown sums to composite, deterministic, dunning never healthy" do
    check all(
            status <- member_of([:active, :trialing, :past_due, :unpaid, :cancelled, :canceled, :paused, nil]),
            pd_count <- integer(0..8),
            pd_days <- integer(0..400),
            pd_amount <- integer(0..5_000_000),
            open <- integer(0..40),
            breaching <- integer(0..20),
            seats <- integer(0..50),
            activity <- one_of([constant(nil), integer(0..400)]),
            max_runs: 200
          ) do
      row = %{
        __subscription__: status && %{status: status},
        __past_due__: %{count: pd_count, amount_cents: pd_amount, max_days_overdue: pd_days},
        __open_tickets__: open,
        __breaching_tickets__: breaching,
        __seats__: seats,
        __activity_days__: activity
      }

      b = HealthScore.score(row)

      # Bounds: the score is always in band, the band always bounded.
      assert b.score in 0..100
      assert b.band in [:healthy, :watch, :at_risk, :critical]
      assert length(b.factors) == 4

      # Sum-consistency: the breakdown sums to the composite (AC-G17-1).
      assert b.score == round(Enum.reduce(b.factors, 0.0, &(&1.contribution + &2)))

      # Every factor value bounded; every explanation present.
      for f <- b.factors do
        assert f.value == :unknown or (f.value >= 0.0 and f.value <= 1.0)
        assert is_binary(f.explanation) and f.explanation != ""
        assert f.contribution >= 0.0
      end

      # Determinism: pure data in → the same breakdown out, every time.
      assert HealthScore.score(row) == b

      # The incoherence fix, universally: ANY dunning input forbids a healthy
      # billing dimension and a healthy composite band.
      if HealthScore.dunning?(row) do
        billing = Enum.find(b.factors, &(&1.name == :billing))
        assert billing.value <= 0.5
        assert HealthScore.factor_band(billing) != :healthy
        assert b.band != :healthy
      end
    end
  end
end
