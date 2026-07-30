defmodule Samen.Scopes.Tags.Blueprint do
  @moduledoc """
  Resource-definition macros for the **Tags** scope (F4; spec §F4, spec-questions c7).

  Two resources: **`Tag`** (an org-scoped, colored label) and **`Tagging`** (the
  polymorphic JOIN attaching a Tag to ANY object via the generic `(subject_key,
  subject_id)` object-ref anchor — the SAME CRM-agnostic pattern
  `Samen.Scopes.Work.Task`/`Samen.Scopes.Docs.{Doc,Note}` established, ADR-041 §4.1).

  ## Why two resources, not one

  A Tag is the reusable LABEL (`"vip"`, colored purple) — one row per org per name. A
  Tagging is one ATTACHMENT of that label to one object (a ticket, a CRM person, …) —
  many rows per Tag. This mirrors the standard label/assignment split (never duplicate
  the label string per attachment; a rename touches one Tag row, not N taggings).

  ## `color` — bounded palette (c7: "not free hex")

  `Tag.color` is a bounded atom enum (house convention: every enum in this codebase is
  declared inline via `constraints: [one_of: [...]]`, e.g. `Ticket.status`/`.priority` —
  there is no `Samen.Type.Color`; free hex input is explicitly rejected per c7).

  ## Org-scoped uniqueness (done-criterion 1)

  A Tag's `name` is unique PER ORG among LIVE (non-archived) rows — the ADR-040 §5.3
  partial-index convention (`WHERE <abbrev>_archived_at IS NULL`), declared in the
  HOST migration (Samen has no Ash identities). Two different orgs may both have a
  `"vip"` tag; the same org may not have two live `"vip"` Tag rows.

  ## Polymorphic attachment (done-criterion 1: "on ≥2 resource types")

  `Tagging.subject_key`/`subject_id` are plain scalars — never a FK — so ONE `Tagging`
  table attaches a Tag to a ticket, a CRM person, a Work task, or any future catalogued
  object, without a schema change. Org-scope enforcement for the anchor is NOT
  re-implemented at this substrate layer (there is no host contact here, matching the
  T43/T45 partition) — it rides the SAME mechanism ADR-041 §6.1 names: a higher
  (samen_web) write helper resolves the subject ref through the org-scoped
  `Samen.Web.ObjectRef.resolve/3` BEFORE anchoring (see `Samen.Web.Tags.attach/5`).
  `Tagging.tag_id` IS a real same-scope `belongs_to` (Tag and Tagging are materialized
  together by the same blueprint call) — guarded by `Samen.Policy.SameOrgFk` so a
  Tagging can never reference another org's Tag.

  A Tag may attach to the SAME object only once (`unique_index(tag_id, subject_key,
  subject_id)`, host migration) — re-attaching is a no-op read, not a duplicate row.

  ## INV-1 — a Tagging cannot leak the tagged object's vault fields

  `Tagging` carries ONLY `tag_id` + the opaque `(subject_key, subject_id)` anchor — no
  copy, snapshot, or denormalization of ANY field from the tagged object. There is
  structurally no attribute on `Tagging` capable of holding the subject's vaulted data;
  a leak would require a NEW attribute, not a masking failure. `Tag.name`/`.color` are
  operator-authored labels, not subject PII (the doc's own words: "Tag names are
  unlikely PII" — c7 posture, not vault-routed).

  ## Soft-delete (ADR-040 §5.9)

  `Tag` is `archivable: true` (a user-managed noun — archiving/restoring a label).
  `Tagging` is NOT archivable — it is a pure join row; "removing a tag from an object"
  is a real destroy (untag), mirroring how `chat.participant`/join-shaped rows are
  treated elsewhere in this codebase (no independent trash state for a pure edge).

  ## Storage-name discipline

  Every column is `<abbrev>_<name>`, matching every other Samen scope.
  """

  # ---------------------------------------------------------------------------
  # Tag — an org-scoped, colored label. Archivable. Unique name per org (host
  # migration: partial unique index WHERE <abbrev>_archived_at IS NULL).
  # ---------------------------------------------------------------------------
  defmacro define_tag(module, otp_app, domain, repo, abbrev) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Tags.Tag — an org-scoped, colored label (F4). `name` is unique per org among
        LIVE rows (partial unique index, host migration). `color` is a BOUNDED palette
        enum (spec-questions c7 — never free hex). Archivable (ADR-040 §5.9). No PII.
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev),
          archivable: true

        postgres do
          table("#{unquote(abbrev)}_tag")
          repo(unquote(repo))
        end

        attributes do
          attribute(:name, :string, public?: true, allow_nil?: false)

          # Bounded palette (c7: "not free hex") — inline enum, matching every other
          # enum in this codebase (Ticket.status/.priority, Agent.role, ...).
          attribute(:color, :atom,
            public?: true,
            default: :gray,
            constraints: [
              one_of: [:gray, :red, :orange, :yellow, :green, :teal, :blue, :purple, :pink]
            ]
          )
        end

        actions do
          defaults([:read, :destroy, create: :*, update: :*])
        end

        policies do
          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end

          policy action_type([:create, :update, :destroy]) do
            forbid_unless(Samen.Policy.OrgScope)
            forbid_unless({Samen.Policy.RoleAtLeast, role: :member})
            authorize_if(always())
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Tagging — the polymorphic JOIN: one Tag attached to one object. `tag_id` is a
  # real same-scope belongs_to (SameOrgFk-guarded); subject_key/subject_id are the
  # generic object-ref anchor (plain scalars, org-scope enforced at the samen_web
  # write boundary, mirroring Work.Task/Docs.{Doc,Note}). NOT archivable (a pure
  # join row — untag is a real destroy).
  # ---------------------------------------------------------------------------
  defmacro define_tagging(module, otp_app, domain, repo, abbrev, tag_mod) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Tags.Tagging — the polymorphic JOIN attaching a `Tag` to any object via the
        generic `(subject_key, subject_id)` object-ref anchor (F4). `tag_id` is a real
        same-scope `belongs_to` (SameOrgFk-guarded — a Tagging can never reference
        another org's Tag). Carries NO copy of the tagged object's own fields (INV-1 —
        structurally cannot leak vault data). NOT archivable (a pure join row; untag is
        a real destroy). Unique per (tag, subject) — host migration.
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_tagging")
          repo(unquote(repo))
        end

        attributes do
          # The generic object-ref anchor (mirrors Samen.Scopes.Work.Task /
          # Samen.Scopes.Docs.{Doc,Note}) — CRM/host-agnostic, never a belongs_to.
          # Org-scope enforced at the samen_web ObjectRef.resolve write boundary,
          # not here (Samen.Web.Tags.attach/5).
          attribute(:subject_key, :string, public?: true, allow_nil?: false)
          attribute(:subject_id, :uuid, public?: true, allow_nil?: false)
        end

        relationships do
          belongs_to :tag, unquote(tag_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(false)
          end
        end

        # F3.5-style same-org FK: a Tagging may only reference a same-org Tag.
        changes do
          change({Samen.Policy.SameOrgFk, relationships: [:tag]})
        end

        actions do
          defaults([:read, :destroy, create: :*])
        end

        policies do
          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end

          policy action_type([:create, :destroy]) do
            forbid_unless(Samen.Policy.OrgScope)
            forbid_unless({Samen.Policy.RoleAtLeast, role: :member})
            authorize_if(always())
          end
        end
      end
    end
  end
end
