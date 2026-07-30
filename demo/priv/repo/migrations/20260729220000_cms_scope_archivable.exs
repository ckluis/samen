defmodule Demo.Repo.Migrations.CmsScopeArchivable do
  @moduledoc """
  ADR-040 §5.9 (T37b) — the CMS scope's adoption sub-item: `page`, `post`,
  `block`, `media`, `navigation`, `seo_meta` flip `archivable true`
  (samen_core/lib/samen/scopes/cms/blueprint.ex). `content_version` stays
  excluded (L — ledger; also retired outright by T38, ADR-040 §6.5) — no
  column added for it.

  The T36 substrate (ash_archival, ADR-037 §5.3 ADOPT) injects one
  abbrev-prefixed `<abbrev>_archived_at :utc_datetime_usec` column per
  adopting resource (NULL = live). §5.3: no `unique_index` exists on any of
  `cpg_page` / `cpt_post` / `cbl_block` / `cmd_media` / `cnv_navigation` /
  `csm_seo_meta` today (confirmed by inspecting `20260706040000_add_cms_scope`
  — the whole migration has zero `unique_index` calls), so there is nothing
  to convert to partial form — the ADR's "the sweep may turn up nothing" case,
  same finding as T37a's billing adoption.

  Additive columns on already-catalogued resources → `catalog_sync/2`'s
  `only:` scoping, so `down` removes exactly these six `fld_field` rows.
  """
  use Samen.Migration

  def change do
    alter table(:cpg_page) do
      add(:cpg_archived_at, :utc_datetime_usec)
    end

    alter table(:cpt_post) do
      add(:cpt_archived_at, :utc_datetime_usec)
    end

    alter table(:cbl_block) do
      add(:cbl_archived_at, :utc_datetime_usec)
    end

    alter table(:cmd_media) do
      add(:cmd_archived_at, :utc_datetime_usec)
    end

    alter table(:cnv_navigation) do
      add(:cnv_archived_at, :utc_datetime_usec)
    end

    alter table(:csm_seo_meta) do
      add(:csm_archived_at, :utc_datetime_usec)
    end

    catalog_sync([Demo.CmsScope.Page], only: [:archived_at])
    catalog_sync([Demo.CmsScope.Post], only: [:archived_at])
    catalog_sync([Demo.CmsScope.Block], only: [:archived_at])
    catalog_sync([Demo.CmsScope.Media], only: [:archived_at])
    catalog_sync([Demo.CmsScope.Navigation], only: [:archived_at])
    catalog_sync([Demo.CmsScope.SeoMeta], only: [:archived_at])
  end
end
