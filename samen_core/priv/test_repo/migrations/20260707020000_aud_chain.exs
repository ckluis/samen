defmodule SamenCore.TestRepo.Migrations.AudChain do
  @moduledoc """
  T4.3 (ADR-002): the `aud_chain` hash-chained, tenant-readable, operator-uneditable
  audit chain — the linked table (abbrev `ach`) that seals reveal/impersonation/erasure
  `aud_event` rows into a per-org tamper-evident hash chain.

  ## What this migration creates

    1. **`aud_chain` table** — one row per chained audit entry (ADR-002 §2.2). Not
       partitioned (its sequencing is per-org chain position, not time). Every column is
       `ach_`-prefixed (self-qualifying storage). `ach_subject_ciphertext` is `bytea` —
       the OPTIONAL per-subject **key-destroyable** ciphertext (AES-256-GCM under DEK_S);
       the chain hash commits only to its SHA-256 digest (`ach_ciphertext_sha256`), so a
       shred leaves the hash unchanged and the chain still verifies post-shred (§2.4).
    2. **UNIQUE (ach_org_id, ach_seq)** — the dense per-org chain sequence. A duplicate
       seq (a fork) is rejected at the DB level.
    3. **Index on (ach_org_id, ach_seq DESC)** — the tip lookup (`FOR UPDATE`) + the
       tenant-view ordered scan.
    4. **Append-only trigger** `aud_chain_append_only_tg` — raises on UPDATE/DELETE at the
       DB level (belt), REUSING the T2.2 `aud_event` pattern verbatim.
    5. **REVOKE UPDATE, DELETE** on `aud_chain` from the app role (braces) — the ops/app
       role literally cannot mutate a chain row.
    6. **Catalog rows** (same-transaction raw SQL) into `tam_table` / `fld_field`.

  ## Why append-only here matters differently than aud_event

  For `aud_event`, append-only preserves the event record. For `aud_chain` it ALSO makes
  the hash chain load-bearing: if the app role could UPDATE a row it could edit a payload
  AND recompute the hash to hide the edit. The REVOKE + trigger stop that; and even a
  party who CAN run DDL (drop + rebuild) is caught by the out-of-band WORM anchor
  (`verify_against_anchor`), not by this table's own enforcement (ADR-002 §3.3).

  Plain `use Ecto.Migration` (not `use Samen.Migration`) for the same reason as
  `aud_event`: this is kernel infra backed by a plain `Ecto.Schema` (`Samen.AuditChain.Entry`),
  so catalog rows are written via direct `execute/2` in the same transaction.
  """

  use Ecto.Migration

  @app_role Application.compile_env(:samen_core, :aud_event_app_role, "clank")

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
    # (1) The chain table.
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

    # (2) Dense per-org sequence — a duplicate seq (a fork) is rejected.
    execute """
    CREATE UNIQUE INDEX aud_chain_org_seq_uidx ON aud_chain (ach_org_id, ach_seq)
    """,
    "DROP INDEX IF EXISTS aud_chain_org_seq_uidx"

    # (3) Tip lookup + tenant-view ordered scan.
    execute """
    CREATE INDEX aud_chain_org_seq_desc_idx ON aud_chain (ach_org_id, ach_seq DESC)
    """,
    "DROP INDEX IF EXISTS aud_chain_org_seq_desc_idx"

    # (4) Append-only trigger (belt) — reuses the T2.2 aud_event pattern verbatim.
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

    # (5) Role revocation (braces).
    execute """
    REVOKE UPDATE, DELETE ON aud_chain FROM #{@app_role}
    """,
    "GRANT UPDATE, DELETE ON aud_chain TO #{@app_role}"

    # (6) Catalog rows (same-transaction).
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
