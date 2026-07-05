defmodule Samen.Migration do
  @moduledoc """
  `Samen.Migration` — the catalog-in-migration-transaction mechanism (from S0.4).
  Reused here to set up the fixture schema for the S0.6 verifier spike.
  """

  defmacro __using__(opts) do
    quote do
      use Ecto.Migration, unquote(opts)
      import Samen.Migration, only: [catalog_sync: 1, catalog_sync: 2, create_catalog_tables: 0]
    end
  end

  @doc """
  Create the catalog storage tables. Call this from the bootstrap migration.
  """
  defmacro create_catalog_tables do
    quote do
      create table(:tam_table, primary_key: false) do
        add(:tam_id, :uuid, primary_key: true, null: false, default: fragment("gen_random_uuid()"))
        add(:tam_table_name, :text, null: false)
        add(:tam_resource, :text, null: false)
      end

      create(unique_index(:tam_table, [:tam_table_name], name: "tam_table_name_index"))

      create table(:fld_field, primary_key: false) do
        add(:fld_id, :uuid, primary_key: true, null: false, default: fragment("gen_random_uuid()"))
        add(:fld_table_name, :text, null: false)
        add(:fld_column_name, :text, null: false)
        add(:fld_logical_name, :text, null: false)
        add(:fld_type, :text, null: false)
      end

      create(
        unique_index(:fld_field, [:fld_table_name, :fld_column_name],
          name: "fld_field_table_column_index"
        )
      )
    end
  end

  @doc "See `catalog_sync/2`."
  defmacro catalog_sync(resources) do
    quote do
      Samen.Migration.__catalog_sync__(unquote(resources), [])
    end
  end

  @doc """
  Reconcile the catalog to the current `Ash.Resource.Info` for `resources`.
  """
  defmacro catalog_sync(resources, opts) do
    quote do
      Samen.Migration.__catalog_sync__(unquote(resources), unquote(opts))
    end
  end

  @doc false
  def __catalog_sync__(resources, opts) do
    resources
    |> List.wrap()
    |> Enum.each(&sync_resource(&1, opts))
  end

  defp sync_resource(resource, opts) do
    only = Keyword.get(opts, :only)
    tam = Samen.Catalog.table(resource)

    flds =
      resource
      |> Samen.Catalog.fields()
      |> filter_fields(only)

    tam_down = if only, do: "SELECT 1", else: delete_tam_sql(tam)
    Ecto.Migration.execute(insert_tam_sql(tam), tam_down)

    Enum.each(flds, fn fld ->
      Ecto.Migration.execute(
        insert_fld_sql(fld),
        delete_fld_sql(fld)
      )
    end)
  end

  defp filter_fields(fields, nil), do: fields

  defp filter_fields(fields, only) when is_list(only) do
    wanted = MapSet.new(Enum.map(only, &to_string/1))
    Enum.filter(fields, &(&1.logical_name in wanted))
  end

  defp insert_tam_sql(%{table_name: t, resource: r}) do
    "INSERT INTO tam_table (tam_table_name, tam_resource) VALUES " <>
      "(#{q(t)}, #{q(r)}) ON CONFLICT (tam_table_name) DO NOTHING"
  end

  defp delete_tam_sql(%{table_name: t}) do
    "DELETE FROM tam_table WHERE tam_table_name = #{q(t)}"
  end

  defp insert_fld_sql(%{table_name: t, column_name: c, logical_name: l, type: ty}) do
    "INSERT INTO fld_field (fld_table_name, fld_column_name, fld_logical_name, fld_type) VALUES " <>
      "(#{q(t)}, #{q(c)}, #{q(l)}, #{q(ty)}) ON CONFLICT (fld_table_name, fld_column_name) DO NOTHING"
  end

  defp delete_fld_sql(%{table_name: t, column_name: c}) do
    "DELETE FROM fld_field WHERE fld_table_name = #{q(t)} AND fld_column_name = #{q(c)}"
  end

  defp q(value) do
    escaped = value |> to_string() |> String.replace("'", "''")
    "'" <> escaped <> "'"
  end
end
