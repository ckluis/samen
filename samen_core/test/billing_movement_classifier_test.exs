defmodule Samen.Billing.MovementClassifierTest do
  @moduledoc """
  AC-G7-1 (U) + the state-space totality guarantee (ADR-017 §2/§5): the PURE
  `MovementClassifier.classify/2` maps EVERY legal `(before, after)` state pair to the
  correct movement `kind` + signed delta, and REFUSES every illegal state (no silent
  default bucket). The classifier is the load-bearing input to the reconciliation
  invariant R1 — this suite is the ground truth for it.

  Exhaustive over the state space: `before ∈ {nil} ∪ statuses`, `after ∈ statuses`,
  crossed with a small MRR-cents grid — every pair classified, asserted against an
  independent oracle derived straight from the ADR's decision table.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Samen.Billing.MovementClassifier
  alias Samen.Billing.MovementClassifier.Movement

  @statuses [:active, :inactive, :trialing, :past_due, :cancelled, :unpaid]
  @active [:active, :trialing, :past_due]
  @mrr_grid [0, 1_000, 5_000, 9_900]

  # An INDEPENDENT oracle (not the impl) for the expected kind — derived directly
  # from the ADR-017 decision table, so a bug in the impl is caught by disagreement.
  defp oracle_kind(before_active?, after_active?, before_cents, after_cents, prior_active?) do
    cond do
      not before_active? and after_active? ->
        if prior_active?, do: :reactivation, else: :new

      before_active? and not after_active? ->
        :churn

      before_active? and after_active? ->
        d = after_cents - before_cents
        cond do
          d > 0 -> :expansion
          d < 0 -> :contraction
          true -> :noop
        end

      true ->
        :noop
    end
  end

  defp oracle_delta(before_active?, after_active?, before_cents, after_cents) do
    b = if before_active?, do: before_cents, else: 0
    a = if after_active?, do: after_cents, else: 0
    a - b
  end

  describe "AC-G7-1 — exhaustive legal state-pair classification (nil-before / CREATE)" do
    test "every (nil → status) pair classifies as :new (or :noop for inactive-after)" do
      for after_status <- @statuses, after_cents <- @mrr_grid do
        after_state = %{status: after_status, mrr_cents: after_cents}
        {:ok, %Movement{} = m} = MovementClassifier.classify(nil, after_state)

        after_active? = after_status in @active
        expected_kind = oracle_kind(false, after_active?, 0, after_cents, false)
        expected_delta = oracle_delta(false, after_active?, 0, after_cents)

        assert m.kind == expected_kind,
               "nil → #{after_status}@#{after_cents}: got #{m.kind}, want #{expected_kind}"

        assert m.delta_cents == expected_delta
        assert m.before_cents == 0
        assert m.after_cents == if(after_active?, do: after_cents, else: 0)
      end
    end
  end

  describe "AC-G7-1 — exhaustive legal state-pair classification (status → status)" do
    test "every (before, after) status × mrr pair classifies per the oracle" do
      for before_status <- @statuses,
          after_status <- @statuses,
          before_cents <- @mrr_grid,
          after_cents <- @mrr_grid do
        before_state = %{status: before_status, mrr_cents: before_cents}
        after_state = %{status: after_status, mrr_cents: after_cents}

        {:ok, %Movement{} = m} = MovementClassifier.classify(before_state, after_state)

        b_active? = before_status in @active
        a_active? = after_status in @active

        # before/after cents carried on the row are the RAW inputs (the classifier
        # trusts the caller's contribution figure); delta gates on active?.
        expected_kind = oracle_kind(b_active?, a_active?, before_cents, after_cents, false)
        expected_delta = oracle_delta(b_active?, a_active?, before_cents, after_cents)

        assert m.kind == expected_kind,
               "#{before_status}@#{before_cents} → #{after_status}@#{after_cents}: " <>
                 "got #{m.kind}, want #{expected_kind}"

        assert m.delta_cents == expected_delta,
               "#{before_status}@#{before_cents} → #{after_status}@#{after_cents}: " <>
                 "delta got #{m.delta_cents}, want #{expected_delta}"
      end
    end
  end

  describe "AC-G7-1 — :new vs :reactivation discriminator (prior_active?)" do
    test "inactive → active with prior_active? true classifies as :reactivation" do
      before_state = %{status: :cancelled, mrr_cents: 0}
      after_state = %{status: :active, mrr_cents: 5_000}

      {:ok, %{kind: :new, delta_cents: 5_000}} =
        MovementClassifier.classify(before_state, after_state, prior_active?: false)

      {:ok, %{kind: :reactivation, delta_cents: 5_000}} =
        MovementClassifier.classify(before_state, after_state, prior_active?: true)
    end

    test "nil → active with prior_active? true is :reactivation (caller asserts the fact)" do
      {:ok, %{kind: :reactivation}} =
        MovementClassifier.classify(nil, %{status: :active, mrr_cents: 100}, prior_active?: true)
    end
  end

  describe "canonical movement examples (the lifecycle the reconciliation R1 test seeds)" do
    test "new sale" do
      {:ok, %{kind: :new, delta_cents: 9_900}} =
        MovementClassifier.classify(nil, %{status: :active, mrr_cents: 9_900})
    end

    test "upgrade → expansion" do
      {:ok, %{kind: :expansion, delta_cents: 10_000}} =
        MovementClassifier.classify(
          %{status: :active, mrr_cents: 9_900},
          %{status: :active, mrr_cents: 19_900}
        )
    end

    test "downgrade → contraction (negative delta)" do
      {:ok, %{kind: :contraction, delta_cents: -10_000}} =
        MovementClassifier.classify(
          %{status: :active, mrr_cents: 19_900},
          %{status: :active, mrr_cents: 9_900}
        )
    end

    test "cancel → churn (loses the whole contribution)" do
      {:ok, %{kind: :churn, delta_cents: -9_900}} =
        MovementClassifier.classify(
          %{status: :active, mrr_cents: 9_900},
          %{status: :cancelled, mrr_cents: 0}
        )
    end

    test "reactivation after churn" do
      {:ok, %{kind: :reactivation, delta_cents: 9_900}} =
        MovementClassifier.classify(
          %{status: :cancelled, mrr_cents: 0},
          %{status: :active, mrr_cents: 9_900},
          prior_active?: true
        )
    end

    test "past_due cure at same price is a :noop (dunning is not churn)" do
      {:ok, %{kind: :noop, delta_cents: 0}} =
        MovementClassifier.classify(
          %{status: :past_due, mrr_cents: 9_900},
          %{status: :active, mrr_cents: 9_900}
        )
    end

    test "trialing is on the book (trial → active at same price is :noop, not :new)" do
      {:ok, %{kind: :noop, delta_cents: 0}} =
        MovementClassifier.classify(
          %{status: :trialing, mrr_cents: 9_900},
          %{status: :active, mrr_cents: 9_900}
        )
    end
  end

  describe "illegal states are REFUSED (fail-closed totality — no silent bucket)" do
    test "unknown status → {:error, :unknown_status}" do
      assert {:error, :unknown_status} =
               MovementClassifier.classify(nil, %{status: :bogus, mrr_cents: 0})

      assert {:error, :unknown_status} =
               MovementClassifier.classify(%{status: :nope, mrr_cents: 0}, %{
                 status: :active,
                 mrr_cents: 0
               })
    end

    test "negative or non-integer MRR → {:error, :illegal_mrr_cents}" do
      assert {:error, :illegal_mrr_cents} =
               MovementClassifier.classify(nil, %{status: :active, mrr_cents: -1})

      assert {:error, :illegal_mrr_cents} =
               MovementClassifier.classify(nil, %{status: :active, mrr_cents: 1.5})
    end

    test "nil after-state → {:error, :after_state_nil}" do
      assert {:error, :after_state_nil} = MovementClassifier.classify(nil, nil)
    end

    test "malformed (non-map) state → {:error, :malformed_state}" do
      assert {:error, :malformed_state} =
               MovementClassifier.classify(nil, %{mrr_cents: 100})
    end

    test "classify!/2 RAISES on an illegal pair (no silent default)" do
      assert_raise ArgumentError, ~r/illegal state pair/, fn ->
        MovementClassifier.classify!(nil, %{status: :bogus, mrr_cents: 0})
      end
    end
  end

  describe "purity + determinism" do
    property "classify/2 is deterministic — same input, same output across calls" do
      status_gen = StreamData.member_of(@statuses)
      cents_gen = StreamData.integer(0..50_000)

      check all(
              before_status <- status_gen,
              after_status <- status_gen,
              before_cents <- cents_gen,
              after_cents <- cents_gen,
              prior_active? <- StreamData.boolean()
            ) do
        before_state = %{status: before_status, mrr_cents: before_cents}
        after_state = %{status: after_status, mrr_cents: after_cents}

        results =
          for _ <- 1..5 do
            MovementClassifier.classify(before_state, after_state, prior_active?: prior_active?)
          end

        assert length(Enum.uniq(results)) == 1
      end
    end

    property "delta always equals after-contribution minus before-contribution" do
      status_gen = StreamData.member_of(@statuses)
      cents_gen = StreamData.integer(0..50_000)

      check all(
              before_status <- status_gen,
              after_status <- status_gen,
              before_cents <- cents_gen,
              after_cents <- cents_gen
            ) do
        before_state = %{status: before_status, mrr_cents: before_cents}
        after_state = %{status: after_status, mrr_cents: after_cents}
        {:ok, m} = MovementClassifier.classify(before_state, after_state)

        b = if before_status in @active, do: before_cents, else: 0
        a = if after_status in @active, do: after_cents, else: 0

        assert m.delta_cents == a - b
      end
    end
  end
end
