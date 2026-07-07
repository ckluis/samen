defmodule Samen.Aggregate.Actor do
  @moduledoc """
  The **token-blind aggregate actor** (T4.2 clause (a); doc §control "Two planes,
  two operator paths").

  > Cross-tenant views (MRR, queues) run on a separate token-blind actor whose
  > resources have no pii_ columns at all. The two paths are mutually exclusive.

  > Cross-tenant work runs token-blind — an aggregate actor with **no org_id**
  > reading a vault-excluded projection where pii_ columns physically don't exist.
  > Seeing one tenant's world is the separate, single-org impersonation path,
  > masked by default. They are mutually exclusive.

  ## Structurally token-blind (not "masked by policy")

  This is a NAMED, SINGLETON actor — there is exactly one aggregate principal
  (`operator_aggregate`), minted by `Samen.Aggregate.Actor.new/0`. It carries:

    * `:id`   — the fixed principal id `"operator_aggregate"` (bounded, never PII).
    * `:kind` — always `:operator_aggregate` (marks the plane; the tenant plane
      never sets this, the impersonation plane sets `:operator`, so a policy /
      the reveal seam can tell them apart).

  It has **NO `org_id`**. This is not an accident to be masked over — it is the
  structural token-blindness the doc stakes:

    * On the **tenant plane**, `Samen.Policy.OrgScope` reads `actor.org_id`; a
      `nil` org_id filters to `expr(false)` → ZERO rows. So the aggregate actor is
      refused by every tenant-plane resource by construction — it can never read a
      single tenant row (T4.2 red path: aggregate actor reading a tenant-plane
      resource denies).
    * On the **reveal path**, `Samen.Reveal.reveal/5` refuses this actor
      structurally — an `:operator_aggregate` actor can NEVER cross the reveal seam
      (T4.2 mutual-exclusion: aggregate ⟂ reveal). Even a live grant does not help;
      the two operator paths are mutually exclusive by principal class.

  The aggregate actor's ONLY reachable surface is the default-deny aggregate domain
  (`Samen.Policy.AggregateActorOnly` admits it and nothing else), whose resources
  project only vault-excluded, non-PII rollup columns — enforced at COMPILE time by
  `Samen.Verifiers.NoPiiColumns` (C7).

  ## Why a distinct principal class (not "an operator with no grant")

  Masked impersonation (T4.1) is a DIFFERENT operator with a target `org_id` and a
  `••••`-by-default posture. That actor CAN cross the reveal seam (with a
  second-party grant). The aggregate actor cannot — it is a different job (structure
  / aggregates across ALL tenants) with a different, weaker principal that can NEVER
  see a subject. Making it a distinct type is what makes "mutually exclusive"
  structural rather than a convention.
  """

  @principal_id "operator_aggregate"

  @enforce_keys [:id]
  defstruct id: @principal_id, kind: :operator_aggregate

  @type t :: %__MODULE__{id: String.t(), kind: :operator_aggregate}

  @doc """
  The fixed principal id for the singleton aggregate actor.
  """
  @spec principal_id() :: String.t()
  def principal_id, do: @principal_id

  @doc """
  Mint the singleton token-blind aggregate actor. There is exactly one aggregate
  principal — it takes no arguments and carries no org_id, no name, no PII.
  """
  @spec new() :: t()
  def new, do: %__MODULE__{id: @principal_id, kind: :operator_aggregate}

  @doc """
  Is this value the token-blind aggregate actor? Matches the struct OR any map
  carrying `kind: :operator_aggregate` (so a policy / the reveal seam recognises it
  even if a caller passes a plain actor map).
  """
  @spec aggregate?(term()) :: boolean()
  def aggregate?(%__MODULE__{}), do: true
  def aggregate?(%{kind: :operator_aggregate}), do: true
  def aggregate?(_), do: false
end
