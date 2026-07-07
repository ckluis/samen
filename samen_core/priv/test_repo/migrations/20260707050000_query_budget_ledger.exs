defmodule SamenCore.TestRepo.Migrations.QueryBudgetLedger do
  @moduledoc """
  T4.5 query-budget ledger kernel table (`aqb_query_ledger`). Abbrev-prefixed,
  token/bounded-only (resource name, cohort key string, tenant scope, counts, an
  actor id for FORENSICS only — never the accounting unit, never plaintext PII).

  Follows the `brl_`/`rvg_`/`imp_` precedent: operator-plane kernel infra backed by a
  plain `Ecto.Schema` (`Samen.Aggregate.QueryLedgerRow`), consulted by the aggregate
  read path, NOT an Ash resource and NOT catalogued (the demo host catalogs its own
  copy in `tam_table`/`fld_field`; the kernel test fixture does not).

  The ledger is the query-budget SCAFFOLD (T4.5 clause (c)): one row per aggregate
  read, keyed by the COHORT being queried (not the actor — per-actor is the wrong
  unit against collusion). It records; it does not enforce (the cross-query budget /
  DP layer is posture under construction, plan T6.6).
  """
  use Ecto.Migration

  def up do
    create table(:aqb_query_ledger, primary_key: false) do
      add(:aqb_id, :uuid, primary_key: true, null: false, default: fragment("gen_random_uuid()"))
      add(:aqb_resource, :text, null: false)
      # The cohort being queried — the load-bearing accounting granularity.
      add(:aqb_cohort_key, :text, null: false)
      # "__aggregate__" for the cross-tenant plane; a future per-tenant budget scopes here.
      add(:aqb_tenant_scope, :text, null: false, default: "__aggregate__")
      add(:aqb_cell_count, :integer, null: false, default: 1)
      # Forensics only — NEVER the accounting unit (count/2 + over_threshold? ignore it).
      add(:aqb_actor_id, :string)
      add(:aqb_read_at, :utc_datetime_usec, null: false)
      add(:aqb_inserted_at, :utc_datetime_usec, null: false)
    end

    # The per-cohort window-count query: reads within a window for one cohort key.
    create(index(:aqb_query_ledger, [:aqb_resource, :aqb_cohort_key, :aqb_tenant_scope, :aqb_read_at]))
  end

  def down do
    drop(table(:aqb_query_ledger))
  end
end
