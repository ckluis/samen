defmodule Demo.Repo.Migrations.CmsRetireContentVersionAddVersions do
  @moduledoc """
  ADR-040 §6.5 (T119) — the CMS content-history destructive break.

  RETIRES the bespoke `cvr_content_version` ledger and replaces it with the E7
  audit-on-write `versioned: :snapshot` history: `Demo.CmsScope.{Page,Post,Block}` now
  generate governed `<Resource>.Version` resources (ash_paper_trail), whose tables this
  migration creates and catalogs.

  ## Zero-data-drop

  `content_version` held only DEV/FIXTURE data (the demo `Smoke` + tests seeded it; no
  lifecycle hook ever appended rows, and no production host mounts the CMS scope). There
  is no history to migrate — a clean drop/create produces the paper_trail-backed shape
  (the handoff's sanctioned path for dev-only fixture data). Test DBs are dropped and
  recreated every run, so on the CI path `cvr_content_version` is never even created
  (its create was elided from the historical `20260706040000_add_cms_scope`); the guarded
  `DROP TABLE IF EXISTS` + catalog cleanup below is a belt-and-braces sweep for any
  lingering persistent dev DB (T97 move-then-drop convention: idempotent, guarded).

  The `<abbrev>_versions` tables are governed like any samen table: allocator-owned
  abbrev (`cpv`/`cvp`/`cbv`), self-qualifying prefixed columns, the mirrored
  `<abbrev>_org_id` (NOT NULL, §6.2), the jsonb `<abbrev>_changes` token-only diff, and
  the universal id/timestamps. Catalogued in-transaction (the catalog-in-tx guarantee).
  """
  use Samen.Migration

  @version_resources [
    Demo.CmsScope.Page.Version,
    Demo.CmsScope.Post.Version,
    Demo.CmsScope.Block.Version
  ]

  def up do
    # Retire the bespoke ledger (idempotent; a no-op on a fresh CI DB that never had it).
    execute("DELETE FROM fld_field WHERE fld_table_name = 'cvr_content_version'")
    execute("DELETE FROM tam_table WHERE tam_table_name = 'cvr_content_version'")
    execute("DROP TABLE IF EXISTS cvr_content_version")

    create table(:cpg_page_versions, primary_key: false) do
      add(:cpv_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:cpv_version_action_type, :text, null: false)
      add(:cpv_org_id, :uuid, null: false)
      add(:cpv_version_source_id, :uuid, null: false)
      add(:cpv_changes, :map)
      add(:cpv_version_inserted_at, :utc_datetime_usec, null: false)
      add(:cpv_version_updated_at, :utc_datetime_usec, null: false)
      add(:cpv_inserted_at, :utc_datetime, null: false)
      add(:cpv_updated_at, :utc_datetime, null: false)
    end

    create table(:cpt_post_versions, primary_key: false) do
      add(:cvp_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:cvp_version_action_type, :text, null: false)
      add(:cvp_org_id, :uuid, null: false)
      add(:cvp_version_source_id, :uuid, null: false)
      add(:cvp_changes, :map)
      add(:cvp_version_inserted_at, :utc_datetime_usec, null: false)
      add(:cvp_version_updated_at, :utc_datetime_usec, null: false)
      add(:cvp_inserted_at, :utc_datetime, null: false)
      add(:cvp_updated_at, :utc_datetime, null: false)
    end

    create table(:cbl_block_versions, primary_key: false) do
      add(:cbv_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:cbv_version_action_type, :text, null: false)
      add(:cbv_org_id, :uuid, null: false)
      add(:cbv_version_source_id, :uuid, null: false)
      add(:cbv_changes, :map)
      add(:cbv_version_inserted_at, :utc_datetime_usec, null: false)
      add(:cbv_version_updated_at, :utc_datetime_usec, null: false)
      add(:cbv_inserted_at, :utc_datetime, null: false)
      add(:cbv_updated_at, :utc_datetime, null: false)
    end

    catalog_sync(@version_resources)
  end

  def down do
    catalog_sync_down(@version_resources)
    drop(table(:cbl_block_versions))
    drop(table(:cpt_post_versions))
    drop(table(:cpg_page_versions))
  end
end
