defmodule Samen.Web.Operator.HealthScore do
  @moduledoc """
  The composite, EXPLAINABLE per-tenant health score (WS-B / B4, design §2; ADR-019).
  A pure compute layer over the ALREADY-assembled operator account row — no read, no
  clock, no vault, no config write. `score/1` takes the `Samen.Web.Operator.Reads`
  account row and returns a `%HealthBreakdown{score: 0..100, band, factors}` where
  every `%Factor{}` carries its raw `value`, `weight`, `contribution`, and a human
  `explanation` — explainable BY CONSTRUCTION (AC-G17-3): the drill-down renders
  "why this score" without a second computation.

  ## The four factors (weights are config-defaulted, heuristic per ADR-019 §4)

    * **`:billing`** (40) — subscription state + DUNNING. This is the incoherence fix
      (AC-G17-2): the old pill mapped `status == :active` → healthy while Billing
      showed past-due invoices. Here any past-due invoice (or a `:past_due` /
      `:unpaid` status — the latter is dunning-exhausted, folded in per B4-P2-2)
      puts the account IN DUNNING and structurally CAPS the billing value at
      #{inspect(0.5)} (`@dunning_cap`) — below the factor's top band — scaled down
      further by days-overdue and invoice count. An account in dunning can NEVER
      rate a top billing dimension, and the composite band is capped at `:watch`.
    * **`:activity`** (25) — product-activity recency (G12 `pae`). Until G12 emits,
      the input is absent and the factor is `:unknown`: it contributes 0 and the
      remaining weights RENORMALIZE, so the score still computes (AC-G17-7) and
      gains fidelity when G12 lands. No fake number is invented.
    * **`:support`** (20) — open-ticket + SLA-breach load (inverse).
    * **`:adoption`** (15) — seat breadth (active admin memberships as the
      minimal-viable seat proxy); flag-adoption breadth folds in when G6 wires.

  ## Score / band arithmetic (the property-tested invariants)

  Each known factor's `contribution = round1(value × weight ÷ known_weight × 100)`
  (weights renormalize over the KNOWN factors); `score = clamp(round(Σ contributions))`.
  So the breakdown always SUMS to the composite (AC-G17-1), the score is always in
  `0..100`, and the compute is deterministic — pure data in, pure data out.

  Bands: `:healthy ≥ 85 · :watch ≥ 65 · :at_risk ≥ 40 · :critical` below — with the
  DUNNING CEILING: if the billing dimension rates at-risk-or-worse, the composite
  band is capped at `:watch`, whatever the other factors say. That is the
  health/dunning coherence guarantee, encoded, not styled.

  ## Not a new PII surface (ADR-019 §3 / AC-G17-5)

  Every input is a bounded count / enum / cent amount / day count. No name, email, or
  freeform string enters the score or the breakdown; the `explanation` strings are
  built from those bounded values only.
  """

  defmodule Factor do
    @moduledoc """
    One explainable health dimension (ADR-019 §2): `name` (bounded atom), `weight`
    (nominal config weight), `value` (the raw 0.0..1.0 health fraction, or `:unknown`),
    `contribution` (renormalized points toward the 0..100 composite), `explanation`
    (a human string built from bounded inputs only — never PII).
    """
    defstruct [:name, :weight, :value, :contribution, :explanation]
  end

  defmodule HealthBreakdown do
    @moduledoc """
    The explainable composite (ADR-019 §2): `score` in `0..100`, `band` in
    `:healthy | :watch | :at_risk | :critical`, `factors` — the four `%Factor{}`s
    whose contributions sum to the composite (AC-G17-1).
    """
    defstruct score: 0, band: :critical, factors: []
  end

  # Config-defaulted weights (ADR-019 §2). Override via
  # `config :samen_web, :health_score_weights, %{billing: .., ...}` — heuristic, tunable.
  @default_weights %{billing: 40, activity: 25, support: 20, adoption: 15}

  # The structural dunning ceiling on the billing VALUE (the incoherence fix): while
  # any invoice is past due, billing can never rate above 0.5 — strictly below the
  # factor's top band (0.85).
  @dunning_cap 0.5

  # Composite band thresholds (score points).
  @band_healthy 85
  @band_watch 65
  @band_at_risk 40

  # Per-factor band thresholds (value fractions).
  @factor_healthy 0.85
  @factor_watch 0.6
  @factor_at_risk 0.35

  @doc """
  Score one assembled account row → `%HealthBreakdown{}`. Pure and deterministic:
  the row carries every input (`__subscription__`, `__past_due__`, `__open_tickets__`,
  `__breaching_tickets__`, `__seats__`, `__activity_days__`) as bounded data — the
  caller (the reads layer) computes any now-relative day counts, so this function
  never reads a clock.
  """
  def score(row) when is_map(row) do
    factors = [billing_factor(row), activity_factor(row), support_factor(row), adoption_factor(row)]

    known_weight =
      factors
      |> Enum.reject(&(&1.value == :unknown))
      |> Enum.reduce(0, &(&1.weight + &2))
      |> max(1)

    factors =
      Enum.map(factors, fn
        %Factor{value: :unknown} = f -> %{f | contribution: 0.0}
        %Factor{} = f -> %{f | contribution: Float.round(f.value * f.weight / known_weight * 100, 1)}
      end)

    score =
      factors
      |> Enum.reduce(0.0, &(&1.contribution + &2))
      |> round()
      |> min(100)
      |> max(0)

    %HealthBreakdown{score: score, band: band_of(score, factors), factors: factors}
  end

  @doc """
  Whether the row is IN DUNNING (the gate-flagged incoherence input): any past-due
  invoice on the books, or a `:past_due` / `:unpaid` subscription status — the
  signals must agree with the rendered health, so ANY of them puts the billing
  dimension under the cap. `:unpaid` (dunning exhausted, subscription parked unpaid —
  the Stripe lifecycle state PAST `:past_due`) is dunning-adjacent by definition; it
  previously fell into the "unrecognized state" branch (band correctly capped, but
  the explanation never flagged it) — folded here per the B9 carry (B4-P2-2).
  """
  def dunning?(row) when is_map(row) do
    past_due(row).count > 0 or sub_status(row) in [:past_due, :unpaid]
  end

  @doc """
  The band of ONE dimension (`:unknown | :healthy | :watch | :at_risk | :critical`) —
  the drill-down's per-factor pill. Thresholds on the raw value fraction.
  """
  def factor_band(%Factor{value: :unknown}), do: :unknown
  def factor_band(%Factor{value: v}) when v >= @factor_healthy, do: :healthy
  def factor_band(%Factor{value: v}) when v >= @factor_watch, do: :watch
  def factor_band(%Factor{value: v}) when v >= @factor_at_risk, do: :at_risk
  def factor_band(%Factor{}), do: :critical

  @doc "The four bounded composite bands, best → worst."
  def bands, do: [:healthy, :watch, :at_risk, :critical]

  # -- composite band (threshold + the dunning ceiling) --------------------------

  # The coherence guard, encoded: a billing dimension at-risk-or-worse (dunning /
  # cancelled / no subscription) caps the composite band at :watch — the list pill
  # can never say "healthy" while Billing shows past-due invoices (AC-G17-2).
  defp band_of(score, factors) do
    base =
      cond do
        score >= @band_healthy -> :healthy
        score >= @band_watch -> :watch
        score >= @band_at_risk -> :at_risk
        true -> :critical
      end

    billing = Enum.find(factors, &(&1.name == :billing))

    if base == :healthy and factor_band(billing) in [:at_risk, :critical] do
      :watch
    else
      base
    end
  end

  # -- the four factors -----------------------------------------------------------

  # Billing state (the incoherence fix). Dunning dominates status: an :active
  # subscription with past-due invoices is IN DUNNING and capped, exactly the case
  # the operator-plane gate flagged.
  defp billing_factor(row) do
    sub = Map.get(row, :__subscription__)
    pd = past_due(row)

    {value, explanation} =
      cond do
        is_nil(sub) ->
          {0.0, "no subscription on file — nothing keeps this account current"}

        sub_status(row) in [:cancelled, :canceled] ->
          {0.0, "subscription cancelled — churned"}

        dunning?(row) ->
          {dunning_value(pd), dunning_explanation(pd, sub_status(row))}

        sub_status(row) in [:active, :trialing] ->
          {1.0, "subscription #{sub_status(row)} and current — no past-due invoices"}

        true ->
          {0.25, "subscription in unrecognized state #{inspect(sub_status(row))}"}
      end

    %Factor{name: :billing, weight: weight(:billing), value: clamp01(value), explanation: explanation}
  end

  # The dunning explanation, built from bounded inputs only (never PII). A dunning
  # STATUS (`:past_due` / `:unpaid`) is named explicitly so a subscription parked
  # `:unpaid` with zero visible invoice rows still reads as dunning, never as an
  # unrecognized state (B4-P2-2).
  defp dunning_explanation(pd, status) do
    status_note = if status in [:past_due, :unpaid], do: "subscription #{status}; ", else: ""

    "in dunning: #{status_note}#{pd.count} past-due invoice(s), #{cents(pd.amount_cents)} overdue, " <>
      "oldest #{pd.max_days_overdue} day(s) past due — billing is capped below the top band " <>
      "until every invoice clears (the dunning ceiling)"
  end

  # Dunning value: starts AT the cap and only goes down — 0.35 over 90 days of age,
  # 0.03 per extra past-due invoice (5 max), floored above zero (cancelled is worse).
  defp dunning_value(pd) do
    days_penalty = min(pd.max_days_overdue, 90) / 90 * 0.35
    count_penalty = min(max(pd.count - 1, 0), 5) * 0.03

    (@dunning_cap - days_penalty - count_penalty)
    |> max(0.02)
    |> min(@dunning_cap)
  end

  # Product-activity recency (G12 pae). Absent signal → :unknown, weights
  # renormalize (AC-G17-7) — the score never invents a number.
  defp activity_factor(row) do
    days = Map.get(row, :__activity_days__)

    {value, explanation} =
      cond do
        not is_integer(days) ->
          {:unknown,
           "no product-activity signal yet (G12 pae not emitting) — excluded from the composite; " <>
             "the remaining weights renormalize"}

        days <= 7 ->
          {1.0, "product activity in the last 7 days (last event #{max(days, 0)} day(s) ago)"}

        days <= 30 ->
          {0.7, "last product activity #{days} days ago (within 30 days)"}

        days <= 90 ->
          {0.35, "last product activity #{days} days ago (within 90 days) — going quiet"}

        true ->
          {0.1, "no product activity in #{days} days — dormant"}
      end

    %Factor{name: :activity, weight: weight(:activity), value: value, explanation: explanation}
  end

  # Support load (inverse): open tickets −0.1 each, SLA breaches −0.2 each.
  defp support_factor(row) do
    open = non_neg(Map.get(row, :__open_tickets__))
    breaching = non_neg(Map.get(row, :__breaching_tickets__))
    value = clamp01(1.0 - 0.1 * open - 0.2 * breaching)

    explanation =
      case {open, breaching} do
        {0, 0} -> "no open desk tickets"
        {o, 0} -> "#{o} open desk ticket(s), none breaching SLA"
        {o, b} -> "#{o} open desk ticket(s), #{b} breaching SLA"
      end

    %Factor{name: :support, weight: weight(:support), value: value, explanation: explanation}
  end

  # Adoption: seat breadth (active admin memberships — the minimal-viable proxy);
  # flag-adoption breadth folds in when G6 lands (noted, never faked).
  defp adoption_factor(row) do
    seats = non_neg(Map.get(row, :__seats__))

    {value, explanation} =
      if seats == 0 do
        {0.0, "no active seats — nobody is in the product; flag-adoption breadth pending (G6)"}
      else
        {clamp01(0.6 + (seats - 1) * 0.1),
         "#{seats} active seat(s) on the account; flag-adoption breadth pending (G6)"}
      end

    %Factor{name: :adoption, weight: weight(:adoption), value: value, explanation: explanation}
  end

  # -- bounded input plumbing -------------------------------------------------------

  defp weight(name) do
    :samen_web
    |> Application.get_env(:health_score_weights, %{})
    |> Map.get(name, Map.fetch!(@default_weights, name))
  end

  defp past_due(row) do
    case Map.get(row, :__past_due__) do
      %{count: c, amount_cents: a, max_days_overdue: d} ->
        %{count: non_neg(c), amount_cents: non_neg(a), max_days_overdue: non_neg(d)}

      _ ->
        %{count: 0, amount_cents: 0, max_days_overdue: 0}
    end
  end

  defp sub_status(row) do
    case Map.get(row, :__subscription__) do
      %{status: status} -> status
      _ -> nil
    end
  end

  defp non_neg(n) when is_integer(n), do: max(n, 0)
  defp non_neg(_), do: 0

  defp clamp01(v) when is_number(v), do: v |> max(0.0) |> min(1.0) |> then(&(&1 / 1))

  defp cents(c), do: "$#{:erlang.float_to_binary(c / 100, decimals: 2)}"
end
