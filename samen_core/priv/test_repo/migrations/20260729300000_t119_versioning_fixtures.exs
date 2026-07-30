defmodule SamenCore.TestRepo.Migrations.T119VersioningFixtures do
  @moduledoc """
  Tables for the E7 audit-on-write pilots (ADR-040 §6, T119):

    * `svc_contact` + its generated `svc_contact_versions` (`:changes_only` mode)
    * `svs_snapshot` + its generated `svs_snapshot_versions` (`:snapshot` + archivable)

  Both source tables fold `Core.Person` (vault-routed `<abbrev>_full_name/_emails/
  _phones` columns holding `vt_*` tokens, never plaintext). The `<abbrev>_versions`
  tables are governed like any samen table: allocator-owned abbrev (`vcv`/`vsv`),
  self-qualifying prefixed columns, the mirrored `<abbrev>_org_id` (NOT NULL — §6.2),
  the jsonb `<abbrev>_changes` diff, and the universal id/timestamps.
  """
  use Ecto.Migration

  def up do
    create table(:svc_contact, primary_key: false) do
      add(:svc_label, :text)
      add(:svc_job_title, :text)
      add(:svc_full_name, :text)
      add(:svc_emails, :text)
      add(:svc_phones, :text)
      add(:svc_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:svc_org_id, :uuid, null: false)
      add(:svc_inserted_at, :utc_datetime, null: false)
      add(:svc_updated_at, :utc_datetime, null: false)
    end

    create table(:svc_contact_versions, primary_key: false) do
      add(:vcv_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:vcv_version_action_type, :text, null: false)
      add(:vcv_org_id, :uuid, null: false)
      add(:vcv_version_source_id, :uuid, null: false)
      add(:vcv_changes, :map)
      add(:vcv_version_inserted_at, :utc_datetime_usec, null: false)
      add(:vcv_version_updated_at, :utc_datetime_usec, null: false)
      add(:vcv_inserted_at, :utc_datetime, null: false)
      add(:vcv_updated_at, :utc_datetime, null: false)
    end

    create table(:svs_snapshot, primary_key: false) do
      add(:svs_label, :text)
      add(:svs_job_title, :text)
      add(:svs_full_name, :text)
      add(:svs_emails, :text)
      add(:svs_phones, :text)
      add(:svs_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:svs_org_id, :uuid, null: false)
      add(:svs_inserted_at, :utc_datetime, null: false)
      add(:svs_updated_at, :utc_datetime, null: false)
    end

    create table(:svs_snapshot_versions, primary_key: false) do
      add(:vsv_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:vsv_version_action_type, :text, null: false)
      add(:vsv_org_id, :uuid, null: false)
      add(:vsv_version_source_id, :uuid, null: false)
      add(:vsv_changes, :map)
      add(:vsv_version_inserted_at, :utc_datetime_usec, null: false)
      add(:vsv_version_updated_at, :utc_datetime_usec, null: false)
      add(:vsv_inserted_at, :utc_datetime, null: false)
      add(:vsv_updated_at, :utc_datetime, null: false)
    end
  end

  def down do
    drop(table(:svs_snapshot_versions))
    drop(table(:svs_snapshot))
    drop(table(:svc_contact_versions))
    drop(table(:svc_contact))
  end
end
