defmodule Demo.Aggregate do
  @moduledoc """
  The demo's **token-blind aggregate plane** domain (T4.2; doc §control "Two planes,
  two operator paths").

  This is a SEPARATE, DEFAULT-DENY Ash domain. Its only admissible actor is the
  singleton `Samen.Aggregate.Actor` (`operator_aggregate`, no `org_id`) — every
  resource here carries a `policy always() do authorize_if
  Samen.Policy.AggregateActorOnly end` block (default deny; no `authorize_if
  always()` fallthrough). A tenant / impersonation / api_key actor reading this
  domain is refused.

  ## Cross-tenant projections (vault-excluded, no pii_ columns)

  Its resources project ONLY vault-excluded, non-PII columns from cross-tenant
  rollup/summary tables (`rol_*`):

    * `Demo.Aggregate.MrrByTier` (`rol_mrr_by_tier`) — cross-tenant MRR (Monthly
      Recurring Revenue) rolled up from the Billing subscription/plan rows, grouped
      by plan tier. Columns: tier (bounded enum), tenant_count (int), mrr_cents
      (int) — a count and a number, never a subject.

    * `Demo.Aggregate.TicketQueueDepth` (`rol_ticket_queue_depth`) — cross-tenant
      support-queue depths rolled up from the Support ticket rows, grouped by
      status. Columns: status (bounded enum), depth (int) — a count, never a
      subject.

  These are the two doc examples: "Cross-tenant views (MRR, queues)". Both are
  `use Samen.Aggregate.Resource`, so the C7 `NoPiiColumns` verifier FAILS the build
  if either declares a `pii_attribute`, a vault, a `pii_`-shaped column, or a
  relationship reaching a PII-bearing resource. Their physical tables contain no
  `pii_` columns (asserted via `information_schema` in the T4.2 tests + the
  whole-app `mix samen.verify.no_pii_columns` backstop).

  ## Reads go through `Samen.Aggregate`

  Operator cross-tenant dashboards read ONLY through `Samen.Aggregate.read_all/2` /
  `read/3` with the aggregate actor — the mutually-exclusive path from masked
  impersonation (single-org, T4.1). The aggregate actor can never cross the reveal
  seam (`Samen.Reveal` refuses it) and can never read a tenant-plane resource
  (org-less → OrgScope filters to zero rows).
  """
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(Demo.Aggregate.MrrByTier)
    resource(Demo.Aggregate.TicketQueueDepth)
  end
end

defmodule Demo.Aggregate.MrrByTier do
  @moduledoc """
  Cross-tenant MRR by plan tier (T4.2 clause (a)+(c)). A `use
  Samen.Aggregate.Resource` projection over the vault-excluded `rol_mrr_by_tier`
  summary table.

  Every column is bounded / non-PII: `tier` (a plan-name enum), `tenant_count` (a
  count), `mrr_cents` (a number). NO `pii_attribute`, NO vault, NO relationship to a
  PII-bearing resource — the C7 verifier enforces this at compile time.

  It has NO `org_id` filter in the read policy: it spans ALL tenants (that is the
  whole point of the cross-tenant aggregate). The `Samen.Aggregate.MrrByTier` table
  is keyed by `tier`, one row per tier, aggregated across every org — a subject is
  not reconstructible from a per-tier MRR total (the k-anon / l-diversity floors are
  T4.5).
  """
  use Samen.Aggregate.Resource,
    otp_app: :demo,
    domain: Demo.Aggregate,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "amr"

  postgres do
    table("amr_mrr_by_tier")
    repo(Demo.Repo)
  end

  attributes do
    # Cross-tenant aggregate: NO single org. Declare org_id ourselves as nullable to
    # opt out of the universal non-null org_id injection — a per-tier MRR total spans
    # ALL tenants, so its `amr_org_id` column stays NULL (the ACTOR has no org_id per
    # the doc; the projection is cross-tenant by design).
    attribute(:org_id, :uuid, public?: true, allow_nil?: true)
    # The plan tier (bounded — a small set of plan names). Non-PII.
    attribute(:tier, :string, public?: true, allow_nil?: false)
    # Number of tenants on this tier (a count). Non-PII.
    attribute(:tenant_count, :integer, public?: true, default: 0)
    # MRR in cents for this tier across all tenants (a number). Non-PII.
    attribute(:mrr_cents, :integer, public?: true, default: 0)
    attribute(:refreshed_at, :utc_datetime, public?: true)
  end

  actions do
    # Read-only projection (aggregate resources are never written by the operator —
    # they are rebuilt from the tenant-plane rollups).
    defaults([:read])
  end

  # DEFAULT DENY. Only the token-blind aggregate actor is admitted (T4.2). There is
  # NO `authorize_if always()` — a non-aggregate actor is refused (Ash policies
  # default to forbid when no authorize_if matches).
  policies do
    policy always() do
      authorize_if(Samen.Policy.AggregateActorOnly)
    end
  end

  @doc """
  The T4.5 cohort spec: MRR-by-tier's cohort is the plan `tier`; the cohort SIZE
  (for k-anonymity) is `tenant_count` — how many tenants are on this tier. The
  RELEASABLE VALUE `mrr_cents` is suppressed when `tenant_count < k` (including a
  count-of-one tier, which would let an operator read one tenant's exact revenue).
  No l-diversity dimension here (MRR is a single sum per tier — the sensitive
  dimension is proved on `TicketQueueDepth` via ticket priority).
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

defmodule Demo.Aggregate.TicketQueueDepth do
  @moduledoc """
  Cross-tenant support-queue depths by status (T4.2 clause (a)+(c)). A `use
  Samen.Aggregate.Resource` projection over the vault-excluded
  `rol_ticket_queue_depth` summary table.

  Every column is bounded / non-PII: `status` (a ticket-status enum), `depth` (a
  count). NO PII, NO vault, NO relationship to a PII-bearing resource. Cross-tenant
  (no org boundary): the queue depth spans all tenants.
  """
  use Samen.Aggregate.Resource,
    otp_app: :demo,
    domain: Demo.Aggregate,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "atq"

  postgres do
    table("atq_ticket_queue_depth")
    repo(Demo.Repo)
  end

  attributes do
    # Cross-tenant aggregate: NO single org (nullable, opt out of non-null injection).
    attribute(:org_id, :uuid, public?: true, allow_nil?: true)
    # Ticket status (bounded enum) — the COHORT key. Non-PII.
    attribute(:status, :string, public?: true, allow_nil?: false)
    # Number of tickets in this status across all tenants (the cohort SIZE — k-anon). Non-PII.
    attribute(:depth, :integer, public?: true, default: 0)
    # Count of DISTINCT ticket PRIORITIES within this status cohort (the l-diversity
    # distinct-sensitive count). A status where every ticket shares one priority
    # (distinct_priorities == 1) is a homogeneous cohort and suppresses. Non-PII (a count).
    attribute(:distinct_priorities, :integer, public?: true, default: 0)
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
  The T4.5 cohort spec with a REAL sensitive dimension (T4.5 clause (b)). The cohort
  is ticket `status`; the cohort SIZE (k-anonymity) is `depth`; the SENSITIVE
  ATTRIBUTE is ticket **priority** (the doc's "e.g. plan tier or ticket category"
  example), whose distinct-value count per cohort is `distinct_priorities`. A status
  cohort with `depth < k` suppresses (k-anon); a status cohort with
  `distinct_priorities < l` — every ticket in that status sharing one priority —
  suppresses (l-diversity homogeneity). The RELEASABLE VALUE `depth` is what
  suppression replaces.
  """
  def aggregate_cohort_spec do
    %Samen.Aggregate.CohortSpec{
      cohort_key_columns: [:status],
      cohort_count_column: :depth,
      distinct_sensitive_column: :distinct_priorities,
      value_columns: [:depth],
      sensitive_attribute: :ticket_priority
    }
  end
end
