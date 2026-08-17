defmodule SamenCore.Support.OrgAnalyticsFixture.Domain do
  @moduledoc """
  Test-support domain for the P17 org-scoped aggregate fixtures (ADR-045 §3). NOT
  registered in `:ash_domains` — the org-scoped read tests + the verifier org-scoped arm
  reference the resources by module directly (via `Samen.Aggregate.read_all_for_org/3` and
  `Mix.Tasks.Samen.Verify.AggregatePrivacy.violations_for/1`), so whole-app discovery is
  not needed and the fixtures stay off the cross-app verifier fleet.
  """
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(SamenCore.Support.OrgAnalyticsFixture.Metric)
  end
end

defmodule SamenCore.Support.OrgAnalyticsFixture.Metric do
  @moduledoc """
  A valid P17 **org-scoped** aggregate-plane projection (ADR-045 §3): a
  `use Samen.Aggregate.Resource` (C7 `NoPiiColumns`-refused) projection carrying a
  NON-NULL `org_id` partition (inherited from the universal injection — NOT opted out),
  guarded by `Samen.Policy.OrgScope`, read by the tenant's own org actor via
  `Samen.Aggregate.read_all_for_org/3`.

  Cohort = subjects in THIS org sharing `kind`; the cohort SIZE (k-anonymity) is
  `subject_count`; the RELEASABLE VALUE `metric` is suppressed by the shipped floor when
  `subject_count < k` (count-of-one included). Every column is a bounded enum / count —
  no vault, no `pii_` column (the C7 verifier enforces this at compile time). Read-only
  projection (`defaults [:read]`); rows are seeded by tests via raw SQL, never a
  tenant-facing write.
  """
  use Samen.Aggregate.Resource,
    otp_app: :samen_core,
    domain: SamenCore.Support.OrgAnalyticsFixture.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "oea"

  postgres do
    table("oea_org_metric")
    repo(SamenCore.TestRepo)
  end

  attributes do
    # org_id is injected NON-NULL by the universal columns (we do NOT opt out) — the real
    # org partition the org-scoped arm requires. kind/subject_count/metric are bounded.
    attribute(:kind, :string, public?: true, allow_nil?: false)
    attribute(:subject_count, :integer, public?: true, default: 0)
    attribute(:metric, :integer, public?: true, default: 0)
  end

  actions do
    defaults([:read])
  end

  # Org-scoped: only the tenant's own org actor may read, filtered to its own org
  # (Samen.Policy.OrgScope is a FilterCheck — foreign-org rows are INVISIBLE, not merely
  # forbidden). This is the tenant-plane isolation, NOT the cross-tenant AggregateActorOnly.
  policies do
    policy action_type(:read) do
      authorize_if(Samen.Policy.OrgScope)
    end
  end

  @doc "The T4.5 cohort spec: cohort = `kind`; size = `subject_count`; value = `metric`."
  def aggregate_cohort_spec do
    %Samen.Aggregate.CohortSpec{
      cohort_key_columns: [:kind],
      cohort_count_column: :subject_count,
      value_columns: [:metric]
    }
  end

  @doc "Opt into the P17 org-scoped aggregate plane (ADR-045 §3)."
  def org_scoped_aggregate?, do: true
end

defmodule SamenCore.Support.OrgAnalyticsFixture.CrossTenant do
  @moduledoc """
  A CROSS-tenant aggregate-plane resource (the org-LESS shape: `AggregateActorOnly`
  policy, nullable org_id, NO `org_scoped_aggregate?/0`). Proves the fail-closed guard on
  `Samen.Aggregate.read_all_for_org/3`: you cannot read a cross-tenant projection "as an
  org actor" through the org-scoped path (`{:error, :not_org_scoped_aggregate}`). The two
  planes stay mutually exclusive — the org path admits only org-scoped resources, the
  cross-tenant `read_all/2` path admits only the token-blind `Aggregate.Actor`.
  """
  use Samen.Aggregate.Resource,
    otp_app: :samen_core,
    domain: nil,
    validate_domain_inclusion?: false,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "oec"

  postgres do
    table("oec_cross_tenant")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:org_id, :uuid, public?: true, allow_nil?: true)
    attribute(:tier, :string, public?: true)
    attribute(:tenant_count, :integer, public?: true)
    attribute(:mrr_cents, :integer, public?: true)
  end

  actions do
    defaults([:read])
  end

  policies do
    policy always() do
      authorize_if(Samen.Policy.AggregateActorOnly)
    end
  end

  def aggregate_cohort_spec do
    %Samen.Aggregate.CohortSpec{
      cohort_key_columns: [:tier],
      cohort_count_column: :tenant_count,
      value_columns: [:mrr_cents]
    }
  end

  # NOTE: NO org_scoped_aggregate?/0 — this is the cross-tenant plane.
end

defmodule SamenCore.Support.OrgAnalyticsFixture.NoPartition do
  @moduledoc """
  The org-scoped verifier RED fixture: a resource that CLAIMS the P17 org-scoped plane
  (`org_scoped_aggregate?/0 == true`) but declares a NULLABLE `org_id` — the CROSS-tenant
  (org-less) shape, NOT an org partition. The org-scoped arm of
  `mix samen.verify.aggregate_privacy` MUST flag it: without a non-null org_id partition,
  `OrgScope` cannot narrow a read to one org and a NULL-org row could enter a tenant's
  own-org read. Compile/introspection-only (no table, never read).
  """
  use Samen.Aggregate.Resource,
    otp_app: :samen_core,
    domain: nil,
    validate_domain_inclusion?: false,
    data_layer: AshPostgres.DataLayer,
    abbrev: "oen"

  postgres do
    table("oen_no_partition")
    repo(SamenCore.TestRepo)
  end

  attributes do
    # DELIBERATELY opt out of the non-null org_id injection → nullable org_id = the WRONG
    # (cross-tenant) shape for an org-scoped projection. This is what the verifier flags.
    attribute(:org_id, :uuid, public?: true, allow_nil?: true)
    attribute(:kind, :string, public?: true)
    attribute(:subject_count, :integer, public?: true)
    attribute(:metric, :integer, public?: true)
  end

  actions do
    defaults([:read])
  end

  def aggregate_cohort_spec do
    %Samen.Aggregate.CohortSpec{
      cohort_key_columns: [:kind],
      cohort_count_column: :subject_count,
      value_columns: [:metric]
    }
  end

  def org_scoped_aggregate?, do: true
end
