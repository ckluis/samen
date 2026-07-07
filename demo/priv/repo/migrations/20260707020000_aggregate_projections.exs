defmodule Demo.Repo.Migrations.AggregateProjections do
  @moduledoc """
  T4.2: the token-blind aggregate plane's **vault-excluded projection** tables.

  Two cross-tenant summary tables the `Demo.Aggregate` domain projects over. Every
  column is a bounded id / enum / count / number / timestamp — there is NO `pii_`
  column here (the C7 `NoPiiColumns` verifier enforces the DSL side at compile time;
  `mix samen.verify.no_pii_columns` asserts the PHYSICAL side against these tables via
  `information_schema`; the T4.2 tests assert it directly).

    * `amr_mrr_by_tier` — cross-tenant MRR by plan tier (one row per tier, across all
      tenants). `amr_org_id` stays NULL: a per-tier MRR total spans all tenants.

    * `atq_ticket_queue_depth` — cross-tenant support-queue depth by status.

  Catalog rows (`tam_table`/`fld_field`) are written in the SAME migration
  transaction as the DDL (the self-qualifying-storage + catalog-parity invariant),
  so C1 `catalog_parity` and C2 `prefixes` pass on these tables.
  """
  use Ecto.Migration

  @mrr_table "amr_mrr_by_tier"
  @mrr_resource "Demo.Aggregate.MrrByTier"
  @mrr_fields [
    {"amr_id", "id", "UUID"},
    {"amr_org_id", "org_id", "UUID"},
    {"amr_tier", "tier", "String"},
    {"amr_tenant_count", "tenant_count", "Integer"},
    {"amr_mrr_cents", "mrr_cents", "Integer"},
    {"amr_refreshed_at", "refreshed_at", "UTCDatetime"},
    {"amr_inserted_at", "inserted_at", "UTCDatetime"},
    {"amr_updated_at", "updated_at", "UTCDatetime"}
  ]

  @tq_table "atq_ticket_queue_depth"
  @tq_resource "Demo.Aggregate.TicketQueueDepth"
  @tq_fields [
    {"atq_id", "id", "UUID"},
    {"atq_org_id", "org_id", "UUID"},
    {"atq_status", "status", "String"},
    {"atq_depth", "depth", "Integer"},
    {"atq_refreshed_at", "refreshed_at", "UTCDatetime"},
    {"atq_inserted_at", "inserted_at", "UTCDatetime"},
    {"atq_updated_at", "updated_at", "UTCDatetime"}
  ]

  def up do
    execute """
    CREATE TABLE #{@mrr_table} (
      amr_id           UUID        NOT NULL DEFAULT gen_random_uuid(),
      amr_org_id       UUID,
      amr_tier         TEXT        NOT NULL,
      amr_tenant_count INTEGER     NOT NULL DEFAULT 0,
      amr_mrr_cents    INTEGER     NOT NULL DEFAULT 0,
      amr_refreshed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
      amr_inserted_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
      amr_updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
      PRIMARY KEY (amr_id)
    )
    """,
    "DROP TABLE IF EXISTS #{@mrr_table}"

    execute "CREATE UNIQUE INDEX amr_mrr_by_tier_tier_uidx ON #{@mrr_table} (amr_tier)",
      "DROP INDEX IF EXISTS amr_mrr_by_tier_tier_uidx"

    execute """
    CREATE TABLE #{@tq_table} (
      atq_id           UUID        NOT NULL DEFAULT gen_random_uuid(),
      atq_org_id       UUID,
      atq_status       TEXT        NOT NULL,
      atq_depth        INTEGER     NOT NULL DEFAULT 0,
      atq_refreshed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
      atq_inserted_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
      atq_updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
      PRIMARY KEY (atq_id)
    )
    """,
    "DROP TABLE IF EXISTS #{@tq_table}"

    execute "CREATE UNIQUE INDEX atq_ticket_queue_depth_status_uidx ON #{@tq_table} (atq_status)",
      "DROP INDEX IF EXISTS atq_ticket_queue_depth_status_uidx"

    catalog_up(@mrr_table, @mrr_resource, @mrr_fields)
    catalog_up(@tq_table, @tq_resource, @tq_fields)
  end

  def down do
    catalog_down(@mrr_table, @mrr_fields)
    catalog_down(@tq_table, @tq_fields)

    execute "DROP INDEX IF EXISTS atq_ticket_queue_depth_status_uidx"
    execute "DROP TABLE IF EXISTS #{@tq_table}"
    execute "DROP INDEX IF EXISTS amr_mrr_by_tier_tier_uidx"
    execute "DROP TABLE IF EXISTS #{@mrr_table}"
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
