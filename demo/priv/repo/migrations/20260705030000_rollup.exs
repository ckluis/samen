defmodule Demo.Repo.Migrations.Rollup do
  @moduledoc """
  T2.3: the demo `rol_daily_event_count` rollup table (per-day / per-org /
  per-subject event counts over `aud_event`).

  Mirrors `SamenCore.TestRepo.Migrations.Rollup` — same DDL, same catalog rows in
  the same migration transaction. The demo dogfoods:

    * the refresh framework (`Samen.Rollup.rebuild_all/1` on the `*/10 * * * *`
      cron via `Samen.Jobs.RollupRefreshWorker`) — dashboards read the small
      `rol_*` summary, never scan raw events;
    * rebuild-or-exclude-on-erasure (`Samen.Erasure.shred/2` wires the policy in);
    * the `no_plaintext_pii` Rollup oracle tier (token/bounded-ID/count only).

  Every column is a bounded ID / enum / count / timestamp / boolean — NO plaintext
  PII type. `rol_subject_id` is a bounded UUID (NOT the contact's name/email).
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
