defmodule Driftwood.Repo.Migrations.BrokerSummary do
  @moduledoc """
  T5.3 clause (a): the TENANT-plane, per-org **broker summary rollup** table
  `dbs_broker_summary`.

  The broker dashboard reads this SMALL per-org summary (load counts by status +
  settlement totals) — it NEVER scans the raw `fop_opportunity` / `stl_settlement`
  rows into the view. This is the doc's rollup idiom on the tenant plane: "dashboards
  read the small summary, never scan raw" — the same shape as the demo's
  `rol_daily_event_count`, freight-flavoured.

  Unlike the cross-tenant aggregate plane (`dag_*` / `dtq_*`, T4.2/token-blind), this
  is an ORG-SCOPED rollup: every row carries `dbs_org_id`, and the broker dashboard
  reads only its own org's row(s) through the tenant scope. It contains NO `pii_`
  column — only bounded ids / enums / counts / cents numbers / timestamps (a load
  count and a settlement total are not subject-identifying).

  It is catalogued in the SAME migration transaction (self-qualifying storage +
  catalog-parity invariant). Its `tam_resource` is a catalog-only marker string
  (`Driftwood.BrokerSummary`) — like the demo rollup, there is no `use Samen.Resource`
  module behind it; it is refreshed by `Driftwood.BrokerRollup.run/2`.
  """
  use Ecto.Migration

  @table "dbs_broker_summary"
  @resource "Driftwood.BrokerSummary"
  @fields [
    {"dbs_id", "id", "UUID"},
    {"dbs_org_id", "org_id", "UUID"},
    {"dbs_status", "status", "String"},
    {"dbs_load_count", "load_count", "Integer"},
    {"dbs_gross_cents", "gross_cents", "Integer"},
    {"dbs_settlement_count", "settlement_count", "Integer"},
    {"dbs_net_payable_cents", "net_payable_cents", "Integer"},
    {"dbs_refreshed_at", "refreshed_at", "UTCDatetime"}
  ]

  def up do
    execute """
    CREATE TABLE #{@table} (
      dbs_id                UUID        NOT NULL DEFAULT gen_random_uuid(),
      dbs_org_id            UUID        NOT NULL,
      dbs_status            TEXT        NOT NULL,
      dbs_load_count        INTEGER     NOT NULL DEFAULT 0,
      dbs_gross_cents       INTEGER     NOT NULL DEFAULT 0,
      dbs_settlement_count  INTEGER     NOT NULL DEFAULT 0,
      dbs_net_payable_cents INTEGER     NOT NULL DEFAULT 0,
      dbs_refreshed_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
      PRIMARY KEY (dbs_id)
    )
    """,
    "DROP TABLE IF EXISTS #{@table}"

    execute """
    CREATE UNIQUE INDEX dbs_broker_summary_dim_uidx ON #{@table} (dbs_org_id, dbs_status)
    """,
    "DROP INDEX IF EXISTS dbs_broker_summary_dim_uidx"

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
    execute "DROP INDEX IF EXISTS dbs_broker_summary_dim_uidx"
    execute "DROP TABLE IF EXISTS #{@table}"
  end
end
