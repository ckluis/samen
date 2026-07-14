defmodule PawChart.Repo.Migrations.AddCockpitRollups do
  @moduledoc """
  WS-B / Phase B9 (AC-X1): the two DOMAIN-SOURCED operator-cockpit rollup tables,
  mounted for the vertical exactly as demo's `AddRevenueRollup` (B2/ADR-018) and
  `AddProductEventRollup` (B8/ADR-021) migrations built them — RAW rollup tables on
  the `rol_daily_event_count` precedent: NO Ash resource fronts them, the table
  names are HOST-INVARIANT (`mrr_revenue_rollup` / `paf_product_event_rollup` in
  every host DB — `Samen.Web.Operator.{Revenue,Analytics}Reads` read them by name),
  and `mrr`/`paf` are COLUMN PREFIXES, not abbrev-registry rows. Catalogued in the
  SAME transaction (ADR-004 catalog-in-tx).

    * `mrr_revenue_rollup` — grain (org_id, period_month, mov_kind) → sum/count,
      recomputed from PawChart's movement ledger
      (`pbv_subscription_event` — PawChart's single Billing mount, the demo
      single-mount pattern: the clinic vertical has no separate operator-book
      billing namespace yet).
    * `paf_product_event_rollup` — the funnel/retention seed rollup over the `vae`
      product-event ledger (funnel + 4-week retention arms).

  Token-blind by construction: bounded ids / period buckets / bounded enums /
  ints / booleans / timestamps — NO plaintext PII type. The `no_plaintext_pii`
  Rollup CI tier asserts exactly that over the specs' `bounded_columns` allow-lists.
  """
  use Ecto.Migration

  @tables [
    {"PawChart.Aggregate.RevenueRollup", "mrr_revenue_rollup",
     [
       {"mrr_id", "id", "UUID"},
       {"mrr_org_id", "org_id", "UUID"},
       {"mrr_period_month", "period_month", "Date"},
       {"mrr_kind", "kind", "Text"},
       {"mrr_delta_cents", "delta_cents", "Integer"},
       {"mrr_count", "count", "Integer"},
       {"mrr_suppressed", "suppressed", "Boolean"},
       {"mrr_refreshed_at", "refreshed_at", "UTCDatetime"}
     ]},
    {"PawChart.Analytics.ProductEventRollup", "paf_product_event_rollup",
     [
       {"paf_id", "id", "UUID"},
       {"paf_org_id", "org_id", "UUID"},
       {"paf_kind", "kind", "Text"},
       {"paf_stage", "stage", "Text"},
       {"paf_cohort_week", "cohort_week", "Date"},
       {"paf_week_offset", "week_offset", "Integer"},
       {"paf_actor_count", "actor_count", "Integer"},
       {"paf_suppressed", "suppressed", "Boolean"},
       {"paf_refreshed_at", "refreshed_at", "UTCDatetime"}
     ]}
  ]

  def up do
    execute """
            CREATE TABLE mrr_revenue_rollup (
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
            "DROP TABLE IF EXISTS mrr_revenue_rollup"

    execute """
            CREATE UNIQUE INDEX mrr_revenue_rollup_dim_uidx
            ON mrr_revenue_rollup (mrr_org_id, mrr_period_month, mrr_kind)
            """,
            "DROP INDEX IF EXISTS mrr_revenue_rollup_dim_uidx"

    execute """
            CREATE TABLE paf_product_event_rollup (
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
            "DROP TABLE IF EXISTS paf_product_event_rollup"

    execute """
            CREATE INDEX paf_product_event_rollup_read_idx
            ON paf_product_event_rollup (paf_org_id, paf_kind)
            """,
            "DROP INDEX IF EXISTS paf_product_event_rollup_read_idx"

    for {resource, table, fields} <- @tables do
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
  end

  def down do
    for {_resource, table, fields} <- Enum.reverse(@tables) do
      for {col, _logical, _type} <- Enum.reverse(fields) do
        execute """
        DELETE FROM fld_field
        WHERE fld_table_name = '#{table}' AND fld_column_name = '#{col}'
        """
      end

      execute "DELETE FROM tam_table WHERE tam_table_name = '#{table}'"
    end

    execute "DROP INDEX IF EXISTS paf_product_event_rollup_read_idx"
    execute "DROP TABLE IF EXISTS paf_product_event_rollup"
    execute "DROP INDEX IF EXISTS mrr_revenue_rollup_dim_uidx"
    execute "DROP TABLE IF EXISTS mrr_revenue_rollup"
  end
end
