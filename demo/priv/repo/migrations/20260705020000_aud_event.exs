defmodule Demo.Repo.Migrations.AudEvent do
  @moduledoc """
  T2.2: the `aud_event` append-only event/audit tier for the demo app.

  Mirrors `SamenCore.TestRepo.Migrations.AudEvent` — same DDL, same catalog rows,
  same append-only enforcement.  See that module for full documentation.

  Demo-specific notes:
    * App role is `"clank"` (the local dev/CI Postgres user).
    * First child partition covers July 2026 (the demo launch month).
  """

  use Ecto.Migration

  @app_role Application.compile_env(:demo, :aud_event_app_role, "clank")

  @resource "Samen.AuditEvent"
  @table "aud_event"
  @fields [
    {"aud_id", "id", "UUID"},
    {"aud_event_type", "event_type", "String"},
    {"aud_subject_id", "subject_id", "String"},
    {"aud_actor_id", "actor_id", "String"},
    {"aud_correlation_id", "correlation_id", "UUID"},
    {"aud_detail", "detail", "String"},
    {"aud_occurred_at", "occurred_at", "UTCDatetime"}
  ]

  def up do
    execute """
    CREATE TABLE aud_event (
      aud_id             UUID        NOT NULL DEFAULT gen_random_uuid(),
      aud_event_type     TEXT        NOT NULL,
      aud_subject_id     TEXT,
      aud_actor_id       TEXT,
      aud_correlation_id UUID,
      aud_detail         TEXT,
      aud_occurred_at    TIMESTAMPTZ NOT NULL,
      PRIMARY KEY (aud_id, aud_occurred_at)
    ) PARTITION BY RANGE (aud_occurred_at)
    """,
    "DROP TABLE IF EXISTS aud_event"

    execute """
    CREATE TABLE IF NOT EXISTS aud_event_y2026m07
    PARTITION OF aud_event
    FOR VALUES FROM ('2026-07-01 00:00:00+00') TO ('2026-08-01 00:00:00+00')
    """,
    "DROP TABLE IF EXISTS aud_event_y2026m07"

    execute """
    CREATE INDEX aud_event_brin_occurred_at
    ON aud_event USING BRIN (aud_occurred_at)
    """,
    "DROP INDEX IF EXISTS aud_event_brin_occurred_at"

    execute """
    CREATE OR REPLACE FUNCTION aud_event_enforce_append_only()
    RETURNS TRIGGER LANGUAGE plpgsql AS $$
    BEGIN
      RAISE EXCEPTION 'aud_event is append-only: UPDATE and DELETE are not permitted. '
        'Event id: %, type: %',
        COALESCE(OLD.aud_id::text, '?'),
        COALESCE(OLD.aud_event_type, '?');
    END;
    $$
    """,
    "DROP FUNCTION IF EXISTS aud_event_enforce_append_only()"

    execute """
    CREATE TRIGGER aud_event_append_only_tg
    BEFORE UPDATE OR DELETE ON aud_event
    FOR EACH ROW EXECUTE FUNCTION aud_event_enforce_append_only()
    """,
    "DROP TRIGGER IF EXISTS aud_event_append_only_tg ON aud_event"

    execute """
    REVOKE UPDATE, DELETE ON aud_event FROM #{@app_role}
    """,
    """
    GRANT UPDATE, DELETE ON aud_event TO #{@app_role}
    """

    execute """
    INSERT INTO tam_table (tam_table_name, tam_resource)
    VALUES ('#{@table}', '#{@resource}')
    ON CONFLICT (tam_table_name) DO NOTHING
    """,
    """
    DELETE FROM tam_table WHERE tam_table_name = '#{@table}'
    """

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

    execute "GRANT UPDATE, DELETE ON aud_event TO #{@app_role}"
    execute "DROP TRIGGER IF EXISTS aud_event_append_only_tg ON aud_event"
    execute "DROP FUNCTION IF EXISTS aud_event_enforce_append_only()"
    execute "DROP INDEX IF EXISTS aud_event_brin_occurred_at"
    execute "DROP TABLE IF EXISTS aud_event_y2026m07"
    execute "DROP TABLE IF EXISTS aud_event"
  end
end
