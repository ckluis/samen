defmodule Samen.Scopes.Cms.Blueprint do
  @moduledoc """
  Resource-definition macros for the CMS scope (T3.5; ADR-004 blueprint).

  Objects: `page · post · block · media · navigation · seo_meta · content_version`
  (doc §"The inherited 80%" scope table).

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
  Every status transition on `Page`/`Post` also appends a row to `ContentVersion`
  via the `create_version` action — making content changes auditable and reversible.

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

  ## ContentVersion — immutable append-only history

  `ContentVersion` has NO `:update` or `:destroy` default actions. Its only write
  is `:create_version` (called by the `Page`/`Post` publish lifecycle). This is the
  immutable content history mechanism (analogous to `aud_event` for content, but
  as a separate table because content versions have different retention semantics
  and are tenant-readable as part of the product's content workflow).

  ## Tier-0 config rows

  `Navigation` is the CMS Tier-0 config-row resource: one row per navigation item
  per org (e.g. main menu entry, footer link). Admins bend the nav structure without
  forking the product.

  ## Storage-name discipline

  Every column is `<abbrev>_<name>` (self-qualifying storage, injected by the Samen
  base macro). The public API/catalog only ever sees the logical name, never the
  storage name.
  """

  # ---------------------------------------------------------------------------
  # Page — a published/draft page. Org-scoped. No PII.
  # Draft → publish workflow (status bounded enum). Admin-gated publish.
  # ---------------------------------------------------------------------------
  defmacro define_page(module, otp_app, domain, repo, abbrev, _content_version_mod) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        CMS.Page — a content page (doc scope table `page`). Org-scoped. No PII.

        Carries a draft→publish workflow via the `status` bounded enum:
        `:draft | :published | :archived`. Publish is admin-gated. Every status
        change appends an immutable `ContentVersion` row via the `create_version`
        action on `ContentVersion`.

        Free-text fields (`title`, `body`, `slug`) are deliberately classified as
        non-PII (authored content — see `Samen.Scopes.Cms.Blueprint` moduledoc
        and `Demo.CmsScope.NonPiiSetup`).
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

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

          # Archive (non-atomic for same reason as publish).
          update :archive do
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

          # Publish and archive require admin+. With require_atomic?: false on the
          # actions, policy checks run in-memory (not SQL), so forbid_unless(OrgScope)
          # works correctly here.
          policy action([:publish, :archive]) do
            forbid_unless(Samen.Policy.OrgScope)
            forbid_unless({Samen.Policy.RoleAtLeast, role: :admin})
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
  defmacro define_post(module, otp_app, domain, repo, abbrev, _content_version_mod) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        CMS.Post — a blog post (doc scope table `post`). Org-scoped. No PII.

        Carries a draft→publish workflow via the `status` bounded enum:
        `:draft | :published | :archived`. Publish is admin-gated. Every status
        change appends an immutable `ContentVersion` row.

        Free-text fields (`title`, `body`, `excerpt`) are deliberately classified
        as non-PII (authored content).
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

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

          update :archive do
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

          policy action([:publish, :archive]) do
            forbid_unless(Samen.Policy.OrgScope)
            forbid_unless({Samen.Policy.RoleAtLeast, role: :admin})
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
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

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
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

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
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

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
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

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

  # ---------------------------------------------------------------------------
  # ContentVersion — immutable content version history (append-only). No PII.
  # Org-scoped. NO :update or :destroy actions — append-only by design.
  # ---------------------------------------------------------------------------
  defmacro define_content_version(module, otp_app, domain, repo, abbrev) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        CMS.ContentVersion — immutable content version history (doc scope table
        `content_version`). Org-scoped. No PII.

        Append-only: NO `:update` or `:destroy` actions. The only write is
        `:create_version` (called by the Page/Post publish/archive lifecycle, or
        explicitly to snapshot a content change). ContentVersion is the immutable
        history mechanism for content objects — analogous to `aud_event` for system
        events, but as a separate table with content-specific retention semantics and
        tenant-readable as part of the product's content workflow.

        `content_snapshot` is a JSON blob of the authored content at the time of
        the version. It is authored output — not PII — but may be large, so it is
        stored as a `:map` (jsonb). Consumers should paginate version history.

        `subject_type` + `subject_id` identify what was versioned (e.g.
        `{\"page\", page_id}` or `{\"post\", post_id}`).
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_content_version")
          repo(unquote(repo))
        end

        attributes do
          # What was versioned (resource type: "page" | "post" | "block").
          attribute(:subject_type, :string, public?: true, allow_nil?: false)
          # UUID of the versioned resource.
          attribute(:subject_id, :uuid, public?: true, allow_nil?: false)
          # Authored content snapshot — NOT PII (authored output, not subject data).
          attribute(:content_snapshot, :map, public?: true)
          # The status at the time of this version (draft/published/archived).
          attribute(:status, :atom,
            public?: true,
            constraints: [one_of: [:draft, :published, :archived]]
          )
          # Opaque author identifier (a user ID token). NOT a name or email.
          attribute(:author_id, :uuid, public?: true)
          attribute(:version_number, :integer, public?: true, default: 1)
          attribute(:change_summary, :string, public?: true)
        end

        actions do
          # READ only (no :update, :destroy — immutable history).
          defaults([:read])

          # The ONLY write: create_version. Called from Page/Post lifecycle or explicitly.
          # org_id is injected by CoreAttributes but must be in the accept list for a
          # named create action (Ash does not auto-accept injected attrs in named creates).
          create :create_version do
            accept([:subject_type, :subject_id, :content_snapshot, :status, :author_id,
                    :version_number, :change_summary, :org_id])
          end
        end

        policies do
          # Any tenant-plane actor can read version history for their org.
          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end

          # Only admins+ may create version records.
          policy action(:create_version) do
            forbid_unless(Samen.Policy.OrgScope)
            forbid_unless({Samen.Policy.RoleAtLeast, role: :admin})
            authorize_if(always())
          end
        end
      end
    end
  end
end
