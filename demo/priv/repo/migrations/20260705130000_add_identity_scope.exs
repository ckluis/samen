defmodule Demo.Repo.Migrations.AddIdentityScope do
  @moduledoc """
  Mounts the Identity scope tables into the Demo host's one Postgres, and catalogs
  them in the SAME migration transaction (ADR-004 §"Migrations": the catalog-in-tx
  guarantee requires DDL + catalog_sync in one transaction in the host's repo).

  This is the copied `Samen.Migration` template the scope-authoring guide (§7)
  documents. The tables are self-qualifying (every column carries the resource's
  abbrev) and the PII columns (usr_full_name, usr_emails, inv_email) hold vault
  `vt_*` tokens — plaintext never lands here (the vault runtime routes it).

  Catalog rows are written for all six Identity resources so `catalog_parity` sees
  them (the T3.1 red path: an Identity table with NO catalog_sync row is a ghost
  table and fails the verifier).
  """
  use Samen.Migration

  @resources [
    Demo.Identity.Org,
    Demo.Identity.User,
    Demo.Identity.Membership,
    Demo.Identity.Role,
    Demo.Identity.ApiKey,
    Demo.Identity.Invitation
  ]

  def up do
    # --- ido_org : the tenant anchor (org-less by policy; core org_id injected) ---
    create table(:ido_org, primary_key: false) do
      add(:ido_name, :text, null: false)
      add(:ido_slug, :text)
      add(:ido_plan, :text, default: "free")
      add(:ido_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      # The org anchor is org-less: its own org_id is nullable (see blueprint).
      add(:ido_org_id, :uuid)
      add(:ido_inserted_at, :utc_datetime, null: false)
      add(:ido_updated_at, :utc_datetime, null: false)
    end

    # --- usr_user : a user 🔒 (full_name/emails vault-routed) ---
    create table(:usr_user, primary_key: false) do
      add(:usr_handle, :text)
      add(:usr_status, :text, default: "active")
      # Composite PII token columns (vault-routed, stored as vt_* tokens):
      add(:usr_full_name, :text)
      add(:usr_emails, :text)
      add(:usr_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:usr_org_id, :uuid, null: false)
      add(:usr_inserted_at, :utc_datetime, null: false)
      add(:usr_updated_at, :utc_datetime, null: false)
    end

    # --- mbs_membership : (user, org, role) ---
    create table(:mbs_membership, primary_key: false) do
      add(:mbs_role, :text, default: "member")
      add(:mbs_status, :text, default: "active")

      add(
        :mbs_user_id,
        references(:usr_user,
          column: :usr_id,
          name: "mbs_membership_mbs_user_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:mbs_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:mbs_org_id, :uuid, null: false)
      add(:mbs_inserted_at, :utc_datetime, null: false)
      add(:mbs_updated_at, :utc_datetime, null: false)
    end

    # --- iro_role : Tier-0 config rows (per-org role catalog) ---
    create table(:iro_role, primary_key: false) do
      add(:iro_name, :text, null: false)
      add(:iro_label, :text)
      add(:iro_rank, :integer, null: false)
      add(:iro_enabled, :boolean, default: true)
      add(:iro_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:iro_org_id, :uuid, null: false)
      add(:iro_inserted_at, :utc_datetime, null: false)
      add(:iro_updated_at, :utc_datetime, null: false)
    end

    # --- key_api_key : scoped credential (two planes) ---
    create table(:key_api_key, primary_key: false) do
      add(:key_token_digest, :text, null: false)
      add(:key_plane, :text, null: false, default: "tenant")
      add(:key_scopes, :map, default: fragment("'{}'::jsonb"))
      add(:key_minter_role, :text)
      add(:key_revoked_at, :utc_datetime)

      add(
        :key_membership_id,
        references(:mbs_membership,
          column: :mbs_id,
          name: "key_api_key_key_membership_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:key_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:key_org_id, :uuid, null: false)
      add(:key_inserted_at, :utc_datetime, null: false)
      add(:key_updated_at, :utc_datetime, null: false)
    end

    # --- inv_invitation : a pending invite 🔒 (email vault-routed) ---
    create table(:inv_invitation, primary_key: false) do
      add(:inv_role, :text, default: "member")
      add(:inv_status, :text, default: "pending")
      add(:inv_accept_token, :text)
      # Composite PII token column (vault-routed):
      add(:inv_email, :text)
      add(:inv_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:inv_org_id, :uuid, null: false)
      add(:inv_inserted_at, :utc_datetime, null: false)
      add(:inv_updated_at, :utc_datetime, null: false)
    end

    # --- catalog the six Identity resources in THIS transaction ---
    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(constraint(:key_api_key, "key_api_key_key_membership_id_fkey"))
    drop(table(:key_api_key))
    drop(table(:inv_invitation))
    drop(table(:iro_role))
    drop(constraint(:mbs_membership, "mbs_membership_mbs_user_id_fkey"))
    drop(table(:mbs_membership))
    drop(table(:usr_user))
    drop(table(:ido_org))
  end
end
