defmodule Samen.Versioning.VersionMixin do
  @moduledoc """
  The E7 version-resource governance mixin (ADR-040 §6.2, INV-3).

  ash_paper_trail generates the `<Resource>.Version` resource with a bare
  `use Ash.Resource` (see `AshPaperTrail.Resource.Transformers.CreateVersionResource`).
  On its own that generated table would be an ungoverned exemption: no abbrev, no
  self-qualifying storage prefix, no catalog registration, no `no_plaintext_pii`
  roster membership. §6.2 forbids that — version resources are real AshPostgres
  tables and "get zero exemptions."

  This mixin is passed as the ash_paper_trail `mixin:` option (an `{module, :inject,
  [version_module]}` MFA). `CreateVersionResource` calls `inject/1` and splices the
  returned AST into the generated module body, where the `samen do … end` section
  becomes available because `Samen.Extension` is wired via `version_extensions`
  (`resource.ex`). The section carries the **allocator-owned abbrev** for the version
  resource — reverse-looked-up from the committed registry at build time
  (`Samen.AbbrevRegistry.abbrev_for!/1`), NEVER pinned in code (ADR-023) and never
  hand-edited (the registry is HANDS-OFF; reserve via `mix samen.abbrev.reserve`).

  With the abbrev in place, the version module's own `Samen.Extension` transformers
  give it exactly what any Samen table gets: `<abbrev>_`-prefixed columns
  (`Samen.Transformers.AbbrevStorage`), the universal `org_id`/timestamps
  (`Samen.Transformers.CoreAttributes` — `id` is skipped, the generated resource
  already declares its `uuid_primary_key`), catalog registration (`Samen.Catalog`),
  the registry verifier, and the `NoPanColumns` guard. `org_id` is mirrored from the
  source record via ash_paper_trail's `attributes_as_attributes: [:org_id]` (wired in
  `resource.ex`), so version rows are OrgScope-boundable exactly like the source.

  The jsonb `changes` column rides the existing freeform-projection audit
  (`mix samen.audit.freeform_projection`) — excluded from the CDC projection under
  default-deny, so a `vt_*` token in a diff never mirrors out. INV-1 holds by
  construction upstream (the diff is `Ash.Type.dump_to_embedded/2` output, which for a
  `Samen.Type.VaultField` is the token, never plaintext), for both `:changes_only`
  and `:snapshot` modes.
  """

  @doc """
  Returns the AST spliced into a generated `<Resource>.Version` module: its
  `samen do abbrev "<reserved>" end` section, resolved from the committed registry.

  `version_module` is the fully-qualified generated module name
  (`Module.concat(source, Version)`), the exact owner the abbrev was reserved under.
  Fail-closed: an unreserved version resource raises at compile time
  (`Samen.AbbrevRegistry.abbrev_for!/1`).
  """
  @spec inject(module()) :: Macro.t()
  def inject(version_module) do
    abbrev = Samen.AbbrevRegistry.abbrev_for!(version_module)

    quote do
      samen do
        abbrev(unquote(abbrev))
      end

      # §6.2 (INV-3): version history is OrgScope-bounded exactly like any samen table —
      # a tenant-plane read sees only its org's version rows (via the mirrored org_id),
      # the operator plane sees them masked/token-only. Writes are system-internal (created
      # only by ash_paper_trail's CreateNewVersion inside the source action's transaction,
      # which already enforced the source resource's own policy), so they are authorized by
      # construction — the source write is the gate, not a second policy on the version.
      policies do
        policy action_type(:read) do
          authorize_if(Samen.Policy.OrgScope)
        end

        policy action_type([:create, :update, :destroy]) do
          authorize_if(always())
        end
      end

      # F3.5 same-org FK (scope-authoring guide §10): the generated `version_source`
      # belongs_to targets the (org-scoped) source resource, so the same-org guard is
      # mandatory like any org-scoped belongs_to. It is a formality here — ash_paper_trail
      # sets `version_source_id` from the just-persisted source record (always same-org, by
      # construction) — but declared so the F3.5 verifier holds by rule, not by exception.
      changes do
        change({Samen.Policy.SameOrgFk, relationships: [:version_source]})
      end
    end
  end
end
