defmodule Demo.Repo.Migrations.MountIdentityCredentialAuthToken do
  @moduledoc """
  ADR-035 §3.1/§4.2 (T02x integration — the demo host's own migration for T02's A1
  self-serve registration identity spine) — adds the identity spine's two new
  org-less resources to the demo host's Identity mount: `Identity.Credential`
  (THE authentication principal) and `Identity.AuthToken` (single-use, expiring,
  hashed-at-rest emailed secrets). Also adds the additive, nullable `usr_credential_id`
  FK column to the already-mounted `usr_user` table (ADR-035 §3.1 — no migration
  break for existing rows).

  Mirrors `samen_web/priv/repo/migrations/20260721010000_mount_identity_credential_auth_token.exs`
  exactly, adapted to demo's abbrevs (`crd`/`atk`, DEFAULT — demo's Identity mount
  passes no `abbrevs:` override, so it uses `Samen.Scopes.Identity.default_abbrevs/0`
  verbatim; the registry already carries these as permanent host rows
  `hosts.demo.crd`/`hosts.demo.atk`, reserved by T02's `mix samen.abbrev.reserve`).

  Catalogued in the SAME transaction for the two new tables (ADR-004 catalog-in-tx);
  the `usr_credential_id` column add mirrors the `add_api_key_expiry_fields`
  precedent (a plain additive column, no catalog_sync needed for a Tier-0-shaped
  add-column on an already-cataloged table).

  No PII here: `email_bidx`/`token_digest`/`sent_to_bidx`/`password_hash`/
  `hash_scheme` are credential-class columns (the `key_token_digest` precedent) —
  non-reversible or hashed, never vault-routed, never allowlisted.
  """
  use Samen.Migration

  @resources [
    Demo.Identity.Credential,
    Demo.Identity.AuthToken
  ]

  def up do
    # --- crd_credential : THE authentication principal (org-less). ---
    create table(:crd_credential, primary_key: false) do
      add(:crd_email_bidx, :text, null: false)
      add(:crd_password_hash, :text)
      add(:crd_hash_scheme, :text)
      add(:crd_verified_at, :utc_datetime)
      add(:crd_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:crd_org_id, :uuid)
      add(:crd_inserted_at, :utc_datetime, null: false)
      add(:crd_updated_at, :utc_datetime, null: false)
    end

    # ADR-035 §4.1 — the global "one account per email" invariant.
    create(unique_index(:crd_credential, [:crd_email_bidx]))

    # --- atk_auth_token : single-use, expiring, hashed-at-rest emailed secrets. ---
    create table(:atk_auth_token, primary_key: false) do
      add(:atk_token_digest, :text, null: false)
      add(:atk_context, :text, null: false)
      add(:atk_sent_to_bidx, :text)
      add(:atk_expires_at, :utc_datetime, null: false)
      add(:atk_consumed_at, :utc_datetime)

      add(
        :atk_credential_id,
        references(:crd_credential,
          column: :crd_id,
          name: "atk_auth_token_atk_credential_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )

      add(:atk_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:atk_org_id, :uuid)
      add(:atk_inserted_at, :utc_datetime, null: false)
      add(:atk_updated_at, :utc_datetime, null: false)
    end

    create(unique_index(:atk_auth_token, [:atk_token_digest]))

    # ADR-035 §3.1 — additive, nullable FK on the already-mounted usr_user table.
    alter table(:usr_user) do
      add(:usr_credential_id, :uuid)
    end

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    alter table(:usr_user) do
      remove(:usr_credential_id)
    end

    drop(constraint(:atk_auth_token, "atk_auth_token_atk_credential_id_fkey"))
    drop(table(:atk_auth_token))
    drop(table(:crd_credential))
  end
end
