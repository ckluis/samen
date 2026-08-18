defmodule Driftwood.Repo.Migrations.HardenIdentityInvitation do
  @moduledoc """
  ADR-035 §4.1/§4.2/§5 A5 (T05) — mirrors
  `demo/priv/repo/migrations/20260721070000_harden_identity_invitation.exs`
  exactly, adapted to Driftwood's operator-mount abbrev (`don_invitation`).
  See the demo migration's moduledoc for the full rationale.
  """
  use Samen.Migration

  @resources [Driftwood.Operator.Invitation]

  def up do
    execute(
      "DELETE FROM fld_field WHERE fld_table_name = 'don_invitation' AND fld_column_name = 'don_accept_token'",
      "INSERT INTO fld_field (fld_table_name, fld_column_name, fld_logical_name, fld_type) VALUES " <>
        "('don_invitation', 'don_accept_token', 'accept_token', 'string') ON CONFLICT (fld_table_name, fld_column_name) DO NOTHING"
    )

    rename(table(:don_invitation), :don_accept_token, to: :don_token_digest)

    alter table(:don_invitation) do
      add(:don_email_bidx, :text)
      add(:don_expires_at, :utc_datetime)
      add(:don_accepted_at, :utc_datetime)
      add(:don_revoked_at, :utc_datetime)
    end

    create(unique_index(:don_invitation, [:don_token_digest]))

    catalog_sync(@resources, only: [:token_digest, :email_bidx, :expires_at, :accepted_at, :revoked_at])
  end

  def down do
    catalog_sync_down(@resources, only: [:token_digest, :email_bidx, :expires_at, :accepted_at, :revoked_at])

    drop(index(:don_invitation, [:don_token_digest]))

    alter table(:don_invitation) do
      remove(:don_revoked_at)
      remove(:don_accepted_at)
      remove(:don_expires_at)
      remove(:don_email_bidx)
    end

    rename(table(:don_invitation), :don_token_digest, to: :don_accept_token)

    execute(
      "INSERT INTO fld_field (fld_table_name, fld_column_name, fld_logical_name, fld_type) VALUES " <>
        "('don_invitation', 'don_accept_token', 'accept_token', 'string') ON CONFLICT (fld_table_name, fld_column_name) DO NOTHING",
      "DELETE FROM fld_field WHERE fld_table_name = 'don_invitation' AND fld_column_name = 'don_accept_token'"
    )
  end
end
