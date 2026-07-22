defmodule Driftwood.Repo.Migrations.MountIdentityCredentialAuthToken do
  @moduledoc """
  ADR-035 §3.1/§4.2 (T02x integration — driftwood's own migration for T02's A1
  self-serve registration identity spine) — adds the identity spine's two new
  org-less resources to driftwood's OPERATOR Identity mount (ADR-010 §8.1;
  driftwood's only Identity mount): `Identity.Credential` (THE authentication
  principal) and `Identity.AuthToken` (single-use, expiring, hashed-at-rest
  emailed secrets). Also adds the additive, nullable `dou_credential_id` FK
  column to the already-mounted `dou_user` table (ADR-035 §3.1 — no migration
  break for existing rows).

  Mirrors `samen_web/priv/repo/migrations/20260721010000_mount_identity_credential_auth_token.exs`
  exactly, adapted to driftwood operator's `do*` abbrevs (`doc`/`dot` — already
  reserved append-only in the registry as `hosts.driftwood.doc`/`hosts.driftwood.dot`
  by T02's `mix samen.abbrev.reserve`, and `driftwood/lib/driftwood/operator.ex`
  already carries the corresponding `abbrevs:` overrides so the mount compiles).

  Catalogued in the SAME transaction for the two new tables (ADR-004 catalog-in-tx);
  the `dou_credential_id` column add mirrors the `add_api_key_expiry_fields`
  precedent (a plain additive column, no catalog_sync needed for a Tier-0-shaped
  add-column on an already-cataloged table).

  No PII here: `email_bidx`/`token_digest`/`sent_to_bidx`/`password_hash`/
  `hash_scheme` are credential-class columns (the `dok_token_digest` precedent) —
  non-reversible or hashed, never vault-routed, never allowlisted.
  """
  use Samen.Migration

  @resources [
    Driftwood.Operator.Credential,
    Driftwood.Operator.AuthToken
  ]

  def up do
    # --- doc_credential : THE authentication principal (org-less). ---
    create table(:doc_credential, primary_key: false) do
      add(:doc_email_bidx, :text, null: false)
      add(:doc_password_hash, :text)
      add(:doc_hash_scheme, :text)
      add(:doc_verified_at, :utc_datetime)
      add(:doc_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:doc_org_id, :uuid)
      add(:doc_inserted_at, :utc_datetime, null: false)
      add(:doc_updated_at, :utc_datetime, null: false)
    end

    # ADR-035 §4.1 — the global "one account per email" invariant.
    create(unique_index(:doc_credential, [:doc_email_bidx]))

    # --- dot_auth_token : single-use, expiring, hashed-at-rest emailed secrets. ---
    create table(:dot_auth_token, primary_key: false) do
      add(:dot_token_digest, :text, null: false)
      add(:dot_context, :text, null: false)
      add(:dot_sent_to_bidx, :text)
      add(:dot_expires_at, :utc_datetime, null: false)
      add(:dot_consumed_at, :utc_datetime)

      add(
        :dot_credential_id,
        references(:doc_credential,
          column: :doc_id,
          name: "dot_auth_token_dot_credential_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )

      add(:dot_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:dot_org_id, :uuid)
      add(:dot_inserted_at, :utc_datetime, null: false)
      add(:dot_updated_at, :utc_datetime, null: false)
    end

    create(unique_index(:dot_auth_token, [:dot_token_digest]))

    # ADR-035 §3.1 — additive, nullable FK on the already-mounted dou_user table.
    alter table(:dou_user) do
      add(:dou_credential_id, :uuid)
    end

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    alter table(:dou_user) do
      remove(:dou_credential_id)
    end

    drop(constraint(:dot_auth_token, "dot_auth_token_dot_credential_id_fkey"))
    drop(table(:dot_auth_token))
    drop(table(:doc_credential))
  end
end
