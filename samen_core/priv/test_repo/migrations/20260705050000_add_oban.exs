defmodule SamenCore.TestRepo.Migrations.AddOban do
  @moduledoc """
  Installs Oban's versioned tables (T1.6 dep on T2.1; T2.1 can be stubbed with
  plain Oban per the plan row). The reveal-grant auto-revoke job (T1.6 clause (d))
  is enqueued IN THE SAME TRANSACTION that writes the grant, so a grant insert
  that rolls back leaves no orphan `oban_jobs` row. That same-tx guarantee needs
  the `oban_jobs` table to exist — this migration creates it.
  """
  use Ecto.Migration

  def up, do: Oban.Migrations.up()

  def down, do: Oban.Migrations.down()
end
