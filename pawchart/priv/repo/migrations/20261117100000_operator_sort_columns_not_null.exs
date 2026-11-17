defmodule PawChart.Repo.Migrations.OperatorSortColumnsNotNull do
  @moduledoc """
  `pmp_plan.pmp_name` and `pqk_ticket.pqk_subject` are the keyset sort columns of `PawChart.Operator.Plan` and
  `PawChart.Operator.Ticket` (`keyset_sort :name` / `:subject`), and both attributes say `allow_nil? false` — but the
  columns were created nullable by the original operator mount (`20260807120000_mount_operator_scopes.exs`; the generator's
  template, `m_mount_operator_scopes.eex`, already says `null: false`). Over a nullable column the ascending keyset cursor
  gets no index bound and the schema lies about what the resource accepts (`mix samen.verify.indexes` now fails on it).

  `Samen.Migration.ExpandContract.set_not_null/4` runs `CHECK (col IS NOT NULL) NOT VALID` -> `VALIDATE` -> `SET NOT NULL`
  -> drop the check, outside the DDL transaction, so no long ACCESS EXCLUSIVE scan.

    * `pmp_plan.pmp_name` — a NULL plan name is filled from the plan's own display label, else its provider plan ref
      (both are the plan's identity as the operator wrote it). A plan with neither is NOT given an invented name: the
      migration stops, naming the count.
    * `pqk_ticket.pqk_subject` — no other column of a ticket says what it is about, and the resource itself refuses an empty
      subject, so there is no correct value to backfill. A NULL subject stops the migration, naming the count (rows that
      `Ash` created always carry one).

  Reversible: `down` drops the NOT NULLs again (a backfilled name stays).
  """
  use Samen.Migration, phase: :expand
  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    set_not_null(repo(), "pmp_plan", "pmp_name", backfill: "COALESCE(pmp_label, pmp_provider_plan_ref)")
    set_not_null(repo(), "pqk_ticket", "pqk_subject")
  end

  def down do
    drop_not_null(repo(), "pqk_ticket", "pqk_subject")
    drop_not_null(repo(), "pmp_plan", "pmp_name")
  end
end
