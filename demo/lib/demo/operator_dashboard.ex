defmodule Demo.OperatorDashboard do
  @moduledoc """
  The operator's **cross-tenant dashboard** (T4.2 clause (d); doc §control "Cross-
  tenant views (MRR, queues) run on a separate token-blind actor").

  This is the SEPARATE, mutually-exclusive path from masked impersonation (T4.1,
  single-org). It reads ONLY through the token-blind aggregate domain
  (`Demo.Aggregate`) via `Samen.Aggregate.read_all/2` with the singleton aggregate
  actor. There is no other data path here — the dashboard NEVER reaches a
  tenant-plane resource directly, never opens an impersonation session, never
  reveals. It sees counts and MRR totals across all tenants, and can never see a
  subject:

    * `Samen.Reveal.reveal/5` refuses the aggregate actor structurally.
    * `Samen.Policy.OrgScope` filters the org-less aggregate actor to zero rows on
      every tenant-plane resource.
    * The aggregate domain's resources are C7-verified to have no `pii_` columns.

  ## The two dashboard views (the doc's two examples)

    * `mrr/0` — total cross-tenant MRR (sum of `mrr_cents` across tiers) plus the
      per-tier breakdown.
    * `queue_depths/0` — support-queue depth per status across all tenants.
  """

  alias Demo.Aggregate.{MrrByTier, TicketQueueDepth}

  @doc """
  Cross-tenant MRR. Returns `{:ok, %{total_cents: n, by_tier: [%{tier, tenant_count,
  mrr_cents}]}}` — read ONLY through the token-blind aggregate domain. Never touches
  a tenant row.
  """
  @spec mrr() :: {:ok, map()} | {:error, term()}
  def mrr do
    case Samen.Aggregate.read_all(MrrByTier) do
      {:ok, rows} ->
        by_tier =
          Enum.map(rows, fn r ->
            %{tier: r.tier, tenant_count: r.tenant_count, mrr_cents: r.mrr_cents}
          end)

        total = Enum.reduce(rows, 0, fn r, acc -> acc + (r.mrr_cents || 0) end)
        {:ok, %{total_cents: total, by_tier: by_tier}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Cross-tenant support-queue depth by status. Returns `{:ok, [%{status, depth}]}` —
  read ONLY through the token-blind aggregate domain.
  """
  @spec queue_depths() :: {:ok, [map()]} | {:error, term()}
  def queue_depths do
    case Samen.Aggregate.read_all(TicketQueueDepth) do
      {:ok, rows} ->
        {:ok, Enum.map(rows, fn r -> %{status: r.status, depth: r.depth} end)}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
