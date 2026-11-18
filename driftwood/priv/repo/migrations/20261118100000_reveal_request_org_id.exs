defmodule Driftwood.Repo.Migrations.RevealRequestOrgId do
  @moduledoc """
  A reveal request carries the tenant org its engine approval is filed under (`rvq_org_id`), so a request whose
  `pii_reveal` approval failed to open can be found by org and re-opened (ADR-040 s4.7, S6). Without it a
  `RevealRequest` names no org and nothing can sweep an org's orphans.

  Expand-style and additive: a NULLABLE column (a row filed before this migration, or filed with no org, stays
  NULL; the code never guesses one), and the index the queue's orphan scan reads, `(org, inserted_at, id)`.
  Existing rows: backfilled from the request's engine approval, literal SQL (no run-time derivation from resources).
    The table, columns and index name are LITERAL; the index is built CONCURRENTLY (no write lock) and idempotently (an
  INVALID leftover of the same name is dropped first).
  """
  use Samen.Migration, phase: :expand
  @disable_ddl_transaction true
  @disable_migration_lock true

  @index "rvq_reveal_request_org_inserted_at_id_idx"

  def up do
    execute("ALTER TABLE rvq_reveal_request ADD COLUMN IF NOT EXISTS rvq_org_id uuid")

    # Backfill from the engine approval filed for the request (its `subject_ref` is `samen:reveal.request:<id>`),
    # newest first. A request with no approval, or only a plane-global one, keeps NULL.
    execute("""
    UPDATE rvq_reveal_request r
       SET rvq_org_id = (SELECT a.fap_org_id
                           FROM fap_approval a
                          WHERE a.fap_kind = 'pii_reveal'
                            AND a.fap_org_id IS NOT NULL
                            AND a.fap_subject_ref = 'samen:reveal.request:' || r.rvq_id::text
                          ORDER BY a.fap_requested_at DESC NULLS LAST
                          LIMIT 1)
     WHERE r.rvq_org_id IS NULL
    """)

    Samen.Migration.ExpandContract.drop_invalid_index("rvq_reveal_request", @index)

    execute(
      "CREATE INDEX CONCURRENTLY IF NOT EXISTS #{@index} ON rvq_reveal_request (rvq_org_id, rvq_inserted_at, rvq_id)"
    )
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS #{@index}")
    execute("ALTER TABLE rvq_reveal_request DROP COLUMN IF EXISTS rvq_org_id")
  end
end
