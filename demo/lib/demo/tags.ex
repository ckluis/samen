defmodule Demo.Tags do
  @moduledoc """
  The Demo host's Tags domain — mounted from the `samen_core` Tags scope blueprint
  (ADR-004; F4, T46), mirroring `Demo.DocsScope`/`Demo.CalendarScope`.

  One `use Samen.Scopes.Tags` expands into two host-owned resources
  (`Demo.Tags.Tag` + `Demo.Tags.Tagging`), a normal `use Samen.Resource` in the DEMO's
  `otp_app`/`repo`, so:

    * their columns are catalogued in the DEMO's `tam_table`/`fld_field` (the
      `AddTagsScope` migration's `catalog_sync/1`);
    * the DEMO's unchanged verifiers scan them;
    * org-scope + RBAC policies are inherited, not re-authored;
    * `Tag` is archivable (ADR-040 §5.9); `Tagging` is a pure join row (not
      archivable — untag is a real destroy).

  ## Deliberate naming: `Demo.Tags`, not `Demo.TagsScope`

  Demo's OTHER scope modules (`SupportScope`, `DocsScope`, `CrmScope`, …) carry a
  `Scope` suffix as a LOCAL Demo convention. This scope does NOT — see
  `Samen.Scopes.Tags` moduledoc "Deliberate naming" for why: it makes the
  `Samen.Web.ObjectRef.Catalog` key `tags.tag`/`tags.tagging` uniform across every
  host (driftwood/pawchart/samen_web already use the un-suffixed style), which is
  what lets the Ticket-tags read join (`Samen.Web.Support.Reads.ticket_tag_names/3`)
  derive the Tagging module identically on every host, demo included.

  Demo stays API-only (per house layout) — no web-surface router mount here, same
  boundary as `Demo.DocsScope`.
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Tags,
    otp_app: :demo,
    repo: Demo.Repo,
    namespace: Demo.Tags,
    abbrevs: %{tag: "dtt", tagging: "tdt"}
end
