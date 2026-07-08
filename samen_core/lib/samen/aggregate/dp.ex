defmodule Samen.Aggregate.Dp do
  @moduledoc """
  **Differential-privacy POSTURE** — a calibrated-noise layer for aggregate counts
  (T6.6; doc "Token-blind isn't inference-blind" honest edge, the "differential-privacy
  posture (calibrated noise composed across queries)" clause).

  This is an **OPT-IN** layer that adds Laplace-calibrated noise to an aggregate COUNT
  before it is released, so a single released count no longer reveals the exact
  contribution of any one subject. It is the DP arm of the same posture-under-construction
  track as the query budget — and this moduledoc is scrupulously honest about the line
  between what this mechanism DOES and what a formal DP guarantee would REQUIRE.

  ## What this DOES (a single-query mechanism, correctly calibrated)

  The Laplace mechanism, textbook form. For a numeric query `q` with **sensitivity**
  `Δq` (the maximum amount one subject's presence/absence can change `q` — for a plain
  count-of-distinct-subjects, `Δq = 1`), releasing `q(D) + Lap(Δq / ε)` satisfies
  `ε`-differential privacy **for that one release**. `ε` (epsilon) is the privacy
  parameter: smaller ε ⇒ more noise ⇒ stronger privacy ⇒ less accuracy.

    * `noisy_count/2` adds `Lap(Δq/ε)` to an integer count (default `Δq = 1`), rounds to
      the nearest non-negative integer, and returns it.
    * The noise is drawn from a true Laplace distribution (inverse-CDF sampling on a
      uniform variate), scale `b = Δq/ε`, mean 0. Over many draws the empirical
      distribution matches `Lap(b)` (the distribution test in `dp_test.exs` asserts this:
      mean ≈ 0, variance ≈ `2b²`, and noise is actually PRESENT — a real spread, not a
      constant).

  ## What this DOES NOT do (the honest, still-open research edge)

  **A single ε-DP release is NOT a system-level privacy guarantee.** The property that
  makes DP a *guarantee* is COMPOSITION: under sequential composition, `k` releases each
  `ε`-DP compose to (at best, without advanced composition) `k·ε`-DP. Every noisy answer
  SPENDS privacy. A formal DP system therefore maintains a running **ε-budget** per
  subject / per dataset and DENIES further releases once the budget is exhausted — exactly
  analogous to, but stronger than, the deterministic query budget in
  `Samen.Aggregate.QueryBudget`.

  This module does **NOT** implement that ε-budget accounting. It calibrates and adds
  noise per query; it does not track cumulative ε spent, and it does not stop you from
  issuing enough noisy queries to average the noise away and recover the true count
  (`E[mean of n noisy answers] → true count`). So:

    * **ENFORCED / real:** correctly-calibrated Laplace noise on a single released count
      (opt-in). The distribution is genuine (tested).
    * **POSTURE under construction / NOT claimed:** a formal ε-DP guarantee across the
      SYSTEM. That needs (1) an ε-budget composed across queries with denial on
      exhaustion, (2) a proven sensitivity bound for every released query (not just plain
      counts), and (3) integration with the cohort/query budget so the two budgets can't
      be dodged by alternating them. t-closeness (bounding a cohort's sensitive-value
      distribution vs the overall distribution) is on the SAME open track and is likewise
      not implemented. We name this as posture, we do not ship it as a proof.

  The deterministic per-cohort query budget (`Samen.Aggregate.QueryBudget`, T6.6 enforcing)
  is the coarse cross-query control that IS enforced today; it caps the NUMBER of reads per
  cohort, which blunts the noise-averaging attack in practice (you cannot issue unlimited
  noisy reads of one cohort). But a bounded number of noisy reads still leaks some signal,
  and the deterministic count budget is not the same object as a composed ε-budget. Both
  facts are stated, neither is hidden.

  ## Configuration

      config :samen_core, :dp_enabled, true      # opt-in; default false (no noise added)
      config :samen_core, :dp_epsilon, 1.0        # privacy parameter ε (default 1.0)

  With `:dp_enabled` unset/false, `maybe_noisy_count/2` is the identity — the exact count
  passes through (the k-anon / l-diversity FLOORS and the query budget are the enforced
  defences; DP is an ADDITIONAL opt-in layer, never the sole defence). ε must be a
  positive number; a non-positive / missing ε falls back to the default.
  """

  @default_epsilon 1.0

  @doc "Is the opt-in DP noise layer enabled? Default `false` (no noise added)."
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:samen_core, :dp_enabled, false) == true
  end

  @doc """
  The configured privacy parameter ε (epsilon). Default #{@default_epsilon}. Smaller ε ⇒
  more noise ⇒ stronger privacy. Must be a positive number; a non-positive / missing value
  falls back to the default.

  Config: `config :samen_core, :dp_epsilon, 1.0`.
  """
  @spec epsilon() :: float()
  def epsilon do
    case Application.get_env(:samen_core, :dp_epsilon, @default_epsilon) do
      e when is_number(e) and e > 0 -> e / 1
      _ -> @default_epsilon
    end
  end

  @doc """
  Add Laplace-calibrated noise to an integer `count` and round to a non-negative integer.

  `opts`:
    * `:epsilon` — override ε (tests use this; production reads config). Must be `> 0`.
    * `:sensitivity` — the query sensitivity `Δq` (default `1` — one subject changes a
      count-of-distinct-subjects by at most 1).

  Returns `count + round(Lap(Δq/ε))`, clamped at 0 (a negative noisy count is meaningless
  for a count query; clamping is standard and does not weaken the ε guarantee for a single
  release — it is post-processing).

  This is the raw mechanism; it ALWAYS adds noise (used by the distribution test).
  `maybe_noisy_count/2` is the opt-in wrapper the read path uses.
  """
  @spec noisy_count(non_neg_integer(), keyword()) :: non_neg_integer()
  def noisy_count(count, opts \\ []) when is_integer(count) do
    eps = opts |> Keyword.get(:epsilon, epsilon()) |> normalize_epsilon()
    sensitivity = Keyword.get(opts, :sensitivity, 1)
    scale = sensitivity / eps

    noisy = count + laplace(scale)
    noisy |> round() |> max(0)
  end

  @doc """
  Opt-in wrapper: add DP noise to a count ONLY when `:dp_enabled` is on; otherwise return
  the exact count unchanged. This is what the aggregate read path calls — DP is an
  ADDITIONAL layer on top of the enforced floors + budget, never the sole defence, and
  it is off by default.
  """
  @spec maybe_noisy_count(non_neg_integer(), keyword()) :: non_neg_integer()
  def maybe_noisy_count(count, opts \\ []) when is_integer(count) do
    if enabled?() do
      noisy_count(count, opts)
    else
      count
    end
  end

  @doc """
  Draw one sample from a Laplace distribution with mean 0 and scale `b` (`b > 0`), via
  inverse-CDF sampling on a uniform variate `u ∈ (-0.5, 0.5]`:
  `x = -b · sign(u) · ln(1 - 2|u|)`.

  Exposed for the distribution test (which draws many samples and asserts mean ≈ 0,
  variance ≈ `2b²`, and a genuine non-zero spread).
  """
  @spec laplace(float()) :: float()
  def laplace(b) when is_number(b) and b > 0 do
    # u in (-0.5, 0.5]; :rand.uniform/0 is in (0, 1].
    u = :rand.uniform() - 0.5
    -b * sign(u) * :math.log(1 - 2 * abs(u))
  end

  defp sign(x) when x > 0, do: 1.0
  defp sign(x) when x < 0, do: -1.0
  defp sign(_), do: 0.0

  defp normalize_epsilon(e) when is_number(e) and e > 0, do: e / 1
  defp normalize_epsilon(_), do: @default_epsilon
end
