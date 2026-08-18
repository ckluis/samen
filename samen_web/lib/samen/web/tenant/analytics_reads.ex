defmodule Samen.Web.Tenant.AnalyticsReads do
  @moduledoc """
  P17 (ADR-045 §3) — the TENANT-plane, **own-org** analytics read layer: a tenant sees
  aggregate insight over its OWN org's activity ("how many of my people reached each
  activation stage") WITHOUT any surface exposing an individual subject. This is the
  intra-org, org-SCOPED twin of the cross-tenant operator analytics
  (`Samen.Web.Operator.AnalyticsReads`, T144 operator-only) — a SEPARATE org-scoped path,
  NOT a relaxation of T144.

  ## The org boundary + the floor — the two load-bearing invariants

    1. **Org-scoped, from the AUTHENTICATED scope (never user input).** Every read binds
       `paf_org_id = $1` where `$1` is the org id off the caller's own authenticated
       `%Samen.Scope{}` (`scope.actor.org_id`), resolved by `Samen.Web.CurrentOrg`. There
       is no `?org=` affordance and no cohort spans orgs — cross-org is impossible by
       construction, the tenant-plane isolation the whole foundry rests on.

    2. **The shipped k-anonymity floor, REUSED not reimplemented.** Every released cell
       passes through `Samen.Aggregate.Privacy.apply/3` (T4.5, config default k=5) with an
       explicit `%Samen.Aggregate.CohortSpec{}` — the SAME floor module + sentinel the
       cross-tenant plane and `Samen.Aggregate.read_all_for_org/3` use. A stage reached by
       fewer than `k` of the org's OWN subjects has its actor count REPLACED by
       `%Samen.Aggregate.Suppressed{}` (renders `⊘`, carries no value). This is the intra-
       org enforcement of the two-plane masking rule projected onto the OUTPUT plane:
       within an org, k-anonymity stops a lower-privilege, `••••`-masked role from
       reconstructing a count-of-one subject's activity by enumerating the cohort key.

  ## Covert-channel discipline (what this surface will NOT emit)

  Only aggregates the floor can prove safe: a per-stage distinct-actor COUNT, floored.
  NEVER a count-of-one (re-identifies), NEVER a min/max/sample-row (leaks a raw value),
  NEVER a raw value below the floor. A sub-floor cohort is SUPPRESSED (`⊘`), never emitted
  — fail closed. There is no un-suppress affordance.

  ## Masking / PII posture

  Token-blind by construction: it reads the `paf_product_event_rollup` (the same rollup
  the operator analytics stands on), whose every column is a bounded stage label, a week
  bucket, or a count — no `pii_` column exists there (AC-G12-3), so there is NOTHING to
  mask and no `Samen.Vault` / `PiiResolution` call, ever. Erasure-safe by construction:
  the read is LIVE-COMPUTED at query time over the current rollup (no NEW precomputed
  store, ADR-046) — an erased subject whose rollup contribution is gone contributes 0 to a
  fresh read; there is no ungoverned analytics store to resurrect them from.

  ## Role gate (P17 Q3)

  Analytics is available to the org's admins AND its lower-privilege members
  (`queryable_roles/0` — the DELIBERATE choice that a masked `:member` gets floored
  insight-without-PII). A caller with no org membership (no `org_id`) is refused —
  `can_query?/1` fail-closes.
  """

  alias Samen.Aggregate.{CohortSpec, Privacy, Suppressed}

  # The org-partitioned rollup (identical name in every host DB — the operator precedent).
  @rollup_table "paf_product_event_rollup"

  # The activation stages, in funnel order (bounded catalog — the B8 rollup grain).
  @funnel_stages ~w(signup first_run first_record)
  @funnel_row_limit 10

  # The org funnel cohort: the org's subjects who reached each stage; the releasable value
  # is that same distinct-actor count. A stage below the floor suppresses wholesale.
  @funnel_spec %CohortSpec{
    cohort_key_columns: [:stage],
    cohort_count_column: :actor_count,
    value_columns: [:actor_count]
  }

  @queryable_roles [:admin, :member]

  @doc "The tenant roles that may query own-org analytics (P17 Q3)."
  @spec queryable_roles() :: [atom()]
  def queryable_roles, do: @queryable_roles

  @doc """
  May this authenticated scope query own-org analytics? Fail-closed: requires a resolved
  org membership (`scope.actor.org_id`) AND a role in `queryable_roles/0`. An org-less /
  role-less caller is refused.
  """
  @spec can_query?(Samen.Scope.t() | map() | nil) :: boolean()
  def can_query?(%Samen.Scope{actor: actor}), do: can_query?(actor)

  def can_query?(%{org_id: org_id, role: role})
      when is_binary(org_id) and role in @queryable_roles,
      do: true

  def can_query?(_), do: false

  @doc """
  The own-org activation funnel, floored:

      [%{stage: "signup", actor_count: n | %Suppressed{}}, ...]

  `scope` is the caller's AUTHENTICATED tenant scope — the org id is taken from it, never
  from a param. Returns `[]` when the caller may not query (fail closed), the mount is
  absent, or on any read error (never partial garbage). `opts` may override `:k` / `:l`
  (tests use this to prove the floor is load-bearing; production reads config).
  """
  @spec funnel(Samen.Web.Mount.t() | nil, Samen.Scope.t(), keyword()) :: [map()]
  def funnel(mount, scope, opts \\ [])

  def funnel(%Samen.Web.Mount{repo: repo}, %Samen.Scope{actor: actor} = scope, opts) do
    org_id = org_id(actor)

    if can_query?(scope) and is_binary(org_id) do
      floored_funnel(repo, org_id, opts)
    else
      []
    end
  rescue
    _ -> []
  end

  def funnel(_, _scope, _opts), do: []

  @doc "How many funnel stages arrived `%Suppressed{}` (feeds the suppression note)."
  def suppressed_count(funnel) when is_list(funnel),
    do: Enum.count(funnel, &Suppressed.suppressed?(&1.actor_count))

  # -- the org-scoped, floored read --------------------------------------------------

  defp floored_funnel(repo, org_id, opts) do
    sql = """
    SELECT paf_stage, COALESCE(SUM(paf_actor_count), 0)::int AS actor_count
    FROM #{@rollup_table}
    WHERE paf_kind = 'funnel' AND paf_suppressed = FALSE
      AND paf_org_id = $1 AND paf_stage IS NOT NULL
    GROUP BY paf_stage
    LIMIT #{@funnel_row_limit}
    """

    case Ecto.Adapters.SQL.query(repo, sql, [org_uuid!(org_id)]) do
      {:ok, %{rows: []}} ->
        []

      {:ok, %{rows: rows}} ->
        by_stage =
          Map.new(rows, fn [stage, actor_count] ->
            {stage, %{stage: stage, actor_count: actor_count}}
          end)

        # All stages in funnel order; an unreached stage is a 0-actor cohort, which the
        # floor then fail-closes (a cohort of 0 cannot prove >= k → suppressed).
        stage_rows =
          Enum.map(@funnel_stages, fn stage ->
            Map.get(by_stage, stage, %{stage: stage, actor_count: 0})
          end)

        {:ok, floored} = Privacy.apply(stage_rows, @funnel_spec, Keyword.take(opts, [:k, :l]))
        floored

      _ ->
        []
    end
  end

  defp org_id(actor) when is_map(actor), do: Map.get(actor, :org_id)
  defp org_id(_), do: nil

  # Bind org_id as a real uuid parameter (never string-interpolated into SQL).
  defp org_uuid!(org_id) when is_binary(org_id), do: Ecto.UUID.dump!(org_id)
end
