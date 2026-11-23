defmodule Samen.Catalog.Transformers.MeaningDeclarations do
  @moduledoc """
  Compile-time check for catalog meaning (ADR-043 §8a). Refuses, with a `Spark.Error.DslError`:

    * a `meaning do field :x … end` that names something that is not an attribute of the resource;
    * the literal `vt_` in ANY meaning text — a resource, attribute (including a materialized `pii_attribute`) or
      relationship description, the meaning label, a synonym, a units string. The AI chokepoint refuses any metadata
      string containing `vt_` (a vault-token sentinel), so a single such description would refuse every auto-grounded
      completion and the MCP browse;
    * authored `units` on a field whose type fixes its own (`samen_catalog_units/1`), and authored `units` longer than
      40 characters.
  """
  # A TRANSFORMER, not a `Spark.Dsl.Verifier`: a verifier's error only surfaces as a warning from the parallel
  # checker (it does not abort `Code.compile_string`), whereas a transformer's `{:error, DslError}` hard-fails the
  # build. It runs after `MaterializePii` so a `pii_attribute` description is already on its attribute.
  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer, as: Verifier

  @impl true
  def after?(Samen.Transformers.MaterializePii), do: true
  def after?(_), do: false

  @impl true
  def before?(_), do: false

  @sentinel "vt_"
  @max_units 40

  @impl true
  def transform(dsl_state) do
    module = Verifier.get_persisted(dsl_state, :module)
    attributes = Verifier.get_entities(dsl_state, [:attributes])
    relationships = Verifier.get_entities(dsl_state, [:relationships])
    fields = Verifier.get_entities(dsl_state, [:meaning])

    section_texts = [Verifier.get_option(dsl_state, [:meaning], :label)] ++ (Verifier.get_option(dsl_state, [:meaning], :synonyms) || [])

    with :ok <- check_field_names(module, fields, attributes),
         :ok <- check_units(module, fields, attributes) do
      with :ok <- check_sentinel(module, dsl_state, attributes, relationships, fields, section_texts) do
        {:ok, dsl_state}
      end
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

  defp check_sentinel(module, dsl_state, attributes, relationships, fields, section_texts) do
    candidates =
      [{[:resource], Verifier.get_option(dsl_state, [:resource], :description)}] ++
        for(a <- attributes, do: {[:attributes, a.name], a.description}) ++
        for(r <- relationships, do: {[:relationships, r.name], r.description}) ++
        for(f <- fields, text <- [f.label, f.units | f.synonyms], do: {[:meaning, :field, f.name], text}) ++
        for(text <- section_texts, do: {[:meaning], text})

    case Enum.find(candidates, fn {_path, text} -> is_binary(text) and String.contains?(text, @sentinel) end) do
      nil ->
        :ok

      {path, text} ->
        error(
          module,
          path,
          "meaning text contains the literal #{inspect(@sentinel)} (#{inspect(text)}). The AI chokepoint refuses any " <>
            "metadata string containing it, which would refuse every auto-grounded completion and the MCP browse. " <>
            "Describe the field's meaning without writing a vault-token prefix."
        )
    end
  end

  defp error(module, path, message) do
    {:error, Spark.Error.DslError.exception(module: module, path: path, message: message)}
  end
end
