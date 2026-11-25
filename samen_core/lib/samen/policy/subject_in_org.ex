defmodule Samen.Policy.SubjectInOrg do
  @moduledoc """
  A write change for a polymorphic anchor `(subject_key, subject_id)` (the `Tags.Tagging` join): the
  subject must be a resource the host knows AND the row it names must exist in the SAME organisation
  as the write.

  ## The hole this closes

  The anchor is two plain scalars, so any key and any UUID were accepted, an id from ANOTHER
  organisation included. Only `Samen.Web.Tags.attach/5` resolved the ref before writing; every other
  path (a direct `Ash.create`, the automation `add_tag` action, a host's own code) skipped the check.
  The check now lives in the resource, so every path has it.

  ## What it enforces

    1. `subject_key` is `<scope>.<resource>` (`Samen.ObjectKey`), resolved to a compiled Ash resource
       under this resource's own host namespace (its module minus its last two segments, the rule
       `Samen.Web.ObjectRef.Catalog.resource_for/2` uses). An unknown key is refused.
    2. That resource has an `org_id` and a Postgres table, and the row `subject_id` exists in it with
       `org_id` equal to the write's `org_id`. The read is a bare query on the WRITE repo
       (`:mutate`), not an `Ash.read`, so `OrgScope` cannot make a foreign row invisible and let the
       check pass vacuously, and a read replica that lacks the row is never asked.
    3. Fail honest: a lookup that cannot run (no repo, a database error, a write with no `org_id`)
       refuses the write; it never passes it.

  Options: `key:` (default `:subject_key`), `id:` (default `:subject_id`).
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, _context) do
    Ash.Changeset.before_action(changeset, &check(&1, opts))
  end

  defp check(changeset, opts) do
    key_attr = Keyword.get(opts, :key, :subject_key)
    id_attr = Keyword.get(opts, :id, :subject_id)
    key = Ash.Changeset.get_attribute(changeset, key_attr)
    id = Ash.Changeset.get_attribute(changeset, id_attr)
    org_id = Ash.Changeset.get_attribute(changeset, :org_id)

    cond do
      is_nil(key) or is_nil(id) ->
        # allow_nil?: false on both reports this; nothing to look up.
        changeset

      not is_binary(org_id) ->
        refuse(changeset, id_attr, "the subject's organisation cannot be checked: the write has no org_id")

      true ->
        case subject_in_org(changeset.resource, key, id, org_id) do
          :ok -> changeset
          {:error, :unknown_subject_key} -> refuse(changeset, key_attr, "unknown subject type")
          {:error, :not_found} -> refuse(changeset, id_attr, "no such subject in this organisation")
          {:error, :unreadable} -> refuse(changeset, id_attr, "the subject could not be checked")
        end
    end
  end

  defp refuse(changeset, field, message),
    do: Ash.Changeset.add_error(changeset, field: field, message: message)

  @doc false
  def subject_in_org(tagging_resource, key, id, org_id) do
    with {:ok, subject} <- resolve(tagging_resource, key) do
      exists_in_org?(subject, id, org_id)
    end
  end

  defp resolve(tagging_resource, key) when is_binary(key) do
    with [scope, resource] when scope != "" and resource != "" <- String.split(key, "."),
         [_, _ | _] = segments <- Module.split(tagging_resource),
         module = Module.concat(Enum.drop(segments, -2) ++ [Macro.camelize(scope), Macro.camelize(resource)]),
         true <- resource?(module) do
      {:ok, module}
    else
      _ -> {:error, :unknown_subject_key}
    end
  end

  defp resolve(_, _), do: {:error, :unknown_subject_key}

  defp resource?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :spark_is, 0) and
      Ash.Resource.Info.resource?(module) and
      not is_nil(Ash.Resource.Info.attribute(module, :org_id)) and
      Ash.Resource.Info.data_layer(module) == AshPostgres.DataLayer
  rescue
    e ->
      Samen.Observability.Failure.report(:subject_in_org_resource, nil, e)
      false
  end

  defp exists_in_org?(subject, id, org_id) do
    with repo when not is_nil(repo) <- AshPostgres.DataLayer.Info.repo(subject, :mutate),
         table when is_binary(table) <- AshPostgres.DataLayer.Info.table(subject),
         [pk_name] <- Ash.Resource.Info.primary_key(subject),
         pk_attr = Ash.Resource.Info.attribute(subject, pk_name),
         org_attr = Ash.Resource.Info.attribute(subject, :org_id),
         {:ok, id_native} <- Ash.Type.dump_to_native(pk_attr.type, id, pk_attr.constraints),
         {:ok, org_native} <- Ash.Type.dump_to_native(org_attr.type, org_id, org_attr.constraints) do
      sql =
        "SELECT 1 FROM #{quote_ident(table)} WHERE #{quote_ident(source(pk_attr))} = $1 AND " <>
          "#{quote_ident(source(org_attr))} = $2 LIMIT 1"

      case repo.query(sql, [id_native, org_native]) do
        {:ok, %{rows: [_ | _]}} -> :ok
        {:ok, %{rows: []}} -> {:error, :not_found}
        {:error, _} -> {:error, :unreadable}
      end
    else
      # an id that is not a UUID can match nothing: the subject does not exist
      :error -> {:error, :not_found}
      _ -> {:error, :unreadable}
    end
  rescue
    e ->
      Samen.Observability.Failure.report(:subject_in_org_lookup, nil, e)
      {:error, :unreadable}
  end

  defp source(attr), do: to_string(attr.source || attr.name)
  defp quote_ident(name), do: ~s("#{String.replace(name, ~s("), ~s(""))}")
end
