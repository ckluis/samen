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
  """

  alias Samen.Aggregate.Actor

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
  """
  @spec read_all(module(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def read_all(resource, opts \\ []) when is_atom(resource) do
    if Samen.Aggregate.Info.aggregate_plane?(resource) do
      actor = Keyword.get(opts, :actor, Actor.new())
      query = Keyword.get(opts, :query, resource)

      case Ash.read(query, actor: actor, authorize?: true) do
        {:ok, rows} -> {:ok, rows}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :not_aggregate_resource}
    end
  end

  @doc """
  Read an aggregate-plane resource and reduce its rows to a single aggregate value
  via `reducer` (e.g. sum the `mrr_cents` column for total cross-tenant MRR).

  Convenience over `read_all/2` for the dashboard's common "one number" case.
  Returns `{:ok, value}` or `{:error, reason}`.
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
