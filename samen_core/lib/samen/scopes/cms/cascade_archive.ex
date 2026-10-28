defmodule Samen.Scopes.Cms.CascadeArchive do
  @moduledoc """
  Archive-side half of the CMS `page ▸ block` composition cascade (ADR-040 §5.4:
  "CMS Page → Block" is one of the three named cascade pairs; "archive_related...
  sets children's `archived_at` to the SAME INSTANT as the parent").

  A listener (issue #96 D3): `Block` runs this generic action when its page emits
  `:archived` (`<Page>.Archival`, `Samen.Archival.Signals`), so `Page` no longer names
  its blocks. The signal carries the page id and the instant just stamped on it, and
  every live block of the page is archived at exactly that instant
  (`Samen.Archival.Cascade.archive_at!/2`). A re-archive of an archived page carries
  the preserved original instant, as before.

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
       approximately-simultaneous one — so the signal threads a SINGLE
       instant explicitly instead of trusting two independent clock reads to
       coincide.
    2. **Audit completeness.** `archive_related` invokes the child resource's
       PRIMARY destroy action — the plain, unaudited `:destroy` — not the
       explicit `:archive` action `Samen.Archival.Archive` is attached to.
       Cascaded blocks would silently skip the `record_archived` audit event
       and the idempotence guard. Routing each block through its own
       `:archive` action keeps the audit trail complete.

  Runs inline, inside the page's `:archive` transaction (`Ash.Signals.Delivery.Inline`),
  so a failure here rolls back the page's own archive too.
  """
  use Ash.Resource.Actions.Implementation

  require Ash.Query

  @impl true
  def run(input, _opts, _context) do
    %{record_id: page_id, archived_at: instant} = input.arguments.signal

    input.resource
    |> Ash.Query.filter(page_id == ^page_id)
    # authz-scope: FK-pinned cascade read — bounded to the just-archived parent page's own
    # blocks, inside that parent's org-authorized archive write
    |> Ash.read!(authorize?: false)
    |> Enum.each(&Samen.Archival.Cascade.archive_at!(&1, instant))

    :ok
  end
end
