defmodule Samen.Scopes.Primitives.SearchIndexPiiChange do
  @moduledoc """
  The write-side half of `Samen.Scopes.Primitives.SearchIndexGuard`: an `Ash.Resource.Change` on the
  `SearchIndex` create AND update that refuses to register a vault-routed field.

  Until this change only the query path (`Samen.Search`) applied the guard, so a row naming a
  `pii_attribute` could be registered; the query path then skipped it, which limited the exposure but
  left the registry saying a vaulted column was indexed. Now the registration itself is refused, on every
  path including `authorize?: false`.

  It refuses, as a changeset error and never a raise:

    * a `resource_name` that is not a loaded Ash resource (the guard cannot read its PII declarations, so
      it cannot clear the field: fail honest, never "no PII");
    * a `field_name` that is a `pii_attribute` of that resource, or the storage column of one;
    * a resource whose PII declarations cannot be introspected.

  Only the fields being written are checked (an update that touches neither `resource_name` nor
  `field_name` is not re-checked).
  """
  use Ash.Resource.Change

  alias Samen.Scopes.Primitives.SearchIndexGuard

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &check/1)
  end

  defp check(changeset) do
    if Ash.Changeset.changing_attribute?(changeset, :resource_name) or
         Ash.Changeset.changing_attribute?(changeset, :field_name) do
      verify(
        changeset,
        Ash.Changeset.get_attribute(changeset, :resource_name),
        Ash.Changeset.get_attribute(changeset, :field_name)
      )
    else
      changeset
    end
  end

  defp verify(changeset, resource_name, field_name) when is_binary(resource_name) and is_binary(field_name) do
    with {:ok, module} <- resolve(resource_name),
         {:ok, pii_names} <- pii_names(module) do
      if field_name in pii_names do
        Ash.Changeset.add_error(changeset,
          field: :field_name,
          message:
            "field #{inspect(field_name)} on #{resource_name} is a vault-routed (pii_attribute) column; " <>
              "PII columns cannot be registered in a search index"
        )
      else
        changeset
      end
    else
      {:error, message} -> Ash.Changeset.add_error(changeset, field: :resource_name, message: message)
    end
  end

  defp verify(changeset, _resource_name, _field_name), do: changeset

  defp resolve(resource_name) do
    module = String.to_existing_atom("Elixir." <> String.trim_leading(resource_name, "Elixir."))

    if Code.ensure_loaded?(module) and function_exported?(module, :spark_is, 0) and
         Ash.Resource.Info.resource?(module) do
      {:ok, module}
    else
      {:error, "#{resource_name} is not a known resource, so its PII columns cannot be checked"}
    end
  rescue
    ArgumentError -> {:error, "#{resource_name} is not a known resource, so its PII columns cannot be checked"}
  end

  # The logical names of the resource's pii attributes AND their storage column names, as strings.
  defp pii_names(module) do
    names = SearchIndexGuard.get_pii_fields(module)

    storage =
      for name <- names,
          attr = Ash.Resource.Info.attribute(module, name),
          not is_nil(attr),
          source = attr.source,
          do: to_string(source)

    {:ok, Enum.map(names, &to_string/1) ++ storage}
  rescue
    _ -> {:error, "the PII declarations of #{inspect(module)} cannot be read, so the field cannot be cleared"}
  end
end
