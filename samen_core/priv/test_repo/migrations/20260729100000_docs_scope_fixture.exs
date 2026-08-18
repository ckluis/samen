defmodule SamenCore.TestRepo.Migrations.DocsScopeFixture do
  @moduledoc """
  Tables for the Docs scope (F3, T45): `sdd_doc` + `sdn_note`, mounted in
  `samen_core` tests via `test/support/docs_fixture.ex`.

  `pii_sdd_secure_body` / `pii_sdn_secure_body` are the vaulted alternatives to
  the plain `body` column (scalar `pii_attribute` columns carry the `pii_`
  prefix per `Samen.Transformers.MaterializePii`, e.g. `pii_cnt_dob`).

  Catalog rows are written by `catalog_sync/1` in the SAME transaction (ADR-004).
  """
  use Samen.Migration

  @resources [
    SamenCore.Support.DocsFixture.Doc,
    SamenCore.Support.DocsFixture.Note
  ]

  def up do
    create table(:sdd_doc, primary_key: false) do
      add(:sdd_title, :text, null: false)
      add(:sdd_body, :text)
      add(:sdd_subject_key, :text)
      add(:sdd_subject_id, :uuid)
      add(:sdd_custom, :map)
      add(:sdd_owner_id, :uuid)
      add(:pii_sdd_secure_body, :text)
      add(:sdd_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:sdd_org_id, :uuid, null: false)
      add(:sdd_inserted_at, :utc_datetime, null: false)
      add(:sdd_updated_at, :utc_datetime, null: false)
      add(:sdd_archived_at, :utc_datetime_usec)
    end

    create(index(:sdd_doc, [:sdd_org_id]))
    create(index(:sdd_doc, [:sdd_subject_key, :sdd_subject_id]))

    create table(:sdn_note, primary_key: false) do
      add(:sdn_body, :text)
      add(:sdn_subject_key, :text)
      add(:sdn_subject_id, :uuid)
      add(:sdn_custom, :map)
      add(:sdn_owner_id, :uuid)
      add(:pii_sdn_secure_body, :text)
      add(:sdn_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:sdn_org_id, :uuid, null: false)
      add(:sdn_inserted_at, :utc_datetime, null: false)
      add(:sdn_updated_at, :utc_datetime, null: false)
      add(:sdn_archived_at, :utc_datetime_usec)
    end

    create(index(:sdn_note, [:sdn_org_id]))
    create(index(:sdn_note, [:sdn_subject_key, :sdn_subject_id]))

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)
    drop(table(:sdn_note))
    drop(table(:sdd_doc))
  end
end
