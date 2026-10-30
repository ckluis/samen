defmodule Samen.Scopes.Work.CascadeArchive do
  @moduledoc """
  Archive-side half of the Work `task ▸ subtask` cascade (ADR-041 §3.5: "archiving a
  parent task archives its subtree at the same instant, restore matches the instant").

  A listener (issue #96 D3) of the task's OWN `:archived` signal (`<Task>.Archival`,
  `Samen.Archival.Signals`): every live DIRECT subtask is archived at exactly the
  parent's instant (`Samen.Archival.Cascade.archive_at!/2`), and each subtask's archive
  emits its own `:archived` with that same instant, so the whole subtree lands on one
  instant level by level. `Samen.Scopes.Work.CycleGuard` refuses a parent cycle, so the
  recursion ends at the leaves. A subtask already archived on its own keeps its own
  instant, which is what lets `Samen.Scopes.Work.CascadeRestore` leave it archived.

  This replaces ash_archival's `archive_related([:subtasks])`, for the two reasons
  `Samen.Scopes.Cms.CascadeArchive` gives: `archive_related` stamps each level with its
  own `DateTime.utc_now/0` read (so a same-instant restore could never match), and it
  runs the subtasks' plain primary `:destroy`, skipping the `record_archived` audit of
  `Samen.Archival.Archive`.

  Runs inline, inside the parent's `:archive` transaction, so a failure here rolls back
  the parent's own archive too.
  """
  use Ash.Resource.Actions.Implementation

  require Ash.Query

  @impl true
  def run(input, _opts, _context) do
    %{record_id: task_id, archived_at: instant} = input.arguments.signal

    input.resource
    |> Ash.Query.filter(parent_id == ^task_id)
    # authz-scope: FK-pinned cascade read — bounded to the just-archived parent task's live
    # direct subtasks, inside that parent's org-authorized archive write
    |> Ash.read!(authorize?: false)
    |> Enum.each(&Samen.Archival.Cascade.archive_at!(&1, instant))

    :ok
  end
end
