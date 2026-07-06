defmodule Demo.Repo.Migrations.AddCmsScope do
  @moduledoc """
  Mounts the CMS scope tables into the Demo host's one Postgres, and catalogs
  them in the SAME migration transaction (ADR-004 §"Migrations": the
  catalog-in-tx guarantee requires DDL + catalog_sync in one transaction in the
  host's repo).

  Resources (T3.5; doc §"The inherited 80%" scope table `page · post · block ·
  media · navigation · seo_meta · content_version`):

    * `cpg_page`            — a content page (draft→publish workflow; no PII)
    * `cpt_post`            — a blog post (draft→publish workflow; no PII)
    * `cbl_block`           — a reusable content block (component/fragment)
    * `cmd_media`           — a media asset (image/video/document reference)
    * `cnv_navigation`      — Tier-0 config rows (nav items per org)
    * `csm_seo_meta`        — SEO metadata attached to a page or post
    * `cvr_content_version` — IMMUTABLE content version history (append-only)

  ## Non-PII classification

  `csm_seo_meta.csm_description` is registered as non-PII (see
  `Demo.CmsScope.NonPiiSetup`). The column is authored marketing copy, not
  subject identity data. Registration happens at seed/test time, not in the
  migration (the `non_pii!` registry uses the app DB, not the migration tx).

  ## ContentVersion immutability

  `cvr_content_version` has NO UPDATE/DELETE granted at the application layer
  (enforced by the Ash resource having no `:update`/`:destroy` actions). The
  append-only invariant is the resource-level guarantee, not a DB trigger
  (unlike `aud_event` which uses a belt-and-braces trigger). This is correct for
  content versions: they are tenant-readable product data with different retention
  semantics than the auditable `aud_event` tier.
  """
  use Samen.Migration

  @resources [
    Demo.CmsScope.Page,
    Demo.CmsScope.Post,
    Demo.CmsScope.Block,
    Demo.CmsScope.Media,
    Demo.CmsScope.Navigation,
    Demo.CmsScope.SeoMeta,
    Demo.CmsScope.ContentVersion
  ]

  def up do
    # --- cpg_page : a content page (draft→publish workflow) ---
    create table(:cpg_page, primary_key: false) do
      add(:cpg_title, :text, null: false)
      add(:cpg_slug, :text)
      add(:cpg_body, :text)
      add(:cpg_status, :text, default: "draft")
      add(:cpg_published_at, :utc_datetime)
      add(:cpg_custom, :map, default: fragment("'{}'::jsonb"))
      add(:cpg_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:cpg_org_id, :uuid, null: false)
      add(:cpg_inserted_at, :utc_datetime, null: false)
      add(:cpg_updated_at, :utc_datetime, null: false)
    end

    # --- cpt_post : a blog post (draft→publish workflow) ---
    create table(:cpt_post, primary_key: false) do
      add(:cpt_title, :text, null: false)
      add(:cpt_slug, :text)
      add(:cpt_body, :text)
      add(:cpt_excerpt, :text)
      add(:cpt_status, :text, default: "draft")
      add(:cpt_published_at, :utc_datetime)
      add(:cpt_custom, :map, default: fragment("'{}'::jsonb"))
      add(:cpt_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:cpt_org_id, :uuid, null: false)
      add(:cpt_inserted_at, :utc_datetime, null: false)
      add(:cpt_updated_at, :utc_datetime, null: false)
    end

    # --- cbl_block : a reusable content block ---
    create table(:cbl_block, primary_key: false) do
      add(:cbl_name, :text, null: false)
      add(:cbl_block_type, :text, default: "generic")
      add(:cbl_content, :map, default: fragment("'{}'::jsonb"))
      add(:cbl_position, :integer, default: 0)
      add(:cbl_enabled, :boolean, default: true)

      add(
        :cbl_page_id,
        references(:cpg_page,
          column: :cpg_id,
          name: "cbl_block_cbl_page_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:cbl_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:cbl_org_id, :uuid, null: false)
      add(:cbl_inserted_at, :utc_datetime, null: false)
      add(:cbl_updated_at, :utc_datetime, null: false)
    end

    # --- cmd_media : a media asset ---
    create table(:cmd_media, primary_key: false) do
      add(:cmd_file_name, :text, null: false)
      add(:cmd_content_type, :text)
      add(:cmd_size_bytes, :integer)
      add(:cmd_storage_key, :text)
      add(:cmd_alt_text, :text)
      add(:cmd_media_type, :text, default: "image")
      add(:cmd_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:cmd_org_id, :uuid, null: false)
      add(:cmd_inserted_at, :utc_datetime, null: false)
      add(:cmd_updated_at, :utc_datetime, null: false)
    end

    # --- cnv_navigation : Tier-0 config rows (nav items per org) ---
    create table(:cnv_navigation, primary_key: false) do
      add(:cnv_label, :text, null: false)
      add(:cnv_url, :text)
      add(:cnv_nav_type, :text, default: "main")
      add(:cnv_position, :integer, default: 0)
      add(:cnv_enabled, :boolean, default: true)
      add(:cnv_target, :text, default: "self")
      add(:cnv_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:cnv_org_id, :uuid, null: false)
      add(:cnv_inserted_at, :utc_datetime, null: false)
      add(:cnv_updated_at, :utc_datetime, null: false)
    end

    # --- csm_seo_meta : SEO metadata for a page or post ---
    create table(:csm_seo_meta, primary_key: false) do
      add(:csm_meta_title, :text)
      # csm_description: authored marketing copy — non-PII (see NonPiiSetup).
      add(:csm_description, :text)
      add(:csm_canonical_url, :text)
      add(:csm_og_title, :text)
      add(:csm_og_description, :text)
      add(:csm_no_index, :boolean, default: false)
      add(:csm_no_follow, :boolean, default: false)

      add(
        :csm_page_id,
        references(:cpg_page,
          column: :cpg_id,
          name: "csm_seo_meta_csm_page_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :csm_post_id,
        references(:cpt_post,
          column: :cpt_id,
          name: "csm_seo_meta_csm_post_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:csm_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:csm_org_id, :uuid, null: false)
      add(:csm_inserted_at, :utc_datetime, null: false)
      add(:csm_updated_at, :utc_datetime, null: false)
    end

    # --- cvr_content_version : IMMUTABLE content version history ---
    # Append-only at the application layer (no :update/:destroy Ash actions).
    # Stores a snapshot of authored content at the time of a publish/archive event.
    create table(:cvr_content_version, primary_key: false) do
      add(:cvr_subject_type, :text, null: false)
      add(:cvr_subject_id, :uuid, null: false)
      add(:cvr_content_snapshot, :map, default: fragment("'{}'::jsonb"))
      add(:cvr_status, :text)
      add(:cvr_author_id, :uuid)
      add(:cvr_version_number, :integer, default: 1)
      add(:cvr_change_summary, :text)
      add(:cvr_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:cvr_org_id, :uuid, null: false)
      add(:cvr_inserted_at, :utc_datetime, null: false)
      add(:cvr_updated_at, :utc_datetime, null: false)
    end

    # --- catalog all seven CMS resources in THIS transaction ---
    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    # Drop in reverse FK order.
    drop(constraint(:csm_seo_meta, "csm_seo_meta_csm_post_id_fkey"))
    drop(constraint(:csm_seo_meta, "csm_seo_meta_csm_page_id_fkey"))
    drop(table(:csm_seo_meta))

    drop(constraint(:cbl_block, "cbl_block_cbl_page_id_fkey"))
    drop(table(:cbl_block))

    drop(table(:cvr_content_version))
    drop(table(:cnv_navigation))
    drop(table(:cmd_media))
    drop(table(:cpt_post))
    drop(table(:cpg_page))
  end
end
