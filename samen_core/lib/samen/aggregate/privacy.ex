defmodule Samen.Aggregate.Privacy do
  @moduledoc """
  The **aggregate-privacy floors** — k-anonymity minimum-cohort suppression and
  l-diversity minimum-distinct suppression, **enforced today** (T4.5 clauses (a)+(b);
  doc §control ∴ block + the "Token-blind isn't inference-blind" honest edge).

  This is the OUTPUT-privacy floor that sits ON TOP of the token-blind aggregate plane
  (T4.2). Token-blindness (no `pii_` columns physically exist) is **input privacy** —
  the doc is explicit that it "says nothing about what the answers leak." A cross-tenant
  aggregate with a count-of-one cohort re-identifies a subject; a k-sized cohort whose
  members all share the sensitive value re-identifies it too (the homogeneity attack).
  So this module enforces two floors on every aggregate read:

    1. **k-anonymity** (clause (a)) — any aggregate cell whose cohort count is `< k`
       (config, `:k_anonymity_min_cohort`, default 5) has its value columns REPLACED by
       `%Samen.Aggregate.Suppressed{reason: :k_anonymity}`. The value is never
       returned — including the count-of-one cohort (`cohort_count == 1`), the worst
       case the doc names.

    2. **l-diversity** (clause (b)) — where a cohort carries a **sensitive attribute**,
       a cohort needs `>= l` DISTINCT sensitive values (config, `:l_diversity_min_distinct`,
       default 2) or its value columns suppress with `reason: :l_diversity`. This catches
       the homogeneity attack: a k-sized cohort whose sensitive attribute takes a single
       value (`distinct_sensitive == 1`) discloses that value for every member.

  ## What is NOT here (posture under construction — the honest edge, VERBATIM)

  > We enforce the minimum-cohort / minimum-distinct floor today and treat the
  > cross-query budget / DP layer as posture under construction, not a solved proof.

  This module is the FLOOR (k-anon + l-div), **enforced**. The cross-query DEFENCE —
  a global / per-cohort query budget, cross-query suppression, and a differential-privacy
  posture (calibrated noise composed across queries), plus **t-closeness** (bounding the
  distance between a cohort's sensitive-value distribution and the overall distribution)
  — is **NOT implemented here**. The budget is a SCAFFOLD (`Samen.Aggregate.QueryBudget`,
  accounting only, WARN-not-enforce); DP / t-closeness are a named research track
  (plan T6.6). This module does not attempt them and does not claim to. A repeated /
  overlapping / differencing query is NOT stopped by this module today (the budget ledger
  records it; full defence is deferred). See the T4.5 report and `Samen.Aggregate.QueryBudget`.

  ## Enforcement point (why this can't be bypassed via the domain)

  `Samen.Aggregate.read_all/2` — the ONLY read surface the token-blind aggregate actor
  can use — routes every returned row set through `Samen.Aggregate.Privacy.apply/3`
  BEFORE returning it, using the reading resource's `aggregate_cohort_spec/0` (see
  `Samen.Aggregate.CohortSpec`). There is no other read path for the aggregate actor
  (the domain is default-deny to every other principal; the actor is org-less so the
  tenant plane filters it to zero rows; the reveal seam refuses it). So the aggregate
  resources' rows physically pass through this suppression module on their way out — you
  cannot read a raw, unsuppressed value "as the aggregate actor" through the domain.
  (The anti-tautology probe in the T4.5 tests sabotages `apply/3` and watches the
  count-of-one / homogeneous red paths flip, proving the routing is load-bearing.)

  ## Cohort spec

  A `%Samen.Aggregate.CohortSpec{}` describes, per aggregate resource, how to read a
  row's cohort count and (optionally) its distinct-sensitive-value count, and which
  columns hold the RELEASABLE VALUES to suppress. See that module. A resource with no
  cohort spec is a fail-closed error here — an aggregate cell with no declared cohort
  size cannot be proven `>= k`, so we refuse to release it (`{:error,
  :no_cohort_spec}`), rather than defaulting to "release" (mask-unknown-by-default, the
  same keystone the PII DSL uses).
  """

  alias Samen.Aggregate.{CohortSpec, Suppressed}

  @default_k 5
  @default_l 2

  @doc """
  The configured minimum cohort size `k` for k-anonymity suppression.

  Config: `config :samen_core, :k_anonymity_min_cohort, N`. Default #{@default_k}
  (a sensible, non-trivial floor: a cohort of at least #{@default_k} subjects is the
  common k-anon default; 1 would be no floor at all). Must be a positive integer `>= 1`.
  """
  @spec k() :: pos_integer()
  def k do
    case Application.get_env(:samen_core, :k_anonymity_min_cohort, @default_k) do
      n when is_integer(n) and n >= 1 -> n
      _ -> @default_k
    end
  end

  @doc """
  The configured minimum distinct-sensitive-value count `l` for l-diversity suppression.

  Config: `config :samen_core, :l_diversity_min_distinct, N`. Default #{@default_l}
  (a cohort must expose at least #{@default_l} distinct sensitive values, or every member
  shares one — the homogeneity attack). Must be a positive integer `>= 1`.
  """
  @spec l() :: pos_integer()
  def l do
    case Application.get_env(:samen_core, :l_diversity_min_distinct, @default_l) do
      n when is_integer(n) and n >= 1 -> n
      _ -> @default_l
    end
  end

  @doc """
  Apply the k-anonymity and l-diversity floors to a list of aggregate rows.

  `rows` is a list of maps (the projection rows, e.g. from `Ash.read`). `spec` is the
  `%CohortSpec{}` for the resource that produced them. `opts` may override `:k` / `:l`
  (tests use this; production reads config).

  Returns `{:ok, rows'}` where each row that fails a floor has its `spec.value_columns`
  REPLACED by a `%Suppressed{}` sentinel (the cohort/diversity metric columns are left
  intact — they are the count that justifies the suppression, not the releasable value).
  Returns `{:error, :no_cohort_spec}` if `spec` is nil (fail closed — see moduledoc).

  Order: **k-anonymity is checked first** (a cohort too small to release is suppressed
  before we even consider its diversity); l-diversity is checked on cohorts that clear
  the k floor. A row can be suppressed by either; the FIRST floor that fires wins the
  `reason`.
  """
  @spec apply([map()], CohortSpec.t() | nil, keyword()) ::
          {:ok, [map()]} | {:error, :no_cohort_spec}
  def apply(rows, spec, opts \\ [])

  def apply(_rows, nil, _opts), do: {:error, :no_cohort_spec}

  def apply(rows, %CohortSpec{} = spec, opts) when is_list(rows) do
    k = floor_opt(Keyword.get(opts, :k), k())
    l = floor_opt(Keyword.get(opts, :l), l())

    {:ok, Enum.map(rows, fn row -> suppress_row(row, spec, k, l) end)}
  end

  # Fail-closed lower bound on an EXPLICIT `:k` / `:l` override (P17-carry-3, ADR-045 §3).
  #
  # A POSITIVE integer override is honored verbatim — including the `k: 1` neuter the
  # aggregate-floor anti-tautology tests drive to prove the floor is load-bearing (a count-of-
  # one releases under `k: 1`). But a NON-positive / non-integer override (`k: 0`, `k: -1`,
  # `l: 0`) would DISABLE the floor entirely — `cohort_count < 0` never fires, so every cohort
  # (count-of-one included) would leak. Such an override is REFUSED and the CONFIG floor applies
  # instead: an explicit opt can only RAISE the floor toward the config minimum, never drive it
  # below (the config minimum, which `k()`/`l()` already guarantee is `>= 1`, is the hard floor).
  # So no caller — not even a server-side one passing a hostile `k: 0` — can emit a sub-floor
  # cohort through this module. `nil` (no override supplied) also falls through to the config
  # floor, preserving the production default.
  defp floor_opt(override, _config_floor) when is_integer(override) and override >= 1,
    do: override

  defp floor_opt(_override, config_floor), do: config_floor

  # --- per-row floor evaluation -------------------------------------------------

  defp suppress_row(row, %CohortSpec{} = spec, k, l) do
    cohort_count = fetch_metric(row, spec.cohort_count_column)

    cond do
      # k-anonymity FLOOR: cohort count < k (or unknown) suppresses. `nil`/non-integer
      # cohort count is treated as failing the floor (fail closed — we cannot prove
      # >= k, so we do not release). This includes count-of-one.
      not is_integer(cohort_count) or cohort_count < k ->
        replace_values(row, spec, Suppressed.k_anonymity(k, cohort_count || 0))

      # l-diversity FLOOR: where a sensitive attribute rides the cohort, the cohort
      # needs >= l DISTINCT sensitive values. A spec with no `distinct_sensitive_column`
      # opts this cohort out of l-diversity (k-anon still applies).
      spec.distinct_sensitive_column != nil ->
        distinct = fetch_metric(row, spec.distinct_sensitive_column)

        if not is_integer(distinct) or distinct < l do
          replace_values(row, spec, Suppressed.l_diversity(l, distinct || 0))
        else
          row
        end

      # Cleared both floors (or l-diversity not applicable): release verbatim.
      true ->
        row
    end
  end

  # Read a metric column from the row (supports atom or string keys — Ash rows are
  # atom-keyed; raw maps in tests may be string-keyed).
  defp fetch_metric(row, column) when is_atom(column) do
    case Map.fetch(row, column) do
      {:ok, v} -> v
      :error -> Map.get(row, Atom.to_string(column))
    end
  end

  # Replace every releasable-value column with the suppression sentinel. The metric
  # columns (cohort count, distinct count) are intentionally LEFT — they justify the
  # suppression and are themselves bounded counts, not the sensitive value.
  defp replace_values(row, %CohortSpec{value_columns: value_columns}, %Suppressed{} = sup) do
    Enum.reduce(value_columns, row, fn col, acc ->
      cond do
        Map.has_key?(acc, col) -> Map.put(acc, col, sup)
        is_atom(col) and Map.has_key?(acc, Atom.to_string(col)) -> Map.put(acc, Atom.to_string(col), sup)
        true -> acc
      end
    end)
  end
end
