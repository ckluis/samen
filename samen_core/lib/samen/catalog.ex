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

  ## Bootstrap

  The catalog tables (`tam_table` and `fld_field`) are plain Ecto DDL tables, not
  Ash resources — this avoids a bootstrap chicken-and-egg (you cannot write catalog
  rows for the catalog tables themselves using the catalog mechanism). The DDL is
  emitted by `Samen.Migration.create_catalog_tables/0` from the bootstrap migration,
  which must run *before* any resource tables are created (spike note F5).
  """

  use Spark.Dsl.Extension

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

  Rows are sorted by `column_name` for deterministic ordering (used by `catalog.dump`).
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

  @doc """
  All Ash resources registered in the given domain(s) that have an AshPostgres
  data layer (i.e. have a physical table). Returns deduplicated modules.
  """
  def resource_modules(domains) when is_list(domains) do
    domains
    |> Enum.flat_map(&Ash.Domain.Info.resources/1)
    |> Enum.filter(&has_postgres_table?/1)
    |> Enum.uniq()
  end

  def resource_modules(domain), do: resource_modules([domain])

  defp has_postgres_table?(resource) do
    # Only resources backed by AshPostgres have a physical table name
    try do
      table = AshPostgres.DataLayer.Info.table(resource)
      is_binary(table) and byte_size(table) > 0
    rescue
      _ -> false
    end
  end

  defp type_string(type) when is_atom(type) do
    type |> inspect() |> String.trim_leading("Ash.Type.")
  end

  defp type_string(type), do: inspect(type)
end
