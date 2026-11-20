defmodule Driftwood.Repo.Migrations.ApiKeyDigestUnique do
  @moduledoc """
  API-key digest uniqueness — the auth lookup (`token_digest == ^digest`) assumes one row per digest, and a
  duplicate makes it error (a 503: fail-closed, but an availability hole). The invariant belongs in the
  database, not in the minting code's luck: `dak_api_key.dak_token_digest` (`Driftwood.Freight.ApiKey`, the public `/api/v1` lookup) and `dok_api_key.dok_token_digest` (the operator Identity mount's `ApiKey`). The unique index on `dak_api_key` replaces the plain lookup index the freight migration created (dropped here, rebuilt by `down`).

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
    concurrent_unique_index(:dak_api_key, :dak_token_digest, name: "dak_api_key_token_digest_uidx")
    # the plain index it replaces (created by 20260708100000_freight_api_key) is now a strict subset of the
    # unique one: same column, and the planner uses the unique index for the same lookup
    execute("DROP INDEX CONCURRENTLY IF EXISTS dak_api_key_dak_token_digest_index")
    concurrent_unique_index(:dok_api_key, :dok_token_digest, name: "dok_api_key_token_digest_uidx")
  end

  def down do
    # put the plain lookup index back before the unique one goes, so the lookup is never without an index
    concurrent_index(:dak_api_key, [:dak_token_digest], name: "dak_api_key_dak_token_digest_index")
    execute("DROP INDEX CONCURRENTLY IF EXISTS dak_api_key_token_digest_uidx")
    execute("DROP INDEX CONCURRENTLY IF EXISTS dok_api_key_token_digest_uidx")
  end
end
