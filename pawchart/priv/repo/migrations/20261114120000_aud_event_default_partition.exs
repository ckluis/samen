defmodule PawChart.Repo.Migrations.AudEventDefaultPartition do
  @moduledoc """
  ARCH-9 — a DEFAULT partition for `aud_event`, so a row whose `aud_occurred_at` is in no monthly partition (a
  backdated or future-dated event, a missed roll-forward) lands there instead of failing the write. Audited
  writes are audit-or-refuse, so a missing partition used to block the business action it audited.

  The default is a safety net, not a destination: `Samen.AuditEvent.PartitionManager` reports every row that
  lands in it and moves it into the month's partition once that exists. See ADR-002 (amendment, ARCH-9).

  Idempotent (`IF NOT EXISTS`). The SQL is the framework's own (`default_partition_sql/0`), shared with the
  partition manager and the generated `aud_event` migration. `down` drops the default partition, and RAISES (rolling the migration back) when it holds
  any row: those rows are in no monthly partition, so dropping the table would destroy audit events nothing else
  holds. Move them first (create the missing months with `Samen.AuditEvent.PartitionManager.ensure_partition/2`,
  which moves the rows in) and run the rollback again.
  """
  use Ecto.Migration

  def up do
    # CREATE … PARTITION OF takes ACCESS EXCLUSIVE on aud_event: give up (the deploy fails, nothing queues) rather
    # than park every audited write behind one long reader. Transaction-scoped; same bound as expand_contract.
    execute "SET LOCAL lock_timeout = '5s'"

    execute Samen.AuditEvent.PartitionManager.default_partition_sql(),
            "DROP TABLE IF EXISTS aud_event_default"
  end

  def down do
    # The guard locks the PARENT first (the order an audited write takes: parent, then partition), so it cannot
    # deadlock with a writer, and gives up instead of queueing every audited write behind it. Transaction-scoped.
    execute "SET LOCAL lock_timeout = '5s'"

    # refuses (raises) while the DEFAULT partition holds rows; the SQL is the framework's, shared by every host
    execute Samen.AuditEvent.PartitionManager.default_partition_down_guard_sql()

    execute "DROP TABLE IF EXISTS aud_event_default"
  end
end
