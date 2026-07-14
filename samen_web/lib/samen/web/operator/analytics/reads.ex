defmodule Samen.Web.Operator.AnalyticsReads do
  @moduledoc """
  Operator product-analytics read layer (WS-B / B8, design §4.5; ADR-021) — the G12
  SEED read, and nothing more: the signup→first-run→first-record activation funnel
  plus the 4-week retention curve, CROSS-TENANT, computed over the
  `paf_product_event_rollup` RAW table (B8's `paf` rollup over the `pae` ledger —
  never a live `pae` scan, never an arbitrary event exploration; no paths, no
  DAU/MAU, no ClickHouse — stated out-of-scope, design §7).

  ## Cross-tenant ⇒ the aggregate floors run HERE (AC-G12-6)

  Unlike the operator's own-book revenue read (tenant-book data, no floor — the B2
  gate analysis), every number on this surface summarizes actors ACROSS tenant orgs,
  so each released cell passes through the SAME enforced k-anonymity floor the
  aggregate plane uses — `Samen.Aggregate.Privacy.apply/3` (T4.5, k-anon min-cohort,
  config default 5) with an explicit `%CohortSpec{}` per read:

    * **funnel** — a stage's cohort is the set of orgs that reached it
      (`org_count`, one rollup row per org × stage); the releasable value is the
      cross-tenant distinct-actor sum. A stage reached by fewer than `k` orgs has
      its actor count REPLACED by `%Samen.Aggregate.Suppressed{}` — the framework
      renders `⊘` and never un-suppresses.
    * **retention** — a cohort is the week's signup class; its size is the
      offset-0 distinct-actor count; the releasable value is the weekly retained
      curve. A cohort smaller than `k` has its ENTIRE curve suppressed
      ("k-anon min 5 on cohort", design §4.5).

  `opts` may override `:k` / `:l` exactly as `Samen.Aggregate.read_all/2` documents
  (tests use the override to prove the floor is load-bearing — the sabotage flip;
  production reads config).

  ## Bounded reads over the rollup, identical table name in every host DB

  Both reads are explicit-`LIMIT` SQL over the `paf` raw table (the `mrr` precedent:
  cron-refreshed by `RollupRefreshWorker` on the B2 `:source :domain` machinery, no
  Ash resource fronts it, `paf` is a column prefix, not a registry abbrev). Bounds:
  3 stages and 5 offsets exist by construction; the LIMITs are hard caps on top.

  ## Masking / PII posture

  Token-blind by construction: every value this module touches is a bounded enum
  label, a week bucket, or a count — `paf` carries NO PII column (AC-G12-3 proved
  the `pae` source token-blind), so there is nothing to mask and no `Samen.Vault`
  call, ever. This is a report module over the Postgres-primary rollup (not the CDC
  mirror); the analytics marker records that posture for the `never_read_current`
  lint.
  """

  use Samen.Cdc.Analytics

  alias Samen.Aggregate.{CohortSpec, Privacy}
  alias Samen.Web.Mount

  # The raw rollup table (ADR-021; identical name in every host DB — the mrr precedent).
  @rollup_table "paf_product_event_rollup"

  # The design's ONE funnel, in order (bounded catalog stages — B8's rollup grain).
  @funnel_stages ~w(signup first_run first_record)

  # Hard caps on top of the by-construction bounds (3 stages; 5 offsets × cohort weeks).
  @funnel_row_limit 10
  # 52 cohort weeks × offsets 0..4 — one year of weekly cohorts, the read hard cap.
  @retention_row_limit 260
  @max_week_offset 4

  # The funnel cohort: orgs reached per stage; the releasable value: the actor sum.
  @funnel_spec %CohortSpec{
    cohort_key_columns: [:stage],
    cohort_count_column: :org_count,
    value_columns: [:actor_count]
  }

  # The retention cohort: the week's signup class (offset-0 actors); the releasable
  # value: the whole weekly curve (suppressed wholesale below the floor).
  @retention_spec %CohortSpec{
    cohort_key_columns: [:cohort_week],
    cohort_count_column: :size,
    value_columns: [:weeks]
  }

  @doc """
  Assemble the whole seed analytics surface, cross-tenant, floored:

      %{
        funnel: [%{stage: "signup", org_count: n, actor_count: n | %Suppressed{}}, ...]
        retention: [%{cohort_week: ~D[], size: n,
                      weeks: [%{offset: 0..4, actors: n, rate: f}] | %Suppressed{}}, ...]
      }

  `funnel` is `[]` only when the rollup has NO funnel rows at all (the empty state);
  otherwise all three stages appear in funnel order (an unreached stage is a 0-org
  cohort — below any floor, suppressed). On any read error the surface is EMPTY
  (`empty/0`), never partial garbage.
  """
  def analytics(mount, opts \\ []) do
    %{funnel: funnel(mount, opts), retention: retention(mount, opts)}
  rescue
    _ -> empty()
  end

  @doc "The empty surface shape (no mount / read error)."
  def empty, do: %{funnel: [], retention: []}

  @doc "How many funnel stages arrived `%Suppressed{}` (feeds the suppression note)."
  def funnel_suppressed(funnel) when is_list(funnel),
    do: Enum.count(funnel, &Samen.Aggregate.Suppressed.suppressed?(&1.actor_count))

  @doc "How many retention cohorts arrived `%Suppressed{}` (feeds the suppression note)."
  def retention_suppressed(retention) when is_list(retention),
    do: Enum.count(retention, &Samen.Aggregate.Suppressed.suppressed?(&1.weeks))

  # -- funnel (cross-tenant orgs-reached per stage, floored) -----------------------

  defp funnel(%Mount{repo: repo}, opts) do
    sql = """
    SELECT paf_stage, COUNT(*)::int AS org_count, COALESCE(SUM(paf_actor_count), 0)::int AS actor_count
    FROM #{@rollup_table}
    WHERE paf_kind = 'funnel' AND paf_suppressed = FALSE AND paf_stage IS NOT NULL
    GROUP BY paf_stage
    LIMIT #{@funnel_row_limit}
    """

    case Ecto.Adapters.SQL.query(repo, sql, []) do
      {:ok, %{rows: []}} ->
        []

      {:ok, %{rows: rows}} ->
        by_stage =
          Map.new(rows, fn [stage, org_count, actor_count] ->
            {stage, %{stage: stage, org_count: org_count, actor_count: actor_count}}
          end)

        # All three stages, funnel order; an unreached stage is a 0-org cohort
        # (which the floor then fail-closes — a cohort of 0 cannot prove >= k).
        stage_rows =
          Enum.map(@funnel_stages, fn stage ->
            Map.get(by_stage, stage, %{stage: stage, org_count: 0, actor_count: 0})
          end)

        {:ok, floored} = Privacy.apply(stage_rows, @funnel_spec, floor_opts(opts))
        floored

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp funnel(_, _opts), do: []

  # -- retention (weekly signup cohorts × offsets 0..4, floored per cohort) --------

  defp retention(%Mount{repo: repo}, opts) do
    sql = """
    SELECT paf_cohort_week, paf_week_offset, COALESCE(SUM(paf_actor_count), 0)::int AS actor_count
    FROM #{@rollup_table}
    WHERE paf_kind = 'retention' AND paf_suppressed = FALSE
      AND paf_cohort_week IS NOT NULL
      AND paf_week_offset BETWEEN 0 AND #{@max_week_offset}
    GROUP BY paf_cohort_week, paf_week_offset
    ORDER BY paf_cohort_week ASC, paf_week_offset ASC
    LIMIT #{@retention_row_limit}
    """

    case Ecto.Adapters.SQL.query(repo, sql, []) do
      {:ok, %{rows: rows}} ->
        cohort_rows =
          rows
          |> Enum.group_by(fn [week, _offset, _count] -> week end)
          |> Enum.sort_by(fn {week, _} -> week end, Date)
          |> Enum.map(fn {week, week_rows} -> cohort_row(week, week_rows) end)

        {:ok, floored} = Privacy.apply(cohort_rows, @retention_spec, floor_opts(opts))
        floored

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp retention(_, _opts), do: []

  # One cohort row: size = the offset-0 distinct-actor count (0 when absent — a
  # sizeless cohort fail-closes at the floor); weeks = the retained curve with
  # per-offset rate over the cohort size.
  defp cohort_row(week, week_rows) do
    counts = Map.new(week_rows, fn [_week, offset, count] -> {offset, count} end)
    size = Map.get(counts, 0, 0)

    weeks =
      for offset <- 0..@max_week_offset, actors = Map.get(counts, offset) do
        %{offset: offset, actors: actors, rate: rate(actors, size)}
      end

    %{cohort_week: week, size: size, weeks: weeks}
  end

  defp rate(_actors, 0), do: nil
  defp rate(actors, size), do: actors / size

  # The floor override seam `Samen.Aggregate.read_all/2` documents: tests pass
  # `k:`/`l:` (the sabotage flip); production reads config (k-anon min 5).
  defp floor_opts(opts), do: Keyword.take(opts, [:k, :l])
end
