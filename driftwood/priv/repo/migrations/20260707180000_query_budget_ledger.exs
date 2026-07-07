defmodule Driftwood.Repo.Migrations.QueryBudgetLedger do
  @moduledoc """
  T5.3 / T4.5 clause (c): the query-budget ledger table `aqb_query_ledger` for
  Driftwood's token-blind aggregate plane. One row per aggregate read, keyed by the
  COHORT being queried (not the actor). Records every read so a per-cohort read count
  can WARN (never enforce — the cross-query budget / DP layer is posture under
  construction, plan T6.6). Mirrors the demo `aqb_query_ledger` (SCAFFOLD — accounting
  only). Bounded columns only; no `pii_` column.

  Catalogued in the SAME migration transaction (catalog-parity invariant).
  """
  use Ecto.Migration

  @table "aqb_query_ledger"
  @resource "Samen.Aggregate.QueryLedgerRow"
  @fields [
    {"aqb_id", "id", "UUID"},
    {"aqb_resource", "resource", "String"},
    {"aqb_cohort_key", "cohort_key", "String"},
    {"aqb_tenant_scope", "tenant_scope", "String"},
    {"aqb_cell_count", "cell_count", "Integer"},
    {"aqb_actor_id", "actor_id", "String"},
    {"aqb_read_at", "read_at", "UTCDatetimeUsec"},
    {"aqb_inserted_at", "inserted_at", "UTCDatetimeUsec"}
  ]

  def up do
    execute """
    CREATE TABLE #{@table} (
      aqb_id           UUID          NOT NULL DEFAULT gen_random_uuid(),
      aqb_resource     TEXT          NOT NULL,
      aqb_cohort_key   TEXT          NOT NULL,
      aqb_tenant_scope TEXT          NOT NULL DEFAULT '__aggregate__',
      aqb_cell_count   INTEGER       NOT NULL DEFAULT 1,
      aqb_actor_id     TEXT,
      aqb_read_at      TIMESTAMPTZ   NOT NULL DEFAULT now(),
      aqb_inserted_at  TIMESTAMPTZ   NOT NULL DEFAULT now(),
      PRIMARY KEY (aqb_id)
    )
    """,
    "DROP TABLE IF EXISTS #{@table}"

    execute(
      "CREATE INDEX aqb_query_ledger_cohort_idx ON #{@table} (aqb_resource, aqb_cohort_key, aqb_tenant_scope, aqb_read_at)",
      "DROP INDEX IF EXISTS aqb_query_ledger_cohort_idx"
    )

    execute """
    INSERT INTO tam_table (tam_table_name, tam_resource)
    VALUES ('#{@table}', '#{@resource}')
    ON CONFLICT (tam_table_name) DO NOTHING
    """,
    "DELETE FROM tam_table WHERE tam_table_name = '#{@table}'"

    for {col, logical, type} <- @fields do
      execute """
      INSERT INTO fld_field (fld_table_name, fld_column_name, fld_logical_name, fld_type)
      VALUES ('#{@table}', '#{col}', '#{logical}', '#{type}')
      ON CONFLICT (fld_table_name, fld_column_name) DO NOTHING
      """,
      """
      DELETE FROM fld_field
      WHERE fld_table_name = '#{@table}' AND fld_column_name = '#{col}'
      """
    end
  end

  def down do
    for {col, _logical, _type} <- Enum.reverse(@fields) do
      execute """
      DELETE FROM fld_field
      WHERE fld_table_name = '#{@table}' AND fld_column_name = '#{col}'
      """
    end

    execute "DELETE FROM tam_table WHERE tam_table_name = '#{@table}'"
    execute "DROP INDEX IF EXISTS aqb_query_ledger_cohort_idx"
    execute "DROP TABLE IF EXISTS #{@table}"
  end
end
