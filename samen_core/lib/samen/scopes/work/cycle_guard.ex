defmodule Samen.Scopes.Work.CycleGuard do
  @moduledoc """
  Refuses a `parent_id` write on the self-referential `Task` tree (ADR-041 §3.4) that
  would make a task its own (transitive) ancestor, and bounds the walk depth so a
  pathological/corrupted chain cannot hang a write.

  Mirrors `Samen.Policy.SameOrgFk`'s bare-repo-query idiom (never `Ash.read`) — this is
  a structural-integrity guard over opaque ids, not a data-leak surface, so bypassing
  `OrgScope` here is safe (and load-bearing: a hidden foreign row must not silently
  vanish from the ancestor walk).

  ## Usage

      changes do
        change(Samen.Scopes.Work.CycleGuard)
      end

  Runs only when `parent_id` is being changed. `nil` (detaching from a parent) is
  always a no-op. A legal N-level tree is accepted; a cycle (including the
  self-parent degenerate case) is refused with a positive control retained by the
  caller's test (a legal re-parent still succeeds).
  """
  use Ash.Resource.Change

  @max_depth 100

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &refuse_cycle/1)
  end

  defp refuse_cycle(changeset) do
    if Ash.Changeset.changing_attribute?(changeset, :parent_id) do
      parent_id = Ash.Changeset.get_attribute(changeset, :parent_id)
      self_id = self_id(changeset)

      cond do
        is_nil(parent_id) ->
          changeset

        not is_nil(self_id) and same_uuid?(parent_id, self_id) ->
          cycle_error(changeset)

        true ->
          case ancestor_ids(changeset.resource, parent_id) do
            {:ok, ancestors} ->
              if not is_nil(self_id) and Enum.any?(ancestors, &same_uuid?(&1, self_id)) do
                cycle_error(changeset)
              else
                changeset
              end

            {:error, :depth_exceeded} ->
              Ash.Changeset.add_error(changeset,
                field: :parent_id,
                message:
                  "parent chain exceeds max depth (#{@max_depth}) — refusing (possible cycle)"
              )
          end
      end
    else
      changeset
    end
  end

  defp self_id(%{data: %{id: id}}) when not is_nil(id), do: id
  defp self_id(_), do: nil

  defp cycle_error(changeset) do
    Ash.Changeset.add_error(changeset,
      field: :parent_id,
      message: "a task cannot be its own ancestor (cycle refused)"
    )
  end

  # Walk parent_id upward from `start_id`, collecting every ancestor id encountered
  # (including start_id itself), bounded by @max_depth.
  defp ancestor_ids(resource, start_id) do
    repo =
      AshPostgres.DataLayer.Info.repo(resource, :read) || AshPostgres.DataLayer.Info.repo(resource)

    table = AshPostgres.DataLayer.Info.table(resource)
    id_source = attribute_source(resource, :id)
    parent_source = attribute_source(resource, :parent_id)

    walk(repo, table, id_source, parent_source, start_id, [], 0)
  end

  defp walk(_repo, _table, _id_src, _parent_src, nil, acc, _depth), do: {:ok, acc}

  defp walk(_repo, _table, _id_src, _parent_src, _id, _acc, depth) when depth > @max_depth do
    {:error, :depth_exceeded}
  end

  defp walk(repo, table, id_src, parent_src, id, acc, depth) do
    sql = "SELECT #{parent_src} FROM #{table} WHERE #{id_src} = $1 LIMIT 1"

    case repo.query(sql, [dump_uuid(id)]) do
      {:ok, %{rows: [[nil]]}} ->
        {:ok, [id | acc]}

      {:ok, %{rows: [[parent_bin]]}} ->
        walk(repo, table, id_src, parent_src, load_uuid(parent_bin), [id | acc], depth + 1)

      {:ok, %{rows: []}} ->
        {:ok, [id | acc]}

      {:error, _reason} ->
        {:ok, [id | acc]}
    end
  end

  defp attribute_source(resource, name) do
    case Ash.Resource.Info.attribute(resource, name) do
      nil -> nil
      attr -> to_string(attr.source || attr.name)
    end
  end

  defp same_uuid?(a, b), do: to_string(a) == to_string(b)

  defp dump_uuid(value) when is_binary(value) and byte_size(value) == 16, do: value

  defp dump_uuid(value) do
    case Ecto.UUID.dump(value) do
      {:ok, bin} -> bin
      :error -> value
    end
  end

  defp load_uuid(bin) when is_binary(bin) and byte_size(bin) == 16 do
    case Ecto.UUID.load(bin) do
      {:ok, uuid} -> uuid
      :error -> bin
    end
  end

  defp load_uuid(other), do: other
end
