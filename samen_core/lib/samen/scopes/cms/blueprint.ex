defmodule Samen.Scopes.Cms.Blueprint do
  @moduledoc """
  Resource-definition macros for the CMS scope (T3.5; ADR-004 blueprint).

  Objects: `page · post · block · media · navigation · seo_meta`
  (doc §"The inherited 80%" scope table). The bespoke `content_version` ledger was
  RETIRED in T119 (ADR-040 §6.5): content history is now the E7 audit-on-write
  `versioned: :snapshot` mechanism (ash_paper_trail-generated `Page.Version` /
  `Post.Version` / `Block.Version`).

  ## PII map (🔒)

  The CMS scope contains NO vault-routed PII objects — the doc's 🔒 map has no
  mark on any CMS resource. Content is the product's authored output, not subject
  identity data.

  ## Non-PII classification (mask-unknown-by-default proof)

  `Samen.NonPii` D9 requires EVERY field type to be classified — fields that are not
  classified default to PII (masked). Free-text CMS fields are explicitly classified
  as non-PII by design (the mask-unknown-by-default proof for this scope). The
  `pii_classify` heuristic (C4) does not flag most of these because their names
  (`title`, `body`, `content`, `slug`) are not in the PII name-token list. However,
  the task spec (T3.5) requires the non-PII classification to be documented and
  proven.

  Fields that receive deliberate non-PII classification via `Samen.NonPii.register/1`
  (registered in the demo's seed task / test setup with distinct reviewers):

  | Table       | Column          | Non-PII rationale                                      |
  |-------------|-----------------|--------------------------------------------------------|
  | cpg_page    | cpg_title       | Published page title — authored content, not PII       |
  | cpt_post    | cpt_title       | Blog post title — authored content, not PII            |
  | csm_seo_meta| csm_description | SEO description — authored marketing copy, not PII     |

  `csm_description` is the most important registration: "description" can resemble
  a free-text name-containing field, so the non-PII! classification is load-bearing
  documentation. Without it, an auditor might question whether authored descriptions
  could leak subject names. The explicit registration + distinct-reviewer sign-off
  proves the field was consciously evaluated and cleared.

  See `Demo.CmsScope.NonPiiSetup` for the runtime registration calls.

  ## Draft → publish workflow

  `Page` and `Post` have a `status` bounded enum:
  `:draft | :published | :archived`. Publish is admin-gated (`RoleAtLeast :admin`).
  Every tracked write on `Page`/`Post`/`Block` (create/update/publish/mark_archived/
  archive/restore) records a full-row `<Module>.Version` snapshot automatically via E7
  `versioned: :snapshot` (ADR-040 §6.5) — content changes are auditable and reversible
  by construction, with no caller obliged to snapshot.

  ## Intentional policy divergence — content :update is member-level (F3.4)

  Most scopes gate ALL writes behind a role floor (`create/update/destroy` require
  admin+). CMS `Page`/`Post` **deliberately diverge**: the default `:update` action
  (a content edit — editing draft body/title) is authorized at `OrgScope` ONLY, so
  any org member may edit content, while the *lifecycle* transitions
  `:publish`/`:archive` (Tier-0 state changes with external visibility) DO require
  admin+. This is the correct CMS RBAC shape — an editorial team edits drafts; only
  an admin publishes. It is called out here (and in scope-authoring guide §7) so the
  divergence is an **explicit, documented choice**, not silent policy drift. Every
  other CMS write resource (`Block`, `Media`, `Navigation`, `SeoMeta`) follows the
  standard admin-gated split-read/split-write idiom.

  ## Content history — E7 `versioned: :snapshot` (ADR-040 §6.5, T119)

  Content history is the E7 audit-on-write mechanism: `Page`/`Post`/`Block` declare
  `versioned: :snapshot`, so ash_paper_trail generates a governed `<Module>.Version`
  resource (allocator-owned abbrev, prefixed columns, mirrored `org_id`, OrgScope,
  catalog, `no_plaintext_pii` roster — §6.2) and records a full-row snapshot on every
  tracked write. The retired bespoke `ContentVersion` was a pre-1.0 destructive break
  (§6.5): it required callers to remember `:create_version` (which the lifecycle never
  actually did), whereas E7 versions by construction. History is read from the Version
  resources; version rows never persist raw action inputs (`store_action_inputs? false`,
  INV-1). This tier stays disjoint from the governance `aud_event` hash-chain (§7.4).

  ## Tier-0 config rows

  `Navigation` is the CMS Tier-0 config-row resource: one row per navigation item
  per org (e.g. main menu entry, footer link). Admins bend the nav structure without
  forking the product.

  ## Soft-delete adoption (ADR-040 §5.9, T37b) — `page ▸cascade block, post, media,
  ## navigation, seo_meta`

  Five of the six writable resources are `archivable: true`: `page`, `post`,
  `media`, `navigation`, `seo_meta`. `block` is archivable too, and is the ONE
  declared composition cascade in this scope: archiving a `page` cascades to
  archive its `block`s at the same instant (`Samen.Scopes.Cms.CascadeArchive`),
  and restoring a `page` restores exactly the same-instant-archived blocks
  (`Samen.Scopes.Cms.CascadeRestore`) — see those modules' docs for why this
  scope does NOT use ash_archival's `archive_related` DSL option directly.
  `seo_meta`'s `page`/`post` belongs_to relationships are NOT cascades (§5.4
  default no-cascade) — an archived page/post's seo_meta row stays live but its
  relationship load correctly resolves to `nil` (the read-preparation leak
  surface every adopting scope must red-test, §5.5).

  The former `content_version` ledger is retired (T119, ADR-040 §6.5) — replaced by
  the E7 `versioned` Version resources, which are neither archivable nor themselves
  versioned (a version of a version is meaningless).

  ### The `:archive` name collision — `page`/`post`'s pre-existing content-status
  ### action renamed to `:mark_archived`

  `Page` and `Post` already had a hand-authored `update :archive` action (sets
  the `status` enum to `:archived` — a content-workflow/visibility transition,
  draft → published → **archived**, wholly independent of soft-delete). ADR-040
  §5.2 reserves the name `:archive` for the E6 substrate's own destroy action
  (`use Samen.Resource, archivable: true` injects `destroy :archive`). Two
  actions cannot share one name on the same Ash resource, so the pre-existing
  content-status action is renamed `:mark_archived` here (same body, same
  policy gate — admin-gated alongside `:publish`). This is a NEW resolution
  pattern (the first resource in the foundry where a business-domain action
  collided with an E6-reserved name); every other CMS action name is
  untouched. The `status` enum itself still has an `:archived` VALUE (data,
  not an action name) — no collision there, only the action needed renaming.

  ## Storage-name discipline

  Every column is `<abbrev>_<name>` (self-qualifying storage, injected by the Samen
  base macro). The public API/catalog only ever sees the logical name, never the
  storage name.
  """

  # ---------------------------------------------------------------------------
  # Page — a published/draft page. Org-scoped. No PII.
  # Draft → publish workflow (status bounded enum). Admin-gated publish.
  # ---------------------------------------------------------------------------
  defmacro define_page(module, otp_app, domain, repo, abbrev, block_mod) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        CMS.Page — a content page (doc scope table `page`). Org-scoped. No PII.

        Carries a draft→publish workflow via the `status` bounded enum:
        `:draft | :published | :archived`. Publish is admin-gated.

        ## Content history (ADR-040 §6.5, T119)

        `versioned: :snapshot` (E7 audit-on-write). EVERY tracked write — create,
        update, publish, `:mark_archived`, and the E6 `:archive`/`:restore` — records a
        full-row `Page.Version` snapshot automatically (ash_paper_trail), fixing the
        long-standing gap where status transitions promised a version but only
        `set_attribute`'d. History is read from `<Module>.Version` (the retired bespoke
        `ContentVersion` is gone — §6.5). No caller need remember to snapshot.

        Free-text fields (`title`, `body`, `slug`) are deliberately classified as
        non-PII (authored content — see `Samen.Scopes.Cms.Blueprint` moduledoc
        and `Demo.CmsScope.NonPiiSetup`).

        ## Soft-delete (ADR-040 §5.9, T37b)

        Archivable. The pre-existing content-status transition (`status` →
        `:archived`) is exposed as `:mark_archived` (renamed from `:archive` —
        see `Samen.Scopes.Cms.Blueprint` moduledoc "The `:archive` name
        collision"); `:archive`/`:restore`/`:archived` are now the E6 substrate
        actions. Archiving a Page cascades to archive its `Block`s at the same
        instant (`Samen.Scopes.Cms.CascadeArchive`); restoring a Page restores
        exactly the same-instant-archived blocks
        (`Samen.Scopes.Cms.CascadeRestore`) — a block archived independently
        stays archived (ADR-040 §5.4).
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev),
          archivable: true,
          versioned: :snapshot

        postgres do
          table("#{unquote(abbrev)}_page")
          repo(unquote(repo))
        end

        attributes do
          attribute(:title, :string, public?: true, allow_nil?: false)
          attribute(:slug, :string, public?: true)
          attribute(:body, :string, public?: true)
          attribute(:status, :atom,
            public?: true,
            default: :draft,
            constraints: [one_of: [:draft, :published, :archived]]
          )
          attribute(:published_at, :utc_datetime, public?: true)
          attribute(:custom, :map, public?: true)
        end

        relationships do
          # The page ▸cascade block composition (ADR-040 §5.4). Inverse of
          # Block's `belongs_to :page`.
          has_many :blocks, unquote(block_mod) do
            public?(true)
            destination_attribute(:page_id)
          end
        end

        changes do
          # Page ▸ Block same-instant cascade, both directions (§5.4). See
          # each module's moduledoc for why this scope does not use
          # ash_archival's `archive_related` DSL option directly.
          #
          # `on:` defaults to `[:create, :update]` (Ash omits `:destroy` by
          # default — "most changes don't make sense for a destroy",
          # `ash/lib/ash/resource/change/change.ex`). `:archive` IS a
          # `:destroy`-type action, so CascadeArchive needs `on: [:destroy]`
          # explicitly or it silently never runs. CascadeRestore's `:restore`
          # is `:update`-typed, already covered by the default.
          change(Samen.Scopes.Cms.CascadeArchive, on: [:destroy])
          change(Samen.Scopes.Cms.CascadeRestore)
        end

        actions do
          defaults([:read, :destroy, create: :*, update: :*])

          # Publish: admin-gated. Sets status to :published and records published_at.
          # require_atomic?: false forces non-bulk (row-by-row) execution so the
          # Ash Policy Authorizer evaluates FilterChecks in-memory (not as SQL).
          # Without this, AshPostgres attempts to include error(Placeholder) in the
          # SQL WHERE clause for forbid_unless(FilterCheck) — unsupported by the
          # data layer.
          update :publish do
            require_atomic?(false)
            argument(:published_at, :utc_datetime, default: &DateTime.utc_now/0)

            change(set_attribute(:status, :published))
            change(set_attribute(:published_at, arg(:published_at)))
          end

          # Content-status transition (status -> :archived). Renamed from
          # `:archive` — that name is now the E6 substrate's soft-destroy
          # action (`archivable: true` above). See blueprint moduledoc.
          update :mark_archived do
            require_atomic?(false)
            change(set_attribute(:status, :archived))
          end
        end

        policies do
          # Read is only org-scoped (any member can read pages).
          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end

          # Default create: org-scoped, any role.
          policy action_type([:create, :destroy]) do
            forbid_unless(Samen.Policy.OrgScope)
            authorize_if(always())
          end

          # The default :update action (updating title, body, etc.) — any member.
          policy action(:update) do
            forbid_unless(Samen.Policy.OrgScope)
            authorize_if(always())
          end

          # Publish and mark_archived require admin+. With require_atomic?: false
          # on the actions, policy checks run in-memory (not SQL), so
          # forbid_unless(OrgScope) works correctly here.
          policy action([:publish, :mark_archived]) do
            forbid_unless(Samen.Policy.OrgScope)
            forbid_unless({Samen.Policy.RoleAtLeast, role: :admin})
            authorize_if(always())
          end

          # :restore (E6 substrate) carries the same posture as the default
          # :update it mediates (ADR-040 §5.2: "archive/restore carry the
          # same policy posture as the destroy/update they mediate") —
          # org-scoped, any member. Needs an explicit policy because Ash
          # policy `action/1` matches by NAME, not type, and `:restore` is a
          # different name from `:update` (same `:update` action TYPE).
          # `:archive` needs no separate policy: it is `destroy`-typed and
          # already covered by the `action_type([:create, :destroy])` block
          # above, matching the destroy posture it mediates.
          policy action(:restore) do
            forbid_unless(Samen.Policy.OrgScope)
            authorize_if(always())
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Post — a blog post. Org-scoped. No PII.
  # Same draft → publish workflow as Page.
  # ---------------------------------------------------------------------------
  defmacro define_post(module, otp_app, domain, repo, abbrev) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        CMS.Post — a blog post (doc scope table `post`). Org-scoped. No PII.

        Carries a draft→publish workflow via the `status` bounded enum:
        `:draft | :published | :archived`. Publish is admin-gated.

        ## Content history (ADR-040 §6.5, T119)

        `versioned: :snapshot` (E7 audit-on-write): every tracked write records a full-row
        `Post.Version` snapshot automatically (ash_paper_trail). History is read from
        `<Module>.Version`; the bespoke `ContentVersion` is retired (§6.5).

        Free-text fields (`title`, `body`, `excerpt`) are deliberately classified
        as non-PII (authored content).

        ## Soft-delete (ADR-040 §5.9, T37b)

        Archivable. No declared cascade (§5.4 default no-cascade — `seo_meta`
        rows referencing an archived Post stay live, per the belongs_to
        relationship-load leak red test). The pre-existing content-status
        transition is `:mark_archived` (renamed from `:archive` — see
        `Samen.Scopes.Cms.Blueprint` moduledoc).
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev),
          archivable: true,
          versioned: :snapshot

        postgres do
          table("#{unquote(abbrev)}_post")
          repo(unquote(repo))
        end

        attributes do
          attribute(:title, :string, public?: true, allow_nil?: false)
          attribute(:slug, :string, public?: true)
          attribute(:body, :string, public?: true)
          attribute(:excerpt, :string, public?: true)
          attribute(:status, :atom,
            public?: true,
            default: :draft,
            constraints: [one_of: [:draft, :published, :archived]]
          )
          attribute(:published_at, :utc_datetime, public?: true)
          attribute(:custom, :map, public?: true)
        end

        actions do
          defaults([:read, :destroy, create: :*, update: :*])

          update :publish do
            require_atomic?(false)
            argument(:published_at, :utc_datetime, default: &DateTime.utc_now/0)
            change(set_attribute(:status, :published))
            change(set_attribute(:published_at, arg(:published_at)))
          end

          # Content-status transition. Renamed from `:archive` — that name is
          # now the E6 substrate's soft-destroy action (`archivable: true`
          # above). See blueprint moduledoc "The `:archive` name collision".
          update :mark_archived do
            require_atomic?(false)
            change(set_attribute(:status, :archived))
          end
        end

        policies do
          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end

          policy action_type([:create, :destroy]) do
            forbid_unless(Samen.Policy.OrgScope)
            authorize_if(always())
          end

          policy action(:update) do
            forbid_unless(Samen.Policy.OrgScope)
            authorize_if(always())
          end

          policy action([:publish, :mark_archived]) do
            forbid_unless(Samen.Policy.OrgScope)
            forbid_unless({Samen.Policy.RoleAtLeast, role: :admin})
            authorize_if(always())
          end

          # :restore — see Page's identical policy for the full rationale.
          policy action(:restore) do
            forbid_unless(Samen.Policy.OrgScope)
            authorize_if(always())
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Block — a reusable content block / component. Org-scoped. No PII.
  # Belongs to a Page (nullable FK).
  # ---------------------------------------------------------------------------
  defmacro define_block(module, otp_app, domain, repo, abbrev, page_mod) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        CMS.Block — a reusable content block (doc scope table `block`). Org-scoped.
        No PII. A block carries a `block_type` (e.g. hero, callout, testimonial) and
        a `content` map (JSON bag). Blocks may be associated with a page (nullable FK).

        Free-text `content` JSON blob is authored CMS output — not PII.

        ## Soft-delete (ADR-040 §5.9, T37b)

        Archivable — and the CASCADE TARGET of `page ▸cascade block` (§5.4):
        archiving a Page cascades to archive its Blocks at the same instant
        (`Samen.Scopes.Cms.CascadeArchive`, declared on Page); a Block can
        also be archived independently of its page, in which case a later
        restore of the page does NOT restore it (the same-instant match,
        `Samen.Scopes.Cms.CascadeRestore`).

        ## Content history (ADR-040 §6.5, T119)

        `versioned: :snapshot` (E7): every tracked write records a full-row
        `Block.Version` snapshot; history is read from `<Module>.Version`.
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev),
          archivable: true,
          versioned: :snapshot

        postgres do
          table("#{unquote(abbrev)}_block")
          repo(unquote(repo))
        end

        attributes do
          attribute(:name, :string, public?: true, allow_nil?: false)
          attribute(:block_type, :atom,
            public?: true,
            default: :generic,
            constraints: [one_of: [:hero, :callout, :testimonial, :richtext, :image, :video, :generic]]
          )
          # JSON bag for block content — authored CMS fragment, not PII.
          attribute(:content, :map, public?: true)
          attribute(:position, :integer, public?: true, default: 0)
          attribute(:enabled, :boolean, public?: true, default: true)
        end

        relationships do
          belongs_to :page, unquote(page_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(true)
          end
        end

        # F3.5 same-org FK: a block may only reference a same-org page.
        changes do
          change({Samen.Policy.SameOrgFk, relationships: [:page]})
        end

        actions do
          defaults([:read, :destroy, create: :*, update: :*])
        end

        policies do
          # Split read-only / write, matching the scope-authoring template idiom
          # (F3.4): reads are org-scoped; writes additionally require admin+.
          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end

          # Block create/update/destroy requires admin+.
          policy action_type([:create, :update, :destroy]) do
            forbid_unless(Samen.Policy.OrgScope)
            forbid_unless({Samen.Policy.RoleAtLeast, role: :admin})
            authorize_if(always())
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Media — a media asset. Org-scoped. No PII.
  # ---------------------------------------------------------------------------
  defmacro define_media(module, otp_app, domain, repo, abbrev) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        CMS.Media — a media asset (doc scope table `media`). Org-scoped. No PII.

        Stores metadata for uploaded assets (images, videos, documents). The actual
        binary is stored externally (S3/equivalent); `storage_key` is the opaque
        reference. `alt_text` is authored accessibility text — not PII.

        ## Soft-delete (ADR-040 §5.9, T37b)

        Archivable. No cascade (§5.4 default — Media is a standalone asset,
        not a composition child of any other CMS resource in this scope).
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev),
          archivable: true

        postgres do
          table("#{unquote(abbrev)}_media")
          repo(unquote(repo))
        end

        attributes do
          attribute(:file_name, :string, public?: true, allow_nil?: false)
          attribute(:content_type, :string, public?: true)
          attribute(:size_bytes, :integer, public?: true)
          # Opaque external storage reference — not PII.
          attribute(:storage_key, :string, public?: true)
          # Authored accessibility text — not PII (deliberate non-PII classification).
          attribute(:alt_text, :string, public?: true)
          attribute(:media_type, :atom,
            public?: true,
            default: :image,
            constraints: [one_of: [:image, :video, :document, :audio]]
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
            forbid_unless({Samen.Policy.RoleAtLeast, role: :admin})
            authorize_if(always())
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Navigation — Tier-0 config rows (nav items per org). Org-scoped. No PII.
  # ---------------------------------------------------------------------------
  defmacro define_navigation(module, otp_app, domain, repo, abbrev) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        CMS.Navigation — Tier-0 config rows (doc scope table `navigation`).
        One row per navigation item per org (e.g. main menu entry, footer link).
        Admins bend the nav catalog without forking the product.

        `label` is authored navigation text — not PII. `nav_type` (main/footer/
        sidebar) identifies the navigation tree the item belongs to.

        ## Soft-delete (ADR-040 §5.9, T37b)

        Archivable. No cascade (§5.4 default).
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev),
          archivable: true

        postgres do
          table("#{unquote(abbrev)}_navigation")
          repo(unquote(repo))
        end

        attributes do
          attribute(:label, :string, public?: true, allow_nil?: false)
          attribute(:url, :string, public?: true)
          attribute(:nav_type, :atom,
            public?: true,
            default: :main,
            constraints: [one_of: [:main, :footer, :sidebar, :utility]]
          )
          attribute(:position, :integer, public?: true, default: 0)
          attribute(:enabled, :boolean, public?: true, default: true)
          attribute(:target, :atom,
            public?: true,
            default: :self,
            constraints: [one_of: [:self, :blank]]
          )
        end

        actions do
          defaults([:read, :destroy, create: :*, update: :*])
        end

        policies do
          # Navigation is Tier-0 config: anyone can read (tenant nav is public data),
          # but only admins can write.
          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end

          policy action_type([:create, :update, :destroy]) do
            forbid_unless(Samen.Policy.OrgScope)
            forbid_unless({Samen.Policy.RoleAtLeast, role: :admin})
            authorize_if(always())
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # SeoMeta — SEO metadata for a page or post. Org-scoped. No PII.
  # ---------------------------------------------------------------------------
  defmacro define_seo_meta(module, otp_app, domain, repo, abbrev, page_mod, post_mod) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        CMS.SeoMeta — SEO metadata (doc scope table `seo_meta`). Org-scoped. No PII.

        Attaches search-engine metadata to a page or post. At most one `seo_meta`
        row per `(org_id, page_id)` or `(org_id, post_id)`.

        `description` is authored marketing copy — not PII. This is the field most
        likely to prompt a `pii_classify` review question (free-text "description"
        fields COULD contain names in hand-rolled apps). Its classification as
        non-PII is deliberate and explicitly registered via `Samen.NonPii.register/1`
        (see `Demo.CmsScope.NonPiiSetup`) with distinct-reviewer sign-off, proving
        the mask-unknown-by-default discipline: the field was consciously evaluated
        and cleared, not silently assumed safe.

        ## Soft-delete (ADR-040 §5.9, T37b)

        Archivable. No cascade FROM its `page`/`post` belongs_to relationships
        (§5.4 default no-cascade): an archived page/post leaves its `seo_meta`
        row live, but the `page`/`post` relationship load correctly resolves
        to `nil` for the archived side (the read-preparation leak surface
        every adopting scope red-tests, §5.5) — SeoMeta is the leak-test
        fixture for this scope (two independent belongs_to consumers).
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev),
          archivable: true

        postgres do
          table("#{unquote(abbrev)}_seo_meta")
          repo(unquote(repo))
        end

        attributes do
          attribute(:meta_title, :string, public?: true)
          # Authored marketing copy: explicitly classified non-PII (see moduledoc).
          attribute(:description, :string, public?: true)
          attribute(:canonical_url, :string, public?: true)
          attribute(:og_title, :string, public?: true)
          attribute(:og_description, :string, public?: true)
          attribute(:no_index, :boolean, public?: true, default: false)
          attribute(:no_follow, :boolean, public?: true, default: false)
        end

        relationships do
          belongs_to :page, unquote(page_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(true)
          end

          belongs_to :post, unquote(post_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(true)
          end
        end

        # F3.5 same-org FK: seo_meta may only reference a same-org page/post.
        changes do
          change({Samen.Policy.SameOrgFk, relationships: [:page, :post]})
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
            forbid_unless({Samen.Policy.RoleAtLeast, role: :admin})
            authorize_if(always())
          end
        end
      end
    end
  end
end
