defmodule Samen.WebTest.Repo.Migrations.MountMailboxScope do
  @moduledoc """
  Mounts the Mailbox universal scope (spec §I1 CRM two-way email sync, T74) into the
  samen_web test host's Postgres, and catalogs both resources in the SAME migration
  transaction (ADR-004 catalog-in-tx). Mirrors `20260803140000_mount_views_scope.exs`
  with the samen_web test host's own `mwc`/`wmm` abbrevs.

  🔒 columns: `pii_mwc_address`, `pii_wmm_subject`, `pii_wmm_body`,
  `pii_wmm_counterparty_address` — every one a scalar vault TOKEN column (`pii_`
  prefix), never plaintext. There is deliberately NO plaintext address/subject/body
  column on this scope (INV-1).
  """
  use Samen.Migration

  @resources [
    Samen.WebTest.Mailbox.Connection,
    Samen.WebTest.Mailbox.MailMessage
  ]

  def up do
    # --- mwc_connection : one user's connected mailbox 🔒 (address vault token) ---
    create table(:mwc_connection, primary_key: false) do
      add(:mwc_user_id, :uuid, null: false)
      add(:mwc_provider, :text, null: false)
      add(:mwc_external_account_id, :text)
      add(:mwc_cursor, :text)
      add(:mwc_status, :text, null: false, default: "disconnected")
      add(:mwc_connected_at, :utc_datetime)
      add(:mwc_last_synced_at, :utc_datetime)
      add(:mwc_last_error, :text)
      # Scalar PII vault token: the mailbox owner's address (pii_ prefix).
      add(:pii_mwc_address, :text)

      add(:mwc_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:mwc_org_id, :uuid, null: false)
      add(:mwc_inserted_at, :utc_datetime, null: false)
      add(:mwc_updated_at, :utc_datetime, null: false)
    end

    create(index(:mwc_connection, [:mwc_org_id]))
    create(index(:mwc_connection, [:mwc_org_id, :mwc_user_id]))

    # --- wmm_mail_message : one synced/sent email 🔒 (subject/body/address tokens) ---
    create table(:wmm_mail_message, primary_key: false) do
      add(:wmm_direction, :text, null: false, default: "inbound")
      add(:wmm_external_id, :text)
      add(:wmm_thread_key, :text)
      add(:wmm_occurred_at, :utc_datetime)
      add(:wmm_subject_key, :text)
      add(:wmm_subject_id, :uuid)
      add(:wmm_company_id, :uuid)
      # Scalar PII vault tokens (pii_ prefix) — free-text + address.
      add(:pii_wmm_subject, :text)
      add(:pii_wmm_body, :text)
      add(:pii_wmm_counterparty_address, :text)

      add(
        :wmm_connection_id,
        references(:mwc_connection,
          column: :mwc_id,
          name: "wmm_mail_message_wmm_connection_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:wmm_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wmm_org_id, :uuid, null: false)
      add(:wmm_inserted_at, :utc_datetime, null: false)
      add(:wmm_updated_at, :utc_datetime, null: false)
    end

    create(index(:wmm_mail_message, [:wmm_org_id]))
    create(index(:wmm_mail_message, [:wmm_org_id, :wmm_subject_key, :wmm_subject_id]))
    create(index(:wmm_mail_message, [:wmm_org_id, :wmm_company_id]))

    # The provider's own message id is the sync idempotency key, per org.
    create(
      unique_index(:wmm_mail_message, [:wmm_org_id, :wmm_external_id],
        name: :wmm_mail_message_org_external_id_index
      )
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)
    drop(table(:wmm_mail_message))
    drop(table(:mwc_connection))
  end
end
