defmodule Samen.Policy.SameOrgFk do
  @moduledoc """
  A reusable **same-org foreign-key** change: refuses a tenant-plane write whose
  `belongs_to` FK points at a row owned by a DIFFERENT org (Phase-3 cross-scope
  review fix F3.2).

  ## The hole this closes

  `Samen.Policy.OrgScope` protects *reads* (foreign-org rows are invisible) and
  *writes to a foreign row* (a row whose own `org_id ≠ actor.org_id` is Forbidden).
  But nothing validated that a `belongs_to` FK on an OTHERWISE same-org row points
  at a same-org target. So an actor in org A could create a same-org row
  (`org_id: org_a`, authorized) whose FK referenced org B's row — storing a
  cross-tenant dangling FK, and, for Marketing `Send`, bypassing org B's
  suppression list (the send row is in org A, the suppression query finds nothing
  for a foreign subscriber, and a send to org B's subscriber is enqueued). The
  T3.14 review proved this live.

  ## What it enforces

  For each configured relationship whose FK is set on the changeset, this change
  loads ONLY the target row's `org_id` (a bounded UUID — never PII) directly from
  the target table and asserts it equals the changeset's `org_id`. A mismatch (or a
  missing target) adds an error and the write is refused. It reads the target's
  `org_id` with a bare repo query — NOT an `Ash.read` — so it is not itself subject
  to `OrgScope` filtering (which would make a foreign target invisible and let the
  check pass vacuously). The check is the *point*: a foreign target must be VISIBLE
  to this validation precisely so it can be REFUSED.

  ## Usage

  In a resource's `changes` block (applies to all create/update actions), or inside
  a specific create action:

      changes do
        change {Samen.Policy.SameOrgFk, relationships: [:subscriber, :campaign]}
      end

  `relationships` is the list of `belongs_to` relationship names to validate. Only
  those whose FK is actually set on the changeset are checked (a nil optional FK is
  a no-op). If `relationships` is omitted, EVERY `belongs_to` relationship on the
  resource is validated (the safe default for the scope-authoring template).

  ## org_id source

  The changeset's `org_id` is read via `Ash.Changeset.get_attribute/2` (set by the
  action / `CoreAttributes`). If the changeset has no `org_id` (an org-less write),
  the change is a no-op — `OrgScope` already fails such writes closed; there is no
  same-org target to compare against.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      case org_id_for(changeset) do
        nil ->
          # No org on the row → OrgScope fails this closed already; nothing to compare.
          changeset

        org_id ->
          rels = relationships_to_check(changeset, opts)
          Enum.reduce(rels, changeset, &validate_relationship(&2, &1, org_id))
      end
    end)
  end

  # The write's org_id. On a create it is set on the changeset (by the action /
  # CoreAttributes). On an update that does NOT touch org_id, `get_attribute/2`
  # returns the NotLoaded/nil changeset value — so we fall back to the PERSISTED
  # `changeset.data.org_id`. Without this fallback, an update that leaves org_id
  # unchanged would compare a same-org FK target against a NotLoaded sentinel and
  # spuriously fail (the ApiKey revoke red path).
  defp org_id_for(changeset) do
    case Ash.Changeset.get_attribute(changeset, :org_id) do
      %Ash.NotLoaded{} -> data_org_id(changeset)
      nil -> data_org_id(changeset)
      org_id -> org_id
    end
  end

  defp data_org_id(%{data: %{org_id: %Ash.NotLoaded{}}}), do: nil
  defp data_org_id(%{data: %{org_id: org_id}}), do: org_id
  defp data_org_id(_), do: nil

  defp relationships_to_check(changeset, opts) do
    case Keyword.get(opts, :relationships) do
      nil -> all_belongs_to(changeset.resource)
      list when is_list(list) -> list
    end
  end

  defp all_belongs_to(resource) do
    resource
    |> Ash.Resource.Info.relationships()
    |> Enum.filter(&(&1.type == :belongs_to))
    |> Enum.map(& &1.name)
  end

  defp validate_relationship(changeset, rel_name, org_id) do
    resource = changeset.resource

    with %{type: :belongs_to} = rel <- Ash.Resource.Info.relationship(resource, rel_name),
         true <- fk_being_written?(changeset, rel.source_attribute),
         fk_value when not is_nil(fk_value) <-
           Ash.Changeset.get_attribute(changeset, rel.source_attribute) do
      case target_org_id(rel, fk_value) do
        {:ok, ^org_id} ->
          changeset

        {:ok, other_org_id} ->
          Ash.Changeset.add_error(
            changeset,
            field: rel.source_attribute,
            message:
              "cross-org FK: #{rel_name} (#{rel.source_attribute}) references a row owned by " <>
                "org #{inspect(other_org_id)}, not this write's org #{inspect(org_id)} " <>
                "(same-org FK required)"
          )

        :not_found ->
          Ash.Changeset.add_error(
            changeset,
            field: rel.source_attribute,
            message:
              "cross-org FK: #{rel_name} (#{rel.source_attribute}) references a row that is not " <>
                "visible / does not exist for this org (same-org FK required)"
          )

        {:error, reason} ->
          # Fail closed: if we cannot verify the target's org, refuse the write.
          Ash.Changeset.add_error(
            changeset,
            field: rel.source_attribute,
            message: "same-org FK check could not verify #{rel_name}: #{inspect(reason)}"
          )
      end
    else
      # No such relationship, FK not being written this action, or FK not set
      # (nil optional FK) → nothing to check.
      _ -> changeset
    end
  end

  # Whether this action is actually WRITING the FK attribute. On a create the FK is
  # always written (even if to nil). On an update we only re-validate an FK that is
  # being CHANGED — an unchanged FK was validated at its own write time, and
  # re-checking it on an unrelated update (e.g. an ApiKey `revoke` that only touches
  # `revoked_at`) would spuriously fail and, worse, block a legitimate write. This
  # is a NARROWING of when we check, never a widening: a same-org invariant, once
  # established at write, holds until the FK is rewritten.
  defp fk_being_written?(%{action_type: :create}, _source_attr), do: true

  defp fk_being_written?(changeset, source_attr) do
    Ash.Changeset.changing_attribute?(changeset, source_attr)
  end

  # Load ONLY the target row's org_id, directly from the target table (bounded UUID,
  # no PII). A bare repo query — NOT an Ash.read — so OrgScope does not hide a
  # foreign target from this validation (the whole point is to SEE it and REFUSE it).
  defp target_org_id(rel, fk_value) do
    dest = rel.destination
    repo = AshPostgres.DataLayer.Info.repo(dest, :read) || AshPostgres.DataLayer.Info.repo(dest)
    table = AshPostgres.DataLayer.Info.table(dest)

    dest_pk_source = attribute_source(dest, rel.destination_attribute)
    org_id_source = attribute_source(dest, :org_id)

    cond do
      is_nil(repo) or is_nil(table) ->
        {:error, :no_data_layer}

      is_nil(org_id_source) ->
        # Target has no org_id (an org-less anchor like Identity.Org) — nothing to
        # enforce; treat as a pass by returning the write's own org (no mismatch).
        {:error, :target_has_no_org_id}

      true ->
        sql =
          "SELECT #{org_id_source} FROM #{table} WHERE #{dest_pk_source} = $1 LIMIT 1"

        case repo.query(sql, [dump_uuid(fk_value)]) do
          {:ok, %{rows: [[nil]]}} -> {:ok, nil}
          {:ok, %{rows: [[org_id_bin]]}} -> {:ok, load_uuid(org_id_bin)}
          {:ok, %{rows: []}} -> :not_found
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp attribute_source(resource, name) do
    case Ash.Resource.Info.attribute(resource, name) do
      nil -> nil
      attr -> to_string(attr.source || attr.name)
    end
  end

  # UUIDs may arrive as strings (from action arguments) or already-dumped binaries.
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
