defmodule PawChart.Repo.Migrations.OperatorTicketBreachedNotNull do
  @moduledoc """
  `PawChart.Operator.Ticket` declares `breached` as `allow_nil? false, default: false`, but the original operator mount
  (`20260807120000_mount_operator_scopes.exs`) created `pqk_ticket.pqk_breached` as a plain nullable column with no default
  (the generator's template, `m_mount_operator_scopes.eex`, and every other host already say `default: false, null: false`).
  `mix samen.verify.indexes` noted the mismatch, and a row written by raw SQL carried a NULL that the SLA sweep
  (`breached = false`) never matches.

  In order: `SET DEFAULT false` (so a writer that omits the column gets false), then
  `Samen.Migration.ExpandContract.set_not_null/4` with the literal backfill `false` (NULL -> false), which refuses new NULLs
  first, validates, then sets NOT NULL outside the DDL transaction under `lock_timeout`.

  Reversible: `down` drops the NOT NULL and the default again (a backfilled false stays). Declared `phase: :expand` for the
  same reason as `20261117100000_operator_sort_columns_not_null.exs`: the Ash attribute already refuses nil, so no old
  binary writes a NULL, and `:expand` keeps `down/0` under the `DownCheck` coverage.
  """
  use Samen.Migration, phase: :expand
  @disable_ddl_transaction true

  def up do
    repo().query!("ALTER TABLE pqk_ticket ALTER COLUMN pqk_breached SET DEFAULT false")
    set_not_null(repo(), "pqk_ticket", "pqk_breached", backfill: "false")
  end

  def down do
    drop_not_null(repo(), "pqk_ticket", "pqk_breached")
    repo().query!("ALTER TABLE pqk_ticket ALTER COLUMN pqk_breached DROP DEFAULT")
  end
end
