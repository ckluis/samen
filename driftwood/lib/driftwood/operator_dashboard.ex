defmodule Driftwood.OperatorDashboard do
  @moduledoc """
  The operator's **cross-tenant dashboard** (T5.3 clause (b); T4.2 mounted over the
  freight vertical; doc §control "Cross-tenant views (MRR, queues) run on a separate
  token-blind actor").

  This is the SEPARATE, mutually-exclusive path from masked impersonation
  (`Driftwood.OperatorImpersonationLive`, single-org). It reads ONLY through the
  token-blind aggregate domain (`Driftwood.Aggregate`) via `Samen.Aggregate.read_all/2`
  with the singleton aggregate actor. There is no other data path here — the dashboard
  NEVER reaches a tenant-plane freight resource directly, never opens an impersonation
  session, never reveals. It sees cross-tenant LOAD VOLUME and MRR totals, and can never
  see a subject:

    * `Samen.Reveal.reveal/5` refuses the aggregate actor structurally.
    * `Samen.Policy.OrgScope` filters the org-less aggregate actor to zero rows on every
      tenant-plane resource.
    * The aggregate domain's resources are C7-verified to have no `pii_` columns.

  ## The two dashboard views (the doc's two examples on the freight shape)

    * `load_volume/0` — cross-tenant load volume by lane (load_count + gross_cents),
      with the k-anonymity floor applied.
    * `mrr/0` — total cross-tenant brokerage MRR (sum of `mrr_cents` across tiers) plus
      the per-tier breakdown.

  ## T4.5 privacy floors are applied by the read path, not here

  Both views read through `Samen.Aggregate.read_all/2`, which enforces the k-anonymity
  floor before returning rows: a lane/tier whose cohort is below `k` comes back with its
  releasable values (`load_count`/`gross_cents`/`mrr_cents`) as a
  `%Samen.Aggregate.Suppressed{}`. The dashboard treats a `%Suppressed{}` cell as
  withheld — it never sums a suppressed value into the cross-tenant total (that would
  re-leak it), and it surfaces the suppression to the operator as `⊘`.
  """

  alias Driftwood.Aggregate.{LoadVolumeByLane, MrrByTier}
  alias Samen.Aggregate.Suppressed

  @doc """
  Cross-tenant LOAD VOLUME by lane. Returns `{:ok, %{total_loads: n,
  total_gross_cents: n, by_lane: [%{lane, tenant_count, load_count, gross_cents}],
  suppressed_lanes: [lane]}}` — read ONLY through the token-blind aggregate domain, with
  the T4.5 k-anonymity floor applied. Never touches a tenant row.

  A lane whose cohort (`tenant_count`) is below `k` has suppressed `load_count` /
  `gross_cents`; that lane is NOT summed into the totals (summing a suppressed value
  would re-leak it) and its name is listed in `suppressed_lanes`.
  """
  @spec load_volume() :: {:ok, map()} | {:error, term()}
  def load_volume do
    case Samen.Aggregate.read_all(LoadVolumeByLane) do
      {:ok, rows} ->
        by_lane =
          Enum.map(rows, fn r ->
            %{
              lane: r.lane,
              tenant_count: r.tenant_count,
              load_count: r.load_count,
              gross_cents: r.gross_cents
            }
          end)

        total_loads =
          Enum.reduce(rows, 0, fn r, acc ->
            if Suppressed.suppressed?(r.load_count), do: acc, else: acc + (r.load_count || 0)
          end)

        total_gross =
          Enum.reduce(rows, 0, fn r, acc ->
            if Suppressed.suppressed?(r.gross_cents), do: acc, else: acc + (r.gross_cents || 0)
          end)

        suppressed_lanes =
          rows
          |> Enum.filter(&Suppressed.suppressed?(&1.load_count))
          |> Enum.map(& &1.lane)

        {:ok,
         %{
           total_loads: total_loads,
           total_gross_cents: total_gross,
           by_lane: by_lane,
           suppressed_lanes: suppressed_lanes
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Cross-tenant brokerage MRR by plan tier. Returns `{:ok, %{total_cents: n, by_tier:
  [%{tier, tenant_count, mrr_cents}], suppressed_tiers: [tier]}}` — read ONLY through the
  token-blind aggregate domain, with the T4.5 k-anonymity floor applied. Never touches a
  tenant row.

  A tier whose cohort (`tenant_count`) is below `k` has a suppressed `mrr_cents`; that
  tier's revenue is NOT summed into `total_cents` and its name is listed in
  `suppressed_tiers`.
  """
  @spec mrr() :: {:ok, map()} | {:error, term()}
  def mrr do
    case Samen.Aggregate.read_all(MrrByTier) do
      {:ok, rows} ->
        by_tier =
          Enum.map(rows, fn r ->
            %{tier: r.tier, tenant_count: r.tenant_count, mrr_cents: r.mrr_cents}
          end)

        total =
          Enum.reduce(rows, 0, fn r, acc ->
            if Suppressed.suppressed?(r.mrr_cents), do: acc, else: acc + (r.mrr_cents || 0)
          end)

        suppressed_tiers =
          rows
          |> Enum.filter(&Suppressed.suppressed?(&1.mrr_cents))
          |> Enum.map(& &1.tier)

        {:ok, %{total_cents: total, by_tier: by_tier, suppressed_tiers: suppressed_tiers}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
