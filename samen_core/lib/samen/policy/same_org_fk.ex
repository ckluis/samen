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
      rels = relationships_to_check(changeset, opts)

      # Decide FIRST whether any foreign key is written: an update that writes none has nothing to
      # compare, so it must not pay for (or depend on) a read of the stored org_id.
      if Enum.any?(rels, &writing_fk?(changeset, &1)) do
        check_written(changeset, rels)
      else
        changeset
      end
    end)
  end

  defp check_written(changeset, rels) do
    case org_id_for(changeset) do
      nil ->
        # No org on the row → OrgScope fails this closed already; nothing to compare.
        changeset

      :no_org ->
        changeset

      {:error, _unreadable} ->
        # The row's org could not be read: refuse a write that sets a foreign key rather than skip the check.
        Ash.Changeset.add_error(changeset,
          field: :org_id,
          message: "same-org FK check could not read this record's org_id"
        )

      org_id ->
        Enum.reduce(rels, changeset, &validate_relationship(&2, &1, org_id))
    end
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

  # `org_id` is not selected by default (`always_select?: false`) and is no longer an update input
  # (`Samen.Policy.OrgIdPinned`), so on an update the record in hand usually has it NotLoaded. Read
  # it from the table by primary key rather than skipping the check: a NotLoaded org_id must never
  # turn the same-org FK guard into a no-op.
  defp data_org_id(%{action_type: :update, data: %{org_id: %Ash.NotLoaded{}}} = changeset), do: stored_org_id(changeset)
  defp data_org_id(%{data: %{org_id: %Ash.NotLoaded{}}}), do: nil
  defp data_org_id(%{data: %{org_id: org_id}}), do: org_id
  defp data_org_id(_), do: nil

  # A tagged result, never an empty value for a failed read: `:unreadable` makes the guard refuse the
  # write (fail closed), `nil` is "no org on this row" (nothing to compare against). The read goes
  # through the WRITE repo (`:mutate`), i.e. the connection the caller's transaction is on — never a
  # read replica, which may not hold the row yet. Every primary-key column is matched, so a composite
  # key reads exactly its own row.
  defp stored_org_id(%{resource: resource, data: data}) do
    with pk when pk != [] <- Ash.Resource.Info.primary_key(resource),
         {:ok, pk_params} <- pk_params(resource, data, pk),
         repo when not is_nil(repo) <- AshPostgres.DataLayer.Info.repo(resource, :mutate),
         table when not is_nil(table) <- AshPostgres.DataLayer.Info.table(resource),
         org_src when not is_nil(org_src) <- attribute_source(resource, :org_id) do
      where =
        pk_params
        |> Enum.with_index(1)
        |> Enum.map_join(" AND ", fn {{src, _value}, i} -> "#{src} = $#{i}" end)

      case repo.query("SELECT #{org_src} FROM #{table} WHERE #{where} LIMIT 1", Enum.map(pk_params, &elem(&1, 1))) do
        {:ok, %{rows: [[nil]]}} -> :no_org
        {:ok, %{rows: [[org_bin]]}} -> load_uuid(org_bin)
        {:ok, %{rows: []}} -> {:error, :unreadable}
        {:error, reason} -> {:error, {:unreadable, reason}}
      end
    else
      _ -> {:error, :unreadable}
    end
  end

  # `{source column, dumped value}` for every primary-key attribute, or `:error` when any key value is
  # missing or cannot be dumped to its storage type.
  defp pk_params(resource, data, pk) do
    Enum.reduce_while(pk, {:ok, []}, fn name, {:ok, acc} ->
      attr = Ash.Resource.Info.attribute(resource, name)

      with value when not is_nil(value) <- Map.get(data, name),
           {:ok, dumped} <- Ash.Type.dump_to_native(attr.type, value, attr.constraints) do
        {:cont, {:ok, acc ++ [{attribute_source(resource, name), dumped}]}}
      else
        _ -> {:halt, :error}
      end
    end)
  end

  defp writing_fk?(changeset, rel_name) do
    case Ash.Resource.Info.relationship(changeset.resource, rel_name) do
      %{type: :belongs_to} = rel -> fk_being_written?(changeset, rel.source_attribute)
      _ -> false
    end
  end

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

        :org_less_target ->
          # The target table carries NO org_id (an org-less anchor like Identity.Org
          # or a shared, cross-org Credential). There is no org on the target to
          # MISMATCH against, so the same-org check has nothing to enforce — PASS
          # (D2 / ADR-046 §4.6). This matches both this module's own inline comment
          # below and the verifier moduledoc ("returns :target_has_no_org_id and
          # passes"). It only ever relaxes the check for a target that structurally
          # cannot cross orgs; a target that HAS an org_id is still routed through
          # the query arm below and a genuine cross-org mismatch is still refused.
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
        # enforce; treat as a PASS (an org-less target cannot cross orgs). The
        # `:org_less_target` sentinel is routed to a pass arm in
        # `validate_relationship/3` (D2 / ADR-046 §4.6) — matching this module's
        # documented contract and the verifier moduledoc, not an add_error refusal.
        :org_less_target

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
