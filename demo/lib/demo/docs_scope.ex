defmodule Demo.DocsScope do
  @moduledoc """
  The Demo host's Docs domain — mounted from the `samen_core` Docs scope
  blueprint (ADR-004; F3, T45), mirroring `Demo.CalendarScope`.

  One `use Samen.Scopes.Docs` expands into two host-owned resources
  (`Demo.DocsScope.Doc` + `Demo.DocsScope.Note`), a normal `use Samen.Resource`
  in the DEMO's `otp_app`/`repo`, so:

    * their columns are catalogued in the DEMO's `tam_table`/`fld_field` (the
      `AddDocsScope` migration's `catalog_sync/1`);
    * the DEMO's unchanged verifiers scan them;
    * org-scope + RBAC policies are inherited, not re-authored;
    * `secure_body` is 🔒 vault-routed (`vault: :pii_doc_body` / `:pii_note_body`)
      — masked per plane through the SAME `Samen.Api.PiiResolution` seam every
      other vaulted field uses (INV-1); `body` is the plain, `FreeTextScan`
      -guarded alternative (the "PII-classified routes to vault" mechanism —
      the caller declares classification by which attribute it writes).

  Demo stays API-only (per house layout) — no web-surface router mount here,
  same boundary as `samen_ics_routes`/the Work scope's web LiveViews.
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Docs,
    otp_app: :demo,
    repo: Demo.Repo,
    namespace: Demo.DocsScope,
    abbrevs: %{doc: "ddd", note: "ddn"}
end
