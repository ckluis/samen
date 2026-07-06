defmodule Samen.Scopes.Cms do
  @moduledoc """
  The **CMS** universal scope (T3.5; doc §"The inherited 80%" scope table:
  `page · post · block · media · navigation · seo_meta · content_version`).

  Ships as a **library-authored blueprint** (ADR-004): `use`-ing this module
  inside a host's Ash domain expands into seven host-owned resources in the host's
  namespace — each a normal `use Samen.Resource` with the host's `otp_app`,
  `repo`, and `domain`.

  ## PII classification — no 🔒 objects in this scope

  The CMS scope contains NO vault-routed PII objects (the doc's 🔒 map has no mark
  on `page · post · block · media · navigation · seo_meta · content_version`). This
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

  ## Draft → publish workflow with content_version immutable history

  `ContentVersion` provides immutable content history:
  - Every time a `Page` or `Post` is updated, a `ContentVersion` row is appended
    (the `create_version` Ash action — called from change hooks or explicitly).
  - Versions are NEVER updated or deleted (append-only; no UPDATE/DELETE actions
    on `ContentVersion`). The `aud_event` tier does not duplicate this — the version
    table IS the immutable history for content objects.
  - The `status` column on `Page`/`Post` drives the draft→publish workflow:
    `:draft` | `:published` | `:archived`. Publish is an admin-gated action.

  ## Tier-0 config rows

  `Navigation` serves as the CMS Tier-0 config resource: one row per navigation item
  per org (e.g. main menu, footer links). Admins bend the nav structure without
  forking the product.

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
    * `Demo.CmsScope.ContentVersion` — immutable content version history (append-only)

  ## Abbrevs (permanent, registry-checked)

  Each resource carries a permanent 3-letter abbrev, reserved in
  `samen_core/priv/abbrev_registry.json` under the HOST module name:

    * `Demo.CmsScope.Page`           → `cpg`
    * `Demo.CmsScope.Post`           → `cpt`
    * `Demo.CmsScope.Block`          → `cbl`
    * `Demo.CmsScope.Media`          → `cmd`
    * `Demo.CmsScope.Navigation`     → `cnv`
    * `Demo.CmsScope.SeoMeta`        → `csm`
    * `Demo.CmsScope.ContentVersion` → `cvr`

  The macro does NOT invent abbrevs. Defaults are provided for the demo mount.
  """

  @default_abbrevs %{
    page: "cpg",
    post: "cpt",
    block: "cbl",
    media: "cmd",
    navigation: "cnv",
    seo_meta: "csm",
    content_version: "cvr"
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
    content_version_mod = Module.concat(namespace, ContentVersion)

    quote do
      require Samen.Scopes.Cms.Blueprint

      # Register the seven CMS resources in the host domain.
      resources do
        resource(unquote(page_mod))
        resource(unquote(post_mod))
        resource(unquote(block_mod))
        resource(unquote(media_mod))
        resource(unquote(navigation_mod))
        resource(unquote(seo_meta_mod))
        resource(unquote(content_version_mod))
      end

      # Materialize resource modules in the host namespace.
      Samen.Scopes.Cms.Blueprint.define_page(
        unquote(page_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.page),
        unquote(content_version_mod)
      )

      Samen.Scopes.Cms.Blueprint.define_post(
        unquote(post_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.post),
        unquote(content_version_mod)
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

      Samen.Scopes.Cms.Blueprint.define_content_version(
        unquote(content_version_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.content_version)
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
