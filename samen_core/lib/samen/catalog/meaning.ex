defmodule Samen.Catalog.Meaning do
  @moduledoc """
  Pure readers for the MEANING of a resource and its fields (ADR-043 §8a): what the catalog dump
  (`mix samen.catalog.dump`) and the AI catalogue (`Samen.AI.Catalog`) expose beside the structural facts.

  Meaning is author-written schema text and code constants, never a row value. It is read from:

    * Ash's native `description` — on the resource (`resource do description … end`), on an attribute, on a
      relationship — plus `pii_attribute … description:` (carried onto the materialized attribute) and the one-time
      descriptions the framework transformers put on `id`, `org_id`, `inserted_at`, `updated_at`, `archived_at`
      and the `custom` bag;
    * the `meaning do … end` section of `Samen.Catalog` (label, synonyms, units);
    * DERIVED facts: `allowed_values` from `one_of` (or an `Ash.Type.Enum`), `max_length` from the constraint, and
      `units` from the TYPE when it fixes them (`samen_catalog_units/1`: Money, Percent, Duration).

  A `belongs_to` source attribute (`company_id`) is described by its relationship's description unless it carries its own.
  An empty or whitespace-only description counts as MISSING (`nil`): ash_paper_trail copies `attr.description || ""`
  into every Version resource.

  This module never touches `Samen.Catalog.fields/1` or the `tam_table`/`fld_field` rows: meaning lives in code, not in
  the database.
  """

  @type field_meaning :: %{
          description: String.t() | nil,
          label: String.t(),
          synonyms: [String.t()],
          units: String.t() | nil,
          allowed_values: [String.t()] | nil,
          max_length: non_neg_integer() | nil
        }

  @type table_meaning :: %{description: String.t() | nil, label: String.t(), synonyms: [String.t()]}

  @typedoc "A resource module, or the Spark DSL state of one still being compiled (the compile-time check reads both)."
  @type source :: module() | map()

  @doc "The resource-level meaning: description (or `nil`), label, synonyms."
  @spec table(source()) :: table_meaning()
  def table(resource) do
    %{
      description: blank_to_nil(Ash.Resource.Info.description(resource)),
      label: blank_to_nil(opt(resource, :label)) || humanize_module(resource),
      synonyms: opt(resource, :synonyms) || []
    }
  end

  @doc """
  The meaning of EVERY attribute of `resource`, keyed by its logical name string (the `logical_name` the catalog
  records), in attribute declaration order.
  """
  @spec fields(source()) :: %{String.t() => field_meaning()}
  def fields(resource) do
    authored = Map.new(Spark.Dsl.Extension.get_entities(resource, [:meaning]), &{&1.name, &1})
    fk_descriptions = fk_descriptions(resource)

    Map.new(Ash.Resource.Info.attributes(resource), fn attr ->
      entry = Map.get(authored, attr.name)

      {to_string(attr.name),
       %{
         description: blank_to_nil(attr.description) || Map.get(fk_descriptions, attr.name),
         label: (entry && blank_to_nil(entry.label)) || humanize(attr.name),
         synonyms: (entry && entry.synonyms) || [],
         units: fixed_units(attr.type, attr.constraints) || (entry && blank_to_nil(entry.units)),
         allowed_values: allowed_values(attr.type, attr.constraints || []),
         max_length: max_length(attr.constraints || [])
       }}
    end)
  end

  @doc "The description of each relationship (`nil` when missing), keyed by relationship name string."
  @spec relationship_descriptions(source()) :: %{String.t() => String.t() | nil}
  def relationship_descriptions(resource) do
    Map.new(Ash.Resource.Info.relationships(resource), fn rel ->
      {to_string(rel.name), blank_to_nil(rel.description)}
    end)
  end

  @doc """
  The units a TYPE fixes by itself (`samen_catalog_units/1` on the type module), or `nil` when it fixes none. An
  authored `units` on such a type is refused at compile time.
  """
  @spec fixed_units(term(), keyword() | nil) :: String.t() | nil
  def fixed_units(type, constraints) when is_atom(type) and not is_nil(type) do
    if compiled?(type) and function_exported?(type, :samen_catalog_units, 1) do
      type.samen_catalog_units(constraints || [])
    end
  end

  def fixed_units(_type, _constraints), do: nil

  @doc "Whether `type` fixes its own units (see `fixed_units/2`)."
  @spec fixes_units?(term()) :: boolean()
  def fixes_units?(type) when is_atom(type) and not is_nil(type) do
    compiled?(type) and function_exported?(type, :samen_catalog_units, 1)
  end

  def fixes_units?(_type), do: false

  @doc "`nil` for a missing, empty or whitespace-only string; the string otherwise."
  @spec blank_to_nil(term()) :: String.t() | nil
  def blank_to_nil(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  def blank_to_nil(_), do: nil

  @doc ~S|Humanizes a logical name: `:close_date` -> "Close date".|
  @spec humanize(atom() | String.t()) :: String.t()
  def humanize(name) do
    name |> to_string() |> String.replace("_", " ") |> String.trim() |> String.capitalize()
  end

  @doc """
  EVERY string the catalog entry can carry from this resource's meaning, with where it sits: the table meaning, each
  field's meaning (description, label, synonyms, units, allowed_values) and each relationship description — plus the
  logical names that key them. Returned as `{path, string}`, `path` like `[:fields, "risk", :allowed_values]`.

  The compile-time sentinel check scans exactly this, so a facet added to `table/1`, `fields/1` or
  `relationship_descriptions/1` is covered without anyone remembering to list it. `source` is a module or a DSL state.
  """
  @spec string_leaves(source()) :: [{[term()], String.t()}]
  def string_leaves(source) do
    leaves([:table], table(source)) ++
      leaves([:fields], fields(source)) ++ leaves([:relationships], relationship_descriptions(source))
  end

  defp leaves(path, string) when is_binary(string), do: [{path, string}]

  defp leaves(path, map) when is_map(map) do
    Enum.flat_map(map, fn {key, value} ->
      key_leaf = if is_binary(key), do: [{path ++ [key, :name], key}], else: []
      key_leaf ++ leaves(path ++ [key], value)
    end)
  end

  defp leaves(path, list) when is_list(list), do: Enum.flat_map(list, &leaves(path, &1))
  defp leaves(_path, _other), do: []

  # --- private --------------------------------------------------------------------------------------------------

  # `Code.ensure_compiled/1`, not `ensure_loaded?/1`: at compile time (the meaning transformer) a type module of this
  # very project may still be compiling, and ensure_compiled waits for it. At runtime the two agree.
  defp compiled?(type), do: match?({:module, _}, Code.ensure_compiled(type))

  defp opt(resource, key), do: Spark.Dsl.Extension.get_opt(resource, [:meaning], key, nil)

  defp humanize_module(resource) when is_atom(resource) do
    resource |> Module.split() |> List.last() |> Macro.underscore() |> humanize()
  end

  defp humanize_module(dsl_state), do: dsl_state |> Spark.Dsl.Extension.get_persisted(:module) |> humanize_module()

  # source attribute -> the belongs_to relationship's description (an attribute's own description wins).
  defp fk_descriptions(resource) do
    resource
    |> Ash.Resource.Info.relationships()
    |> Enum.filter(&(&1.type == :belongs_to))
    |> Enum.flat_map(fn rel ->
      case blank_to_nil(rel.description) do
        nil -> []
        description -> [{rel.source_attribute, description}]
      end
    end)
    |> Map.new()
  end

  defp allowed_values({:array, inner}, constraints) do
    allowed_values(inner, Keyword.get(constraints, :items) || [])
  end

  defp allowed_values(type, constraints) do
    case Keyword.get(constraints, :one_of) do
      values when is_list(values) and values != [] -> Enum.map(values, &to_string/1)
      _ -> enum_values(type)
    end
  end

  defp enum_values(type) when is_atom(type) and not is_nil(type) do
    if compiled?(type) and function_exported?(type, :values, 0) and
         Spark.implements_behaviour?(type, Ash.Type.Enum) do
      Enum.map(type.values(), &to_string/1)
    end
  end

  defp enum_values(_type), do: nil

  defp max_length(constraints) do
    case Keyword.get(constraints, :max_length) do
      n when is_integer(n) and n >= 0 -> n
      _ -> nil
    end
  end
end
