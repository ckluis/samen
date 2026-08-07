defmodule Samen.WebTest.Repo.Migrations.MountCmsScope do
  @moduledoc """
  Mounts the CMS universal scope (T3.5) into the samen_web test host's Postgres —
  the FIRST samen_web materialization of this scope (T78, spec §I5 helpdesk
  knowledge base). Catalogs all six resources in the SAME migration transaction
  (ADR-004 catalog-in-tx). Mirrors demo's `20260706040000_add_cms_scope` +
  `20260729220000_cms_scope_archivable` (archivable folded in directly here,
  since this mount starts fresh) with the samen_web test host's own
  `cwp`/`cpw`/`wcb`/`cwm`/`wcn`/`wcs` abbrevs.

  ## `cpw_visibility` — the KB reuse seam (T78)

  `Post` gains one new attribute beyond the demo shape: `cpw_visibility`
  (`"internal" | "public"`, default `"internal"`). This is the ENTIRE delta that
  turns a CMS post into a helpdesk knowledge-base article — no parallel article
  resource. A public+published post is portal-visible (unauthenticated,
  `Post.read_public`); an internal post is agent-only (`Post`'s default
  org-scoped `:read`). No PII on this scope (doc §"The inherited 80%" — CMS has
  no 🔒 mark).
  """
  use Samen.Migration

  @resources [
    Samen.WebTest.Cms.Page,
    Samen.WebTest.Cms.Post,
    Samen.WebTest.Cms.Block,
    Samen.WebTest.Cms.Media,
    Samen.WebTest.Cms.Navigation,
    Samen.WebTest.Cms.SeoMeta
  ]

  def up do
    # --- cwp_page : a content page (draft→publish workflow) ---
    create table(:cwp_page, primary_key: false) do
      add(:cwp_title, :text, null: false)
      add(:cwp_slug, :text)
      add(:cwp_body, :text)
      add(:cwp_status, :text, default: "draft")
      add(:cwp_published_at, :utc_datetime)
      add(:cwp_custom, :map, default: fragment("'{}'::jsonb"))
      add(:cwp_archived_at, :utc_datetime_usec)
      add(:cwp_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:cwp_org_id, :uuid, null: false)
      add(:cwp_inserted_at, :utc_datetime, null: false)
      add(:cwp_updated_at, :utc_datetime, null: false)
    end

    # --- cpw_post : a blog post / KB article (draft→publish workflow) ---
    create table(:cpw_post, primary_key: false) do
      add(:cpw_title, :text, null: false)
      add(:cpw_slug, :text)
      add(:cpw_body, :text)
      add(:cpw_excerpt, :text)
      add(:cpw_status, :text, default: "draft")
      add(:cpw_published_at, :utc_datetime)
      add(:cpw_custom, :map, default: fragment("'{}'::jsonb"))
      # T78 (spec §I5) — the KB reuse seam: internal (agent-only) vs public
      # (portal-deflectable) article. See moduledoc.
      add(:cpw_visibility, :text, null: false, default: "internal")
      add(:cpw_archived_at, :utc_datetime_usec)
      add(:cpw_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:cpw_org_id, :uuid, null: false)
      add(:cpw_inserted_at, :utc_datetime, null: false)
      add(:cpw_updated_at, :utc_datetime, null: false)
    end

    create(index(:cpw_post, [:cpw_org_id, :cpw_status, :cpw_visibility]))

    # --- wcb_block : a reusable content block ---
    create table(:wcb_block, primary_key: false) do
      add(:wcb_name, :text, null: false)
      add(:wcb_block_type, :text, default: "generic")
      add(:wcb_content, :map, default: fragment("'{}'::jsonb"))
      add(:wcb_position, :integer, default: 0)
      add(:wcb_enabled, :boolean, default: true)

      add(
        :wcb_page_id,
        references(:cwp_page,
          column: :cwp_id,
          name: "wcb_block_wcb_page_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:wcb_archived_at, :utc_datetime_usec)
      add(:wcb_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wcb_org_id, :uuid, null: false)
      add(:wcb_inserted_at, :utc_datetime, null: false)
      add(:wcb_updated_at, :utc_datetime, null: false)
    end

    # --- cwm_media : a media asset ---
    create table(:cwm_media, primary_key: false) do
      add(:cwm_file_name, :text, null: false)
      add(:cwm_content_type, :text)
      add(:cwm_size_bytes, :integer)
      add(:cwm_storage_key, :text)
      add(:cwm_alt_text, :text)
      add(:cwm_media_type, :text, default: "image")
      add(:cwm_archived_at, :utc_datetime_usec)
      add(:cwm_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:cwm_org_id, :uuid, null: false)
      add(:cwm_inserted_at, :utc_datetime, null: false)
      add(:cwm_updated_at, :utc_datetime, null: false)
    end

    # --- wcn_navigation : Tier-0 config rows (nav items per org) ---
    create table(:wcn_navigation, primary_key: false) do
      add(:wcn_label, :text, null: false)
      add(:wcn_url, :text)
      add(:wcn_nav_type, :text, default: "main")
      add(:wcn_position, :integer, default: 0)
      add(:wcn_enabled, :boolean, default: true)
      add(:wcn_target, :text, default: "self")
      add(:wcn_archived_at, :utc_datetime_usec)
      add(:wcn_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wcn_org_id, :uuid, null: false)
      add(:wcn_inserted_at, :utc_datetime, null: false)
      add(:wcn_updated_at, :utc_datetime, null: false)
    end

    # --- wcs_seo_meta : SEO metadata for a page or post ---
    create table(:wcs_seo_meta, primary_key: false) do
      add(:wcs_meta_title, :text)
      add(:wcs_description, :text)
      add(:wcs_canonical_url, :text)
      add(:wcs_og_title, :text)
      add(:wcs_og_description, :text)
      add(:wcs_no_index, :boolean, default: false)
      add(:wcs_no_follow, :boolean, default: false)

      add(
        :wcs_page_id,
        references(:cwp_page,
          column: :cwp_id,
          name: "wcs_seo_meta_wcs_page_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :wcs_post_id,
        references(:cpw_post,
          column: :cpw_id,
          name: "wcs_seo_meta_wcs_post_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:wcs_archived_at, :utc_datetime_usec)
      add(:wcs_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wcs_org_id, :uuid, null: false)
      add(:wcs_inserted_at, :utc_datetime, null: false)
      add(:wcs_updated_at, :utc_datetime, null: false)
    end

    # --- E7 versioned: :snapshot — Page/Post/Block version history (ADR-040 §6.5) ---
    create table(:cwp_page_versions, primary_key: false) do
      add(:pcv_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:pcv_version_action_type, :text, null: false)
      add(:pcv_org_id, :uuid, null: false)
      add(:pcv_version_source_id, :uuid, null: false)
      add(:pcv_changes, :map)
      add(:pcv_version_inserted_at, :utc_datetime_usec, null: false)
      add(:pcv_version_updated_at, :utc_datetime_usec, null: false)
      add(:pcv_inserted_at, :utc_datetime, null: false)
      add(:pcv_updated_at, :utc_datetime, null: false)
    end

    create table(:cpw_post_versions, primary_key: false) do
      add(:pvc_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:pvc_version_action_type, :text, null: false)
      add(:pvc_org_id, :uuid, null: false)
      add(:pvc_version_source_id, :uuid, null: false)
      add(:pvc_changes, :map)
      add(:pvc_version_inserted_at, :utc_datetime_usec, null: false)
      add(:pvc_version_updated_at, :utc_datetime_usec, null: false)
      add(:pvc_inserted_at, :utc_datetime, null: false)
      add(:pvc_updated_at, :utc_datetime, null: false)
    end

    create table(:wcb_block_versions, primary_key: false) do
      add(:cvb_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:cvb_version_action_type, :text, null: false)
      add(:cvb_org_id, :uuid, null: false)
      add(:cvb_version_source_id, :uuid, null: false)
      add(:cvb_changes, :map)
      add(:cvb_version_inserted_at, :utc_datetime_usec, null: false)
      add(:cvb_version_updated_at, :utc_datetime_usec, null: false)
      add(:cvb_inserted_at, :utc_datetime, null: false)
      add(:cvb_updated_at, :utc_datetime, null: false)
    end

    catalog_sync(@resources)

    catalog_sync([
      Samen.WebTest.Cms.Page.Version,
      Samen.WebTest.Cms.Post.Version,
      Samen.WebTest.Cms.Block.Version
    ])
  end

  def down do
    catalog_sync_down([
      Samen.WebTest.Cms.Page.Version,
      Samen.WebTest.Cms.Post.Version,
      Samen.WebTest.Cms.Block.Version
    ])

    catalog_sync_down(@resources)

    drop(table(:wcb_block_versions))
    drop(table(:cpw_post_versions))
    drop(table(:cwp_page_versions))

    drop(constraint(:wcs_seo_meta, "wcs_seo_meta_wcs_post_id_fkey"))
    drop(constraint(:wcs_seo_meta, "wcs_seo_meta_wcs_page_id_fkey"))
    drop(table(:wcs_seo_meta))

    drop(table(:wcn_navigation))
    drop(table(:cwm_media))

    drop(constraint(:wcb_block, "wcb_block_wcb_page_id_fkey"))
    drop(table(:wcb_block))

    drop(table(:cpw_post))
    drop(table(:cwp_page))
  end
end
