defmodule Samen.DpTest do
  @moduledoc """
  T6.6 — the OPT-IN differential-privacy noise POSTURE (`Samen.Aggregate.Dp`).

  Proves the Laplace mechanism is REAL (not a stub) and OPT-IN, while the moduledoc /
  report stay honest that a SINGLE ε-DP release is not a system-level DP guarantee
  (composition across queries is the still-open research edge).

  What is asserted here (the enforced/real part):
    * noise is genuinely PRESENT when DP is enabled (a distribution, not a constant);
    * the noise matches a Laplace(scale=Δq/ε): empirical mean ≈ 0, variance ≈ 2b²;
    * smaller ε ⇒ MORE noise (the privacy/accuracy knob works);
    * DP is OPT-IN: off by default, the exact count passes through unchanged;
    * a negative noisy count clamps to 0 (post-processing, count queries).

  What is NOT asserted (because it is NOT implemented — the honest edge): a composed
  ε-budget across queries. The averaging attack (mean of many noisy answers → true count)
  is REAL and documented; the deterministic per-cohort query budget blunts it in practice
  but is not a formal ε-budget. See the Dp moduledoc + the T6.6 report.
  """
  use ExUnit.Case, async: true

  alias Samen.Aggregate.Dp

  # ==========================================================================
  # OPT-IN: off by default, identity pass
  # ==========================================================================

  test "DP is OPT-IN: off by default, maybe_noisy_count is the identity" do
    refute Dp.enabled?()
    # With DP off, the exact count is returned every time (no noise).
    for _ <- 1..50, do: assert(Dp.maybe_noisy_count(42) == 42)
  end

  # ==========================================================================
  # NOISE IS PRESENT + LAPLACE-SHAPED (the distribution test)
  # ==========================================================================

  test "RED-shaped (noise present): noisy_count produces a genuine spread, not a constant" do
    samples = for _ <- 1..2_000, do: Dp.noisy_count(100, epsilon: 0.5)

    distinct = samples |> Enum.uniq() |> length()
    # A real distribution has many distinct values — a stub returning the exact count
    # would have exactly ONE. (b = 1/0.5 = 2, so the spread is wide.)
    assert distinct > 10, "expected a real noise spread, got #{distinct} distinct values"

    # Not every sample equals the true count (the whole point of DP noise).
    refute Enum.all?(samples, &(&1 == 100))
  end

  test "the noise matches Laplace(b = Δq/ε): mean ≈ 0, variance ≈ 2b²" do
    b = 4.0
    n = 20_000
    draws = for _ <- 1..n, do: Dp.laplace(b)

    mean = Enum.sum(draws) / n
    var = Enum.reduce(draws, 0.0, fn x, acc -> acc + (x - mean) * (x - mean) end) / n

    # Laplace(0, b): mean 0, variance 2b². With n=20k the empirical values are close.
    assert_in_delta mean, 0.0, 0.25
    expected_var = 2 * b * b
    assert_in_delta var, expected_var, expected_var * 0.15
  end

  test "smaller ε ⇒ MORE noise (the privacy/accuracy knob is real)" do
    n = 5_000
    spread = fn eps ->
      draws = for _ <- 1..n, do: Dp.noisy_count(1_000, epsilon: eps) - 1_000
      Enum.reduce(draws, 0.0, fn x, acc -> acc + abs(x) end) / n
    end

    tight = spread.(2.0)
    loose = spread.(0.25)

    # ε=0.25 (b=4) is much noisier than ε=2.0 (b=0.5): mean absolute noise is larger.
    assert loose > tight * 2,
           "expected smaller ε to be much noisier (loose=#{loose}, tight=#{tight})"
  end

  # ==========================================================================
  # CLAMP + CONFIG
  # ==========================================================================

  test "a noisy count clamps at 0 (never negative — post-processing for count queries)" do
    # A tiny true count with heavy noise (ε=0.1, b=10) frequently underflows; assert the
    # floor holds across many draws.
    results = for _ <- 1..2_000, do: Dp.noisy_count(0, epsilon: 0.1)
    assert Enum.all?(results, &(&1 >= 0))
    assert is_integer(hd(results))
  end

  test "epsilon/0 reads config, defaults to 1.0, rejects non-positive" do
    assert Dp.epsilon() == 1.0

    prev = Application.get_env(:samen_core, :dp_epsilon)

    try do
      Application.put_env(:samen_core, :dp_epsilon, 0.5)
      assert Dp.epsilon() == 0.5
      # A non-positive ε is invalid (would be infinite/negative noise scale) → default.
      Application.put_env(:samen_core, :dp_epsilon, 0)
      assert Dp.epsilon() == 1.0
    after
      if prev,
        do: Application.put_env(:samen_core, :dp_epsilon, prev),
        else: Application.delete_env(:samen_core, :dp_epsilon)
    end
  end

  test "maybe_noisy_count adds noise when DP is ENABLED" do
    prev = Application.get_env(:samen_core, :dp_enabled)

    try do
      Application.put_env(:samen_core, :dp_enabled, true)
      assert Dp.enabled?()
      samples = for _ <- 1..500, do: Dp.maybe_noisy_count(100, epsilon: 0.5)
      # With DP on, at least some samples differ from the exact count.
      refute Enum.all?(samples, &(&1 == 100))
    after
      if prev,
        do: Application.put_env(:samen_core, :dp_enabled, prev),
        else: Application.delete_env(:samen_core, :dp_enabled)
    end
  end
end
