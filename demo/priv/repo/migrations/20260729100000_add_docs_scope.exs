defmodule Demo.Repo.Migrations.AddDocsScope do
  @moduledoc """
  Mounts the Docs universal scope (F3, T45) into the demo host's one Postgres,
  and catalogs the resources in the SAME migration transaction (ADR-004
  catalog-in-tx). Mirrors `20260728190000_add_calendar_scope.exs`.

    * `ddd_doc`  — Doc: title, `body` (plain, `FreeTextScan`-guarded) /
      `secure_body` (🔒 vaulted, `vault: :pii_doc_body`), the generic
      `(subject_key, subject_id)` object-ref anchor. Archivable (ADR-040 §5.9).
    * `ddn_note` — Note: same `body`/`secure_body` posture (`vault:
      :pii_note_body`), same object-ref anchor. Archivable.
  """
  use Samen.Migration

  @resources [
    Demo.DocsScope.Doc,
    Demo.DocsScope.Note
  ]

  def up do
    create table(:ddd_doc, primary_key: false) do
      add(:ddd_title, :text, null: false)
      add(:ddd_body, :text)
      add(:ddd_subject_key, :text)
      add(:ddd_subject_id, :uuid)
      add(:ddd_custom, :map)
      add(:ddd_owner_id, :uuid)
      add(:pii_ddd_secure_body, :text)
      add(:ddd_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:ddd_org_id, :uuid, null: false)
      add(:ddd_inserted_at, :utc_datetime, null: false)
      add(:ddd_updated_at, :utc_datetime, null: false)
      add(:ddd_archived_at, :utc_datetime_usec)
    end

    create(index(:ddd_doc, [:ddd_org_id]))
    create(index(:ddd_doc, [:ddd_subject_key, :ddd_subject_id]))

    create table(:ddn_note, primary_key: false) do
      add(:ddn_body, :text)
      add(:ddn_subject_key, :text)
      add(:ddn_subject_id, :uuid)
      add(:ddn_custom, :map)
      add(:ddn_owner_id, :uuid)
      add(:pii_ddn_secure_body, :text)
      add(:ddn_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:ddn_org_id, :uuid, null: false)
      add(:ddn_inserted_at, :utc_datetime, null: false)
      add(:ddn_updated_at, :utc_datetime, null: false)
      add(:ddn_archived_at, :utc_datetime_usec)
    end

    create(index(:ddn_note, [:ddn_org_id]))
    create(index(:ddn_note, [:ddn_subject_key, :ddn_subject_id]))

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)
    drop(table(:ddn_note))
    drop(table(:ddd_doc))
  end
end
