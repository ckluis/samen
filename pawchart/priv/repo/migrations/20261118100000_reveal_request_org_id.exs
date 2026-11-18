defmodule PawChart.Repo.Migrations.RevealRequestOrgId do
  @moduledoc """
  A reveal request carries the tenant org its engine approval is filed under (`rvq_org_id`), so a request whose
  `pii_reveal` approval failed to open can be found by org and re-opened (ADR-040 s4.7, S6). Without it a
  `RevealRequest` names no org and nothing can sweep an org's orphans.

  Expand-style and additive: a NULLABLE column (a row filed before this migration, or filed with no org, stays
  NULL; the code never guesses one), and the index the queue's orphan scan reads, `(org, inserted_at, id)`.
  This host has no approvals table, so there is nothing to backfill from: existing rows stay NULL.
    The table, columns and index name are LITERAL; the index is built CONCURRENTLY (no write lock) and idempotently (an
  INVALID leftover of the same name is dropped first).
  """
  use Samen.Migration, phase: :expand
  @disable_ddl_transaction true
  @disable_migration_lock true

  @index "rvq_reveal_request_org_inserted_at_id_idx"

  def up do
    execute("ALTER TABLE rvq_reveal_request ADD COLUMN IF NOT EXISTS rvq_org_id uuid")

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
