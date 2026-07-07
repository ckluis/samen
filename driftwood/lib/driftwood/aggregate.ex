defmodule Driftwood.Aggregate do
  @moduledoc """
  Driftwood's **token-blind aggregate plane** domain (T5.3 clause (b); T4.2 mounted
  over the freight vertical; doc §control "Cross-tenant views (MRR, queues) run on a
  separate token-blind actor").

  This is the SEPARATE, DEFAULT-DENY Ash domain — the mutually-exclusive path from
  masked impersonation (T4.1 / `Driftwood.OperatorImpersonationLive`, single-org).
  Its only admissible actor is the singleton `Samen.Aggregate.Actor`
  (`operator_aggregate`, no `org_id`) — every resource here carries a
  `policy always() do authorize_if Samen.Policy.AggregateActorOnly end` block
  (default deny; no `authorize_if always()` fallthrough). A tenant / impersonation /
  api_key actor reading this domain is refused.

  ## Cross-tenant projections (vault-excluded, no pii_ columns)

  Its resources project ONLY vault-excluded, non-PII columns from cross-tenant
  rollup/summary tables (freight's version of the demo `rol_*` idea):

    * `Driftwood.Aggregate.LoadVolumeByLane` (`dag_load_volume_by_lane`) — cross-tenant
      LOAD VOLUME rolled up from the freight Load (Opportunity) rows, grouped by
      lane bucket + load status. Columns: lane (bounded enum), tenant_count (int),
      load_count (int), gross_cents (int) — counts and numbers, never a subject.

    * `Driftwood.Aggregate.MrrByTier` (`dtq_mrr_by_tier`) — cross-tenant brokerage MRR
      by plan tier rolled up from a per-tenant subscription-tier column carried on the
      Company (Carrier) custom bag. Columns: tier (bounded enum), tenant_count (int),
      mrr_cents (int) — a count and a number, never a subject.

  These are the doc's two examples on the freight shape: "cross-tenant load volume /
  MRR with NO PII". Both are `use Samen.Aggregate.Resource`, so the C7 `NoPiiColumns`
  verifier FAILS the build if either declares a `pii_attribute`, a vault, a
  `pii_`-shaped column, or a relationship reaching a PII-bearing resource. Their
  physical tables contain no `pii_` columns (asserted via `information_schema` in the
  T5.3 tests + the whole-app `mix samen.verify.no_pii_columns` backstop).

  ## Reads go through `Samen.Aggregate`

  The operator cross-tenant dashboard (`Driftwood.OperatorDashboard`) reads ONLY
  through `Samen.Aggregate.read_all/2` / `read/3` with the aggregate actor. The
  aggregate actor can never cross the reveal seam (`Samen.Reveal` refuses it) and can
  never read a tenant-plane resource (org-less → OrgScope filters to zero rows) — the
  same structural guarantee the demo proved (T4.2), re-proved on the freight vertical.
  """
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(Driftwood.Aggregate.LoadVolumeByLane)
    resource(Driftwood.Aggregate.MrrByTier)
  end
end

defmodule Driftwood.Aggregate.LoadVolumeByLane do
  @moduledoc """
  Cross-tenant LOAD VOLUME by lane (T5.3 clause (b): "cross-tenant load volume"). A
  `use Samen.Aggregate.Resource` projection over the vault-excluded
  `dag_load_volume_by_lane` summary table.

  Every column is bounded / non-PII: `lane` (a coarse origin→destination region
  bucket, NOT a precise address — a bounded string), `tenant_count` (a count),
  `load_count` (a count), `gross_cents` (a number). NO `pii_attribute`, NO vault, NO
  relationship to a PII-bearing resource — the C7 verifier enforces this at compile
  time. Cross-tenant (no org boundary): the volume spans all brokerages.
  """
  use Samen.Aggregate.Resource,
    otp_app: :driftwood,
    domain: Driftwood.Aggregate,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "dag"

  postgres do
    table("dag_load_volume_by_lane")
    repo(Driftwood.Repo)
  end

  attributes do
    # Cross-tenant aggregate: NO single org. Declare org_id ourselves as nullable to
    # opt out of the universal non-null org_id injection — a per-lane volume spans ALL
    # brokerages, so its `dag_org_id` stays NULL (the ACTOR has no org_id).
    attribute(:org_id, :uuid, public?: true, allow_nil?: true)
    # The lane bucket (a coarse region pair, e.g. "TX->CA"). The COHORT key. Non-PII.
    attribute(:lane, :string, public?: true, allow_nil?: false)
    # Number of distinct brokerage tenants with loads on this lane (the cohort SIZE —
    # k-anonymity). Non-PII (a count).
    attribute(:tenant_count, :integer, public?: true, default: 0)
    # Number of loads on this lane across all tenants (a count). Non-PII.
    attribute(:load_count, :integer, public?: true, default: 0)
    # Total gross value cents of loads on this lane across all tenants (a number). Non-PII.
    attribute(:gross_cents, :integer, public?: true, default: 0)
    attribute(:refreshed_at, :utc_datetime, public?: true)
  end

  actions do
    # Read-only projection (aggregate resources are never written by the operator —
    # they are rebuilt from the tenant-plane rollups).
    defaults([:read])
  end

  # DEFAULT DENY. Only the token-blind aggregate actor is admitted (T4.2 / T5.3). There
  # is NO `authorize_if always()` — a non-aggregate actor is refused.
  policies do
    policy always() do
      authorize_if(Samen.Policy.AggregateActorOnly)
    end
  end

  @doc """
  The T4.5 cohort spec: the lane cohort's SIZE (for k-anonymity) is `tenant_count` —
  how many distinct brokerages have loads on this lane. The RELEASABLE values
  (`load_count`, `gross_cents`) are suppressed when `tenant_count < k` (including a
  count-of-one lane, which would let an operator read one brokerage's exact volume on
  that lane).
  """
  def aggregate_cohort_spec do
    %Samen.Aggregate.CohortSpec{
      cohort_key_columns: [:lane],
      cohort_count_column: :tenant_count,
      distinct_sensitive_column: nil,
      value_columns: [:load_count, :gross_cents],
      sensitive_attribute: nil
    }
  end
end

defmodule Driftwood.Aggregate.MrrByTier do
  @moduledoc """
  Cross-tenant brokerage MRR by plan tier (T5.3 clause (b): "cross-tenant … MRR"). A
  `use Samen.Aggregate.Resource` projection over the vault-excluded `dtq_mrr_by_tier`
  summary table.

  Every column is bounded / non-PII: `tier` (a plan-name enum), `tenant_count` (a
  count), `mrr_cents` (a number). NO `pii_attribute`, NO vault, NO relationship to a
  PII-bearing resource — the C7 verifier enforces this at compile time. Cross-tenant
  (no org boundary): a per-tier MRR total spans every brokerage tenant.
  """
  use Samen.Aggregate.Resource,
    otp_app: :driftwood,
    domain: Driftwood.Aggregate,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "dtq"

  postgres do
    table("dtq_mrr_by_tier")
    repo(Driftwood.Repo)
  end

  attributes do
    attribute(:org_id, :uuid, public?: true, allow_nil?: true)
    # The brokerage plan tier (bounded — a small set of plan names). Non-PII.
    attribute(:tier, :string, public?: true, allow_nil?: false)
    # Number of tenants on this tier (a count — the cohort SIZE for k-anon). Non-PII.
    attribute(:tenant_count, :integer, public?: true, default: 0)
    # MRR in cents for this tier across all brokerages (a number). Non-PII.
    attribute(:mrr_cents, :integer, public?: true, default: 0)
    attribute(:refreshed_at, :utc_datetime, public?: true)
  end

  actions do
    defaults([:read])
  end

  policies do
    policy always() do
      authorize_if(Samen.Policy.AggregateActorOnly)
    end
  end

  @doc """
  The T4.5 cohort spec: MRR-by-tier's cohort is the plan `tier`; the cohort SIZE (for
  k-anonymity) is `tenant_count`. The RELEASABLE value `mrr_cents` is suppressed when
  `tenant_count < k` (including a count-of-one tier, which would let an operator read
  one tenant's exact revenue).
  """
  def aggregate_cohort_spec do
    %Samen.Aggregate.CohortSpec{
      cohort_key_columns: [:tier],
      cohort_count_column: :tenant_count,
      distinct_sensitive_column: nil,
      value_columns: [:mrr_cents],
      sensitive_attribute: nil
    }
  end
end
