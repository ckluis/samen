defmodule Samen.Aggregate.CohortSpec do
  @moduledoc """
  Describes, per aggregate-plane resource, **what a cohort is** so the privacy floors
  (`Samen.Aggregate.Privacy`) and the query-budget ledger (`Samen.Aggregate.QueryBudget`)
  can be applied to its rows (T4.5).

  An aggregate projection row is one CELL of a cross-tenant summary: a per-tier MRR, a
  per-status queue depth, a per-status ticket-category diversity. The privacy floors need
  to know, for each such row:

    * `cohort_key_columns` — the columns that identify WHICH cohort this row is (e.g.
      `[:tier]`, `[:status]`). Used by the query-budget ledger to account a read against
      the cohort being queried (NOT the requesting actor — per the doc, per-actor is the
      wrong unit against collusion).

    * `cohort_count_column` — the column holding the cohort SIZE: how many distinct
      subjects / tenants contributed to this cell. This is what k-anonymity compares to
      `k`. A cell whose cohort count is `< k` (including count-of-one) is suppressed.

    * `distinct_sensitive_column` — (optional) the column holding the count of DISTINCT
      values of the **sensitive attribute** that rides this cohort. This is what
      l-diversity compares to `l`. A cell whose distinct-sensitive count is `< l`
      (including a homogeneous cohort where every member shares one value) is suppressed.
      `nil` opts the resource out of l-diversity (k-anon still applies).

    * `value_columns` — the RELEASABLE VALUE columns the floors suppress when they fire
      (e.g. `[:mrr_cents]`, `[:depth]`). The count / diversity metric columns are NOT
      listed here — they justify the suppression and are themselves bounded counts.

    * `sensitive_attribute` — (optional, documentation) the NAME of the sensitive
      dimension l-diversity protects (e.g. `:ticket_category`, `:plan_tier`). Recorded so
      the report / moduledoc can name the real sensitive dimension the demo proves.

  ## How a resource declares its cohort spec

  An aggregate resource exposes its spec by defining `aggregate_cohort_spec/0` returning
  a `%CohortSpec{}`. `Samen.Aggregate.read_all/2` reads it via `spec_for/1`. A resource
  with NO `aggregate_cohort_spec/0` returns `nil` — and `Samen.Aggregate.Privacy.apply/3`
  treats a `nil` spec as a fail-closed error (`{:error, :no_cohort_spec}`): an aggregate
  cell whose cohort size cannot be established cannot be proven `>= k`, so it is NOT
  released. This is the mask-unknown-by-default keystone applied to the output plane.
  """

  @enforce_keys [:cohort_count_column, :value_columns]
  defstruct cohort_key_columns: [],
            cohort_count_column: nil,
            distinct_sensitive_column: nil,
            value_columns: [],
            sensitive_attribute: nil

  @type t :: %__MODULE__{
          cohort_key_columns: [atom()],
          cohort_count_column: atom(),
          distinct_sensitive_column: atom() | nil,
          value_columns: [atom()],
          sensitive_attribute: atom() | nil
        }

  @doc """
  Read the cohort spec a resource declares via `aggregate_cohort_spec/0`, or `nil` if it
  declares none. Fail-closed downstream: `Samen.Aggregate.Privacy.apply/3` refuses a `nil`
  spec, so an aggregate resource with no cohort spec cannot release unsuppressed values.
  """
  @spec spec_for(module()) :: t() | nil
  def spec_for(resource) when is_atom(resource) do
    if function_exported?(resource, :aggregate_cohort_spec, 0) do
      case resource.aggregate_cohort_spec() do
        %__MODULE__{} = spec -> spec
        _ -> nil
      end
    else
      nil
    end
  end
end
