defmodule Samen.MultiNode.Repo do
  @moduledoc """
  A SECOND Ecto/AshPostgres repo, used ONLY by the L4 multi-node Oban proof
  (T90; `test/multinode/oban_multinode_test.exs`).

  Unlike `SamenCore.TestRepo` (which runs under the SQL sandbox, so its
  connections are private per-test and Oban producers cannot actually execute),
  this repo points at a DEDICATED database (`samen_core_multinode_test`) with the
  NORMAL connection pool — no sandbox. That is the whole point: two real BEAM
  nodes both open real pooled connections to ONE Postgres and run real Oban
  producers against the same `oban_jobs` table. Exactly-once and leadership are
  then properties of Postgres (`SELECT … FOR UPDATE SKIP LOCKED`, the unique
  index, `Oban.Peer` DB leadership), which is precisely the production topology.

  Schema is migrated from the SAME migration set as `SamenCore.TestRepo`
  (`priv/test_repo/migrations`), so there is zero schema drift between the proof
  DB and the kernel test DB.
  """
  use AshPostgres.Repo, otp_app: :samen_core

  @impl true
  def installed_extensions do
    ["ash-functions", AshMoney.AshPostgresExtension]
  end

  @impl true
  def min_pg_version do
    %Version{major: 14, minor: 0, patch: 0}
  end
end
