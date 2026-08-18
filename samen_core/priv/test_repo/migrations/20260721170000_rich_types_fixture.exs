defmodule SamenCore.TestRepo.Migrations.RichTypesFixture do
  @moduledoc """
  T13 test fixture tables (ADR-036 H2/H3 rich scalar types):

    * `srp_personal_fixture` — the PERSONAL-use fixture: `EmailAddress`/
      `PhoneNumber`/`URL` declared as vaulted `pii_attribute`s, so their
      physical columns are `Samen.Type.VaultField`-typed `pii_`-prefixed
      `:text` columns holding an opaque `vt_*` token (never plaintext).
    * `sro_org_fixture` — the ORG-level / catalog-dump / Priority-ordering
      fixture: plain (non-vaulted) columns of every new H2/H3 type.
  """
  use Samen.Migration

  @resources [
    SamenCore.Support.RichTypes.PersonalFixture,
    SamenCore.Support.RichTypes.OrgFixture
  ]

  def up do
    create table(:srp_personal_fixture, primary_key: false) do
      add(:srp_label, :text)
      add(:pii_srp_email, :text)
      add(:pii_srp_phone, :text)
      add(:pii_srp_profile_url, :text)
      add(:srp_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:srp_org_id, :uuid, null: false)
      add(:srp_inserted_at, :utc_datetime, null: false)
      add(:srp_updated_at, :utc_datetime, null: false)
    end

    create table(:sro_org_fixture, primary_key: false) do
      add(:sro_name, :text)
      add(:sro_percent, :decimal)
      add(:sro_score, :decimal)
      add(:sro_duration, :integer)
      add(:sro_priority, :integer)
      add(:sro_website, :text)
      add(:sro_support_email, :text)
      add(:sro_support_phone, :text)
      add(:sro_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:sro_org_id, :uuid, null: false)
      add(:sro_inserted_at, :utc_datetime, null: false)
      add(:sro_updated_at, :utc_datetime, null: false)
    end

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)
    drop(table(:sro_org_fixture))
    drop(table(:srp_personal_fixture))
  end
end
