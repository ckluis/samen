defmodule Demo.Repo.Migrations.AggregatePrivacyFloors do
  @moduledoc """
  T4.5: the aggregate-privacy floors + query-budget ledger.

  Adds, to the token-blind aggregate projections (T4.2):

    * `atq_distinct_priorities` on `atq_ticket_queue_depth` — the count of DISTINCT
      ticket PRIORITIES within each status cohort. This is the l-diversity
      distinct-sensitive-value count for the real sensitive dimension the demo proves
      (ticket priority — the doc's "e.g. plan tier or ticket category" example). A
      status cohort whose tickets all share one priority (`distinct_priorities == 1`)
      is a homogeneous cohort and suppresses under l-diversity.

  The k-anonymity cohort SIZE columns already exist: `atq_depth` (tickets per status)
  and `amr_tenant_count` (tenants per tier). No new column is needed for k-anon.

  Adds the **query-budget ledger** table `aqb_query_ledger` (T4.5 clause (c)): one row
  per aggregate read, keyed by the COHORT being queried (not the actor). It records
  every read so a per-cohort read count can WARN (never enforce — the cross-query
  budget / DP layer is posture under construction, plan T6.6).

  Catalog rows (`tam_table`/`fld_field`) are written in the SAME migration transaction
  as the DDL (the self-qualifying-storage + catalog-parity invariant), so C1
  `catalog_parity` and C2 `prefixes` pass.
  """
  use Ecto.Migration

  @tq_table "atq_ticket_queue_depth"

  @ledger_table "aqb_query_ledger"
  @ledger_resource "Samen.Aggregate.QueryLedgerRow"
  @ledger_fields [
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
    # l-diversity distinct-sensitive-value count on the queue-depth projection.
    execute(
      "ALTER TABLE #{@tq_table} ADD COLUMN atq_distinct_priorities INTEGER NOT NULL DEFAULT 0",
      "ALTER TABLE #{@tq_table} DROP COLUMN IF EXISTS atq_distinct_priorities"
    )

    execute(
      """
      INSERT INTO fld_field (fld_table_name, fld_column_name, fld_logical_name, fld_type)
      VALUES ('#{@tq_table}', 'atq_distinct_priorities', 'distinct_priorities', 'Integer')
      ON CONFLICT (fld_table_name, fld_column_name) DO NOTHING
      """,
      """
      DELETE FROM fld_field
      WHERE fld_table_name = '#{@tq_table}' AND fld_column_name = 'atq_distinct_priorities'
      """
    )

    # The query-budget ledger (T4.5 clause (c)). Bounded columns only — no pii_ column.
    # This is NOT an aggregate-plane projection (it is the accounting side table), so it
    # is intentionally not a `use Samen.Aggregate.Resource`.
    execute """
    CREATE TABLE #{@ledger_table} (
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
    "DROP TABLE IF EXISTS #{@ledger_table}"

    # Index the accounting key so per-cohort window counts stay cheap.
    execute(
      "CREATE INDEX aqb_query_ledger_cohort_idx ON #{@ledger_table} (aqb_resource, aqb_cohort_key, aqb_tenant_scope, aqb_read_at)",
      "DROP INDEX IF EXISTS aqb_query_ledger_cohort_idx"
    )

    catalog_up(@ledger_table, @ledger_resource, @ledger_fields)
  end

  def down do
    catalog_down(@ledger_table, @ledger_fields)
    execute "DROP INDEX IF EXISTS aqb_query_ledger_cohort_idx"
    execute "DROP TABLE IF EXISTS #{@ledger_table}"

    execute """
    DELETE FROM fld_field
    WHERE fld_table_name = '#{@tq_table}' AND fld_column_name = 'atq_distinct_priorities'
    """

    execute "ALTER TABLE #{@tq_table} DROP COLUMN IF EXISTS atq_distinct_priorities"
  end

  defp catalog_up(table, resource, fields) do
    execute """
    INSERT INTO tam_table (tam_table_name, tam_resource)
    VALUES ('#{table}', '#{resource}')
    ON CONFLICT (tam_table_name) DO NOTHING
    """,
    "DELETE FROM tam_table WHERE tam_table_name = '#{table}'"

    for {col, logical, type} <- fields do
      execute """
      INSERT INTO fld_field (fld_table_name, fld_column_name, fld_logical_name, fld_type)
      VALUES ('#{table}', '#{col}', '#{logical}', '#{type}')
      ON CONFLICT (fld_table_name, fld_column_name) DO NOTHING
      """,
      """
      DELETE FROM fld_field
      WHERE fld_table_name = '#{table}' AND fld_column_name = '#{col}'
      """
    end
  end

  defp catalog_down(table, fields) do
    for {col, _logical, _type} <- Enum.reverse(fields) do
      execute """
      DELETE FROM fld_field
      WHERE fld_table_name = '#{table}' AND fld_column_name = '#{col}'
      """
    end

    execute "DELETE FROM tam_table WHERE tam_table_name = '#{table}'"
  end
end
