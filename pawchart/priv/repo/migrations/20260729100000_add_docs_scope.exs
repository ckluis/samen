defmodule PawChart.Repo.Migrations.AddDocsScope do
  @moduledoc """
  Mounts the Docs universal scope (F3, T45) into PawChart's Postgres, and
  catalogs the resources in the SAME migration transaction (ADR-004
  catalog-in-tx). Mirrors `20260728190000_add_calendar_scope.exs`.

    * `pdd_doc`  — Doc: title, `body` (plain, `FreeTextScan`-guarded) /
      `secure_body` (🔒 vaulted, `vault: :pii_doc_body`), the generic
      `(subject_key, subject_id)` object-ref anchor. Archivable (ADR-040 §5.9).
    * `pdn_note` — Note: same `body`/`secure_body` posture (`vault:
      :pii_note_body`), same object-ref anchor. Archivable.
  """
  use Samen.Migration

  @resources [
    PawChart.Docs.Doc,
    PawChart.Docs.Note
  ]

  def up do
    create table(:pdd_doc, primary_key: false) do
      add(:pdd_title, :text, null: false)
      add(:pdd_body, :text)
      add(:pdd_subject_key, :text)
      add(:pdd_subject_id, :uuid)
      add(:pdd_custom, :map)
      add(:pdd_owner_id, :uuid)
      add(:pii_pdd_secure_body, :text)
      add(:pdd_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:pdd_org_id, :uuid, null: false)
      add(:pdd_inserted_at, :utc_datetime, null: false)
      add(:pdd_updated_at, :utc_datetime, null: false)
      add(:pdd_archived_at, :utc_datetime_usec)
    end

    create(index(:pdd_doc, [:pdd_org_id]))
    create(index(:pdd_doc, [:pdd_subject_key, :pdd_subject_id]))

    create table(:pdn_note, primary_key: false) do
      add(:pdn_body, :text)
      add(:pdn_subject_key, :text)
      add(:pdn_subject_id, :uuid)
      add(:pdn_custom, :map)
      add(:pdn_owner_id, :uuid)
      add(:pii_pdn_secure_body, :text)
      add(:pdn_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:pdn_org_id, :uuid, null: false)
      add(:pdn_inserted_at, :utc_datetime, null: false)
      add(:pdn_updated_at, :utc_datetime, null: false)
      add(:pdn_archived_at, :utc_datetime_usec)
    end

    create(index(:pdn_note, [:pdn_org_id]))
    create(index(:pdn_note, [:pdn_subject_key, :pdn_subject_id]))

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)
    drop(table(:pdn_note))
    drop(table(:pdd_doc))
  end
end
