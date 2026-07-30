defmodule Samen.Archival do
  @moduledoc """
  Runtime API for the E6 soft-delete substrate (ADR-040 §5). The `archivable`
  convention — `use Samen.Resource, archivable: true` — attaches the columns,
  actions, and default read filter; this module is the ergonomic surface over them
  and the place restore-conflicts become a fail-honest `{:error, :restore_conflict}`.

  ## What `archivable true` gives a resource

    * `<abbrev>_archived_at` timestamp (NULL = live, spec-question c6);
    * a soft primary `:destroy` (a plain destroy archives) + explicit `:archive`;
    * `:restore` (clears `archived_at`, honest on a partial-index conflict);
    * `:archived` read (includes archived rows — trash/retention);
    * `:destroy_permanently` (the untouched terminal hard-delete — retention/erasure/
      operator only);
    * the `Samen.Archival.ExcludeArchived` preparation on every read, so archived rows
      are hidden from default reads / list / search by construction.

  Masking, org-scope, and crypto-shred are orthogonal and unchanged: an archived row
  keeps its vaulted tokens, stays OrgScope-filtered and mask-by-default on every plane,
  and remains erasure-countable (§5.1, INV-1/INV-2/INV-5).

  ## Uniqueness (§5.3)

  Unique slots use **partial** indexes (`WHERE <abbrev>_archived_at IS NULL`) so an
  archived row frees its slot. `restore/2` therefore can collide with a live row that
  claimed the slot since — it returns `{:error, :restore_conflict}` (never auto-rename,
  never clobber).
  """

  @doc """
  Soft-delete `record` (sets `archived_at`, audited). Idempotent: archiving an
  already-archived record is a no-op that returns `{:ok, record}` without moving the
  timestamp or writing a duplicate audit event. Returns the archived record.
  """
  @spec archive(Ash.Resource.record(), Keyword.t()) ::
          {:ok, Ash.Resource.record()} | {:error, term()}
  def archive(record, opts \\ []) do
    Ash.destroy(record, Keyword.merge([action: :archive, return_destroyed?: true], opts))
  end

  @doc """
  Restore `record` (clears `archived_at`, audited). Idempotent on an already-live
  record. Returns `{:error, :restore_conflict}` when a live row now occupies the
  record's unique slot (§5.3) — honest, never clobbering.
  """
  @spec restore(Ash.Resource.record(), Keyword.t()) ::
          {:ok, Ash.Resource.record()} | {:error, :restore_conflict | term()}
  def restore(record, opts \\ []) do
    case Ash.update(record, %{}, Keyword.merge([action: :restore], opts)) do
      {:ok, restored} -> {:ok, restored}
      {:error, error} -> normalize_restore_error(error)
    end
  rescue
    error ->
      if restore_conflict?(error) do
        {:error, :restore_conflict}
      else
        reraise error, __STACKTRACE__
      end
  end

  @doc """
  A query over `resource` that INCLUDES archived rows (the `:archived` read).
  Retention sweeps and cascade-restore read through this path — the default
  preparation would hide exactly the rows they must see (§5.6).
  """
  @spec archived_query(module()) :: Ash.Query.t()
  def archived_query(resource) do
    Ash.Query.for_read(resource, :archived)
  end

  @doc "Whether `resource` opted into the soft-delete substrate."
  @spec archivable?(module()) :: boolean()
  def archivable?(resource), do: Samen.Info.archivable?(resource)

  defp normalize_restore_error(error) do
    if restore_conflict?(error), do: {:error, :restore_conflict}, else: {:error, error}
  end

  # A restore collides with a live row on the partial unique index. Because samen has
  # no Ash identity for it (§5.3 — uniqueness lives in migration-level partial indexes),
  # Ash cannot map the violation to a typed identity error: it surfaces as an
  # `Ecto.ConstraintError` (unique) wrapped/stringified inside `Ash.Error.Unknown`.
  # We walk the error tree and detect the unique-constraint signature, mapping it to the
  # honest `:restore_conflict` the UI copy surfaces (never auto-rename, never clobber).
  # (When an Ash identity+`identity_wheres_to_sql` is ever added, this becomes a typed match.)
  defp restore_conflict?(%Postgrex.Error{postgres: %{code: :unique_violation}}), do: true
  defp restore_conflict?(%Ecto.ConstraintError{type: :unique}), do: true

  defp restore_conflict?(%{errors: errors}) when is_list(errors),
    do: Enum.any?(errors, &restore_conflict?/1)

  defp restore_conflict?(%{error: error}), do: restore_conflict?(error)
  defp restore_conflict?(errors) when is_list(errors), do: Enum.any?(errors, &restore_conflict?/1)

  defp restore_conflict?(bin) when is_binary(bin),
    do: String.contains?(bin, "unique_constraint") or String.contains?(bin, "unique_violation")

  defp restore_conflict?(_), do: false
end
