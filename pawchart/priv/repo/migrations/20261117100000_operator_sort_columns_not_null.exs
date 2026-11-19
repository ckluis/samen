defmodule PawChart.Repo.Migrations.OperatorSortColumnsNotNull do
  @moduledoc """
  `pmp_plan.pmp_name` and `pqk_ticket.pqk_subject` are the keyset sort columns of `PawChart.Operator.Plan` and
  `PawChart.Operator.Ticket` (`keyset_sort :name` / `:subject`), and both attributes say `allow_nil? false` — but the
  columns were created nullable by the original operator mount (`20260807120000_mount_operator_scopes.exs`; the generator's
  template, `m_mount_operator_scopes.eex`, already says `null: false`). Over a nullable column the ascending keyset cursor
  gets no index bound and the schema lies about what the resource accepts (`mix samen.verify.indexes` now fails on it).

  `Samen.Migration.ExpandContract.set_not_null/4` runs `CHECK (col IS NOT NULL) NOT VALID` (so no new NULL can be written)
  -> the backfill -> a NULL count -> `VALIDATE` -> `SET NOT NULL` + drop the check, outside the DDL transaction and with each
  ACCESS EXCLUSIVE statement under `lock_timeout`, so no long scan and no queue behind a long transaction.

    * `pmp_plan.pmp_name` — a NULL plan name is filled from the plan's own display label, else its provider plan ref
      (both are the plan's identity as the operator wrote it; an empty or blank one is not a name). A plan with neither is
      NOT given an invented name: the migration stops, naming the count. The plans the expression COULD answer for keep
      their backfilled `pmp_name` (those batches are committed): a stop leaves the column's definition untouched, not the
      data.
    * `pqk_ticket.pqk_subject` — no other column of a ticket says what it is about, and the resource itself refuses an empty
      subject, so there is no correct value to backfill. A NULL subject stops the migration, naming the count (rows that
      `Ash` created always carry one).

  Reversible: `down` drops the NOT NULLs again (a backfilled name stays).

  Declared `phase: :expand` on purpose, although narrowing a column is a contract-style change: the Ash attributes already
  refuse nil, so no old binary writes a NULL, there is no bake window to wait for, and `:expand` keeps `down/0` under the
  `DownCheck` coverage. The migration lock is NOT disabled: two nodes migrating at once would otherwise run `set_not_null/4`
  on the same table together, and one's `DROP CONSTRAINT IF EXISTS` would remove the other's freshly added check.
  """
  use Samen.Migration, phase: :expand
  @disable_ddl_transaction true

  def up do
    set_not_null(repo(), "pmp_plan", "pmp_name", backfill: "COALESCE(NULLIF(btrim(pmp_label), ''), NULLIF(btrim(pmp_provider_plan_ref), ''))")
    set_not_null(repo(), "pqk_ticket", "pqk_subject")
  end

  def down do
    drop_not_null(repo(), "pqk_ticket", "pqk_subject")
    drop_not_null(repo(), "pmp_plan", "pmp_name")
  end
end
