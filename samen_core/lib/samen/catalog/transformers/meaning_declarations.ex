defmodule Samen.Catalog.Transformers.MeaningDeclarations do
  @moduledoc """
  Compile-time check for catalog meaning (ADR-043 §8a). Refuses, with a `Spark.Error.DslError`:

    * a `meaning do field :x … end` that names something that is not an attribute of the resource, or names the same
      attribute twice;
    * the literal `vt_` in ANY string the catalog entry can carry from the resource's meaning. The AI chokepoint
      refuses any metadata string containing `vt_` (a vault-token sentinel), so one such string would refuse every
      auto-grounded completion and the MCP browse. "Any string" is by construction, not by a list of sources: the
      check scans `Samen.Catalog.Meaning.string_leaves/1`, the leaves of what the reader (`table/1`, `fields/1`,
      `relationship_descriptions/1`) itself returns, with `Samen.AI.VtSentinel`, the predicate the chokepoint uses.
      A new facet added to the reader is covered without touching this module. That covers the table label,
      description and synonyms; each field's description, label, synonyms, units and `allowed_values` (`one_of` atoms
      and `Ash.Type.Enum` values); each relationship description; and the logical attribute and relationship names;
    * authored `units` on a field whose type fixes its own (`samen_catalog_units/1`), and authored `units` longer than
      40 characters.

  ## Ordering

  A TRANSFORMER, not a `Spark.Dsl.Verifier`: a verifier's error only surfaces as a warning from the parallel
  checker (it does not abort `Code.compile_string`), whereas a transformer's `{:error, DslError}` hard-fails the
  build. It must see the FINAL attribute set and every description, so it is declared to run after each transformer
  that adds or describes an attribute (`@after_transformers`). Spark sorts unconstrained transformers in hash order,
  so without these declarations `meaning field :company_id` / `:org_id` / `:archived_at` would be accepted or refused
  by luck.
  """
  use Spark.Dsl.Transformer

  alias Samen.AI.VtSentinel
  alias Samen.Catalog.Meaning
  alias Spark.Dsl.Transformer

  # Every transformer that adds an attribute (FK source, id/org_id/timestamps, archived_at) or writes an attribute
  # description (pii_attribute, the `custom` bag), plus `AbbrevStorage` (which runs after them all).
  @after_transformers [
    Ash.Resource.Transformers.BelongsToAttribute,
    Samen.Transformers.CoreAttributes,
    Samen.Transformers.ArchivableAttribute,
    Samen.Transformers.MaterializeCustomFields,
    Samen.Transformers.MaterializePii,
    Samen.Transformers.AbbrevStorage
  ]

  @doc false
  def after_transformers, do: @after_transformers

  @impl true
  def after?(transformer), do: transformer in @after_transformers

  @impl true
  def before?(_), do: false

  @max_units 40

  @impl true
  def transform(dsl_state) do
    module = Transformer.get_persisted(dsl_state, :module)
    attributes = Transformer.get_entities(dsl_state, [:attributes])
    fields = Transformer.get_entities(dsl_state, [:meaning])

    with :ok <- check_field_names(module, fields, attributes),
         :ok <- check_duplicates(module, fields),
         :ok <- check_units(module, fields, attributes),
         :ok <- check_sentinel(module, dsl_state) do
      {:ok, dsl_state}
    end
  end

  defp check_duplicates(module, fields) do
    dup = fields |> Enum.frequencies_by(& &1.name) |> Enum.find(fn {_name, n} -> n > 1 end)

    case dup do
      nil ->
        :ok

      {name, n} ->
        error(
          module,
          [:meaning, :field, name],
          "meaning field #{inspect(name)} is declared more than once (#{n} times) in #{inspect(module)}; " <>
            "merge them into one `field` entry."
        )
    end
  end

  defp check_field_names(module, fields, attributes) do
    names = MapSet.new(attributes, & &1.name)

    case Enum.find(fields, &(not MapSet.member?(names, &1.name))) do
      nil ->
        :ok

      %{name: name} ->
        error(
          module,
          [:meaning, :field, name],
          "meaning field #{inspect(name)} is not an attribute of this resource. Attributes: " <>
            "#{inspect(attributes |> Enum.map(& &1.name) |> Enum.sort())}."
        )
    end
  end

  defp check_units(module, fields, attributes) do
    by_name = Map.new(attributes, &{&1.name, &1})

    Enum.find_value(fields, :ok, fn field ->
      attr = Map.get(by_name, field.name)

      cond do
        is_nil(field.units) ->
          nil

        attr && Samen.Catalog.Meaning.fixes_units?(attr.type) ->
          error(
            module,
            [:meaning, :field, field.name, :units],
            "meaning field #{inspect(field.name)} authors units #{inspect(field.units)}, but its type " <>
              "#{inspect(attr.type)} fixes its own units (samen_catalog_units/1); remove the authored `units`."
          )

        String.length(field.units) > @max_units ->
          error(
            module,
            [:meaning, :field, field.name, :units],
            "meaning field #{inspect(field.name)} units are longer than #{@max_units} characters."
          )

        true ->
          nil
      end
    end)
  end

  defp check_sentinel(module, dsl_state) do
    case Enum.find(Meaning.string_leaves(dsl_state), fn {_path, text} -> VtSentinel.in_string?(text) end) do
      nil ->
        :ok

      {path, text} ->
        error(
          module,
          [:meaning | path],
          "#{inspect(module)}: the catalog meaning text at #{inspect(path)} contains the literal " <>
            "#{inspect(VtSentinel.sentinel())} (#{inspect(text)}). The AI chokepoint refuses any metadata string " <>
            "containing it, which would refuse every auto-grounded completion and the MCP browse. " <>
            "Reword it (or rename the attribute or value) without a vault-token prefix."
        )
    end
  end

  defp error(module, path, message) do
    {:error, Spark.Error.DslError.exception(module: module, path: path, message: message)}
  end
end
