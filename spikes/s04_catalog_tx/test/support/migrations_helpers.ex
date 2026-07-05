defmodule Samen.Migrations.Helpers do
  @moduledoc """
  Test-support helpers that seed / unseed the bootstrap catalog for exactly the
  columns the bootstrap migration created (id, name, org_id) — NOT com_phone,
  which a later migration adds together with its own catalog row.

  These call `Samen.Catalog` for the row shapes (so the seed stays consistent with
  introspection) but restrict to the bootstrap column set, then emit the same
  `execute` statements `Samen.Migration` uses. They run inside the bootstrap
  migration transaction.
  """
  import Ecto.Migration

  @bootstrap_columns ~w(com_id com_name com_org_id)

  def seed_bootstrap_catalog do
    resource = S04CatalogTx.Crm.Contact
    tam = Samen.Catalog.table(resource)

    execute(
      "INSERT INTO tam_table (tam_table_name, tam_resource) VALUES " <>
        "('#{tam.table_name}', '#{tam.resource}') ON CONFLICT (tam_table_name) DO NOTHING"
    )

    resource
    |> Samen.Catalog.fields()
    |> Enum.filter(&(&1.column_name in @bootstrap_columns))
    |> Enum.each(fn fld ->
      execute(
        "INSERT INTO fld_field (fld_table_name, fld_column_name, fld_logical_name, fld_type) " <>
          "VALUES ('#{fld.table_name}', '#{fld.column_name}', '#{fld.logical_name}', '#{fld.type}') " <>
          "ON CONFLICT (fld_table_name, fld_column_name) DO NOTHING"
      )
    end)
  end

  def unseed_bootstrap_catalog do
    execute("DELETE FROM fld_field WHERE fld_table_name = 'com_contact'")
    execute("DELETE FROM tam_table WHERE tam_table_name = 'com_contact'")
  end
end
