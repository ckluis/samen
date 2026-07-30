defmodule Samen.Archival.OnlyArchived do
  @moduledoc """
  The trash-view filter for the `:archived` read (ADR-040 §5.2). ash_archival's
  `FilterArchived` gives you two postures per read: filtered (`is_nil(archived_at)`, live
  only) or — via `exclude_read_actions` — unfiltered (all rows). Neither is a *trash view*.

  `:archived` is declared in `exclude_read_actions` (so ash_archival adds no filter) and gets
  THIS preparation instead, which adds `not is_nil(archived_at)` — **only archived rows**, the
  surface trash UIs and the retention sweep read. Samen glue ash_archival does not ship.
  """
  use Ash.Resource.Preparation

  require Ash.Query

  @impl true
  def prepare(query, _opts, _context) do
    Ash.Query.filter(query, not is_nil(archived_at))
  end
end
