defmodule Demo.Repo.Migrations.TntObjectRecord do
  @moduledoc """
  Bootstrap the Tier-2 tables on the demo app (T3.9; plan §DoD "Tier-0/1/2 work on
  the demo app"):

    * `tnt_object` — the org-scoped custom-object catalog (plain DDL).
    * `tnt_record` — the Tier-2 record table (`tnr_*`).

  These let the demo dogfood the Tier-2 ladder rung: define a custom object + its
  fields, validate an attribute bag, and run the tnt-catalog parity + one-way
  boundary verifiers. No FK from any demo system table into either table (the
  one-way boundary), which `mix samen.verify.tnt_boundary` asserts over the demo's
  scope domains.
  """
  use Samen.Migration

  def up do
    create_tnt_object_table()
    create_tnt_record_table()
  end

  def down do
    drop(table(:tnt_record))
    drop(table(:tnt_object))
  end
end
