defmodule SamenCore.TestRepo.Migrations.MigrationMeta do
  @moduledoc """
  T2.4: the `samen_migration_meta` bake-window ledger.

  Written by expand migrations (`expand_setup(change_key: ...)`), read by the
  contract-phase gate (`contract_setup/1` / `contract_ready?/2`). See
  `Samen.Migration.Meta`.

  Plain `use Ecto.Migration` (like the catalog / aud_event / rollup tables) — this
  is kernel infrastructure, not an Ash resource, so it carries no catalog rows and
  is not scanned by the PII oracle (it holds only change keys, phases, timestamps,
  and migration module names — no subject data).
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
