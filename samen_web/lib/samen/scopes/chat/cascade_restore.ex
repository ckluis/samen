defmodule Samen.Scopes.Chat.CascadeRestore do
  @moduledoc """
  Restore-side half of the chat `thread ▸ participant` / `thread ▸ message` composition
  cascade — the counterpart to `Samen.Scopes.Chat.CascadeArchive` (ADR-040 §5.4: "restore of
  a cascade parent restores exactly the children whose `archived_at` equals the parent's —
  the same-instant match; a child independently archived earlier stays archived"). Mirrors
  `Samen.Scopes.Cms.CascadeRestore` (T37b), generalized to TWO cascaded resources.

  Self-guards on `changeset.action.name == :restore` (action TYPE alone, `:update`, cannot
  discriminate `:restore` from the plain `:update`, since the DSL's `on:` option only
  filters by type).

  Reads the thread's PRE-restore `archived_at` (`changeset.data.archived_at` — the exact
  instant `Samen.Scopes.Chat.CascadeArchive` stamped onto both the thread and its cascaded
  participants/messages) and restores exactly the archived Participants/Messages whose own
  `archived_at` equals that instant. A member archived independently (a different instant,
  whether before or after the thread's cascade-archive, or a distinct wall-clock second, or
  the SAME wall-clock second but a different microsecond post-T124) is left alone — restore
  is scoped to the cascade set, not "every archived member under this thread".

  Runs inside the parent `:restore` action's transaction. A `:restore_conflict` on any
  matched member aborts the WHOLE transaction (the parent restore included) —
  `Enum.reduce_while` halts on the first error and returns it, which the enclosing
  `after_action` propagates as a transaction rollback, never a partial cascade.
  """
  use Ash.Resource.Change

  require Ash.Query

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, record ->
      if changeset.action.name == :restore do
        restore_matching_members(changeset, record)
      else
        {:ok, record}
      end
    end)
  end

  defp restore_matching_members(changeset, record) do
    case Ash.Changeset.get_data(changeset, :archived_at) do
      %DateTime{} = instant ->
        participant_resource =
          changeset.resource
          |> Ash.Resource.Info.relationship(:participants)
          |> Map.fetch!(:destination)

        message_resource =
          changeset.resource
          |> Ash.Resource.Info.relationship(:messages)
          |> Map.fetch!(:destination)

        members =
          matching_archived(participant_resource, record.id, instant) ++
            matching_archived(message_resource, record.id, instant)

        Enum.reduce_while(members, {:ok, record}, fn member, {:ok, _acc} ->
          case Samen.Archival.restore(member, authorize?: false) do
            {:ok, _} -> {:cont, {:ok, record}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      _ ->
        # The thread was already live (idempotent no-op restore) — nothing to
        # cascade; also covers the defensive nil case.
        {:ok, record}
    end
  end

  defp matching_archived(resource, thread_id, instant) do
    resource
    |> Ash.Query.for_read(:archived)
    |> Ash.Query.filter(thread_id == ^thread_id and archived_at == ^instant)
    |> Ash.read!(authorize?: false)
  end
end
