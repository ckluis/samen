defmodule Samen.Scopes.Work.CascadeRestore do
  @moduledoc """
  Restore-side half of the Work `task ▸ subtask` cascade — the counterpart to
  `Samen.Scopes.Work.CascadeArchive` (ADR-041 §3.5: "restore matches the instant";
  ADR-040 §5.4: "restore of a cascade parent restores exactly the children whose
  `archived_at` equals the parent's").

  A listener (issue #96 D3) of the task's OWN `:restored` signal (`<Task>.Archival`,
  `Samen.Archival.Signals`). The signal carries the task's PRE-restore `archived_at` —
  the instant `CascadeArchive` stamped onto its whole subtree — and this restores exactly
  the archived DIRECT subtasks archived at that instant. Each of their restores emits its
  own `:restored` with the same instant, so the cascade walks the subtree level by level.
  A subtask archived on its own (a different instant) stays archived, and so does its
  own subtree. A `nil` instant (the task was already live) restores nothing.

  A subtask that fails to restore (a `:restore_conflict`) is returned as the listener's
  error, which fails the parent's restore and rolls the WHOLE transaction back — never a
  partial cascade (ADR-040 §5.3/§5.4).

  Runs `authorize?: false` (a system-level structural cascade following an
  already-authorized parent restore); the listener action itself is reachable only as a
  listener (`signal_in/2` bypass).
  """
  use Ash.Resource.Actions.Implementation

  require Ash.Query

  @impl true
  def run(input, _opts, _context) do
    case input.arguments.signal do
      %{record_id: task_id, archived_at: %DateTime{} = instant} ->
        input.resource
        |> Ash.Query.for_read(:archived)
        |> Ash.Query.filter(parent_id == ^task_id and archived_at == ^instant)
        # authz-scope: FK-pinned cascade read — bounded to the restored parent task's direct
        # subtasks archived at the SAME instant (org-authorized parent write)
        |> Ash.read!(authorize?: false)
        |> Samen.Archival.Cascade.restore_each()

      _ ->
        # The task was already live (idempotent no-op restore) — nothing to cascade.
        :ok
    end
  end
end
