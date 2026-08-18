defmodule Samen.WebTest.Repo.Migrations.MountDocsScope do
  @moduledoc """
  Tables for the Docs scope (F3, T45): `wdd_doc` + `wdn_note`, mounted in
  `samen_web` tests via `test/support/docs.ex`. Mirrors
  `20260728180000_mount_calendar_scope.exs`.

  `pii_wdd_secure_body` / `pii_wdn_secure_body` are the vaulted alternatives to
  the plain `body` column (scalar `pii_attribute` columns carry the `pii_`
  prefix per `Samen.Transformers.MaterializePii`).

  Catalog rows are written by `catalog_sync/1` in the SAME transaction (ADR-004).
  """
  use Samen.Migration

  @resources [
    Samen.WebTest.Docs.Doc,
    Samen.WebTest.Docs.Note
  ]

  def up do
    create table(:wdd_doc, primary_key: false) do
      add(:wdd_title, :text, null: false)
      add(:wdd_body, :text)
      add(:wdd_subject_key, :text)
      add(:wdd_subject_id, :uuid)
      add(:wdd_custom, :map)
      add(:wdd_owner_id, :uuid)
      add(:pii_wdd_secure_body, :text)
      add(:wdd_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wdd_org_id, :uuid, null: false)
      add(:wdd_inserted_at, :utc_datetime, null: false)
      add(:wdd_updated_at, :utc_datetime, null: false)
      add(:wdd_archived_at, :utc_datetime_usec)
    end

    create(index(:wdd_doc, [:wdd_org_id]))
    create(index(:wdd_doc, [:wdd_subject_key, :wdd_subject_id]))

    create table(:wdn_note, primary_key: false) do
      add(:wdn_body, :text)
      add(:wdn_subject_key, :text)
      add(:wdn_subject_id, :uuid)
      add(:wdn_custom, :map)
      add(:wdn_owner_id, :uuid)
      add(:pii_wdn_secure_body, :text)
      add(:wdn_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wdn_org_id, :uuid, null: false)
      add(:wdn_inserted_at, :utc_datetime, null: false)
      add(:wdn_updated_at, :utc_datetime, null: false)
      add(:wdn_archived_at, :utc_datetime_usec)
    end

    create(index(:wdn_note, [:wdn_org_id]))
    create(index(:wdn_note, [:wdn_subject_key, :wdn_subject_id]))

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)
    drop(table(:wdn_note))
    drop(table(:wdd_doc))
  end
end
