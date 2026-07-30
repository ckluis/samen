defmodule Samen.Scopes.Docs.Blueprint do
  @moduledoc """
  Resource-definition macros for the **Docs** scope (F3; spec §F3/§F8).

  Two resources: **`Doc`** (a titled rich-text document) and **`Note`** (an untitled
  short annotation) — both attachable to ANY object via the generic `(subject_key,
  subject_id)` object-ref anchor (the SAME CRM-agnostic pattern `Samen.Scopes.Work.Task`
  established, ADR-041 §4.1: a plain scalar pair, never a cross-scope `belongs_to`).

  ## Distinct from CMS `Page`/`Post` (spec F3)

  `Doc`/`Note` are NOT CMS content. CMS `Page`/`Post` (`Samen.Scopes.Cms`) are the
  product's PUBLISHED, draft→publish-workflowed authored output (marketing/site
  content). `Doc`/`Note` are internal, attachable, per-object documentation/annotation
  records — no publish workflow, no CMS table, no shared storage (own abbrev-qualified
  tables: `<abbrev>_doc` / `<abbrev>_note`, never `cpg_page`/`cpt_post`).

  ## PII map (INV-1) — the "vaulted when PII-classified" mechanism

  | Attribute | Classification | Vault? |
  |---|---|---|
  | `body` | freeform authored content, default-deny-CDC-excluded, NOT vaulted — but
    write-guarded: `Samen.Pii.FreeTextScan` (the F3 Unit 6 tenant free-text chokepoint,
    already shipped on `Marketing.Suppression.notes`) refuses a bare email/SSN/phone
    -shaped value at the write boundary (fail-closed, DB unchanged) | no (guarded) |
  | `secure_body` | PII-classified rich text — the caller who KNOWS a body carries subject
    PII writes it here instead of `body` | **yes** — `vault: :pii_doc_body` (Doc) /
    `:pii_note_body` (Note) |
  | `title` (Doc only), `subject_key`, `custom`, ids/timestamps, `owner_id` | non-PII | no |

  A resource's `body` and `secure_body` are two independently-writable attributes, not a
  single field with a hidden storage switch — the SAME discipline `Samen.CustomFields`
  Tier-1 uses for a `pii_declared` custom field (ADR-036 D6): the classification is a
  DECLARED choice at the write site (which attribute you set), not an automatic runtime
  reclassification. `FreeTextScan` is the fail-closed belt on the plain path: a caller
  who tries to smuggle an obviously PII-shaped value into `body` is refused and must use
  `secure_body` instead. Both paths are governed writes — `body` through `FreeTextScan`,
  `secure_body` through the standard `Samen.Pii.WriteGuard` + `Samen.Vault.Change`
  chokepoint every `pii_attribute` gets by construction (never re-implemented here).

  ## Object-ref attachment (F3 "attachable to any object")

  `subject_key`/`subject_id` mirror `Samen.Scopes.Work.Task`'s anchor exactly: plain
  scalars, never a CRM/host FK. Org-scope enforcement for the anchor is NOT
  re-implemented at this substrate layer (there is no CRM/host contact here, matching
  the T43 partition) — it rides the SAME mechanism ADR-041 §6.1 names for Task: a
  higher (samen_web) write helper resolves the subject ref through the org-scoped
  `Samen.Web.ObjectRef.resolve/3` BEFORE anchoring, so a cross-org attach is inert by
  construction (see `Samen.Web.Docs.attach/5`).

  ## Soft-delete (ADR-040 §5.9)

  Both `Doc` and `Note` are `archivable: true` (user-managed nouns, T36 convention).

  ## Storage-name discipline

  Every column is `<abbrev>_<name>`, matching every other Samen scope.
  """

  # ---------------------------------------------------------------------------
  # Doc — a titled rich-text document. Org-scoped. Attachable via object-ref.
  # Archivable. `body` (plain, FreeTextScan-guarded) vs `secure_body` (vaulted).
  # ---------------------------------------------------------------------------
  defmacro define_doc(module, otp_app, domain, repo, abbrev) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Docs.Doc — a titled rich-text document (F3). Org-scoped. Attachable to any
        object via the generic `(subject_key, subject_id)` object-ref anchor
        (`Samen.Web.ObjectRef`, `samen:<key>:<uuid>` pattern — never a FK).

        `body` is plain freeform content, write-guarded by `Samen.Pii.FreeTextScan`
        (refuses a bare email/SSN/phone-shaped value). `secure_body` is the vaulted
        alternative (`vault: :pii_doc_body`) for content the caller has classified as
        carrying subject PII — masked per plane like any other 🔒 field (INV-1).

        Archivable (ADR-040 §5.9). Distinct from CMS `Page`/`Post` — own table
        (`#{unquote(abbrev)}_doc`), no publish workflow, no shared storage.
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev),
          archivable: true

        postgres do
          table("#{unquote(abbrev)}_doc")
          repo(unquote(repo))
        end

        attributes do
          attribute(:title, :string, public?: true, allow_nil?: false)
          # Plain freeform content — FreeTextScan-guarded (see moduledoc).
          attribute(:body, :string, public?: true)
          # The generic object-ref anchor (mirrors Samen.Scopes.Work.Task) —
          # CRM/host-agnostic, never a belongs_to. Org-scope enforced at the
          # samen_web ObjectRef.resolve write boundary, not here.
          attribute(:subject_key, :string, public?: true)
          attribute(:subject_id, :uuid, public?: true)
          attribute(:custom, :map, public?: true)
          # Plain uuid — mirrors Samen.Scopes.Work.Task.owner_id (no cross-scope
          # coupling to a specific Identity module shape at mount time).
          attribute(:owner_id, :uuid, public?: true)
        end

        pii do
          vault(:pii_doc_body)
          pii_attribute(:secure_body, :string, vault: :pii_doc_body)
        end

        changes do
          # F3 Unit 6 tenant free-text write chokepoint (already shipped on
          # Marketing.Suppression.notes) — adopted here at 0 new framework LOC.
          change({Samen.Pii.FreeTextScan, fields: [:body]})
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
  # Note — an untitled short annotation. Org-scoped. Attachable via object-ref.
  # Archivable. Same body/secure_body PII posture as Doc.
  # ---------------------------------------------------------------------------
  defmacro define_note(module, otp_app, domain, repo, abbrev) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Docs.Note — an untitled short annotation (F3). Org-scoped. Attachable to any
        object via the generic `(subject_key, subject_id)` object-ref anchor, same
        discipline as `Docs.Doc`.

        `body` is plain freeform content, write-guarded by `Samen.Pii.FreeTextScan`.
        `secure_body` is the vaulted alternative (`vault: :pii_note_body`) for
        PII-classified content — masked per plane (INV-1).

        Archivable (ADR-040 §5.9). Distinct from CMS `Page`/`Post` — own table
        (`#{unquote(abbrev)}_note`), no publish workflow, no shared storage.
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev),
          archivable: true

        postgres do
          table("#{unquote(abbrev)}_note")
          repo(unquote(repo))
        end

        attributes do
          # Plain freeform content — FreeTextScan-guarded (see moduledoc).
          attribute(:body, :string, public?: true)
          attribute(:subject_key, :string, public?: true)
          attribute(:subject_id, :uuid, public?: true)
          attribute(:custom, :map, public?: true)
          attribute(:owner_id, :uuid, public?: true)
        end

        pii do
          vault(:pii_note_body)
          pii_attribute(:secure_body, :string, vault: :pii_note_body)
        end

        changes do
          change({Samen.Pii.FreeTextScan, fields: [:body]})
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
end
