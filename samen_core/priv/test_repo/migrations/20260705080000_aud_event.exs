defmodule SamenCore.TestRepo.Migrations.AudEvent do
  @moduledoc """
  T2.2: the `aud_event` append-only event/audit tier.

  ## What this migration creates

    1. **`aud_event` partitioned parent table** (RANGE on `aud_occurred_at`).
    2. **`aud_event_y2026m07` first child partition** (July 2026 — current month at
       phase start).  `Samen.AuditEvent.PartitionManager` creates subsequent months.
    3. **BRIN index** on `aud_occurred_at` — a few-KB index over a huge append-only
       table (doc: "BRIN indexes on time columns").
    4. **Append-only trigger** `aud_event_append_only_tg` — raises on UPDATE/DELETE
       at the DB level (belt to the role-revocation braces).
    5. **REVOKE UPDATE, DELETE** on `aud_event` from the `clank` app role.
    6. **Catalog rows** (inserted in the SAME transaction as the DDL above) via raw
       SQL into `tam_table` and `fld_field`.

  ## Partitioned-table catalog handling

  `aud_event` is a PARTITIONED TABLE.  Its child partitions (`aud_event_y2026m07`,
  etc.) are NOT separate catalog entries — they are transparent storage shards of
  the parent's schema.  Only the PARENT table is registered in `tam_table`/`fld_field`.
  The catalog rows reflect the parent's column set, which every partition inherits.
  Queries to `information_schema.columns` for the parent table name return the correct
  shared column set without duplicating catalog entries per partition.  Child
  partitions created later by the partition manager do NOT need additional catalog rows.

  This is the key distinction for partitioned tables in the Samen catalog idiom:
  one tam_table row → one logical resource; child partitions are implementation detail.

  ## Why plain `use Ecto.Migration` (not `use Samen.Migration`)

  `Samen.Migration`'s `catalog_sync` macro introspects Ash resources
  (`AshPostgres.DataLayer.Info.table/1`, `Ash.Resource.Info.attributes/1`).  The
  `aud_event` table is kernel infrastructure backed by a plain `Ecto.Schema`
  (`Samen.AuditEvent`), not a full Ash resource.  So catalog rows are written via
  direct `execute/2` SQL inside this migration's transaction — the same atomicity
  guarantee applies (DDL + catalog INSERT share the same `BEGIN...COMMIT`).

  ## Role revocation (braces)

  `REVOKE UPDATE, DELETE ON aud_event FROM clank` makes the app role structurally
  incapable of mutating rows.  Any UPDATE or DELETE by the application fails with a
  Postgres permission error BEFORE the trigger even fires.

  In production, configure the least-privilege app role explicitly via
  `:aud_event_app_role`; this migration defaults to `"clank"` (the CI/dev role).

  ## Append-only trigger (belt)

  Even if an operator re-grants UPDATE/DELETE to the app role (or runs ad-hoc SQL as
  a superuser), the `BEFORE UPDATE OR DELETE` trigger raises an exception:
  `ERROR: aud_event is append-only; UPDATE/DELETE are not permitted`.

  ## Simulation note

  There is NO physical replica or Neon account in the CI environment.  This migration
  targets the local primary.  The T2.5 PITR game-day task is the operator TODO for
  Neon/replica wiring.
  """

  use Ecto.Migration

  # The Postgres role the application uses.  In CI this is "clank" (the local dev
  # role).  In production, configure the least-privilege app role explicitly.
  @app_role Application.compile_env(:samen_core, :aud_event_app_role, "clank")

  # Catalog row data for the parent `aud_event` table.
  # Only the PARENT is registered — child partitions inherit and are not catalogued.
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
    # -----------------------------------------------------------------------
    # (1) Parent partitioned table
    # -----------------------------------------------------------------------
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
    """
    DROP TABLE IF EXISTS aud_event
    """

    # -----------------------------------------------------------------------
    # (2) First child partition: July 2026 (current month at phase start).
    #     PartitionManager creates later months.
    # -----------------------------------------------------------------------
    execute """
    CREATE TABLE IF NOT EXISTS aud_event_y2026m07
    PARTITION OF aud_event
    FOR VALUES FROM ('2026-07-01 00:00:00+00') TO ('2026-08-01 00:00:00+00')
    """,
    """
    DROP TABLE IF EXISTS aud_event_y2026m07
    """

    # -----------------------------------------------------------------------
    # (3) BRIN index on the partition key column
    # -----------------------------------------------------------------------
    execute """
    CREATE INDEX aud_event_brin_occurred_at
    ON aud_event USING BRIN (aud_occurred_at)
    """,
    "DROP INDEX IF EXISTS aud_event_brin_occurred_at"

    # -----------------------------------------------------------------------
    # (4) Append-only trigger function + trigger
    # -----------------------------------------------------------------------
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

    # -----------------------------------------------------------------------
    # (5) Role revocation (braces — belt is the trigger above)
    # -----------------------------------------------------------------------
    # REVOKE is idempotent — safe even if the role does not hold the privilege.
    execute """
    REVOKE UPDATE, DELETE ON aud_event FROM #{@app_role}
    """,
    # On rollback: restore what we revoked.
    """
    GRANT UPDATE, DELETE ON aud_event TO #{@app_role}
    """

    # -----------------------------------------------------------------------
    # (6) Catalog rows for the PARENT partitioned table.
    #
    # Written in the SAME Ecto migration transaction as the DDL above — the
    # doc's "BEGIN; CREATE TABLE ...; INSERT INTO fld_field ...; COMMIT" atomicity
    # guarantee.  Child partitions inherit the schema and do NOT get separate rows.
    # -----------------------------------------------------------------------
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
    # Remove catalog rows first (reverse the INSERTs).
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

    # Drop child partition first (cannot drop parent while children exist).
    execute "DROP TABLE IF EXISTS aud_event_y2026m07"
    execute "DROP TABLE IF EXISTS aud_event"
  end
end
