defmodule Samen.WebTest.Repo.Migrations.HardenIdentityInvitation do
  @moduledoc """
  ADR-035 §4.1/§4.2/§5 A5 (T05) — mirrors
  `demo/priv/repo/migrations/20260721070000_harden_identity_invitation.exs`
  exactly, adapted to the samen_web test host's Operator-mount abbrev
  (`won_invitation`). See the demo migration's moduledoc for the full
  rationale.
  """
  use Samen.Migration

  @resources [Samen.WebTest.Operator.Invitation]

  def up do
    execute(
      "DELETE FROM fld_field WHERE fld_table_name = 'won_invitation' AND fld_column_name = 'won_accept_token'",
      "INSERT INTO fld_field (fld_table_name, fld_column_name, fld_logical_name, fld_type) VALUES " <>
        "('won_invitation', 'won_accept_token', 'accept_token', 'string') ON CONFLICT (fld_table_name, fld_column_name) DO NOTHING"
    )

    rename(table(:won_invitation), :won_accept_token, to: :won_token_digest)

    alter table(:won_invitation) do
      add(:won_email_bidx, :text)
      add(:won_expires_at, :utc_datetime)
      add(:won_accepted_at, :utc_datetime)
      add(:won_revoked_at, :utc_datetime)
    end

    create(unique_index(:won_invitation, [:won_token_digest]))

    catalog_sync(@resources, only: [:token_digest, :email_bidx, :expires_at, :accepted_at, :revoked_at])
  end

  def down do
    catalog_sync_down(@resources, only: [:token_digest, :email_bidx, :expires_at, :accepted_at, :revoked_at])

    drop(index(:won_invitation, [:won_token_digest]))

    alter table(:won_invitation) do
      remove(:won_revoked_at)
      remove(:won_accepted_at)
      remove(:won_expires_at)
      remove(:won_email_bidx)
    end

    rename(table(:won_invitation), :won_token_digest, to: :won_accept_token)

    execute(
      "INSERT INTO fld_field (fld_table_name, fld_column_name, fld_logical_name, fld_type) VALUES " <>
        "('won_invitation', 'won_accept_token', 'accept_token', 'string') ON CONFLICT (fld_table_name, fld_column_name) DO NOTHING",
      "DELETE FROM fld_field WHERE fld_table_name = 'won_invitation' AND fld_column_name = 'won_accept_token'"
    )
  end
end
