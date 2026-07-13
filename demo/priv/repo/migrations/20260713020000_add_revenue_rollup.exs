defmodule Demo.Repo.Migrations.AddRevenueRollup do
  @moduledoc """
  WS-B / Phase B2 (ADR-018): the DOMAIN-SOURCED revenue-movement rollup
  (`mrr_revenue_rollup`) — `Demo.Aggregate.RevenueRollup`. Grain
  `(org_id, period_month, mov_kind) → sum(mrr_delta_cents), count`, recomputed from
  the `mov` subscription-movement ledger (a DOMAIN table, ADR-017), NOT from
  `aud_event`. This is the ADR-007 `:source :domain` generalization made real:
  the erasure REBUILD arm deletes the subject's `mov` rows then recomputes this
  rollup subject-free (AC-G7-7 — proven by the destruction oracle).

  Catalogued in the SAME transaction (ADR-004 catalog-in-tx), mirroring the
  `rol_daily_event_count` DDL shape.

  Token-blind by construction: every column is a bounded id (uuid), a period bucket
  (date), a bounded enum (kind as text), a signed integer (cents), a count, a
  boolean, or a timestamp — there is NO plaintext PII type. The `no_plaintext_pii`
  Rollup CI tier asserts exactly that over the `bounded_columns` allow-list.

    * `mrr_subject_column`/`mrr_suppressed` — a domain rollup is subject-free
      aggregate by construction (its grain is period/kind, it carries NO per-subject
      column), so the ADR-018 domain arm never uses these. They are OMITTED from the
      spec (`subject_column: nil`); the erasure hook is the ledger-side
      `subject_delete_sql`. `mrr_suppressed` is carried physically only so a future
      operator-driven period suppression has a column, but no arm flips it today.
  """
  use Ecto.Migration

  @resource "Demo.Aggregate.RevenueRollup"
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
