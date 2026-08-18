defmodule Samen.Archival.Restore do
  @moduledoc """
  The soft-delete **restore** write (ADR-040 §5.2) behind the `:restore` update
  action. Clears `archived_at` (back to NULL = live) and emits a `record_restored`
  governance audit event inside the action transaction.

  ## Idempotence (§5.2, T36 c4)

  Double-restore is a **no-op**: restoring an already-live row (`archived_at` NULL)
  touches nothing and writes no audit event.

  ## Restore conflict (§5.3)

  Uniqueness lives in **partial** unique indexes (`WHERE <abbrev>_archived_at IS
  NULL`), so an archived row frees its slot and a live row can claim it. Clearing
  `archived_at` on restore can therefore collide — the DB raises a unique violation,
  which `Samen.Archival.restore/2` maps to a fail-honest `{:error, :restore_conflict}`
  (never auto-rename, never clobber). This change stays simple; the conflict is a
  DB-level fact surfaced at the API boundary.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    if already_live?(changeset) do
      # Idempotent no-op: nothing to restore, no audit.
      changeset
    else
      changeset
      |> Ash.Changeset.force_change_attribute(:archived_at, nil)
      |> Ash.Changeset.after_action(fn cs, record ->
        Samen.Archival.Audit.write(cs, record, "record_restored")
        {:ok, record}
      end)
    end
  end

  # Live iff `archived_at` is explicitly `nil`. A real instant means archived
  # (proceed to restore); `%Ash.NotLoaded{}` is treated as "proceed" (safe: force nil).
  defp already_live?(changeset) do
    Ash.Changeset.get_data(changeset, :archived_at) == nil
  end
end
