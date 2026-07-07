defmodule Demo.Repo.Migrations.AudChain do
  @moduledoc """
  T4.3 (ADR-002): the `aud_chain` hash-chained, tenant-readable, operator-uneditable
  audit chain for the demo app.

  Mirrors `SamenCore.TestRepo.Migrations.AudChain` — same DDL, same append-only
  enforcement (role REVOKE + trigger), same catalog rows. See that module for full
  documentation.

  Demo-specific: app role is `"clank"` (the local dev/CI Postgres user).
  """

  use Ecto.Migration

  @app_role Application.compile_env(:demo, :aud_event_app_role, "clank")

  @resource "Samen.AuditChain.Entry"
  @table "aud_chain"
  @fields [
    {"ach_id", "id", "UUID"},
    {"ach_org_id", "org_id", "String"},
    {"ach_seq", "seq", "Integer"},
    {"ach_prior_hash", "prior_hash", "String"},
    {"ach_hash", "hash", "String"},
    {"ach_aud_id", "aud_id", "UUID"},
    {"ach_event_type", "event_type", "String"},
    {"ach_subject_id", "subject_id", "String"},
    {"ach_actor_id", "actor_id", "String"},
    {"ach_correlation_id", "correlation_id", "String"},
    {"ach_detail", "detail", "String"},
    {"ach_occurred_at", "occurred_at", "UTCDatetime"},
    {"ach_ciphertext_sha256", "ciphertext_sha256", "String"},
    {"ach_subject_ciphertext", "subject_ciphertext", "Binary"},
    {"ach_inserted_at", "inserted_at", "UTCDatetime"}
  ]

  def up do
    execute """
    CREATE TABLE aud_chain (
      ach_id                  UUID        NOT NULL DEFAULT gen_random_uuid(),
      ach_org_id              TEXT        NOT NULL,
      ach_seq                 BIGINT      NOT NULL,
      ach_prior_hash          TEXT        NOT NULL,
      ach_hash                TEXT        NOT NULL,
      ach_aud_id              UUID,
      ach_event_type          TEXT        NOT NULL,
      ach_subject_id          TEXT,
      ach_actor_id            TEXT,
      ach_correlation_id      TEXT,
      ach_detail              TEXT,
      ach_occurred_at         TIMESTAMPTZ NOT NULL,
      ach_ciphertext_sha256   TEXT        NOT NULL,
      ach_subject_ciphertext  BYTEA,
      ach_inserted_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
      PRIMARY KEY (ach_id)
    )
    """,
    "DROP TABLE IF EXISTS aud_chain"

    execute """
    CREATE UNIQUE INDEX aud_chain_org_seq_uidx ON aud_chain (ach_org_id, ach_seq)
    """,
    "DROP INDEX IF EXISTS aud_chain_org_seq_uidx"

    execute """
    CREATE INDEX aud_chain_org_seq_desc_idx ON aud_chain (ach_org_id, ach_seq DESC)
    """,
    "DROP INDEX IF EXISTS aud_chain_org_seq_desc_idx"

    execute """
    CREATE OR REPLACE FUNCTION aud_chain_enforce_append_only()
    RETURNS TRIGGER LANGUAGE plpgsql AS $$
    BEGIN
      RAISE EXCEPTION 'aud_chain is append-only: UPDATE and DELETE are not permitted. '
        'Chain entry id: %, org: %, seq: %',
        COALESCE(OLD.ach_id::text, '?'),
        COALESCE(OLD.ach_org_id, '?'),
        COALESCE(OLD.ach_seq::text, '?');
    END;
    $$
    """,
    "DROP FUNCTION IF EXISTS aud_chain_enforce_append_only()"

    execute """
    CREATE TRIGGER aud_chain_append_only_tg
    BEFORE UPDATE OR DELETE ON aud_chain
    FOR EACH ROW EXECUTE FUNCTION aud_chain_enforce_append_only()
    """,
    "DROP TRIGGER IF EXISTS aud_chain_append_only_tg ON aud_chain"

    execute """
    REVOKE UPDATE, DELETE ON aud_chain FROM #{@app_role}
    """,
    "GRANT UPDATE, DELETE ON aud_chain TO #{@app_role}"

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

    execute "GRANT UPDATE, DELETE ON aud_chain TO #{@app_role}"
    execute "DROP TRIGGER IF EXISTS aud_chain_append_only_tg ON aud_chain"
    execute "DROP FUNCTION IF EXISTS aud_chain_enforce_append_only()"
    execute "DROP INDEX IF EXISTS aud_chain_org_seq_desc_idx"
    execute "DROP INDEX IF EXISTS aud_chain_org_seq_uidx"
    execute "DROP TABLE IF EXISTS aud_chain"
  end
end
