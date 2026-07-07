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

  ## T4.5 privacy floors are applied by the read path, not here

  Both views read through `Samen.Aggregate.read_all/2`, which enforces the k-anonymity
  and l-diversity floors before returning rows: a tier whose `tenant_count < k` (a
  count-of-one tier, which would leak one tenant's exact revenue) comes back with
  `mrr_cents` = `%Samen.Aggregate.Suppressed{}`, and a status cohort with `depth < k`
  or `distinct_priorities < l` (homogeneous priorities) comes back with `depth`
  suppressed. The dashboard treats a `%Suppressed{}` cell as withheld — it never sums a
  suppressed value into the cross-tenant total (that would re-leak it), and it surfaces
  the suppression to the operator as `⊘`.
  """

  alias Demo.Aggregate.{MrrByTier, TicketQueueDepth}
  alias Samen.Aggregate.Suppressed

  @doc """
  Cross-tenant MRR. Returns `{:ok, %{total_cents: n, by_tier: [%{tier, tenant_count,
  mrr_cents}], suppressed_tiers: [tier]}}` — read ONLY through the token-blind
  aggregate domain, with the T4.5 k-anonymity floor applied. Never touches a tenant row.

  A tier whose cohort (`tenant_count`) is below `k` has a suppressed `mrr_cents`; that
  tier's revenue is NOT summed into `total_cents` (summing a suppressed value would
  re-leak it) and its tier name is listed in `suppressed_tiers`.
  """
  @spec mrr() :: {:ok, map()} | {:error, term()}
  def mrr do
    case Samen.Aggregate.read_all(MrrByTier) do
      {:ok, rows} ->
        by_tier =
          Enum.map(rows, fn r ->
            %{tier: r.tier, tenant_count: r.tenant_count, mrr_cents: r.mrr_cents}
          end)

        # Sum only NON-suppressed cells — a suppressed tier is withheld, not zeroed.
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

  @doc """
  Cross-tenant support-queue depth by status. Returns `{:ok, [%{status, depth}]}` —
  read ONLY through the token-blind aggregate domain, with the T4.5 k-anonymity +
  l-diversity floors applied. A status cohort that is too small (`depth < k`) or too
  homogeneous in priority (`distinct_priorities < l`) comes back with `depth` =
  `%Samen.Aggregate.Suppressed{}`.
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
