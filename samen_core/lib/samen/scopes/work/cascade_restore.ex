defmodule Samen.Scopes.Work.CascadeRestore do
  @moduledoc """
  The restore-side counterpart to `archive_related([:subtasks])` (ADR-041 §3.5:
  "archiving a parent task archives its subtree at the same instant, restore
  matches the instant"). ash_archival ships `archive_related` for the archive
  side only — it has no restore-cascade primitive — so the Work scope adds this
  narrow, resource-local change with a **self-guard on
  `changeset.action.name == :restore`**. (The DSL's `on:` option on a resource-level
  `changes do change(...) end` entry only discriminates by action TYPE —
  `:create`/`:update`/`:destroy` — not by action NAME; `:restore` is type `:update`,
  same as the plain `:update` action, so `on: [:update]` would also fire on every
  ordinary update. The self-guard is what actually narrows this to `:restore` only.)

  Restores every DIRECT archived subtask of the just-restored task. Each
  subtask's own `:restore` action carries the SAME change, so the cascade reaches
  the whole subtree recursively without a hand-rolled recursive query —
  symmetric with how `archive_related`'s cascade reaches a subtree by
  re-invoking each child's own (also-archivable) destroy action.

  Runs `authorize?: false` (a system-level structural cascade following an
  already-authorized parent restore — mirrors ash_archival's own
  `archive_related` internals, which run under the same posture by default).
  """
  use Ash.Resource.Change

  require Ash.Query

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, record ->
      if changeset.action.name == :restore do
        restore_subtasks(record)
      end

      {:ok, record}
    end)
  end

  defp restore_subtasks(%resource{id: id}) do
    subtasks =
      resource
      |> Ash.Query.for_read(:archived)
      |> Ash.Query.filter(parent_id == ^id)
      |> Ash.read!(authorize?: false)

    Enum.each(subtasks, &Samen.Archival.restore(&1, authorize?: false))
  end
end
