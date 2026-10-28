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

  A listener (issue #96 D3): `Conversation` runs this generic action when its ticket
  emits `:archived` (`<Ticket>.Archival`, `Samen.Archival.Signals`), so `Ticket` no
  longer names its conversations or messages. The signal carries the ticket id and
  the instant just stamped on it (the preserved original instant on a re-archive).

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
  `Samen.Scopes.Support.Blueprint` moduledocs). This listener routes each cascaded
  member through its own `:archive` action with `authorize?: false` (bypassing
  policy entirely, same as every other cascade in this foundry) regardless, so
  the cascade path never depends on either resource's actor-facing policy and
  the audit trail stays complete.

  Runs inline, inside the ticket's `:archive` transaction (`Ash.Signals.Delivery.Inline`),
  so a failure here rolls back the ticket's own archive too.
  """
  use Ash.Resource.Actions.Implementation

  require Ash.Query

  @impl true
  def run(input, _opts, _context) do
    %{record_id: ticket_id, archived_at: instant} = input.arguments.signal

    conversations = live_conversations(input.resource, ticket_id)
    Enum.each(conversations, &Samen.Archival.Cascade.archive_at!(&1, instant))

    input.resource
    |> message_resource()
    |> archive_live_messages(Enum.map(conversations, & &1.id), instant)

    :ok
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
    |> Enum.each(&Samen.Archival.Cascade.archive_at!(&1, instant))
  end

  defp message_resource(conversation_resource) do
    conversation_resource
    |> Ash.Resource.Info.relationship(:messages)
    |> Map.fetch!(:destination)
  end
end
