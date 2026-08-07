defmodule SamenCore.TestRepo.Migrations.FleetFixture do
  @moduledoc """
  T82 (ADR-044 §4.1, WS-J J1) — the samen_core test-suite mount of the fleet
  registry blueprint (`Samen.Fleet.Scope`, `test/support/fleet_fixture.ex`).
  Mirrors the Mailbox/Outreach fixture migrations with this host's own
  `sfa`/`sfc`/`sfe`/`sfr`/`sfd` abbrevs.

  No `pii_` column anywhere — every column here is a bounded scalar, a KMS-wrapped
  opaque blob (`sfc_secret_ciphertext`), or schema-validated jsonb
  (`sfr_payload`/`sfd_payload`/`sfd_target`). `mix samen.verify.no_pii_columns`
  (INV-2) covers this table set via the C7 `NoPiiColumns` compile verifier already
  running on every `use Samen.Aggregate.Resource`.
  """
  use Samen.Migration

  @resources [
    SamenCore.Support.FleetFixture.App,
    SamenCore.Support.FleetFixture.Credential,
    SamenCore.Support.FleetFixture.EnrollmentToken,
    SamenCore.Support.FleetFixture.Report,
    SamenCore.Support.FleetFixture.Directive
  ]

  def up do
    # --- sfa_app : one registered product ---
    create table(:sfa_app, primary_key: false) do
      add(:sfa_slug, :text, null: false)
      add(:sfa_display_name, :text, null: false)
      add(:sfa_mode, :text, null: false)
      add(:sfa_base_url, :text)
      add(:sfa_status, :text, null: false, default: "active")
      add(:sfa_registered_at, :utc_datetime_usec, null: false)
      add(:sfa_stale_after_s, :integer, null: false, default: 300)

      add(:sfa_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:sfa_org_id, :uuid)
      add(:sfa_inserted_at, :utc_datetime, null: false)
      add(:sfa_updated_at, :utc_datetime, null: false)
    end

    create(unique_index(:sfa_app, [:sfa_slug], name: :sfa_app_slug_index))

    # --- sfc_credential : one key version for one app ---
    create table(:sfc_credential, primary_key: false) do
      add(:sfc_app_id, :uuid, null: false)
      add(:sfc_key_version, :integer, null: false, default: 1)
      add(:sfc_kind, :text, null: false)
      add(:sfc_public_key, :text)
      add(:sfc_secret_ciphertext, :text)
      add(:sfc_capability, :text, null: false)
      add(:sfc_activated_at, :utc_datetime_usec, null: false)
      add(:sfc_retire_at, :utc_datetime_usec)
      add(:sfc_revoked_at, :utc_datetime_usec)

      add(:sfc_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:sfc_org_id, :uuid)
      add(:sfc_inserted_at, :utc_datetime, null: false)
      add(:sfc_updated_at, :utc_datetime, null: false)
    end

    create(index(:sfc_credential, [:sfc_app_id]))
    create(index(:sfc_credential, [:sfc_app_id, :sfc_key_version]))

    # --- sfe_enrollment_token : a single-use mode-B enrollment grant ---
    create table(:sfe_enrollment_token, primary_key: false) do
      add(:sfe_token_digest, :text, null: false)
      add(:sfe_app_slug, :text, null: false)
      add(:sfe_display_name, :text, null: false)
      add(:sfe_expires_at, :utc_datetime_usec, null: false)
      add(:sfe_consumed_at, :utc_datetime_usec)
      add(:sfe_consumed_app_id, :uuid)

      add(:sfe_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:sfe_org_id, :uuid)
      add(:sfe_inserted_at, :utc_datetime, null: false)
      add(:sfe_updated_at, :utc_datetime, null: false)
    end

    create(unique_index(:sfe_enrollment_token, [:sfe_token_digest], name: :sfe_token_digest_index))

    # --- sfr_report : one received FleetReport ---
    create table(:sfr_report, primary_key: false) do
      add(:sfr_app_id, :uuid, null: false)
      add(:sfr_schema_version, :integer, null: false, default: 1)
      add(:sfr_generated_at_us, :bigint, null: false)
      add(:sfr_received_at, :utc_datetime_usec, null: false)
      add(:sfr_transport, :text, null: false)
      add(:sfr_payload, :map, null: false, default: %{})

      add(:sfr_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:sfr_org_id, :uuid)
      add(:sfr_inserted_at, :utc_datetime, null: false)
      add(:sfr_updated_at, :utc_datetime, null: false)
    end

    create(index(:sfr_report, [:sfr_app_id, :sfr_received_at]))

    # --- sfd_directive : one published fleet directive ---
    create table(:sfd_directive, primary_key: false) do
      add(:sfd_fleet_revision, :integer, null: false)
      add(:sfd_target, :map, null: false, default: %{})
      add(:sfd_payload, :map, null: false, default: %{})
      add(:sfd_published_by, :text, null: false)
      add(:sfd_published_at, :utc_datetime_usec, null: false)

      add(:sfd_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:sfd_org_id, :uuid)
      add(:sfd_inserted_at, :utc_datetime, null: false)
      add(:sfd_updated_at, :utc_datetime, null: false)
    end

    create(index(:sfd_directive, [:sfd_fleet_revision]))

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)
    drop(table(:sfd_directive))
    drop(table(:sfr_report))
    drop(table(:sfe_enrollment_token))
    drop(table(:sfc_credential))
    drop(table(:sfa_app))
  end
end
