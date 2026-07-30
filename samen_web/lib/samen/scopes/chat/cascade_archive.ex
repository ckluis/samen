defmodule Samen.Scopes.Chat.CascadeArchive do
  @moduledoc """
  Archive-side half of the chat `thread ▸ participant` / `thread ▸ message` composition
  cascade (ADR-040 §5.4: "chat Thread → Message" is one of the three named cascade pairs;
  the roster's ¶ footnote extends the same same-instant cascade to `participant`
  — "archiving a thread also retires its cross-plane grants from default reads on both
  planes"). Mirrors `Samen.Scopes.Cms.CascadeArchive` (T37b) — same self-guard, same
  after_action/force_change_attribute shape — generalized to TWO cascaded resources
  instead of one.

  Self-guards on `changeset.action.name == :archive`. The resource-level
  `changes do change(...) end` block Thread declares this in applies to every action by
  default (create/update/destroy alike); action TYPE (`:destroy`) alone cannot discriminate
  the explicit `:archive` soft-destroy from the plain `:destroy`, so the guard is on the
  action NAME.

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

  Both `ChatParticipant` and `ChatMessage` are `archivable: true` (substrate only — their
  `:archive`/`:restore` actions are policy-locked to `forbid_if(always())` for any real
  actor; see `Samen.Scopes.Chat.Blueprint` moduledoc), so routing each cascaded member
  through its own `:archive` action here — with `authorize?: false`, the ONLY way to reach
  it — keeps the audit trail complete while honoring the "no independent archive" contract.

  Runs inside the parent `:archive` action's transaction (nested `Ash`/`Ecto.Repo.transaction`
  calls in the same process reuse the outer transaction), so a failure here rolls back the
  thread's own archive too.
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

  # `on: [:destroy]` (declared where this change is attached on ChatThread) scopes by
  # action TYPE, so it also reaches `:destroy` (plain) and `:destroy_permanently` —
  # neither should run the cascade (self-guarded to `:archive` in `change/3` above) and
  # both are otherwise atomic-eligible. `:archive` itself is forced non-atomic
  # (`require_atomic?: false`, `Samen.Resource`'s archival_dsl), so it always goes through
  # `change/3` above regardless of what this returns. `:ok` tells Ash's atomicity checker
  # this change contributes nothing when running atomically — without it,
  # `:destroy_permanently` would spuriously lose atomic eligibility just for being the
  # same TYPE as `:archive`.
  @impl true
  def atomic(_changeset, _opts, _context) do
    :ok
  end

  defp cascade_archive_members(changeset, record) do
    case record.archived_at do
      %DateTime{} = instant ->
        archive_all(participant_resource(changeset.resource), record.id, instant)
        archive_all(message_resource(changeset.resource), record.id, instant)
        {:ok, record}

      _ ->
        # Defensive: the parent's own archive somehow left archived_at nil
        # (should not happen post-commit) — nothing to propagate.
        {:ok, record}
    end
  end

  defp archive_all(resource, thread_id, instant) do
    resource
    |> Ash.Query.filter(thread_id == ^thread_id)
    |> Ash.read!(authorize?: false)
    |> Enum.each(&archive_member_at(&1, instant))
  end

  defp archive_member_at(member, instant) do
    member
    |> Ash.Changeset.for_destroy(:archive, %{}, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:archived_at, instant)
    |> Ash.destroy!(authorize?: false)
  end

  defp participant_resource(thread_resource) do
    thread_resource
    |> Ash.Resource.Info.relationship(:participants)
    |> Map.fetch!(:destination)
  end

  defp message_resource(thread_resource) do
    thread_resource
    |> Ash.Resource.Info.relationship(:messages)
    |> Map.fetch!(:destination)
  end
end
