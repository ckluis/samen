defmodule Samen.Scopes.Cms.CascadeRestore do
  @moduledoc """
  Restore-side half of the CMS `page ▸ block` composition cascade — the
  counterpart to `Samen.Scopes.Cms.CascadeArchive` (ADR-040 §5.4: "restore of a
  cascade parent restores exactly the children whose `archived_at` equals the
  parent's — the same-instant match; a child independently archived earlier
  stays archived"). ash_archival ships no restore-cascade primitive at all
  (`Samen.Scopes.Work.CascadeRestore` has the same shape for the Task→Subtask
  tree).

  A listener (issue #96 D3): `Block` runs this generic action when its page emits
  `:restored` (`<Page>.Archival`). The signal carries the page's PRE-restore
  `archived_at` — the exact instant `Samen.Scopes.Cms.CascadeArchive` stamped onto both
  the page and its cascaded blocks — and this restores exactly the archived Blocks
  whose own `archived_at` equals that instant. A Block archived independently (a
  different instant, whether before or after the page's cascade-archive) is left
  alone — restore is scoped to the cascade set, not "every archived block under this
  page". A `nil` instant (the page was already live) restores nothing.

  Runs inline, inside the page's `:restore` transaction. A `:restore_conflict` on any
  matched Block is returned as the listener's error, which fails the page's restore and
  rolls the WHOLE transaction back — never a partial cascade (ADR-040 §5.3/§5.4).
  """
  use Ash.Resource.Actions.Implementation

  require Ash.Query

  @impl true
  def run(input, _opts, _context) do
    case input.arguments.signal do
      %{record_id: page_id, archived_at: %DateTime{} = instant} ->
        input.resource
        |> Ash.Query.for_read(:archived)
        |> Ash.Query.filter(page_id == ^page_id and archived_at == ^instant)
        # authz-scope: FK-pinned cascade read — bounded to the restored parent page's blocks
        # archived at the SAME instant (org-authorized parent write)
        |> Ash.read!(authorize?: false)
        |> Samen.Archival.Cascade.restore_each()

      _ ->
        # The page was already live (idempotent no-op restore) — nothing to cascade.
        :ok
    end
  end
end
