defmodule Samen.Scopes.Support.CascadeRestore do
  @moduledoc """
  Restore-side half of the support `ticket ▸ conversation ▸ message` composition
  cascade — the counterpart to `Samen.Scopes.Support.CascadeArchive` (ADR-040
  §5.4: "restore of a cascade parent restores exactly the children whose
  `archived_at` equals the parent's — the same-instant match; a child
  independently archived earlier stays archived"). Mirrors
  `Samen.Scopes.Cms.CascadeRestore` (T37b) / `Samen.Scopes.Chat.CascadeRestore`
  (T37e), generalized one level deeper (see `CascadeArchive`'s moduledoc for why).

  Self-guards on `changeset.action.name == :restore` (action TYPE alone,
  `:update`, cannot discriminate `:restore` from the plain `:update`, since the
  DSL's `on:` option only filters by type).

  Reads the ticket's PRE-restore `archived_at` (`changeset.data.archived_at` —
  the exact instant `Samen.Scopes.Support.CascadeArchive` stamped onto the ticket
  and its cascaded conversations/messages) and restores exactly the archived
  Conversations under this ticket whose own `archived_at` equals that instant,
  THEN — scoped to exactly those matched conversation ids — the archived
  Messages whose `archived_at` ALSO equals that instant. Both hops filter by BOTH
  the id scope (`ticket_id`/`conversation_id in [...]`) AND the instant equality:
  the id scope alone would already prevent cross-ticket leakage (a DIFFERENT
  ticket's cascade-archived conversation can never match this query, regardless
  of any timestamp collision), and the instant equality alone would not be
  sufficient without it (see the T124-adjacent same-wall-clock-second defense
  this buys — the scope's leak red test exercises this directly with two
  tickets whose cascades collide in the same second).

  ## "Independently archived, stays archived" (T125, posture A)

  As of T125 (ADR-040 §5.4/§5.9 reconciled), `Conversation`/`Message` carry no
  `forbid_if(always())` lock — an authorized actor CAN archive either directly,
  independent of the ticket's cascade (see `Samen.Scopes.Support.Blueprint`
  moduledocs). So, exactly like CMS's `Block`, it is now possible to construct a
  conversation/message that is "independently archived, at a different instant,
  under the SAME still-live ticket": this restore's dual `ticket_id`/
  `conversation_id` id-scope AND `archived_at` instant-equality match excludes
  it precisely because its `archived_at` does not equal the ticket's own cascade
  instant — the id-scope alone would NOT be enough to exclude it here (unlike the
  cross-ticket case below, where id-scope alone already suffices). The contract
  is ALSO still exercised, as before, via a DIFFERENT ticket's cascade-archived
  conversation/message, which this restore's `ticket_id`/`conversation_id`
  scoping structurally can never touch regardless of any timestamp collision —
  both cases are covered by the scope's test suite.

  Runs inside the parent `:restore` action's transaction. A `:restore_conflict` on
  any matched member aborts the WHOLE transaction (the parent restore included) —
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
        conversation_resource = conversation_resource(changeset.resource)
        message_resource = message_resource(conversation_resource)

        matching_conversations =
          matching_archived_conversations(conversation_resource, record.id, instant)

        conversation_ids = Enum.map(matching_conversations, & &1.id)

        matching_messages =
          matching_archived_messages(message_resource, conversation_ids, instant)

        members = matching_conversations ++ matching_messages

        Enum.reduce_while(members, {:ok, record}, fn member, {:ok, _acc} ->
          case Samen.Archival.restore(member, authorize?: false) do
            {:ok, _} -> {:cont, {:ok, record}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      _ ->
        # The ticket was already live (idempotent no-op restore) — nothing to
        # cascade; also covers the defensive nil case.
        {:ok, record}
    end
  end

  defp matching_archived_conversations(resource, ticket_id, instant) do
    resource
    |> Ash.Query.for_read(:archived)
    |> Ash.Query.filter(ticket_id == ^ticket_id and archived_at == ^instant)
    # authz-scope: FK-pinned cascade read — bounded to the restored parent ticket's
    # conversations archived at the SAME instant (org-authorized parent write)
    |> Ash.read!(authorize?: false)
  end

  defp matching_archived_messages(_resource, [], _instant), do: []

  defp matching_archived_messages(resource, conversation_ids, instant) do
    resource
    |> Ash.Query.for_read(:archived)
    |> Ash.Query.filter(conversation_id in ^conversation_ids and archived_at == ^instant)
    # authz-scope: FK-pinned cascade read — bounded to exactly the conversation ids restored by THIS sweep
    |> Ash.read!(authorize?: false)
  end

  defp conversation_resource(ticket_resource) do
    ticket_resource
    |> Ash.Resource.Info.relationship(:conversations)
    |> Map.fetch!(:destination)
  end

  defp message_resource(conversation_resource) do
    conversation_resource
    |> Ash.Resource.Info.relationship(:messages)
    |> Map.fetch!(:destination)
  end
end
