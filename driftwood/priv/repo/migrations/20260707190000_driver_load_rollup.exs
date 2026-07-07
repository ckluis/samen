defmodule Driftwood.Repo.Migrations.DriverLoadRollup do
  @moduledoc """
  T5.4: the DRIVER-keyed **load-count rollup** (`drl_driver_load_count`) — per-day /
  per-org / per-driver dispatch-event counts over the raw append-only `aud_event`
  tier.

  This is the rollup the crypto-shred game-day (T5.4) governs across BOTH erasure
  arms. A load-count derived aggregate that included a driver's dispatch events can
  still encode that driver AFTER a key-shred (key-shred does not touch a count), so
  it is registered in `config :samen_core, :rollups` and the erasure orchestration
  runs rebuild-or-exclude-on-erasure over it:

    * REBUILD arm  — where the raw `aud_event` partitions covering the driver are
      retained: delete the driver's raw events, recompute the rollup driver-free.
    * SUPPRESS arm — where the covering window is archived/detached: flip
      `drl_suppressed = TRUE` on the driver's derived rows.

  Mirrors `Demo.Repo.Migrations.Rollup` (`rol_daily_event_count`) — same DDL shape,
  same catalog rows in the SAME migration transaction (the self-qualifying-storage +
  catalog-parity invariant), same append-only-source semantics. Every column is a
  bounded id / count / boolean / timestamp — there is NO plaintext PII type here
  (`drl_subject_id` is the driver's bounded UUID, never a name/CDL). The
  `no_plaintext_pii` Rollup CI tier asserts exactly that.
  """

  use Ecto.Migration

  @resource "Driftwood.Freight.DriverLoadCount"
  @table "drl_driver_load_count"
  @fields [
    {"drl_id", "id", "UUID"},
    {"drl_day", "day", "Date"},
    {"drl_org_id", "org_id", "UUID"},
    {"drl_subject_id", "subject_id", "UUID"},
    {"drl_load_count", "load_count", "Integer"},
    {"drl_suppressed", "suppressed", "Boolean"},
    {"drl_refreshed_at", "refreshed_at", "UTCDatetime"}
  ]

  def up do
    execute """
    CREATE TABLE #{@table} (
      drl_id           UUID        NOT NULL DEFAULT gen_random_uuid(),
      drl_day          DATE        NOT NULL,
      drl_org_id       UUID,
      drl_subject_id   UUID,
      drl_load_count   INTEGER     NOT NULL DEFAULT 0,
      drl_suppressed   BOOLEAN     NOT NULL DEFAULT FALSE,
      drl_refreshed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
      PRIMARY KEY (drl_id)
    )
    """,
    "DROP TABLE IF EXISTS #{@table}"

    execute """
    CREATE UNIQUE INDEX drl_driver_load_count_dim_uidx
    ON #{@table} (drl_day, drl_org_id, drl_subject_id)
    """,
    "DROP INDEX IF EXISTS drl_driver_load_count_dim_uidx"

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
    execute "DROP INDEX IF EXISTS drl_driver_load_count_dim_uidx"
    execute "DROP TABLE IF EXISTS #{@table}"
  end
end
