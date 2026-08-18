defmodule Samen.WebTest.Repo.Migrations.MountFleetScope do
  @moduledoc """
  T82 (ADR-044 §4.1, WS-J J1) — mounts the fleet registry blueprint
  (`Samen.Fleet.Scope`) into the samen_web test host's Postgres, mirroring
  `20260806010000_mount_mailbox_scope.exs` with this host's own
  `wfa`/`wfc`/`wfe`/`wfr`/`wfd` abbrevs.

  No `pii_` column anywhere — every column is a bounded scalar, a KMS-wrapped
  opaque blob (`wfc_secret_ciphertext`), or schema-validated jsonb
  (`wfr_payload`/`wfd_payload`/`wfd_target`).
  """
  use Samen.Migration

  @resources [
    Samen.WebTest.Fleet.App,
    Samen.WebTest.Fleet.Credential,
    Samen.WebTest.Fleet.EnrollmentToken,
    Samen.WebTest.Fleet.Report,
    Samen.WebTest.Fleet.Directive
  ]

  def up do
    create table(:wfa_app, primary_key: false) do
      add(:wfa_slug, :text, null: false)
      add(:wfa_display_name, :text, null: false)
      add(:wfa_mode, :text, null: false)
      add(:wfa_base_url, :text)
      add(:wfa_status, :text, null: false, default: "active")
      add(:wfa_registered_at, :utc_datetime_usec, null: false)
      add(:wfa_stale_after_s, :integer, null: false, default: 300)

      add(:wfa_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wfa_org_id, :uuid)
      add(:wfa_inserted_at, :utc_datetime, null: false)
      add(:wfa_updated_at, :utc_datetime, null: false)
    end

    create(unique_index(:wfa_app, [:wfa_slug], name: :wfa_app_slug_index))

    create table(:wfc_credential, primary_key: false) do
      add(:wfc_app_id, :uuid, null: false)
      add(:wfc_key_version, :integer, null: false, default: 1)
      add(:wfc_kind, :text, null: false)
      add(:wfc_public_key, :text)
      add(:wfc_secret_ciphertext, :text)
      add(:wfc_capability, :text, null: false)
      add(:wfc_activated_at, :utc_datetime_usec, null: false)
      add(:wfc_retire_at, :utc_datetime_usec)
      add(:wfc_revoked_at, :utc_datetime_usec)

      add(:wfc_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wfc_org_id, :uuid)
      add(:wfc_inserted_at, :utc_datetime, null: false)
      add(:wfc_updated_at, :utc_datetime, null: false)
    end

    create(index(:wfc_credential, [:wfc_app_id]))
    create(index(:wfc_credential, [:wfc_app_id, :wfc_key_version]))

    create table(:wfe_enrollment_token, primary_key: false) do
      add(:wfe_token_digest, :text, null: false)
      add(:wfe_app_slug, :text, null: false)
      add(:wfe_display_name, :text, null: false)
      add(:wfe_expires_at, :utc_datetime_usec, null: false)
      add(:wfe_consumed_at, :utc_datetime_usec)
      add(:wfe_consumed_app_id, :uuid)

      add(:wfe_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wfe_org_id, :uuid)
      add(:wfe_inserted_at, :utc_datetime, null: false)
      add(:wfe_updated_at, :utc_datetime, null: false)
    end

    create(unique_index(:wfe_enrollment_token, [:wfe_token_digest], name: :wfe_token_digest_index))

    create table(:wfr_report, primary_key: false) do
      add(:wfr_app_id, :uuid, null: false)
      add(:wfr_schema_version, :integer, null: false, default: 1)
      add(:wfr_generated_at_us, :bigint, null: false)
      add(:wfr_received_at, :utc_datetime_usec, null: false)
      add(:wfr_transport, :text, null: false)
      add(:wfr_payload, :map, null: false, default: %{})

      add(:wfr_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wfr_org_id, :uuid)
      add(:wfr_inserted_at, :utc_datetime, null: false)
      add(:wfr_updated_at, :utc_datetime, null: false)
    end

    create(index(:wfr_report, [:wfr_app_id, :wfr_received_at]))

    create table(:wfd_directive, primary_key: false) do
      add(:wfd_fleet_revision, :integer, null: false)
      add(:wfd_target, :map, null: false, default: %{})
      add(:wfd_payload, :map, null: false, default: %{})
      add(:wfd_published_by, :text, null: false)
      add(:wfd_published_at, :utc_datetime_usec, null: false)

      add(:wfd_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wfd_org_id, :uuid)
      add(:wfd_inserted_at, :utc_datetime, null: false)
      add(:wfd_updated_at, :utc_datetime, null: false)
    end

    create(index(:wfd_directive, [:wfd_fleet_revision]))

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)
    drop(table(:wfd_directive))
    drop(table(:wfr_report))
    drop(table(:wfe_enrollment_token))
    drop(table(:wfc_credential))
    drop(table(:wfa_app))
  end
end
