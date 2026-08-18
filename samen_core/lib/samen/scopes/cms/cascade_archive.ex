defmodule Samen.Scopes.Cms.CascadeArchive do
  @moduledoc """
  Archive-side half of the CMS `page ▸ block` composition cascade (ADR-040 §5.4:
  "CMS Page → Block" is one of the three named cascade pairs; "archive_related...
  sets children's `archived_at` to the SAME INSTANT as the parent").

  Self-guards on `changeset.action.name == :archive` — the resource-level
  `changes do change(...) end` block Page declares this in applies to every
  action by default (create/update/destroy alike); action TYPE (`:destroy`)
  alone cannot discriminate the explicit `:archive` soft-destroy from the plain
  `:destroy`, so the guard is on the action NAME (the same reasoning
  `Samen.Scopes.Work.CascadeRestore` documents for its own self-guard).

  ## Why NOT ash_archival's `archive_related` DSL option

  `archive_related([:blocks])` is the textbook mechanism (and the one
  `Samen.Scopes.Work.Blueprint`'s Task→Subtask cascade uses), but it has two
  gaps that matter for the CMS scope's binding same-instant contract:

    1. **Timestamp exactness.** `archive_related` cascades via a SEPARATE
       `Ash.bulk_destroy!` call against the children's own primary destroy
       action. `Ash.Resource.Change.SetAttribute` (the builtin behind
       ash_archival's `archived_at` stamp) calls `value.()` — i.e.
       `DateTime.utc_now/0` — ONCE PER invocation (`ash/lib/ash/resource/
       change/set_attribute.ex`), so the parent's own stamp and the cascaded
       children's stamp are two INDEPENDENT clock reads, not guaranteed
       byte-identical. ADR-040 §5.4's restore-side contract ("restore of a
       cascade parent restores exactly the children whose `archived_at`
       EQUALS the parent's") needs a real equality, not an
       approximately-simultaneous one — so this change threads a SINGLE
       instant explicitly instead of trusting two independent clock reads to
       coincide.
    2. **Audit completeness.** `archive_related` invokes the child resource's
       PRIMARY destroy action — the plain, unaudited `:destroy` — not the
       explicit `:archive` action `Samen.Archival.Archive` is attached to.
       Cascaded blocks would silently skip the `record_archived` audit event
       and the idempotence guard. Routing each block through its own
       `:archive` action (as this change does) keeps the audit trail
       complete.

  Runs inside the parent `:archive` action's transaction (same DB transaction
  as the page's own soft-destroy — nested `Ash`/`Ecto.Repo.transaction` calls
  in the same process reuse the outer transaction rather than opening a new
  one), so a failure here rolls back the page's own archive too.
  """
  use Ash.Resource.Change

  require Ash.Query

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, record ->
      if changeset.action.name == :archive do
        cascade_archive_blocks(changeset, record)
      else
        {:ok, record}
      end
    end)
  end

  # `on: [:destroy]` (declared where this change is attached on Page) scopes
  # by action TYPE, so it also reaches `:destroy` (plain) and
  # `:destroy_permanently` — neither should run the cascade (self-guarded to
  # `:archive` in `change/3` above) and both are otherwise atomic-eligible.
  # `:archive` itself is forced non-atomic (`require_atomic?: false`,
  # `Samen.Resource`'s archival_dsl), so it always goes through `change/3`
  # above regardless of what this returns. `:ok` tells Ash's atomicity
  # checker this change contributes nothing when running atomically —
  # without it, `:destroy_permanently` would spuriously lose atomic
  # eligibility just for being the same TYPE as `:archive`.
  @impl true
  def atomic(_changeset, _opts, _context) do
    :ok
  end

  defp cascade_archive_blocks(changeset, record) do
    case record.archived_at do
      %DateTime{} = instant ->
        changeset.resource
        |> block_resource()
        |> Ash.Query.filter(page_id == ^record.id)
        |> Ash.read!(authorize?: false)
        |> Enum.each(&archive_block_at(&1, instant))

        {:ok, record}

      _ ->
        # Defensive: the parent's own archive somehow left archived_at nil
        # (should not happen post-commit) — nothing to propagate.
        {:ok, record}
    end
  end

  defp archive_block_at(block, instant) do
    block
    |> Ash.Changeset.for_destroy(:archive, %{}, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:archived_at, instant)
    |> Ash.destroy!(authorize?: false)
  end

  defp block_resource(page_resource) do
    page_resource
    |> Ash.Resource.Info.relationship(:blocks)
    |> Map.fetch!(:destination)
  end
end
