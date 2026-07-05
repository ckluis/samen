defmodule SamenCore.TestRepo.Migrations.Rollup do
  @moduledoc """
  T2.3: the `rol_daily_event_count` rollup table (per-day / per-org / per-subject
  event counts over `aud_event`).

  ## What this migration creates

    1. **`rol_daily_event_count` rollup table** — a small derived summary over the
       raw append-only `aud_event` tier. Dashboards read THIS table, never scan raw
       events (doc §data: "the dashboard query hits ENG_daily_rollup (small), not
       raw events").

    2. **Catalog rows** (in the SAME migration transaction) via raw SQL into
       `tam_table` / `fld_field`.

  ## Token / bounded-ID only (the oracle's rollup tier asserts this)

  Every column is a bounded ID, an enum, a count, a timestamp, or a boolean flag —
  NO plaintext PII type:

    * `rol_id`            — UUID (opaque row id)
    * `rol_day`           — DATE bucket (the per-day dimension)
    * `rol_org_id`        — bounded org id (UUID)
    * `rol_subject_id`    — bounded subject id (UUID / token — NOT the subject's
                            name/email/SSN). This is the linkage column erasure
                            matches on.
    * `rol_event_count`   — INTEGER count
    * `rol_suppressed`    — BOOLEAN: the exclude/suppress arm flips this true when a
                            subject is erased in an already-archived window.
    * `rol_refreshed_at`  — TIMESTAMPTZ: when the rollup row was last materialised.

  A UNIQUE index on `(rol_day, rol_org_id, rol_subject_id)` makes the rebuild INSERT
  idempotent and the per-subject grouping the erasure arm keys on well-defined.

  ## Why plain `use Ecto.Migration`

  Like `aud_event`, the rollup table is kernel infrastructure (a derived summary),
  not an Ash resource — so catalog rows are written via `execute/2` in this
  migration's transaction (same BEGIN..COMMIT atomicity as the DDL).
  """

  use Ecto.Migration

  @resource "Samen.Rollup.DailyEventCount"
  @table "rol_daily_event_count"
  @fields [
    {"rol_id", "id", "UUID"},
    {"rol_day", "day", "Date"},
    {"rol_org_id", "org_id", "UUID"},
    {"rol_subject_id", "subject_id", "UUID"},
    {"rol_event_count", "event_count", "Integer"},
    {"rol_suppressed", "suppressed", "Boolean"},
    {"rol_refreshed_at", "refreshed_at", "UTCDatetime"}
  ]

  def up do
    execute """
    CREATE TABLE rol_daily_event_count (
      rol_id           UUID        NOT NULL DEFAULT gen_random_uuid(),
      rol_day          DATE        NOT NULL,
      rol_org_id       UUID,
      rol_subject_id   UUID,
      rol_event_count  INTEGER     NOT NULL DEFAULT 0,
      rol_suppressed   BOOLEAN     NOT NULL DEFAULT FALSE,
      rol_refreshed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
      PRIMARY KEY (rol_id)
    )
    """,
    "DROP TABLE IF EXISTS rol_daily_event_count"

    execute """
    CREATE UNIQUE INDEX rol_daily_event_count_dim_uidx
    ON rol_daily_event_count (rol_day, rol_org_id, rol_subject_id)
    """,
    "DROP INDEX IF EXISTS rol_daily_event_count_dim_uidx"

    # Catalog rows for the rollup table (in this migration's transaction).
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
    execute "DROP INDEX IF EXISTS rol_daily_event_count_dim_uidx"
    execute "DROP TABLE IF EXISTS rol_daily_event_count"
  end
end
