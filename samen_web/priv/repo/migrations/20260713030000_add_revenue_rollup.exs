defmodule Samen.WebTest.Repo.Migrations.AddRevenueRollup do
  @moduledoc """
  WS-B / Phase B3: the `mrr_revenue_rollup` RAW rollup table for the samen_web scratch
  test DB — the SAME shape as the demo's B2 table (ADR-018), so the framework
  `Samen.Web.Operator.RevenueReads` (which reads this table bounded, never a live
  movement scan) has real rows to render in the operator revenue tests.

  The `rol_daily_event_count` precedent: a RAW table — NO Ash resource fronts it, NO
  abbrev-registry row (`mrr` is the column prefix, not an abbrev). Catalogued in the
  same transaction (ADR-004 catalog-in-tx) under the framework logical name, mirroring
  the rol precedent's `Samen.Rollup.*` naming.

  Token-blind by construction: every column is a bounded id, a period bucket, a
  bounded enum (kind as text), a signed integer (cents), a count, a boolean, or a
  timestamp — no plaintext PII type.
  """
  use Ecto.Migration

  @resource "Samen.Rollup.RevenueRollup"
  @table "mrr_revenue_rollup"
  @fields [
    {"mrr_id", "id", "UUID"},
    {"mrr_org_id", "org_id", "UUID"},
    {"mrr_period_month", "period_month", "Date"},
    {"mrr_kind", "kind", "Text"},
    {"mrr_delta_cents", "delta_cents", "Integer"},
    {"mrr_count", "count", "Integer"},
    {"mrr_suppressed", "suppressed", "Boolean"},
    {"mrr_refreshed_at", "refreshed_at", "UTCDatetime"}
  ]

  def up do
    execute """
    CREATE TABLE #{@table} (
      mrr_id           UUID        NOT NULL DEFAULT gen_random_uuid(),
      mrr_org_id       UUID        NOT NULL,
      mrr_period_month DATE        NOT NULL,
      mrr_kind         TEXT        NOT NULL,
      mrr_delta_cents  INTEGER     NOT NULL DEFAULT 0,
      mrr_count        INTEGER     NOT NULL DEFAULT 0,
      mrr_suppressed   BOOLEAN     NOT NULL DEFAULT FALSE,
      mrr_refreshed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
      PRIMARY KEY (mrr_id)
    )
    """,
    "DROP TABLE IF EXISTS #{@table}"

    execute """
    CREATE UNIQUE INDEX mrr_revenue_rollup_dim_uidx
    ON #{@table} (mrr_org_id, mrr_period_month, mrr_kind)
    """,
    "DROP INDEX IF EXISTS mrr_revenue_rollup_dim_uidx"

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
    execute "DROP INDEX IF EXISTS mrr_revenue_rollup_dim_uidx"
    execute "DROP TABLE IF EXISTS #{@table}"
  end
end
