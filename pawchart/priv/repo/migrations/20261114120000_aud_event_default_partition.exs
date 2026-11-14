defmodule PawChart.Repo.Migrations.AudEventDefaultPartition do
  @moduledoc """
  ARCH-9 — a DEFAULT partition for `aud_event`, so a row whose `aud_occurred_at` is in no monthly partition (a
  backdated or future-dated event, a missed roll-forward) lands there instead of failing the write. Audited
  writes are audit-or-refuse, so a missing partition used to block the business action it audited.

  The default is a safety net, not a destination: `Samen.AuditEvent.PartitionManager` reports every row that
  lands in it and moves it into the month's partition once that exists. See ADR-002 (amendment, ARCH-9).

  Idempotent (`IF NOT EXISTS`). The SQL is the framework's own (`default_partition_sql/0`), shared with the
  partition manager and the generated `aud_event` migration. `down` drops the default partition; it refuses
  (Postgres FK-free `DROP`) nothing, so run it only when the default holds no rows you need — rows in it are
  rows in no monthly partition, and are gone with it.
  """
  use Ecto.Migration

  def up do
    execute Samen.AuditEvent.PartitionManager.default_partition_sql(),
            "DROP TABLE IF EXISTS aud_event_default"
  end

  def down do
    execute "DROP TABLE IF EXISTS aud_event_default"
  end
end
