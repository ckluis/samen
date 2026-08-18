defmodule Driftwood.Repo.Migrations.AddDocsScope do
  @moduledoc """
  Mounts the Docs universal scope (F3, T45) into Driftwood's Postgres, and
  catalogs the resources in the SAME migration transaction (ADR-004
  catalog-in-tx). Mirrors `20260728200000_add_calendar_scope.exs`.

    * `fdd_doc`  — Doc: title, `body` (plain, `FreeTextScan`-guarded) /
      `secure_body` (🔒 vaulted, `vault: :pii_doc_body`), the generic
      `(subject_key, subject_id)` object-ref anchor. Archivable (ADR-040 §5.9).
    * `fdn_note` — Note: same `body`/`secure_body` posture (`vault:
      :pii_note_body`), same object-ref anchor. Archivable.
  """
  use Samen.Migration

  @resources [
    Driftwood.Docs.Doc,
    Driftwood.Docs.Note
  ]

  def up do
    create table(:fdd_doc, primary_key: false) do
      add(:fdd_title, :text, null: false)
      add(:fdd_body, :text)
      add(:fdd_subject_key, :text)
      add(:fdd_subject_id, :uuid)
      add(:fdd_custom, :map)
      add(:fdd_owner_id, :uuid)
      add(:pii_fdd_secure_body, :text)
      add(:fdd_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fdd_org_id, :uuid, null: false)
      add(:fdd_inserted_at, :utc_datetime, null: false)
      add(:fdd_updated_at, :utc_datetime, null: false)
      add(:fdd_archived_at, :utc_datetime_usec)
    end

    create(index(:fdd_doc, [:fdd_org_id]))
    create(index(:fdd_doc, [:fdd_subject_key, :fdd_subject_id]))

    create table(:fdn_note, primary_key: false) do
      add(:fdn_body, :text)
      add(:fdn_subject_key, :text)
      add(:fdn_subject_id, :uuid)
      add(:fdn_custom, :map)
      add(:fdn_owner_id, :uuid)
      add(:pii_fdn_secure_body, :text)
      add(:fdn_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fdn_org_id, :uuid, null: false)
      add(:fdn_inserted_at, :utc_datetime, null: false)
      add(:fdn_updated_at, :utc_datetime, null: false)
      add(:fdn_archived_at, :utc_datetime_usec)
    end

    create(index(:fdn_note, [:fdn_org_id]))
    create(index(:fdn_note, [:fdn_subject_key, :fdn_subject_id]))

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)
    drop(table(:fdn_note))
    drop(table(:fdd_doc))
  end
end
