defmodule Samen.Scopes.Support.CascadeArchive do
  @moduledoc """
  Archive-side half of the support `ticket ▸ conversation ▸ message` composition
  cascade (ADR-040 §5.4: "Ticket → Conversation → Message" is the ADR's own
  canonical worked example of a composition cascade). Mirrors
  `Samen.Scopes.Cms.CascadeArchive` (T37b) and `Samen.Scopes.Chat.CascadeArchive`
  (T37e) — same self-guard, same `after_action`/`force_change_attribute` shape —
  generalized ONE LEVEL DEEPER: unlike CMS's `page ▸ block` and chat's
  `thread ▸ {participant, message}` (both single-hop: every cascaded child has a
  DIRECT foreign key to the cascade parent), support's `message` is NOT directly
  FKed to `ticket` — only to `conversation`, which is itself the direct cascade
  child. So this module sweeps in two hops: first Conversations by `ticket_id`,
  then Messages by `conversation_id` scoped to EXACTLY the conversations just
  swept (never "every message under this ticket ever" — there is no such query
  since message has no ticket_id column at all).

  Self-guards on `changeset.action.name == :archive`. The resource-level
  `changes do change(...) end` block Ticket declares this in applies to every
  action by default (create/update/destroy alike); action TYPE (`:destroy`) alone
  cannot discriminate the explicit `:archive` soft-destroy from the plain
  `:destroy`, so the guard is on the action NAME.

  ## Why NOT ash_archival's `archive_related` DSL option

  Same two gaps `Samen.Scopes.Cms.CascadeArchive`/`Samen.Scopes.Chat.CascadeArchive`
  document in full:

    1. **Timestamp exactness.** `archive_related` cascades via a separate
       `Ash.bulk_destroy!` against each child's own primary destroy action;
       `Ash.Resource.Change.SetAttribute` calls `DateTime.utc_now/0` ONCE PER
       invocation, so the parent's stamp and the cascaded children's stamp are
       independent clock reads, not guaranteed byte-identical. ADR-040 §5.4's
       restore-side contract ("restore of a cascade parent restores exactly the
       children whose `archived_at` EQUALS the parent's") needs a real equality —
       doubly so here, where the equality check is the ONLY thing that lets a
       message's restore-time query recover which conversation it belongs to
       under a given ticket-archive instant (see `CascadeRestore`).
    2. **Audit completeness.** `archive_related` invokes each child's PRIMARY
       (plain, unaudited) destroy action, not the explicit `:archive` action
       `Samen.Archival.Archive` is attached to — cascaded conversations/messages
       would silently skip the `record_archived` audit event and the idempotence
       guard.

  Both `Conversation` and `Message` are `archivable: true`, and — as of T125
  (ADR-040 §5.4/§5.9 reconciled, posture A) — neither carries a
  `forbid_if(always())` lock: both are ordinary independently-archivable
  resources (an authorized actor may also archive either directly; see
  `Samen.Scopes.Support.Blueprint` moduledocs). This change routes each cascaded
  member through its own `:archive` action with `authorize?: false` (bypassing
  policy entirely, same as every other cascade in this foundry) regardless, so
  the cascade path never depends on either resource's actor-facing policy and
  the audit trail stays complete.

  Runs inside the parent `:archive` action's transaction (nested `Ash`/
  `Ecto.Repo.transaction` calls in the same process reuse the outer transaction),
  so a failure here rolls back the ticket's own archive too.
  """
  use Ash.Resource.Change

  require Ash.Query

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, record ->
      if changeset.action.name == :archive do
        cascade_archive_members(changeset, record)
      else
        {:ok, record}
      end
    end)
  end

  # `on: [:destroy]` (declared where this change is attached on Ticket) scopes by
  # action TYPE, so it also reaches `:destroy` (plain) and `:destroy_permanently` —
  # neither should run the cascade (self-guarded to `:archive` in `change/3` above)
  # and both are otherwise atomic-eligible. `:archive` itself is forced non-atomic
  # (`require_atomic?: false`, `Samen.Resource`'s archival_dsl), so it always goes
  # through `change/3` above regardless of what this returns. `:ok` tells Ash's
  # atomicity checker this change contributes nothing when running atomically —
  # without it, `:destroy_permanently` would spuriously lose atomic eligibility
  # just for being the same TYPE as `:archive`.
  @impl true
  def atomic(_changeset, _opts, _context) do
    :ok
  end

  defp cascade_archive_members(changeset, record) do
    case record.archived_at do
      %DateTime{} = instant ->
        conversation_resource = conversation_resource(changeset.resource)
        message_resource = message_resource(conversation_resource)

        conversations = live_conversations(conversation_resource, record.id)
        Enum.each(conversations, &archive_member_at(&1, instant))

        conversation_ids = Enum.map(conversations, & &1.id)
        archive_live_messages(message_resource, conversation_ids, instant)

        {:ok, record}

      _ ->
        # Defensive: the parent's own archive somehow left archived_at nil
        # (should not happen post-commit) — nothing to propagate.
        {:ok, record}
    end
  end

  defp live_conversations(resource, ticket_id) do
    resource
    |> Ash.Query.filter(ticket_id == ^ticket_id)
    # authz-scope: FK-pinned cascade read — bounded to the just-archived parent ticket's own
    # conversations, inside that parent's org-authorized archive write
    |> Ash.read!(authorize?: false)
  end

  # Sweeps messages by `conversation_id in [...]`, scoped to EXACTLY the
  # conversations just archived above in THIS sweep — i.e. the conversations
  # that were still LIVE under this ticket a moment ago (`live_conversations/2`
  # reads through the default, archived-excluding preparation). As of T125,
  # Conversation is independently-archivable, so a live ticket CAN also have
  # already-archived conversations — those are correctly excluded from
  # `live_conversations/2`'s result and therefore never re-swept here (they
  # keep their own, earlier `archived_at`, per §5.4's independent-archive
  # contract), leaving only the conversations this ticket-archive itself just
  # cascaded into.
  defp archive_live_messages(_resource, [], _instant), do: :ok

  defp archive_live_messages(resource, conversation_ids, instant) do
    resource
    |> Ash.Query.filter(conversation_id in ^conversation_ids)
    # authz-scope: FK-pinned cascade read — bounded to exactly the conversation ids archived
    # by THIS sweep (the parent write was org-authorized)
    |> Ash.read!(authorize?: false)
    |> Enum.each(&archive_member_at(&1, instant))
  end

  defp archive_member_at(member, instant) do
    member
    |> Ash.Changeset.for_destroy(:archive, %{}, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:archived_at, instant)
    |> Ash.destroy!(authorize?: false)
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
