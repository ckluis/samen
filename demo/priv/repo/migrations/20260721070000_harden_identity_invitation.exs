defmodule Demo.Repo.Migrations.HardenIdentityInvitation do
  @moduledoc """
  ADR-035 §4.1/§4.2/§5 A5 (T05) — hardens the demo host's Identity mount
  `inv_invitation` table to the ADR's token/lookup discipline:

    * `inv_accept_token` (plaintext-shaped) RENAMED to `inv_token_digest`
      (SHA-256 digest at rest — the `ApiKey token_digest` precedent).
    * `inv_email_bidx` ADDED — the non-reversible keyed-HMAC lookup index
      (§4.1) so accept-time credential matching never needs a vault reveal.
    * `inv_expires_at`/`inv_accepted_at`/`inv_revoked_at` ADDED — the 14-day
      invite-context row + the 4-state lifecycle's terminal timestamps.

  `inv_invitation` was cataloged in the ORIGINAL `add_identity_scope`
  migration (T3.1), so this is a schema change to an ALREADY-cataloged
  table, not a new resource — `catalog_sync(..., only: [...])` re-syncs
  exactly the touched logical field names (the `add_api_key_expiry_fields`
  new-columns precedent), and the stale `accept_token` `fld_field` row (whose
  physical column no longer exists post-rename) is explicitly deleted so
  `catalog_parity`'s "orphan catalog row" check stays clean in both
  directions (storage ⇄ catalog).
  """
  use Samen.Migration

  @resources [Demo.Identity.Invitation]

  def up do
    # The stale catalog row for the renamed column — deleted explicitly (its
    # physical column is gone after the rename below); reinstated on down/0.
    execute(
      "DELETE FROM fld_field WHERE fld_table_name = 'inv_invitation' AND fld_column_name = 'inv_accept_token'",
      "INSERT INTO fld_field (fld_table_name, fld_column_name, fld_logical_name, fld_type) VALUES " <>
        "('inv_invitation', 'inv_accept_token', 'accept_token', 'string') ON CONFLICT (fld_table_name, fld_column_name) DO NOTHING"
    )

    rename(table(:inv_invitation), :inv_accept_token, to: :inv_token_digest)

    alter table(:inv_invitation) do
      add(:inv_email_bidx, :text)
      add(:inv_expires_at, :utc_datetime)
      add(:inv_accepted_at, :utc_datetime)
      add(:inv_revoked_at, :utc_datetime)
    end

    create(unique_index(:inv_invitation, [:inv_token_digest]))

    catalog_sync(@resources, only: [:token_digest, :email_bidx, :expires_at, :accepted_at, :revoked_at])
  end

  def down do
    catalog_sync_down(@resources, only: [:token_digest, :email_bidx, :expires_at, :accepted_at, :revoked_at])

    drop(index(:inv_invitation, [:inv_token_digest]))

    alter table(:inv_invitation) do
      remove(:inv_revoked_at)
      remove(:inv_accepted_at)
      remove(:inv_expires_at)
      remove(:inv_email_bidx)
    end

    rename(table(:inv_invitation), :inv_token_digest, to: :inv_accept_token)

    execute(
      "INSERT INTO fld_field (fld_table_name, fld_column_name, fld_logical_name, fld_type) VALUES " <>
        "('inv_invitation', 'inv_accept_token', 'accept_token', 'string') ON CONFLICT (fld_table_name, fld_column_name) DO NOTHING",
      "DELETE FROM fld_field WHERE fld_table_name = 'inv_invitation' AND fld_column_name = 'inv_accept_token'"
    )
  end
end
