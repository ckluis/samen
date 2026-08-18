defmodule Samen.Scopes.Cms.CascadeRestore do
  @moduledoc """
  Restore-side half of the CMS `page ▸ block` composition cascade — the
  counterpart to `Samen.Scopes.Cms.CascadeArchive` (ADR-040 §5.4: "restore of a
  cascade parent restores exactly the children whose `archived_at` equals the
  parent's — the same-instant match; a child independently archived earlier
  stays archived"). ash_archival ships no restore-cascade primitive at all
  (`Samen.Scopes.Work.CascadeRestore` is the direct precedent for this shape,
  though Work's Task→Subtask cascade restores every archived descendant
  unconditionally — CMS needs the stricter same-instant match because Page and
  Block are DIFFERENT resources with independent archivability, so "a block
  archived on its own" is a real, distinguishable case Work's self-referential
  subtree doesn't have to consider).

  Self-guards on `changeset.action.name == :restore` (mirrors
  `Samen.Scopes.Work.CascadeRestore` — action TYPE alone, `:update`, cannot
  discriminate `:restore` from the plain `:update`, since the DSL's `on:`
  option only filters by type).

  Reads the page's PRE-restore `archived_at` (`changeset.data.archived_at` —
  the exact instant `Samen.Scopes.Cms.CascadeArchive` stamped onto both the
  page and its cascaded blocks) and restores exactly the archived Blocks whose
  own `archived_at` equals that instant. A Block archived independently (a
  different instant, whether before or after the page's cascade-archive) is
  left alone — restore is scoped to the cascade set, not "every archived block
  under this page".

  Runs inside the parent `:restore` action's transaction. A `:restore_conflict`
  on any matched Block aborts the WHOLE transaction (the parent restore
  included) — `Enum.reduce_while` halts on the first error and returns it,
  which the enclosing `after_action` propagates as a transaction rollback,
  never a partial cascade (ADR-040 §5.3/§5.4).
  """
  use Ash.Resource.Change

  require Ash.Query

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, record ->
      if changeset.action.name == :restore do
        restore_matching_blocks(changeset, record)
      else
        {:ok, record}
      end
    end)
  end

  defp restore_matching_blocks(changeset, record) do
    case Ash.Changeset.get_data(changeset, :archived_at) do
      %DateTime{} = instant ->
        block_resource =
          changeset.resource
          |> Ash.Resource.Info.relationship(:blocks)
          |> Map.fetch!(:destination)

        blocks =
          block_resource
          |> Ash.Query.for_read(:archived)
          |> Ash.Query.filter(page_id == ^record.id and archived_at == ^instant)
          |> Ash.read!(authorize?: false)

        Enum.reduce_while(blocks, {:ok, record}, fn block, {:ok, _acc} ->
          case Samen.Archival.restore(block, authorize?: false) do
            {:ok, _} -> {:cont, {:ok, record}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      _ ->
        # The page was already live (idempotent no-op restore) — nothing to
        # cascade; also covers the defensive nil case.
        {:ok, record}
    end
  end
end
