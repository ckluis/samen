defmodule Samen.WebTest.Repo.Migrations.MountIdentityCredentialAuthToken do
  @moduledoc """
  ADR-035 §3.1/§4.2 (T02, A1 self-serve registration) — adds the identity spine's
  two new org-less resources to the samen_web test host's Operator Identity mount:
  `Identity.Credential` (THE authentication principal) and `Identity.AuthToken`
  (single-use, expiring, hashed-at-rest emailed secrets). Also adds the additive,
  nullable `wou_credential_id` FK column to the already-mounted `wou_user` table
  (ADR-035 §3.1 — no migration break for existing rows).

  Fresh `woc`/`wot` abbrevs (append-only registry rows, `mix samen.abbrev.reserve`).
  Catalogued in the SAME transaction for the two new tables (ADR-004 catalog-in-tx);
  the `wou_credential_id` column add mirrors the `add_api_key_expiry_fields`
  precedent (a plain additive column, no catalog_sync needed for a Tier-0-shaped
  add-column on an already-cataloged table).

  No PII here: `email_bidx`/`token_digest`/`sent_to_bidx`/`password_hash`/
  `hash_scheme` are credential-class columns (the `wok_token_digest` precedent) —
  non-reversible or hashed, never vault-routed, never allowlisted.
  """
  use Samen.Migration

  @resources [
    Samen.WebTest.Operator.Credential,
    Samen.WebTest.Operator.AuthToken
  ]

  def up do
    # --- woc_credential : THE authentication principal (org-less). ---
    create table(:woc_credential, primary_key: false) do
      add(:woc_email_bidx, :text, null: false)
      add(:woc_password_hash, :text)
      add(:woc_hash_scheme, :text)
      add(:woc_verified_at, :utc_datetime)
      add(:woc_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:woc_org_id, :uuid)
      add(:woc_inserted_at, :utc_datetime, null: false)
      add(:woc_updated_at, :utc_datetime, null: false)
    end

    # ADR-035 §4.1 — the global "one account per email" invariant.
    create(unique_index(:woc_credential, [:woc_email_bidx]))

    # --- wot_auth_token : single-use, expiring, hashed-at-rest emailed secrets. ---
    create table(:wot_auth_token, primary_key: false) do
      add(:wot_token_digest, :text, null: false)
      add(:wot_context, :text, null: false)
      add(:wot_sent_to_bidx, :text)
      add(:wot_expires_at, :utc_datetime, null: false)
      add(:wot_consumed_at, :utc_datetime)

      add(
        :wot_credential_id,
        references(:woc_credential,
          column: :woc_id,
          name: "wot_auth_token_wot_credential_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )

      add(:wot_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wot_org_id, :uuid)
      add(:wot_inserted_at, :utc_datetime, null: false)
      add(:wot_updated_at, :utc_datetime, null: false)
    end

    create(unique_index(:wot_auth_token, [:wot_token_digest]))

    # ADR-035 §3.1 — additive, nullable FK on the already-mounted wou_user table.
    alter table(:wou_user) do
      add(:wou_credential_id, :uuid)
    end

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    alter table(:wou_user) do
      remove(:wou_credential_id)
    end

    drop(constraint(:wot_auth_token, "wot_auth_token_wot_credential_id_fkey"))
    drop(table(:wot_auth_token))
    drop(table(:woc_credential))
  end
end
