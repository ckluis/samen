defmodule Driftwood.OperatorAggregate do
  @moduledoc """
  The host adapter that feeds Driftwood's token-blind cross-tenant projection into the
  FRAMEWORK operator aggregate surface (`Samen.Web.Operator.AggregateLive`, ADR-009 §5.3
  clause 2).

  The framework owns the token-blind CHROME (the banner, the metric cards, the `⊘`
  suppression rendering) but cannot derive a vertical's projection SHAPE by name — freight
  MRR-by-tier / load-volume-by-lane is Driftwood-specific. So Driftwood supplies this MFA
  (`{Driftwood.OperatorAggregate, :load, []}`) on the mount labels; the framework calls it
  and renders the generic `%{metrics: [...], groups: [...]}` it returns.

  This reads ONLY through `Driftwood.OperatorDashboard`, which reads ONLY through the
  token-blind aggregate domain (`Driftwood.Aggregate`) with the singleton aggregate actor —
  there is no PII path here (C7-verified: the aggregate domain has no `pii_` column). A
  `%Samen.Aggregate.Suppressed{}` value flows through untouched so the framework renders it
  as `⊘`; money is tagged `{:money, cents}` so the framework's `cell/1` formats dollars.

  The bespoke driftwood-local `OperatorDashboardLive` (which hand-rolled this exact layout)
  is DELETED — its render moved to the framework; only this data-shaping adapter stays,
  because the projection is the vertical's business.
  """

  alias Driftwood.OperatorDashboard
  alias Samen.Aggregate.Suppressed

  @doc """
  The token-blind projection for the framework aggregate surface. Returns
  `%{metrics: [...], groups: [...], suppressed_count: n}` — the generic shape
  `Samen.Web.Operator.AggregateLive` renders. Fails safe to an empty projection if the
  aggregate reads error (the framework then renders the structurally-correct empty plane).
  """
  @spec load() :: %{metrics: list(), groups: list(), suppressed_count: non_neg_integer()}
  def load do
    with {:ok, lv} <- OperatorDashboard.load_volume(),
         {:ok, mrr} <- OperatorDashboard.mrr() do
      %{
        metrics: metrics(lv, mrr),
        groups: [mrr_group(mrr), load_volume_group(lv)],
        suppressed_count: suppressed_count(lv, mrr)
      }
    else
      _ -> %{metrics: [], groups: [], suppressed_count: 0}
    end
  end

  # -- metric cards ------------------------------------------------------------

  defp metrics(lv, mrr) do
    [
      %{label: "Portfolio MRR", value: {:money, mrr.total_cents}, sub: "across tiers"},
      %{label: "Active tenants", value: active_tenants(mrr), sub: "org-level cohorts"},
      %{label: "Loads / total", value: lv.total_loads, sub: "across all lanes"},
      %{label: "Total gross", value: {:money, lv.total_gross_cents}, sub: "across all lanes"}
    ]
  end

  # -- MRR-by-tier group -------------------------------------------------------

  defp mrr_group(mrr) do
    %{
      id: "mrr-by-tier",
      title: "MRR by tier",
      columns: ["Plan tier", "Tenants", "MRR"],
      rows:
        Enum.map(mrr.by_tier, fn r ->
          [r.tier, r.tenant_count, money(r.mrr_cents)]
        end)
    }
  end

  # -- load-volume-by-lane group ----------------------------------------------

  defp load_volume_group(lv) do
    %{
      id: "load-volume",
      title: "Load volume by lane",
      columns: ["Lane", "Tenants", "Loads", "Gross"],
      rows:
        Enum.map(lv.by_lane, fn r ->
          [r.lane, r.tenant_count, r.load_count, money(r.gross_cents)]
        end)
    }
  end

  # -- helpers -----------------------------------------------------------------

  # Money cells: a suppressed value flows through untouched (the framework renders `⊘`);
  # a real integer is tagged `{:money, cents}` so the framework's `cell/1` formats dollars.
  defp money(%Suppressed{} = s), do: s
  defp money(cents) when is_integer(cents), do: {:money, cents}
  defp money(_), do: {:money, 0}

  # Distinct tenant count: each tenant sits in exactly one tier, so summing per-tier
  # tenant_counts gives the portfolio size; suppressed cohorts are skipped (never
  # re-leak a small cohort).
  defp active_tenants(mrr) do
    Enum.reduce(mrr.by_tier, 0, fn r, acc ->
      if match?(%Suppressed{}, r.tenant_count), do: acc, else: acc + (r.tenant_count || 0)
    end)
  end

  defp suppressed_count(lv, mrr) do
    length(Map.get(lv, :suppressed_lanes, [])) + length(Map.get(mrr, :suppressed_tiers, []))
  end
end
