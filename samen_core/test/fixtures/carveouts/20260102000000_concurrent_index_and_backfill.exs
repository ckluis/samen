defmodule Samen.Carveouts.ConcurrentIndexAndBackfill do
  @moduledoc """
  The expand-phase carve-outs that run OUTSIDE the DDL transaction (doc §runs 2b):
  a CREATE INDEX CONCURRENTLY build and a chunked backfill. Requires
  `@disable_ddl_transaction true` (which is why it must NOT call catalog_sync — the
  paired-migration composition with T1.2).
  """
  use Samen.Migration, phase: :expand
  @disable_ddl_transaction true

  def up do
    # No expand_setup here: SET LOCAL is transaction-scoped and this migration runs
    # outside a transaction. The carve-outs deliberately have no statement_timeout so
    # the 15s ceiling can't abort a large index build or backfill.
    concurrent_index(:cov_widget, [:cov_name], name: "cov_widget_name_cidx")

    chunked_backfill(repo(), :cov_widget, "cov_backfilled = cov_name",
      column: :cov_backfilled,
      chunk_size: 10
    )
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS cov_widget_name_cidx")
  end
end
