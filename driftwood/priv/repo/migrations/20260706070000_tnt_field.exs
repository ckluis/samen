defmodule Driftwood.Repo.Migrations.TntField do
  @moduledoc """
  Bootstrap the `tnt_field` table — the Tier-1 tenant custom-field catalog
  (T3.8; vision doc §core "Every custom field is catalogued").

  The demo's CRM-scope resources (`Person`/`Company`/`Opportunity`) carry an
  `xxx_custom` jsonb bag, so the base macro wires `Samen.CustomFields.Change` onto
  them; that change validates every bag write against this table. It must exist
  before any such write.

  Like `tam_table`/`fld_field`, this is a plain Ecto DDL table (not an Ash
  resource): same bootstrap reasoning.
  """
  use Samen.Migration

  def up do
    create_tnt_field_table()
  end

  def down do
    drop(table(:tnt_field))
  end
end
