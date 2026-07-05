defmodule Demo.Repo.Migrations.CrmResources do
  @moduledoc """
  Creates the Demo CRM resource tables and bootstraps the catalog in the same
  migration transaction (S0.4 mechanism: BEGIN; CREATE TABLE ...; INSERT INTO
  fld_field ...; COMMIT — atomic, fail-closed).

  Also adds `cnt_notes` as a raw DDL column on cnt_contact — the non_pii!
  reviewed plaintext column (T1.9 acceptance: one non_pii! reviewed column).
  This column is NOT an Ash attribute (it is managed by the erasure arm directly),
  so it is in the catalog_parity allow-list.
  """
  use Samen.Migration

  @resources [Demo.Crm.Org, Demo.Crm.Membership, Demo.Crm.Contact]

  def up do
    # --- org_org -----------------------------------------------------------
    create table(:org_org, primary_key: false) do
      add(:org_name, :text, null: false)
      add(:org_slug, :text)
      add(:org_plan, :text, default: "free")
      add(:org_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:org_org_id, :uuid, null: false)
      add(:org_inserted_at, :utc_datetime, null: false)
      add(:org_updated_at, :utc_datetime, null: false)
    end

    # --- cnt_contact -------------------------------------------------------
    # Must be created before mbr_membership (which has an FK to cnt_contact).
    create table(:cnt_contact, primary_key: false) do
      add(:cnt_display_name, :text, null: false)
      add(:cnt_active, :boolean, default: true)
      # Composite PII token columns (vault-routed, stored as vt_* tokens):
      add(:cnt_full_name, :text)
      add(:cnt_emails, :text)
      # Scalar pii_ column: dob → pii_cnt_dob (abbrev-prefixed scalar rule)
      add(:pii_cnt_dob, :text)
      add(:cnt_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:cnt_org_id, :uuid, null: false)
      add(:cnt_inserted_at, :utc_datetime, null: false)
      add(:cnt_updated_at, :utc_datetime, null: false)
    end

    # The non_pii! reviewed plaintext column. NOT an Ash attribute. In the
    # catalog_parity allow-list. Registered as non_pii! at test-setup time.
    # cnt_subject_id: a :text shadow of the primary key for use by the non_pii!
    # erasure arm (which passes subject IDs as strings). The cnt_id is :uuid;
    # raw SQL params via Postgrex need a 16-byte binary for :uuid columns but a
    # string for :text columns. We use cnt_subject_id (text, mirrors cnt_id) as
    # the erasure subject column for the non_pii! registration.
    alter table(:cnt_contact) do
      add(:cnt_notes, :text)
      add(:cnt_subject_id, :text)
    end

    # --- mbr_membership ----------------------------------------------------
    create table(:mbr_membership, primary_key: false) do
      add(:mbr_role, :text, default: "member")
      add(:mbr_status, :text, default: "active")

      add(
        :mbr_contact_id,
        references(:cnt_contact,
          column: :cnt_id,
          name: "mbr_membership_mbr_contact_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:mbr_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:mbr_org_id, :uuid, null: false)
      add(:mbr_inserted_at, :utc_datetime, null: false)
      add(:mbr_updated_at, :utc_datetime, null: false)
    end

    # --- catalog bootstrap (in the same tx) --------------------------------
    create_catalog_tables()
    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)
    drop(table(:fld_field))
    drop(table(:tam_table))

    drop(constraint(:mbr_membership, "mbr_membership_mbr_contact_id_fkey"))
    drop(table(:mbr_membership))
    drop(table(:cnt_contact))
    drop(table(:org_org))
  end
end
