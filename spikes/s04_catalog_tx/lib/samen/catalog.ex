defmodule Samen.Catalog do
  @moduledoc """
  Introspects `Ash.Resource.Info` into the shape the machine catalog records.

  The catalog is the doc's "data dictionary for machines": `tam_table` names every
  physical table, `fld_field` names every physical column, both keyed on the
  *storage* names (abbrev-prefixed by the S0.2 transformer) so a catalog row is a
  faithful description of what actually exists in Postgres.

  This module is pure: it turns a resource module into row descriptions. The
  transaction coupling (writing these rows in the SAME migration transaction as
  the DDL) lives in `Samen.Migration`. Keeping introspection pure is what lets
  the acceptance test assert "catalog contents match `Ash.Resource.Info`" by
  comparing DB rows against `Samen.Catalog.fields/1` directly.
  """

  @doc """
  The `tam_table` row for a resource: `{table_name, resource_module_string}`.
  """
  def table(resource) do
    %{
      table_name: table_name(resource),
      resource: inspect(resource)
    }
  end

  @doc """
  The physical table name (from the AshPostgres data layer config).
  """
  def table_name(resource) do
    AshPostgres.DataLayer.Info.table(resource)
  end

  @doc """
  The `fld_field` rows for a resource — one per physical column, keyed on the
  abbrev-prefixed storage name (`attribute.source`), NOT the logical name.

  Each row carries `{table_name, column_name, logical_name, type}` so the catalog
  is self-qualifying: a machine reading `fld_field` sees exactly the column that
  exists in the DB.
  """
  def fields(resource) do
    tbl = table_name(resource)

    resource
    |> Ash.Resource.Info.attributes()
    |> Enum.map(fn attr ->
      %{
        table_name: tbl,
        column_name: to_string(attr.source || attr.name),
        logical_name: to_string(attr.name),
        type: type_string(attr.type)
      }
    end)
    |> Enum.sort_by(& &1.column_name)
  end

  defp type_string(type) when is_atom(type) do
    type |> inspect() |> String.trim_leading("Ash.Type.")
  end

  defp type_string(type), do: inspect(type)
end
