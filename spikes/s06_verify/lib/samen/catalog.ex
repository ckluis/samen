defmodule Samen.Catalog do
  @moduledoc """
  Introspects `Ash.Resource.Info` into the shape the machine catalog records.

  Pure module: turns a resource module into catalog row descriptions. The
  transaction coupling lives in `Samen.Migration`. Keeping introspection pure
  lets the verifier compare DB rows against `Samen.Catalog.fields/1` directly.
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
