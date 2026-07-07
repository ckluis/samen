defmodule Driftwood.Repo.Migrations.MigrationMeta do
  @moduledoc """
  T2.4: bootstrap the `samen_migration_meta` bake-window ledger for the demo.

  Written by expand migrations (`expand_setup(change_key: ...)`), read by the
  contract-phase gate (`contract_setup/1`). Kernel infrastructure — no catalog rows,
  holds only change keys / phases / timestamps / migration names (no subject data).
  """
  use Ecto.Migration

  def up do
    execute(
      Samen.Migration.Meta.create_table_sql(),
      Samen.Migration.Meta.drop_table_sql()
    )
  end

  def down do
    execute(Samen.Migration.Meta.drop_table_sql())
  end
end
