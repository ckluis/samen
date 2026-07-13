defmodule Samen.Revenue.Metrics do
  @moduledoc """
  The PURE revenue-metric compute (WS-B / G7; design §1.4, ADR-017/018).

  Given the movement sums for a period — the by-`kind` `sum(mrr_delta_cents)` the
  `mrr_revenue_rollup` (`:source :domain`, ADR-018) materialises at grain
  `(org_id, period_month, kind)` — this computes the **MRR waterfall**, **NRR**,
  **gross / net / logo churn**, and (over the raw `mov` timeline) the **cohort
  retention grid**. Every function is a **pure fold over its input**: no DB access,
  no clock, no side effects — the same input always yields the same result. That
  purity is what makes them unit-testable in isolation (AC-G7-8) and what keeps the
  reconciliation invariant R1 (AC-G7-4/5) load-bearing: the waterfall's `closing`
  is a deterministic function of `opening + Σ(signed deltas)`, so it can be checked
  against the independently-computed snapshot MRR delta to the cent.

  ## Placement — kernel, not web

  These are pure functions over bounded integers + enums with NO web dependency,
  needed by the reconciliation proof (demo — `samen_core`-only), the operator
  revenue read (`samen_web`, B3), API/worker code paths, and every vertical. Like
  the notifications record/dispatch core and (later) the flag engine, the compute
  belongs in the kernel; the thin `Samen.Web.Operator` read that renders it is the
  web layer (B3). No PII can enter or leave — inputs are `kind` atoms + cent
  integers; the cohort input is customer-keyed bounded ids + timestamps.

  ## The sign convention (why the waterfall reconciles)

  The `mov` ledger's `mrr_delta_cents` is ALREADY SIGNED by the classifier:
  `:new`/`:expansion`/`:reactivation` are POSITIVE, `:contraction`/`:churn` are
  NEGATIVE, `:noop` is 0. So the period's NET change is simply the arithmetic sum of
  every kind's delta:

      net_change = new + expansion + contraction + churn + reactivation   (signed)

  and `closing == opening + net_change`. That is Invariant R1 in one line — no
  re-sign, no re-join. For DISPLAY the waterfall also exposes the conventional
  magnitude form (design §1.4):

      opening + new + expansion − |contraction| − |churn| + reactivation = closing

  where `contraction`/`churn` are shown as positive magnitudes with explicit minus
  bars. Both forms are algebraically identical; the signed form is the one the
  reconciliation test asserts on.

  ## Inputs

    * `waterfall/1`, `nrr/1`, `*_churn_rate/1` take a **movement-sum map** — a map
      keyed by the six `kind` atoms → signed cent totals, plus `:opening_cents` (the
      opening MRR at the period start) and (for logo churn) `:opening_logos` /
      counts. `movement_sums_from_rollup_rows/1` builds this map from raw
      `mrr_revenue_rollup` rows for one org+period.
    * `cohort_retention/1` takes the raw `mov` timeline rows (customer-keyed) and
      groups customers by their signup-month (`:new` row), then computes retained %
      per subsequent month from each customer's own movement timeline.
  """

  @kinds [:new, :expansion, :contraction, :churn, :reactivation, :noop]

  # The revenue-active kinds AFTER which a customer is on the book (used by cohort
  # retention to decide "retained in month M"). A customer is retained through a
  # month iff their running MRR (from the signed timeline) is > 0 at/through it.

  defmodule Waterfall do
    @moduledoc """
    The MRR movement waterfall for one period (design §1.4). `net_change` is the
    signed sum of every component (the R1 reconciliation quantity); `closing ==
    opening + net_change` ALWAYS holds by construction.

    `contraction`/`churn` are stored SIGNED (negative — as they ride the ledger) so
    `opening + new + expansion + contraction + churn + reactivation == closing` is a
    plain sum. The display magnitudes are `abs(contraction)` / `abs(churn)`.
    """
    @enforce_keys [
      :opening_cents,
      :new_cents,
      :expansion_cents,
      :contraction_cents,
      :churn_cents,
      :reactivation_cents,
      :net_change_cents,
      :closing_cents
    ]
    defstruct [
      :opening_cents,
      :new_cents,
      :expansion_cents,
      :contraction_cents,
      :churn_cents,
      :reactivation_cents,
      :net_change_cents,
      :closing_cents
    ]

    @type t :: %__MODULE__{
            opening_cents: integer(),
            new_cents: integer(),
            expansion_cents: integer(),
            contraction_cents: integer(),
            churn_cents: integer(),
            reactivation_cents: integer(),
            net_change_cents: integer(),
            closing_cents: integer()
          }
  end

  @doc "The movement kinds the metrics fold over."
  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  @doc """
  Build the movement-sum map this module's functions consume from RAW
  `mrr_revenue_rollup` rows for ONE org + ONE period.

  `rows` is a list of maps (or `{kind, delta_cents, count}` tuples) — one per
  `mov_kind` present in the rollup for the period. Missing kinds default to 0.
  `opening_cents` is threaded by the caller (the opening MRR at the period start,
  independently known — e.g. the prior period's closing, or the live snapshot at
  the boundary). Returns a map keyed by the six kind atoms → signed cent totals,
  plus `:opening_cents`, `:new_logos` and `:churn_logos` (from the counts).

  Fail-closed: an unknown kind raises (the rollup grain is a bounded enum — a kind
  outside the model is a data-integrity bug, not a silent drop).
  """
  @spec movement_sums_from_rollup_rows([map()] | [tuple()], keyword()) :: map()
  def movement_sums_from_rollup_rows(rows, opts \\ []) when is_list(rows) do
    opening = Keyword.get(opts, :opening_cents, 0)

    base =
      @kinds
      |> Map.new(&{&1, 0})
      |> Map.put(:opening_cents, opening)
      |> Map.put(:new_logos, 0)
      |> Map.put(:churn_logos, 0)

    Enum.reduce(rows, base, fn row, acc ->
      {kind, delta, count} = normalize_rollup_row(row)

      unless kind in @kinds do
        raise ArgumentError,
              "Revenue.Metrics: unknown mov_kind #{inspect(kind)} in rollup row — the rollup " <>
                "grain is a bounded enum #{inspect(@kinds)}; a kind outside it is a data bug"
      end

      acc
      |> Map.update!(kind, &(&1 + delta))
      |> bump_logos(kind, count)
    end)
  end

  defp bump_logos(acc, :new, count), do: Map.update!(acc, :new_logos, &(&1 + count))
  defp bump_logos(acc, :churn, count), do: Map.update!(acc, :churn_logos, &(&1 + count))
  defp bump_logos(acc, _kind, _count), do: acc

  # Accept a raw rollup row as a map (string or atom keys) or a {kind, delta, count}
  # tuple. Normalizes the kind to an atom (the rollup stores it as text).
  defp normalize_rollup_row({kind, delta, count}), do: {to_kind(kind), delta, count}

  defp normalize_rollup_row(%{} = m) do
    kind = m[:kind] || m["kind"] || m[:mrr_kind] || m["mrr_kind"]
    delta = m[:delta_cents] || m["delta_cents"] || m[:mrr_delta_cents] || m["mrr_delta_cents"] || 0
    count = m[:count] || m["count"] || m[:mrr_count] || m["mrr_count"] || 0
    {to_kind(kind), delta, count}
  end

  defp to_kind(k) when is_atom(k), do: k

  defp to_kind(k) when is_binary(k) do
    # Bounded set — only the six known kinds are convertible (never String.to_atom
    # on unbounded input).
    case Enum.find(@kinds, &(Atom.to_string(&1) == k)) do
      nil -> :__unknown__
      atom -> atom
    end
  end

  @doc """
  The MRR movement waterfall for one period → `%Waterfall{}`.

  Takes the movement-sum map (`movement_sums_from_rollup_rows/1` output or a plain
  map with the six kind keys + `:opening_cents`). `net_change_cents` is the signed
  sum of the five revenue-moving kinds (`:noop` contributes 0 by definition);
  `closing_cents == opening_cents + net_change_cents` — Invariant R1 by
  construction.
  """
  @spec waterfall(map()) :: Waterfall.t()
  def waterfall(sums) when is_map(sums) do
    opening = fetch_cents(sums, :opening_cents)
    new = fetch_cents(sums, :new)
    expansion = fetch_cents(sums, :expansion)
    contraction = fetch_cents(sums, :contraction)
    churn = fetch_cents(sums, :churn)
    reactivation = fetch_cents(sums, :reactivation)

    # The signed net — :noop is 0 and excluded (a no-op moves no MRR). This IS the
    # R1 quantity: Σ(signed mov deltas) over the period.
    net = new + expansion + contraction + churn + reactivation

    %Waterfall{
      opening_cents: opening,
      new_cents: new,
      expansion_cents: expansion,
      contraction_cents: contraction,
      churn_cents: churn,
      reactivation_cents: reactivation,
      net_change_cents: net,
      closing_cents: opening + net
    }
  end

  @doc """
  The DISPLAY form of the waterfall (design §1.4): contraction/churn as POSITIVE
  magnitudes so the visual reads `opening + new + expansion − contraction − churn +
  reactivation = closing`. Returns a map with `:contraction_magnitude_cents` /
  `:churn_magnitude_cents` (>= 0) alongside the signed struct fields.
  """
  @spec waterfall_display(map()) :: map()
  def waterfall_display(sums) when is_map(sums) do
    w = waterfall(sums)

    %{
      opening_cents: w.opening_cents,
      new_cents: w.new_cents,
      expansion_cents: w.expansion_cents,
      contraction_magnitude_cents: abs(w.contraction_cents),
      churn_magnitude_cents: abs(w.churn_cents),
      reactivation_cents: w.reactivation_cents,
      net_change_cents: w.net_change_cents,
      closing_cents: w.closing_cents
    }
  end

  @doc """
  Net Revenue Retention (design §1.4):

      NRR = (opening + expansion + contraction + churn) / opening

  (`expansion` positive, `contraction`/`churn` negative — a pure fraction of the
  EXISTING book's retained + expanded MRR; new logos are EXCLUDED, that is the
  definition of NRR). Returns a float ratio (1.0 == flat), or `nil` when `opening ==
  0` (undefined — no book to retain).
  """
  @spec nrr(map()) :: float() | nil
  def nrr(sums) when is_map(sums) do
    opening = fetch_cents(sums, :opening_cents)

    if opening == 0 do
      nil
    else
      expansion = fetch_cents(sums, :expansion)
      contraction = fetch_cents(sums, :contraction)
      churn = fetch_cents(sums, :churn)
      (opening + expansion + contraction + churn) / opening
    end
  end

  @doc """
  Gross revenue churn rate (design §1.4): the fraction of opening MRR LOST to
  contraction + churn, ignoring expansion/new — `(|contraction| + |churn|) /
  opening`. Returns a float in `0.0..1.0+`, or `nil` when `opening == 0`.
  """
  @spec gross_churn_rate(map()) :: float() | nil
  def gross_churn_rate(sums) when is_map(sums) do
    opening = fetch_cents(sums, :opening_cents)

    if opening == 0 do
      nil
    else
      contraction = fetch_cents(sums, :contraction)
      churn = fetch_cents(sums, :churn)
      (abs(contraction) + abs(churn)) / opening
    end
  end

  @doc """
  Net revenue churn rate: gross churn OFFSET by expansion —
  `(|contraction| + |churn| − expansion) / opening`. Can go negative (net
  expansion). `nil` when `opening == 0`.
  """
  @spec net_churn_rate(map()) :: float() | nil
  def net_churn_rate(sums) when is_map(sums) do
    opening = fetch_cents(sums, :opening_cents)

    if opening == 0 do
      nil
    else
      contraction = fetch_cents(sums, :contraction)
      churn = fetch_cents(sums, :churn)
      expansion = fetch_cents(sums, :expansion)
      (abs(contraction) + abs(churn) - expansion) / opening
    end
  end

  @doc """
  Logo (customer-count) churn rate (design §1.4): `count(:churn movements) /
  opening_logos`. Uses the `:churn_logos` count from the rollup and the
  `:opening_logos` the caller threads (the active-customer count at period start).
  Returns a float, or `nil` when `opening_logos == 0`.
  """
  @spec logo_churn_rate(map()) :: float() | nil
  def logo_churn_rate(sums) when is_map(sums) do
    opening_logos = Map.get(sums, :opening_logos, 0)

    if opening_logos == 0 do
      nil
    else
      churn_logos = Map.get(sums, :churn_logos, 0)
      churn_logos / opening_logos
    end
  end

  # ---------------------------------------------------------------------------
  # Cohort retention grid (over the raw mov timeline — customer-keyed)
  # ---------------------------------------------------------------------------

  @doc """
  The cohort retention grid (design §1.4): customers grouped by signup-month (their
  `:new` `mov` row), retained % per subsequent month from EACH customer's own
  movement timeline.

  `mov_rows` is the raw `mov` ledger for the org — a list of maps each carrying at
  least `:customer_id`, `:kind`, `:mrr_after_cents` (or `:mrr_delta_cents`), and
  `:occurred_at` (a `Date`/`DateTime`/`NaiveDateTime`). A customer's signup month is
  the month of their FIRST `:new` row; they are "retained" in a later month iff
  their running MRR (folding the signed deltas through the timeline) is `> 0` at the
  END of that month — i.e. they still contribute revenue.

  Returns:

      %{
        cohorts: [%{
          cohort_month: ~D[2026-01-01],
          size: 12,                       # customers who signed up that month
          retention: [                    # index 0 = signup month (always 100%)
            %{month_offset: 0, retained: 12, rate: 1.0},
            %{month_offset: 1, retained: 10, rate: 0.833...},
            ...
          ]
        }, ...],
        max_offset: 3
      }

  Pure + deterministic: the same rows always yield the same grid. No clock — the
  grid spans only the months present in the data (no "future empty months").
  """
  @spec cohort_retention([map()], keyword()) :: map()
  def cohort_retention(mov_rows, opts \\ []) when is_list(mov_rows) do
    # Group rows by customer, each timeline sorted by occurred_at.
    by_customer =
      mov_rows
      |> Enum.reject(&(row_customer_id(&1) in [nil, ""]))
      |> Enum.group_by(&row_customer_id/1)
      |> Map.new(fn {cust, rows} -> {cust, Enum.sort_by(rows, &row_month/1, Date)} end)

    # Each customer's signup month = month of first :new row. Customers with no
    # :new row (e.g. only pre-ledger noop) are excluded from cohorts.
    customers =
      by_customer
      |> Enum.flat_map(fn {cust, rows} ->
        case Enum.find(rows, &(row_kind(&1) == :new)) do
          nil -> []
          new_row -> [{cust, row_month(new_row), rows}]
        end
      end)

    # The full month axis (distinct signup months, ascending) — cohorts.
    cohort_months =
      customers
      |> Enum.map(fn {_cust, signup_month, _rows} -> signup_month end)
      |> Enum.uniq()
      |> Enum.sort(Date)

    # The max month present across ALL timelines bounds the retention offsets so the
    # grid is data-shaped (no invented future months).
    all_months =
      mov_rows
      |> Enum.reject(&(row_customer_id(&1) in [nil, ""]))
      |> Enum.map(&row_month/1)

    last_month = if all_months == [], do: nil, else: Enum.max(all_months, Date)
    horizon = Keyword.get(opts, :horizon)

    cohorts =
      Enum.map(cohort_months, fn cohort_month ->
        members =
          Enum.filter(customers, fn {_c, m, _r} -> Date.compare(m, cohort_month) == :eq end)

        size = length(members)
        max_off = cohort_max_offset(cohort_month, last_month, horizon)

        retention =
          for offset <- 0..max_off do
            target_month = add_months(cohort_month, offset)

            retained =
              Enum.count(members, fn {_cust, _signup, rows} ->
                retained_through?(rows, target_month)
              end)

            %{
              month_offset: offset,
              retained: retained,
              rate: if(size == 0, do: 0.0, else: retained / size)
            }
          end

        %{cohort_month: cohort_month, size: size, retention: retention}
      end)

    max_offset =
      cohorts
      |> Enum.flat_map(fn c -> Enum.map(c.retention, & &1.month_offset) end)
      |> case do
        [] -> 0
        offs -> Enum.max(offs)
      end

    %{cohorts: cohorts, max_offset: max_offset}
  end

  # A customer is retained THROUGH `target_month` iff their running MRR — folding the
  # signed deltas of every movement up to and including that month — is > 0. This is
  # the self-contained reconciliation quantity (the ledger carries signed deltas), so
  # retention needs no price re-join.
  defp retained_through?(rows, target_month) do
    running =
      rows
      |> Enum.filter(fn r -> Date.compare(row_month(r), target_month) != :gt end)
      |> Enum.reduce(0, fn r, acc -> acc + row_delta(r) end)

    running > 0
  end

  defp cohort_max_offset(_cohort_month, nil, _horizon), do: 0

  defp cohort_max_offset(cohort_month, last_month, horizon) do
    data_offset = month_diff(cohort_month, last_month)

    case horizon do
      nil -> max(data_offset, 0)
      h when is_integer(h) -> data_offset |> max(0) |> min(h)
    end
  end

  # ---------------------------------------------------------------------------
  # Row accessors (tolerate atom-key maps + the mov Ash struct shape)
  # ---------------------------------------------------------------------------

  defp row_customer_id(%{customer_id: id}), do: id
  defp row_customer_id(%{"customer_id" => id}), do: id
  defp row_customer_id(%{mov_customer_id: id}), do: id
  defp row_customer_id(%{"mov_customer_id" => id}), do: id
  defp row_customer_id(_), do: nil

  defp row_kind(row) do
    raw = row_get(row, [:kind, "kind", :mov_kind, "mov_kind"])

    cond do
      is_atom(raw) -> raw
      is_binary(raw) -> to_kind(raw)
      true -> nil
    end
  end

  # The signed MRR delta of a row (the reconciliation quantity).
  defp row_delta(row) do
    row_get(row, [:mrr_delta_cents, "mrr_delta_cents", :delta_cents, "delta_cents"]) || 0
  end

  # The month bucket of a row (first of the occurred_at month, as a Date).
  defp row_month(row) do
    row
    |> row_get([:occurred_at, "occurred_at", :mov_occurred_at, "mov_occurred_at"])
    |> to_month_start()
  end

  defp row_get(row, keys) do
    Enum.find_value(keys, fn k ->
      case row do
        %{} -> Map.get(row, k)
        _ -> nil
      end
    end)
  end

  defp to_month_start(%Date{} = d), do: %Date{d | day: 1}
  defp to_month_start(%DateTime{} = dt), do: to_month_start(DateTime.to_date(dt))
  defp to_month_start(%NaiveDateTime{} = dt), do: to_month_start(NaiveDateTime.to_date(dt))

  # add N months to a month-start Date.
  defp add_months(%Date{year: y, month: m}, offset) do
    total = (y * 12 + (m - 1)) + offset
    %Date{year: div(total, 12), month: rem(total, 12) + 1, day: 1}
  end

  # whole-month difference from `a` to `b` (b >= a assumed for cohorts).
  defp month_diff(%Date{year: ya, month: ma}, %Date{year: yb, month: mb}) do
    (yb * 12 + mb) - (ya * 12 + ma)
  end

  # Fetch a signed cent value from the sums map (atom key), defaulting to 0.
  defp fetch_cents(sums, key), do: Map.get(sums, key, 0)
end
