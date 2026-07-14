defmodule Demo.Repo.Migrations.AddHealthByBandAggregate do
  @moduledoc """
  WS-B B4 (AC-G17-6): the token-blind aggregate-plane projection for **cross-tenant
  health-band distribution** ("how many accounts are at-risk across the fleet") — the
  third `Demo.Aggregate` projection, alongside `amr_mrr_by_tier` and
  `atq_ticket_queue_depth`.

    * `ahb_health_by_band` — cross-tenant account count per health BAND
      (`:healthy | :watch | :at_risk | :critical`), one row per band, across all
      tenants. Every column is bounded / non-PII: `ahb_band` (a health-band enum),
      `ahb_account_count` (a count). `ahb_org_id` stays NULL — a per-band account
      count spans ALL tenants (the cross-tenant aggregate).

  Per design §2.3 (LOAD-BEARING) + ADR-019 §5 + build-plan B4 task 4: cross-tenant
  health routes through `operator_aggregate` + a `CohortSpec` on `band` with k-anon
  `min_cohort = 5` — a band with <5 accounts renders `%Suppressed{}`. The RELEASABLE
  VALUE `account_count` is BOTH the cohort SIZE (k-anon compares it to `k`) and the
  value suppressed when the floor fires. No l-diversity dimension (a per-band account
  count is a single count — no sensitive sub-attribute rides it).

  Catalog rows (`tam_table`/`fld_field`) are written in the SAME migration
  transaction as the DDL (the self-qualifying-storage + catalog-parity invariant),
  so C1 `catalog_parity` and C2 `prefixes` pass; the C7 `NoPiiColumns` verifier +
  `mix samen.verify.no_pii_columns` enforce there is NO `pii_` column here.
  """
  use Ecto.Migration

  @table "ahb_health_by_band"
  @resource "Demo.Aggregate.HealthByBand"
  @fields [
    {"ahb_id", "id", "UUID"},
    {"ahb_org_id", "org_id", "UUID"},
    {"ahb_band", "band", "String"},
    {"ahb_account_count", "account_count", "Integer"},
    {"ahb_refreshed_at", "refreshed_at", "UTCDatetime"},
    {"ahb_inserted_at", "inserted_at", "UTCDatetime"},
    {"ahb_updated_at", "updated_at", "UTCDatetime"}
  ]

  def up do
    execute """
    CREATE TABLE #{@table} (
      ahb_id            UUID        NOT NULL DEFAULT gen_random_uuid(),
      ahb_org_id        UUID,
      ahb_band          TEXT        NOT NULL,
      ahb_account_count INTEGER     NOT NULL DEFAULT 0,
      ahb_refreshed_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
      ahb_inserted_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
      ahb_updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
      PRIMARY KEY (ahb_id)
    )
    """,
    "DROP TABLE IF EXISTS #{@table}"

    execute "CREATE UNIQUE INDEX ahb_health_by_band_band_uidx ON #{@table} (ahb_band)",
      "DROP INDEX IF EXISTS ahb_health_by_band_band_uidx"

    catalog_up(@table, @resource, @fields)
  end

  def down do
    catalog_down(@table, @fields)
    execute "DROP INDEX IF EXISTS ahb_health_by_band_band_uidx"
    execute "DROP TABLE IF EXISTS #{@table}"
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
