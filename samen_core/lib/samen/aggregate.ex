defmodule Samen.Aggregate do
  @moduledoc """
  The **token-blind aggregate plane** runtime (T4.2; doc §control "Two planes, two
  operator paths").

  > Cross-tenant views (MRR, queues) run on a separate token-blind actor whose
  > resources have no pii_ columns at all. The two paths are mutually exclusive.

  This is the SEPARATE operator path from masked impersonation (T4.1). Where
  impersonation reaches ONE tenant org's real rows (masked by default), the
  aggregate plane runs CROSS-TENANT and token-blind: the `operator_aggregate` actor
  (`Samen.Aggregate.Actor`, no `org_id`) reads a **vault-excluded projection** — the
  `rol_*`/summary tables where `pii_` columns physically don't exist.

  ## What this module does

    1. `read/2` — read an aggregate-plane resource with the singleton aggregate
       actor. The resource's default-deny policy (`Samen.Policy.AggregateActorOnly`)
       admits ONLY that actor; the read carries no org boundary because there is no
       org — it spans all tenants. Because the resource is a `use
       Samen.Aggregate.Resource` (C7-verified) projection over a `rol_*` table, no
       PII is reachable.

    2. **Mutual exclusion, both directions** — `Samen.Aggregate` is deliberately the
       ONLY surface the aggregate actor can use:

         * `Samen.Reveal.reveal/5` refuses an `:operator_aggregate` actor
           structurally (aggregate ⟂ reveal — T4.2), so the aggregate actor can
           never cross the reveal seam.
         * `Samen.Policy.OrgScope` filters an org-less actor to ZERO rows, so the
           aggregate actor can never read a tenant-plane resource.
         * `Samen.Policy.AggregateActorOnly` refuses every non-aggregate actor, so a
           tenant / impersonation / api_key actor can never read the aggregate plane.

  ## Cross-tenant MRR / queue-depth reads

  Operator dashboards call `Samen.Aggregate.read/2` (or `read_all/2`) to get
  cross-tenant MRR (from Billing rollups) and support-queue depths (from the T2.3
  event rollups). Those are the two doc examples: "Cross-tenant views (MRR, queues)".
  Each reads a bounded projection (tier / count / cents) — never a subject.

  ## Aggregate-privacy floors + query-budget ledger (T4.5)

  `read_all/2` is the ONLY read surface the token-blind aggregate actor can use, so it
  is where the **output-privacy floors** are enforced and where the **query-budget
  ledger** accounts every read — you cannot read a raw, unsuppressed aggregate value
  "as the aggregate actor" through the domain, because this chokepoint routes every row
  set through the floors before returning it:

    1. **Query-budget accounting (scaffold)** — every returned cohort is recorded in
       `Samen.Aggregate.QueryBudget`, keyed by cohort (NOT by actor). WARN-not-enforce
       (T4.5 clause (c)). Recording is best-effort — a ledger failure never fails a read
       (the floors, not the budget, are the enforced defence).

    2. **k-anonymity + l-diversity floors (ENFORCED)** — the row set passes through
       `Samen.Aggregate.Privacy.apply/3` using the resource's `aggregate_cohort_spec/0`
       (`Samen.Aggregate.CohortSpec`). Any cell whose cohort count is `< k`
       (count-of-one included) or whose distinct-sensitive count is `< l` (a homogeneous
       cohort) has its value REPLACED by `%Samen.Aggregate.Suppressed{}` (T4.5 clauses
       (a)+(b)). Fail closed: a resource with NO cohort spec returns
       `{:error, :no_cohort_spec}` — an aggregate cell whose cohort size cannot be
       established is not released.

  A caller can pass `suppress: false` ONLY on internal control paths (the ledger rebuild
  reads its own raw rows) — the operator dashboard NEVER does; suppression is the default
  and the demo dashboard depends on it.
  """

  alias Samen.Aggregate.{Actor, CohortSpec, Privacy, QueryBudget}

  @doc """
  Read every row of an aggregate-plane resource with the singleton token-blind
  aggregate actor. Returns `{:ok, rows}` or `{:error, reason}`.

  The read is authorized (`authorize?: true`) against the resource's default-deny
  policy — so this only succeeds because the actor IS the aggregate actor. A read
  attempted with any other actor (or actor-less) returns zero rows / forbidden.

  Refuses (`{:error, :not_aggregate_resource}`) if the resource did not opt into the
  aggregate plane (`use Samen.Aggregate.Resource`) — fail closed: you cannot read a
  tenant-plane resource "as the aggregate actor" through here.

  Options:
    * `:actor` — override the actor (tests use this to prove a NON-aggregate actor is
      refused). Defaults to `Samen.Aggregate.Actor.new/0`.
    * `:query` — a preset `Ash.Query` (e.g. a filter/sort over bounded columns).
    * `:suppress` — apply the k-anon / l-diversity floors (T4.5). Defaults to `true`
      (the enforced default; the operator dashboard relies on it). `false` is an
      internal control-path escape for callers that read their own raw rows (the ledger
      rebuild) — it does NOT route through the domain's operator-facing path.
    * `:account` — record the read in the query-budget ledger (T4.5 clause (c)).
      Defaults to `true`. `false` suppresses accounting for internal/no-op reads.
    * `:k` / `:l` — override the floors (tests use this; production reads config).
  """
  @spec read_all(module(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def read_all(resource, opts \\ []) when is_atom(resource) do
    if Samen.Aggregate.Info.aggregate_plane?(resource) do
      actor = Keyword.get(opts, :actor, Actor.new())
      query = Keyword.get(opts, :query, resource)

      case Ash.read(query, actor: actor, authorize?: true) do
        {:ok, rows} ->
          # The read passed the default-deny policy (so the actor IS the aggregate
          # actor). Now route the rows through the T4.5 output-privacy pipeline:
          # account every cohort (scaffold, per-cohort, never denies), then enforce the
          # k-anon / l-diversity floors. Both keyed off the resource's cohort spec.
          spec = CohortSpec.spec_for(resource)

          if Keyword.get(opts, :account, true), do: account_reads(resource, rows, spec, actor)

          if Keyword.get(opts, :suppress, true) do
            Privacy.apply(rows, spec, Keyword.take(opts, [:k, :l]))
          else
            {:ok, rows}
          end

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :not_aggregate_resource}
    end
  end

  # Account each returned cohort in the query-budget ledger, keyed by COHORT (not actor).
  # Best-effort (QueryBudget.record/1 never raises the caller) — the ledger is a scaffold,
  # the floors are the enforced defence. A nil cohort spec means no cohort key to account,
  # so accounting is skipped (the floors still fail-close the read downstream).
  defp account_reads(_resource, _rows, nil, _actor), do: :ok

  defp account_reads(resource, rows, %CohortSpec{} = spec, actor) do
    actor_id = actor_id(actor)

    Enum.each(rows, fn row ->
      QueryBudget.record(%{
        resource: resource,
        cohort_key: cohort_key(row, spec),
        cell_count: 1,
        actor_id: actor_id
      })
    end)

    :ok
  end

  # Build the cohort key string from the spec's cohort_key_columns, e.g. "tier=Pro".
  # This is the accounting granularity — the cohort being queried.
  defp cohort_key(row, %CohortSpec{cohort_key_columns: cols}) do
    cols
    |> Enum.map(fn col ->
      value = Map.get(row, col) || Map.get(row, to_string(col))
      "#{col}=#{value}"
    end)
    |> Enum.join("&")
  end

  defp actor_id(%{id: id}) when is_binary(id), do: id
  defp actor_id(_), do: "unknown"

  @doc """
  Read an aggregate-plane resource and reduce its rows to a single aggregate value
  via `reducer` (e.g. sum the `mrr_cents` column for total cross-tenant MRR).

  Convenience over `read_all/2` for the dashboard's common "one number" case.
  Returns `{:ok, value}` or `{:error, reason}`.

  Rows are suppressed by the T4.5 floors before the reduce (via `read_all/2`), so the
  reducer only sees released rows. A row whose `value_columns` were suppressed carries
  a `%Samen.Aggregate.Suppressed{}` in place of the value — the reducer must handle it
  (or return a non-number). This helper does NOT auto-skip suppressed rows because it
  cannot know which of the row's fields the reducer reads; callers that sum a single
  value column should guard with `Samen.Aggregate.Suppressed.suppressed?/1` (the demo
  `OperatorDashboard.mrr/0` shows the pattern — a suppressed cell is withheld from the
  total, never zeroed or summed).
  """
  @spec read(module(), (map() -> number()), keyword()) :: {:ok, number()} | {:error, term()}
  def read(resource, reducer, opts \\ []) when is_atom(resource) and is_function(reducer, 1) do
    case read_all(resource, opts) do
      {:ok, rows} -> {:ok, Enum.reduce(rows, 0, fn row, acc -> acc + reducer.(row) end)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The singleton token-blind aggregate actor. Sugar over
  `Samen.Aggregate.Actor.new/0` so callers don't reach into the Actor module.
  """
  @spec actor() :: Actor.t()
  def actor, do: Actor.new()
end
