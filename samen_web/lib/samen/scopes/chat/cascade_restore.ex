defmodule Samen.Scopes.Chat.CascadeRestore do
  @moduledoc """
  Restore-side half of the chat `thread ▸ participant` / `thread ▸ message` composition
  cascade — the counterpart to `Samen.Scopes.Chat.CascadeArchive` (ADR-040 §5.4: "restore of
  a cascade parent restores exactly the children whose `archived_at` equals the parent's —
  the same-instant match; a child independently archived earlier stays archived"). Mirrors
  `Samen.Scopes.Cms.CascadeRestore` (T37b), generalized to TWO cascaded resources.

  A listener (issue #96 D3): `ChatParticipant` and `ChatMessage` EACH run this generic
  action when their thread emits `:restored` (`<ChatThread>.Archival`). The signal carries
  the thread's PRE-restore `archived_at` — the exact instant `Samen.Scopes.Chat.CascadeArchive` stamped onto both the thread and its cascaded
  participants/messages) and restores exactly the archived Participants/Messages whose own
  `archived_at` equals that instant. A member archived independently (a different instant,
  whether before or after the thread's cascade-archive, or a distinct wall-clock second, or
  the SAME wall-clock second but a different microsecond post-T124) is left alone — restore
  is scoped to the cascade set, not "every archived member under this thread".

  Runs inline, inside the thread's `:restore` transaction. A `:restore_conflict` on any
  matched member is returned as the listener's error, which fails the thread's restore and
  rolls the WHOLE transaction back — never a partial cascade. A `nil` instant (the thread
  was already live) restores nothing.
  """
  use Ash.Resource.Actions.Implementation

  require Ash.Query

  @impl true
  def run(input, _opts, _context) do
    case input.arguments.signal do
      %{record_id: thread_id, archived_at: %DateTime{} = instant} ->
        input.resource
        |> Ash.Query.for_read(:archived)
        |> Ash.Query.filter(thread_id == ^thread_id and archived_at == ^instant)
        # authz-scope: FK-pinned cascade read — bounded to the restored parent thread's members
        # archived at the SAME instant (org-authorized parent write)
        |> Ash.read!(authorize?: false)
        |> Samen.Archival.Cascade.restore_each()

      _ ->
        # The thread was already live (idempotent no-op restore) — nothing to cascade.
        :ok
    end
  end
end
