defmodule SamenCore.TestRepo.Migrations.TntField do
  @moduledoc """
  Bootstrap the `tnt_field` table — the Tier-1 tenant custom-field catalog
  (T3.8; vision doc §core "Every custom field is catalogued").

  Like `tam_table`/`fld_field`, `tnt_field` is a plain Ecto DDL table (not an
  Ash resource): same bootstrap reasoning. Unlike `fld_field` (system columns),
  `tnt_field` is org-scoped — one row per `(org, table, field)` custom-field
  definition. No FK from any system table references bag *content*; the jsonb
  zone is sealed.
  """
  use Samen.Migration

  def up do
    create_tnt_field_table()
  end

  def down do
    drop(table(:tnt_field))
  end
end
