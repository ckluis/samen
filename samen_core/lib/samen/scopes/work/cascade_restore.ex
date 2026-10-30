defmodule Samen.Scopes.Work.CascadeRestore do
  @moduledoc """
  The restore-side counterpart to `archive_related([:subtasks])` (ADR-041 §3.5:
  "archiving a parent task archives its subtree at the same instant, restore
  matches the instant"). ash_archival ships `archive_related` for the archive
  side only — it has no restore-cascade primitive — so the Work scope adds this
  narrow listener.

  A listener (issue #96 D3) of the task's OWN `:restored` signal (`<Task>.Archival`,
  `Samen.Archival.Signals`): restoring a task restores every DIRECT archived subtask,
  and each subtask's restore emits its own `:restored`, so the cascade reaches the
  whole subtree recursively without a hand-rolled recursive query — symmetric with
  how `archive_related`'s cascade reaches a subtree by re-invoking each child's own
  (also-archivable) destroy action. `Samen.Scopes.Work.CycleGuard` refuses a parent
  cycle, so the recursion ends at the leaves.

  Kept exactly as the change it replaces behaved: every archived direct subtask is
  restored (no same-instant match), also when the parent was already live, and a
  subtask that fails to restore does not fail the parent.

  Runs `authorize?: false` (a system-level structural cascade following an
  already-authorized parent restore — mirrors ash_archival's own
  `archive_related` internals, which run under the same posture by default).
  """
  use Ash.Resource.Actions.Implementation

  require Ash.Query

  @impl true
  def run(input, _opts, _context) do
    %{record_id: task_id} = input.arguments.signal

    input.resource
    |> Ash.Query.for_read(:archived)
    |> Ash.Query.filter(parent_id == ^task_id)
    # authz-scope: FK-pinned cascade read — bounded to the restored parent task's direct
    # subtasks (org-authorized parent write)
    |> Ash.read!(authorize?: false)
    |> Enum.each(&Samen.Archival.restore(&1, authorize?: false))

    :ok
  end
end
