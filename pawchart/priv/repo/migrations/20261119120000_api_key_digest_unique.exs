defmodule PawChart.Repo.Migrations.ApiKeyDigestUnique do
  @moduledoc """
  API-key digest uniqueness — the auth lookup (`token_digest == ^digest`) assumes one row per digest, and a
  duplicate makes it error (a 503: fail-closed, but an availability hole). The invariant belongs in the
  database, not in the minting code's luck: `pok_api_key.pok_token_digest` (`PawChart.Operator.ApiKey`, which the MCP key resolver reads).

  Table, column and index name are LITERAL: this migration means the same thing forever. Built
  `CONCURRENTLY` (no write lock on a populated table, hence `@disable_ddl_transaction true`; an index is not a
  catalogued object, so no `catalog_sync`); a same-named INVALID leftover is dropped before the build. If the
  table already holds a duplicate digest the migration RAISES, naming the table and column; it deletes nothing
  and prints no digest, so a person resolves the duplicates and runs it again.
  """
  use Samen.Migration, phase: :expand
  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    concurrent_unique_index(:pok_api_key, :pok_token_digest, name: "pok_api_key_token_digest_uidx")
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS pok_api_key_token_digest_uidx")
  end
end
