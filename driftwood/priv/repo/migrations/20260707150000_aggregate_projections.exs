defmodule Driftwood.Repo.Migrations.AggregateProjections do
  @moduledoc """
  T5.3 clause (b): the token-blind aggregate plane's **vault-excluded projection**
  tables for the freight vertical (T4.2 mounted over Driftwood).

  Two cross-tenant summary tables the `Driftwood.Aggregate` domain projects over. Every
  column is a bounded id / enum / count / number / timestamp — there is NO `pii_`
  column here (the C7 `NoPiiColumns` verifier enforces the DSL side at compile time;
  `mix samen.verify.no_pii_columns` asserts the PHYSICAL side against these tables via
  `information_schema`; the T5.3 tests assert it directly).

    * `dag_load_volume_by_lane` — cross-tenant LOAD VOLUME by lane bucket (one row per
      lane, across all brokerages). `dag_org_id` stays NULL: per-lane volume spans all
      tenants (doc §control "cross-tenant load volume … with NO PII").

    * `dtq_mrr_by_tier` — cross-tenant brokerage MRR by plan tier (doc: "… / MRR").

  Catalog rows (`tam_table`/`fld_field`) are written in the SAME migration transaction
  as the DDL (the self-qualifying-storage + catalog-parity invariant), so C1
  `catalog_parity` and C2 `prefixes` pass on these tables.
  """
  use Ecto.Migration

  @lane_table "dag_load_volume_by_lane"
  @lane_resource "Driftwood.Aggregate.LoadVolumeByLane"
  @lane_fields [
    {"dag_id", "id", "UUID"},
    {"dag_org_id", "org_id", "UUID"},
    {"dag_lane", "lane", "String"},
    {"dag_tenant_count", "tenant_count", "Integer"},
    {"dag_load_count", "load_count", "Integer"},
    {"dag_gross_cents", "gross_cents", "Integer"},
    {"dag_refreshed_at", "refreshed_at", "UTCDatetime"},
    {"dag_inserted_at", "inserted_at", "UTCDatetime"},
    {"dag_updated_at", "updated_at", "UTCDatetime"}
  ]

  @mrr_table "dtq_mrr_by_tier"
  @mrr_resource "Driftwood.Aggregate.MrrByTier"
  @mrr_fields [
    {"dtq_id", "id", "UUID"},
    {"dtq_org_id", "org_id", "UUID"},
    {"dtq_tier", "tier", "String"},
    {"dtq_tenant_count", "tenant_count", "Integer"},
    {"dtq_mrr_cents", "mrr_cents", "Integer"},
    {"dtq_refreshed_at", "refreshed_at", "UTCDatetime"},
    {"dtq_inserted_at", "inserted_at", "UTCDatetime"},
    {"dtq_updated_at", "updated_at", "UTCDatetime"}
  ]

  def up do
    execute """
    CREATE TABLE #{@lane_table} (
      dag_id           UUID        NOT NULL DEFAULT gen_random_uuid(),
      dag_org_id       UUID,
      dag_lane         TEXT        NOT NULL,
      dag_tenant_count INTEGER     NOT NULL DEFAULT 0,
      dag_load_count   INTEGER     NOT NULL DEFAULT 0,
      dag_gross_cents  INTEGER     NOT NULL DEFAULT 0,
      dag_refreshed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
      dag_inserted_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
      dag_updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
      PRIMARY KEY (dag_id)
    )
    """,
    "DROP TABLE IF EXISTS #{@lane_table}"

    execute "CREATE UNIQUE INDEX dag_load_volume_by_lane_lane_uidx ON #{@lane_table} (dag_lane)",
      "DROP INDEX IF EXISTS dag_load_volume_by_lane_lane_uidx"

    execute """
    CREATE TABLE #{@mrr_table} (
      dtq_id           UUID        NOT NULL DEFAULT gen_random_uuid(),
      dtq_org_id       UUID,
      dtq_tier         TEXT        NOT NULL,
      dtq_tenant_count INTEGER     NOT NULL DEFAULT 0,
      dtq_mrr_cents    INTEGER     NOT NULL DEFAULT 0,
      dtq_refreshed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
      dtq_inserted_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
      dtq_updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
      PRIMARY KEY (dtq_id)
    )
    """,
    "DROP TABLE IF EXISTS #{@mrr_table}"

    execute "CREATE UNIQUE INDEX dtq_mrr_by_tier_tier_uidx ON #{@mrr_table} (dtq_tier)",
      "DROP INDEX IF EXISTS dtq_mrr_by_tier_tier_uidx"

    catalog_up(@lane_table, @lane_resource, @lane_fields)
    catalog_up(@mrr_table, @mrr_resource, @mrr_fields)
  end

  def down do
    catalog_down(@mrr_table, @mrr_fields)
    catalog_down(@lane_table, @lane_fields)

    execute "DROP INDEX IF EXISTS dtq_mrr_by_tier_tier_uidx"
    execute "DROP TABLE IF EXISTS #{@mrr_table}"
    execute "DROP INDEX IF EXISTS dag_load_volume_by_lane_lane_uidx"
    execute "DROP TABLE IF EXISTS #{@lane_table}"
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
