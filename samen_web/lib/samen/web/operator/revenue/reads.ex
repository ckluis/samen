defmodule Samen.Web.Operator.RevenueReads do
  @moduledoc """
  Operator revenue read layer (WS-B / B3, design §1.3-1.4; ADR-017/018). Assembles the
  operator revenue surface — MRR movement waterfall per period, NRR / churn tiles, and
  the cohort retention grid — for the OPERATOR ORG's OWN book of business on the tenant
  plane (per-org drill-down is tenant-book data the SaaS owns: NO aggregate floor
  applies here, per the B2 gate analysis; the CROSS-tenant MRR-by-plan section is the
  separate `operator_aggregate` path on `RevenueLive`, floors enforced at the
  `Samen.Aggregate.read_all/2` chokepoint).

  ## Wraps the kernel fold — never recomputes

  Every metric is `Samen.Revenue.Metrics` (the B2 pure kernel): this module only
  FETCHES bounded rows and THREADS them through `movement_sums_from_rollup_rows/2`,
  `waterfall/1`, `nrr/1`, `gross_churn_rate/1`, `net_churn_rate/1`,
  `logo_churn_rate/1`, and `cohort_retention/1`. The one piece of state this module
  owns is the period CHAINING the kernel documents as caller-threaded: each period's
  `opening_cents` is the prior period's `closing_cents` (day one opens at 0 — the B1
  backfill seeds a synthetic `:new` per active subscription, so the chain reconciles
  from the install boundary; Invariant R1).

  ## Reads the rollup, never a live movement scan (AC-G7-6)

  The per-period sums come from the `mrr_revenue_rollup` RAW table (ADR-018 — the
  `rol_daily_event_count` precedent: cron-refreshed by `RollupRefreshWorker`, no Ash
  resource fronts it, `mrr` is its column prefix, not a registry abbrev), read with an
  explicit `LIMIT` and an `mrr_org_id` filter. The only `mov` LEDGER read is the
  cohort-retention timeline (the kernel's documented raw-timeline input), OrgScope'd
  through Ash and explicitly `limit`-bounded — swept by the `reads.ex` AST lint
  (`Samen.Web.Reads.Lint.assert_all_bounded!/0`).

  ## Masking / PII posture

  Token-blind by construction: every value this module touches is a bounded id, enum,
  signed cent integer, count, or date — the `mov`/`mrr` columns carry NO PII (AC-G7-3),
  so there is nothing to mask and no `Samen.Vault` call, ever. This is a report module
  over the Postgres-primary rollup (not the CDC mirror); the analytics marker records
  that posture for the `never_read_current` lint.
  """

  use Samen.Cdc.Analytics

  alias Samen.Revenue.Metrics
  alias Samen.Web.Mount

  # The raw rollup table (ADR-018; identical name in every host DB — the rol precedent).
  @rollup_table "mrr_revenue_rollup"

  # Bounded by construction: 60 months × 6 kinds — the rollup read hard cap.
  @rollup_row_limit 360

  # The mov-timeline cap for the cohort grid (the kit's hard page cap, as
  # `Samen.Web.Operator.Reads` uses for its book-of-business fan-outs).
  @lookup_limit 200

  @doc """
  Assemble the whole revenue surface for the operator org:

      %{
        periods: [%{month:, waterfall: %Metrics.Waterfall{}, display:, nrr:,
                    gross_churn:, net_churn:, logo_churn:}, ...]  # ascending
        latest:  the last period (or nil),
        cohorts: Metrics.cohort_retention/1 grid over the mov timeline
      }

  On any read error the surface is EMPTY (`empty/0`), never partial garbage.
  """
  def revenue(mount, scope) do
    operator_org_id = Samen.Web.Operator.org_id(mount)

    periods =
      mount
      |> rollup_rows(operator_org_id)
      |> periods()

    %{
      periods: periods,
      latest: List.last(periods),
      cohorts: Metrics.cohort_retention(movement_timeline(mount, scope))
    }
  rescue
    _ -> empty()
  end

  @doc "The empty surface shape (no org / read error)."
  def empty do
    %{periods: [], latest: nil, cohorts: %{cohorts: [], max_offset: 0}}
  end

  # -- rollup read (raw table, bounded SQL) --------------------------------------

  # One org's rollup rows, ascending by period. Explicit LIMIT — bounded by
  # construction; the org filter keeps this the operator's OWN book (tenant-book
  # drill-down, no floor). Returns [%{period_month:, kind:, delta_cents:, count:}].
  defp rollup_rows(_mount, nil), do: []

  defp rollup_rows(%Mount{repo: repo}, operator_org_id) do
    sql = """
    SELECT mrr_period_month, mrr_kind, mrr_delta_cents, mrr_count
    FROM #{@rollup_table}
    WHERE mrr_org_id = $1 AND mrr_suppressed = FALSE
    ORDER BY mrr_period_month ASC, mrr_kind ASC
    LIMIT #{@rollup_row_limit}
    """

    with {:ok, org_uuid} <- Ecto.UUID.dump(operator_org_id),
         {:ok, %{rows: rows}} <- Ecto.Adapters.SQL.query(repo, sql, [org_uuid]) do
      Enum.map(rows, fn [month, kind, delta, count] ->
        %{period_month: month, kind: kind, delta_cents: delta, count: count}
      end)
    else
      _ -> []
    end
  rescue
    _ -> []
  end

  # -- period chaining (kernel-documented caller threading) -----------------------

  # Fold the rollup rows into per-period metric maps, chaining opening MRR (prior
  # closing) and opening logo count through the kernel folds. All arithmetic beyond
  # the chain thread lives in Samen.Revenue.Metrics.
  defp periods(rollup_rows) do
    {periods, _acc} =
      rollup_rows
      |> Enum.group_by(& &1.period_month)
      |> Enum.sort_by(fn {month, _rows} -> month end, Date)
      |> Enum.map_reduce({0, 0}, fn {month, rows}, {opening_cents, opening_logos} ->
        sums =
          rows
          |> Metrics.movement_sums_from_rollup_rows(opening_cents: opening_cents)
          |> Map.put(:opening_logos, opening_logos)

        waterfall = Metrics.waterfall(sums)

        period = %{
          month: month,
          waterfall: waterfall,
          display: Metrics.waterfall_display(sums),
          nrr: Metrics.nrr(sums),
          gross_churn: Metrics.gross_churn_rate(sums),
          net_churn: Metrics.net_churn_rate(sums),
          logo_churn: Metrics.logo_churn_rate(sums)
        }

        {period, {waterfall.closing_cents, max(opening_logos + logo_delta(rows), 0)}}
      end)

    periods
  end

  # Net logo movement of one period from the rollup COUNTS: new + reactivation − churn.
  defp logo_delta(rows) do
    Enum.reduce(rows, 0, fn %{kind: kind, count: count}, acc ->
      case to_string(kind) do
        "new" -> acc + count
        "reactivation" -> acc + count
        "churn" -> acc - count
        _ -> acc
      end
    end)
  end

  # -- mov timeline (cohort grid input — OrgScope'd, bounded Ash read) ------------

  # The raw movement timeline the kernel's cohort_retention/1 documents as its input.
  # Customer-keyed bounded ids + enums + cents + timestamps — no PII (AC-G7-3).
  defp movement_timeline(mount, scope) do
    Mount.resource(mount, SubscriptionEvent)
    |> Ash.Query.ensure_selected([:customer_id, :kind, :mrr_delta_cents, :occurred_at])
    |> Ash.Query.sort(occurred_at: :asc)
    |> Ash.Query.limit(@lookup_limit)
    |> Ash.read!(scope: scope)
  rescue
    _ -> []
  end
end
