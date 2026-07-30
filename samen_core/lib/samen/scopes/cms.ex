defmodule Samen.Scopes.Cms do
  @moduledoc """
  The **CMS** universal scope (T3.5; doc §"The inherited 80%" scope table:
  `page · post · block · media · navigation · seo_meta`).

  Ships as a **library-authored blueprint** (ADR-004): `use`-ing this module
  inside a host's Ash domain expands into six host-owned resources in the host's
  namespace — each a normal `use Samen.Resource` with the host's `otp_app`,
  `repo`, and `domain` — plus the three generated E7 `<Resource>.Version` resources
  for `Page`/`Post`/`Block` (ADR-040 §6.5). The bespoke `content_version` ledger was
  RETIRED in T119 in favor of E7 audit-on-write (see below).

  ## PII classification — no 🔒 objects in this scope

  The CMS scope contains NO vault-routed PII objects (the doc's 🔒 map has no mark
  on `page · post · block · media · navigation · seo_meta`). This
  is deliberate: content is the product's authored output, not subject identity data.

  **Mask-unknown-by-default** (D9 / plan §A: "every field type must be classified or
  it defaults to PII"): free-text content fields that look name/email-shaped would be
  flagged by `pii_classify`. We register them as deliberately non-PII using `non_pii!`
  in the `Samen.NonPii.Registry` (the T1.8c mechanism). The classification, rationale,
  and reviewer sign-off are documented in this module and in the registry entry. See
  §"Non-PII classification" below.

  ## Non-PII classification (mask-unknown-by-default proof)

  The following free-text fields are classified as **non-PII by design**, registered
  in `Samen.NonPii.Registry`, and documented with reviewer rationale:

  | Table       | Column          | Rationale                                              |
  |-------------|-----------------|--------------------------------------------------------|
  | cpg_page    | cpg_title       | Published page title — authored content, not subject PII |
  | cpg_page    | cpg_body        | Published page body — authored content, not subject PII  |
  | cpt_post    | cpt_title       | Blog post title — authored content, not subject PII     |
  | cpt_post    | cpt_body        | Blog post body — authored content, not subject PII      |
  | cbl_block   | cbl_content     | Block content JSON — authored CMS fragment, not PII     |
  | cmd_media   | cmd_alt_text    | Alt text for accessibility — authored content, not PII  |
  | cnv_navigation | cnv_label    | Nav link label — authored content, not PII              |

  Each is a system-generated or author-written string that describes published content,
  not a natural person. The `pii_classify` verifier (C4) would otherwise flag them as
  potentially PII because they are free-text strings. We clear them explicitly with
  `non_pii!(table, column, reviewer: "T3.5-scope-author", reason: "...")` in the
  registry so the build stays green and the classification is auditable.

  ## Draft → publish workflow with E7 versioned history (ADR-040 §6.5, T119)

  Content history is the E7 audit-on-write mechanism (`versioned: :snapshot`):
  - `Page`/`Post`/`Block` each generate a governed `<Resource>.Version` resource
    (ash_paper_trail) that records a full-row snapshot on EVERY tracked write —
    create/update/publish/mark_archived/archive/restore — automatically. No caller
    remembers to snapshot (the bug the retired ContentVersion had: its lifecycle
    promised versions but only `set_attribute`'d).
  - Version rows never persist raw action inputs (`store_action_inputs? false`,
    INV-1) and stay disjoint from the `aud_event` governance hash-chain (§7.4).
  - The `status` column on `Page`/`Post` drives the draft→publish workflow:
    `:draft` | `:published` | `:archived`. Publish is an admin-gated action.

  ## Tier-0 config rows

  `Navigation` serves as the CMS Tier-0 config resource: one row per navigation item
  per org (e.g. main menu, footer links). Admins bend the nav structure without
  forking the product.

  ## Soft-delete adoption (ADR-040 §5.9, T37b)

  `page`, `post`, `block`, `media`, `navigation`, `seo_meta` are `archivable: true`.
  `page ▸cascade block` is the one declared composition cascade — see
  `Samen.Scopes.Cms.Blueprint`'s moduledoc for the full detail, including the
  `:archive` → `:mark_archived` rename on Page/Post's pre-existing content-status
  action. (The former `content_version` ledger was retired in T119 — content history
  is the E7 `versioned` mechanism; the generated `<Resource>.Version` resources are
  themselves neither archivable nor versioned.)

  ## Mounting CMS (the host side)

      defmodule Demo.CmsScope do
        use Ash.Domain, validate_config_inclusion?: false

        use Samen.Scopes.Cms,
          otp_app: :demo,
          repo: Demo.Repo,
          namespace: Demo.CmsScope
      end

  This defines, in the host's namespace:

    * `Demo.CmsScope.Page`           — a published page (draft→publish workflow)
    * `Demo.CmsScope.Post`           — a blog post (draft→publish workflow)
    * `Demo.CmsScope.Block`          — a content block (component/fragment)
    * `Demo.CmsScope.Media`          — a media asset (image/video/document reference)
    * `Demo.CmsScope.Navigation`     — Tier-0 config rows (nav items per org)
    * `Demo.CmsScope.SeoMeta`        — SEO metadata attached to a page or post
    * `Demo.CmsScope.Page.Version`   — E7 content history for Page (generated)
    * `Demo.CmsScope.Post.Version`   — E7 content history for Post (generated)
    * `Demo.CmsScope.Block.Version`  — E7 content history for Block (generated)

  ## Abbrevs (permanent, registry-checked)

  Each resource carries a permanent 3-letter abbrev, reserved in
  `samen_core/priv/abbrev_registry.json` under the HOST module name:

    * `Demo.CmsScope.Page`           → `cpg`  (`Page.Version`  → `cpv`)
    * `Demo.CmsScope.Post`           → `cpt`  (`Post.Version`  → `cvp`)
    * `Demo.CmsScope.Block`          → `cbl`  (`Block.Version` → `cbv`)
    * `Demo.CmsScope.Media`          → `cmd`
    * `Demo.CmsScope.Navigation`     → `cnv`
    * `Demo.CmsScope.SeoMeta`        → `csm`

  The macro does NOT invent abbrevs. The resource abbrevs are literals (defaults for
  the demo mount); the generated `<Resource>.Version` abbrevs are reserved in the same
  registry and injected into the generated modules at build time (never pinned in code —
  ADR-023/§6.2). `cvr` (the retired ContentVersion) stays in the registry, never
  recycled (permanence), but owns no live resource.
  """

  @default_abbrevs %{
    page: "cpg",
    post: "cpt",
    block: "cbl",
    media: "cmd",
    navigation: "cnv",
    seo_meta: "csm"
  }

  @doc false
  def default_abbrevs, do: @default_abbrevs

  defmacro __using__(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app) |> Macro.expand(__CALLER__)
    repo = Keyword.fetch!(opts, :repo) |> Macro.expand(__CALLER__)
    namespace = Keyword.fetch!(opts, :namespace) |> Macro.expand(__CALLER__)
    domain = __CALLER__.module

    # Resolve abbrevs to a plain %{atom => string} map AT EXPANSION TIME so each
    # blueprint call receives a LITERAL abbrev string.
    abbrevs = resolve_abbrevs(Keyword.get(opts, :abbrevs), __CALLER__)

    page_mod = Module.concat(namespace, Page)
    post_mod = Module.concat(namespace, Post)
    block_mod = Module.concat(namespace, Block)
    media_mod = Module.concat(namespace, Media)
    navigation_mod = Module.concat(namespace, Navigation)
    seo_meta_mod = Module.concat(namespace, SeoMeta)

    # E7 (ADR-040 §6.5, T119): Page/Post/Block are `versioned: :snapshot`, so
    # ash_paper_trail generates a governed `<Resource>.Version` for each — real domain
    # members that must be registered (the retired bespoke ContentVersion is gone).
    page_version_mod = Module.concat(page_mod, Version)
    post_version_mod = Module.concat(post_mod, Version)
    block_version_mod = Module.concat(block_mod, Version)

    quote do
      require Samen.Scopes.Cms.Blueprint

      # Register the six CMS resources + the three generated Version resources.
      resources do
        resource(unquote(page_mod))
        resource(unquote(post_mod))
        resource(unquote(block_mod))
        resource(unquote(media_mod))
        resource(unquote(navigation_mod))
        resource(unquote(seo_meta_mod))
        resource(unquote(page_version_mod))
        resource(unquote(post_version_mod))
        resource(unquote(block_version_mod))
      end

      # Materialize resource modules in the host namespace.
      Samen.Scopes.Cms.Blueprint.define_page(
        unquote(page_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.page),
        unquote(block_mod)
      )

      Samen.Scopes.Cms.Blueprint.define_post(
        unquote(post_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.post)
      )

      Samen.Scopes.Cms.Blueprint.define_block(
        unquote(block_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.block),
        unquote(page_mod)
      )

      Samen.Scopes.Cms.Blueprint.define_media(
        unquote(media_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.media)
      )

      Samen.Scopes.Cms.Blueprint.define_navigation(
        unquote(navigation_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.navigation)
      )

      Samen.Scopes.Cms.Blueprint.define_seo_meta(
        unquote(seo_meta_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.seo_meta),
        unquote(page_mod),
        unquote(post_mod)
      )
    end
  end

  # Resolve the abbrev override (an AST map literal or nil) to a plain
  # %{atom => string} map, merged over the defaults.
  defp resolve_abbrevs(nil, _caller), do: @default_abbrevs

  defp resolve_abbrevs({:%{}, _, pairs}, caller) do
    override =
      Map.new(pairs, fn {k, v} ->
        {Macro.expand(k, caller), Macro.expand(v, caller)}
      end)

    Map.merge(@default_abbrevs, override)
  end

  defp resolve_abbrevs(other, _caller) do
    raise ArgumentError,
          "use Samen.Scopes.Cms, abbrevs: must be a compile-time map literal " <>
            "(%{page: \"abc\", ...}). Got: #{Macro.to_string(other)}"
  end
end
