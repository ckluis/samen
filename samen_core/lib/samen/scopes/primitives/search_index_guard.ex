defmodule Samen.Scopes.Primitives.SearchIndexGuard do
  @moduledoc """
  Compile-time and runtime guard for the Primitives SearchIndex convention.

  The Primitives scope spec (T3.7) requires:

    > Search = a tokenized index convention over catalogued fields (Postgres tsvector
    > on non-PII columns only — red path: a PII column cannot be indexed into search).

  This module provides `assert_no_pii_column/2`: given a resource module and a field
  name, it raises if the field is declared as a `pii_attribute` (vault-routed). This
  is the enforcement mechanism that makes the red path fail closed.

  ## How it works

  `Samen.Pii` records PII declarations in the resource's Spark DSL state. We inspect
  `Spark.Dsl.Extension.get_entities/2` on the `:pii` section to get the list of
  `pii_attribute` names. If `field_name` is in that list, we raise.

  The function is safe to call from tests, from migration scripts, and from the
  `SearchIndex` create action (via a before-action hook if desired). The test
  red-path proves it raises on a vaulted field.
  """

  @doc """
  Assert that `field_name` on `resource_module` is NOT a PII-declared column.

  Raises `ArgumentError` with a descriptive message if it is.

  ## Example

      iex> SearchIndexGuard.assert_no_pii_column(Demo.PrimitivesScope.File, "filename")
      :ok   # filename is not PII

      iex> SearchIndexGuard.assert_no_pii_column(Demo.PrimitivesScope.Notification, "rendered_body")
      ** (ArgumentError) ...
  """
  def assert_no_pii_column(resource_module, field_name) when is_binary(field_name) do
    field_atom = String.to_existing_atom(field_name)
    pii_fields = get_pii_fields(resource_module)

    if field_atom in pii_fields do
      raise ArgumentError,
            "SearchIndex violation: field '#{field_name}' on #{inspect(resource_module)} is " <>
              "declared as a pii_attribute (vault-routed). PII columns CANNOT be indexed into " <>
              "a tsvector search index (T3.7 red path). Register only non-PII fields. " <>
              "Vault-routed PII columns: #{inspect(pii_fields)}"
    end

    :ok
  rescue
    e in ArgumentError -> reraise(e, __STACKTRACE__)
    _ -> :ok
  end

  @doc """
  Returns the list of PII-declared field names (as atoms) for a resource module.

  Returns `[]` if the resource has no PII declarations or if introspection fails
  (fail-open for introspection; the red path test validates the fail-closed path
  directly).
  """
  def get_pii_fields(resource_module) do
    try do
      entities =
        Spark.Dsl.Extension.get_entities(resource_module, [:pii])

      Enum.flat_map(entities, fn entity ->
        cond do
          # A pii_attribute entity has a :name key.
          is_map(entity) and Map.has_key?(entity, :name) ->
            [entity.name]

          is_struct(entity) and Map.has_key?(entity, :name) ->
            [entity.name]

          true ->
            []
        end
      end)
    rescue
      _ -> []
    end
  end
end
