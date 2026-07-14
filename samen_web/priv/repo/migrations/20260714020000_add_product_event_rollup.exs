defmodule Samen.WebTest.Repo.Migrations.AddProductEventRollup do
  @moduledoc """
  WS-B / Phase B8 (ADR-021): the `paf_product_event_rollup` RAW rollup table for the
  samen_web scratch test DB — the SAME shape as the demo's B8 table, so the framework
  `Samen.Web.Operator.AnalyticsReads` (which reads this table bounded, cross-tenant,
  under the aggregate k-anon floors) has real rows to render in the operator
  analytics tests.

  The `mrr_revenue_rollup` (B3 scratch) precedent exactly: a RAW table — NO Ash
  resource fronts it, NO abbrev-registry row (`paf` is the column prefix, not an
  abbrev). Catalogued in the same transaction (ADR-004 catalog-in-tx) under the
  framework logical name, mirroring the mrr precedent's `Samen.Rollup.*` naming.

  Token-blind by construction: every column is a bounded id (uuid), a bounded enum
  label (kind/stage as text), a week bucket (date), a count/offset (int), a boolean,
  or a timestamp — no plaintext PII type.
  """
  use Ecto.Migration

  @resource "Samen.Rollup.ProductEventRollup"
  @table "paf_product_event_rollup"
  @fields [
    {"paf_id", "id", "UUID"},
    {"paf_org_id", "org_id", "UUID"},
    {"paf_kind", "kind", "Text"},
    {"paf_stage", "stage", "Text"},
    {"paf_cohort_week", "cohort_week", "Date"},
    {"paf_week_offset", "week_offset", "Integer"},
    {"paf_actor_count", "actor_count", "Integer"},
    {"paf_suppressed", "suppressed", "Boolean"},
    {"paf_refreshed_at", "refreshed_at", "UTCDatetime"}
  ]

  def up do
    execute """
            CREATE TABLE #{@table} (
              paf_id           UUID        NOT NULL DEFAULT gen_random_uuid(),
              paf_org_id       UUID        NOT NULL,
              paf_kind         TEXT        NOT NULL,
              paf_stage        TEXT,
              paf_cohort_week  DATE,
              paf_week_offset  INTEGER,
              paf_actor_count  INTEGER     NOT NULL DEFAULT 0,
              paf_suppressed   BOOLEAN     NOT NULL DEFAULT FALSE,
              paf_refreshed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
              PRIMARY KEY (paf_id)
            )
            """,
            "DROP TABLE IF EXISTS #{@table}"

    execute """
            CREATE INDEX paf_product_event_rollup_read_idx
            ON #{@table} (paf_org_id, paf_kind)
            """,
            "DROP INDEX IF EXISTS paf_product_event_rollup_read_idx"

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
    execute "DROP INDEX IF EXISTS paf_product_event_rollup_read_idx"
    execute "DROP TABLE IF EXISTS #{@table}"
  end
end
