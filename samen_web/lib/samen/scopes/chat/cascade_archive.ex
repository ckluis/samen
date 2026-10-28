defmodule Samen.Scopes.Chat.CascadeArchive do
  @moduledoc """
  Archive-side half of the chat `thread ▸ participant` / `thread ▸ message` composition
  cascade (ADR-040 §5.4: "chat Thread → Message" is one of the three named cascade pairs;
  the roster's ¶ footnote extends the same same-instant cascade to `participant`
  — "archiving a thread also retires its cross-plane grants from default reads on both
  planes"). Mirrors `Samen.Scopes.Cms.CascadeArchive` (T37b), generalized to TWO cascaded resources
  instead of one.

  A listener (issue #96 D3): `ChatParticipant` and `ChatMessage` EACH run this generic
  action when their thread emits `:archived` (`<ChatThread>.Archival`,
  `Samen.Archival.Signals`), each archiving its own rows of that thread, so the thread
  names neither. The signal carries the thread id and the instant just stamped on it.

  ## Why NOT ash_archival's `archive_related` DSL option

  Same two gaps `Samen.Scopes.Cms.CascadeArchive` documents in full:

    1. **Timestamp exactness.** `archive_related` cascades via a separate `Ash.bulk_destroy!`
       against each child's own primary destroy action; `Ash.Resource.Change.SetAttribute`
       calls `DateTime.utc_now/0` ONCE PER invocation, so the parent's stamp and the
       cascaded children's stamp are independent clock reads, not guaranteed byte-identical.
       ADR-040 §5.4's restore-side contract ("restore of a cascade parent restores exactly
       the children whose `archived_at` EQUALS the parent's") needs a real equality.
    2. **Audit completeness.** `archive_related` invokes each child's PRIMARY (plain,
       unaudited) destroy action, not the explicit `:archive` action `Samen.Archival.Archive`
       is attached to — cascaded participants/messages would silently skip the
       `record_archived` audit event and the idempotence guard.

  Both `ChatParticipant` and `ChatMessage` are `archivable: true`. `ChatParticipant`'s
  `:archive`/`:restore` actions are policy-locked to `forbid_if(always())` for any real actor
  (the cross-plane grant-carrier exception, §5.9 ¶); `ChatMessage` carries NO such lock as of
  T125 (ADR-040 §5.4/§5.9 reconciled, posture A) — an authorized actor may also archive a
  message directly. Either way, this listener routes each cascaded member through its own
  `:archive` action with `authorize?: false` (bypassing policy entirely, same as every other
  cascade in this foundry) so the cascade path itself never depends on — and is never blocked
  by — either resource's actor-facing policy, keeping the audit trail complete regardless.

  Runs inline, inside the thread's `:archive` transaction (`Ash.Signals.Delivery.Inline`),
  so a failure here rolls back the thread's own archive too.
  """
  use Ash.Resource.Actions.Implementation

  require Ash.Query

  @impl true
  def run(input, _opts, _context) do
    %{record_id: thread_id, archived_at: instant} = input.arguments.signal

    input.resource
    |> Ash.Query.filter(thread_id == ^thread_id)
    # authz-scope: FK-pinned cascade read — bounded to the archived parent thread's own
    # members, inside that parent's org-authorized archive write
    |> Ash.read!(authorize?: false)
    |> Enum.each(&Samen.Archival.Cascade.archive_at!(&1, instant))

    :ok
  end
end
