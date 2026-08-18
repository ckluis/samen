defmodule SamenCore.TestRepo.Migrations.MailboxFixture do
  @moduledoc """
  T75 (spec §I2) — a SECOND materialization of the existing T74 Mailbox scope
  blueprint (`Samen.Scopes.Mailbox`) inside `samen_core`'s own test suite
  (`test/support/mailbox_fixture.ex`), so `sequence_send_test.exs` can prove
  `Samen.Sequences.MailboxReplyCheck` reads REAL `MailMessage` rows — no new
  inbound path. Mirrors `samen_web`'s `20260806010000_mount_mailbox_scope.exs`
  with this host's own `scm`/`smm` abbrevs.

  🔒 columns: `pii_scm_address`, `pii_smm_subject`, `pii_smm_body`,
  `pii_smm_counterparty_address` — every one a scalar vault TOKEN column, never
  plaintext (INV-1, unchanged from T74).
  """
  use Samen.Migration

  @resources [
    SamenCore.Support.MailboxFixture.Connection,
    SamenCore.Support.MailboxFixture.MailMessage
  ]

  def up do
    # --- scm_connection : one user's connected mailbox 🔒 (address vault token) ---
    create table(:scm_connection, primary_key: false) do
      add(:scm_user_id, :uuid, null: false)
      add(:scm_provider, :text, null: false)
      add(:scm_external_account_id, :text)
      add(:scm_cursor, :text)
      add(:scm_status, :text, null: false, default: "disconnected")
      add(:scm_connected_at, :utc_datetime)
      add(:scm_last_synced_at, :utc_datetime)
      add(:scm_last_error, :text)
      add(:pii_scm_address, :text)

      add(:scm_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:scm_org_id, :uuid, null: false)
      add(:scm_inserted_at, :utc_datetime, null: false)
      add(:scm_updated_at, :utc_datetime, null: false)
    end

    create(index(:scm_connection, [:scm_org_id]))
    create(index(:scm_connection, [:scm_org_id, :scm_user_id]))

    # --- smm_mail_message : one synced/sent email 🔒 (subject/body/address tokens) ---
    create table(:smm_mail_message, primary_key: false) do
      add(:smm_direction, :text, null: false, default: "inbound")
      add(:smm_external_id, :text)
      add(:smm_thread_key, :text)
      add(:smm_occurred_at, :utc_datetime)
      add(:smm_subject_key, :text)
      add(:smm_subject_id, :uuid)
      add(:smm_company_id, :uuid)
      add(:pii_smm_subject, :text)
      add(:pii_smm_body, :text)
      add(:pii_smm_counterparty_address, :text)

      add(
        :smm_connection_id,
        references(:scm_connection,
          column: :scm_id,
          name: "smm_mail_message_smm_connection_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:smm_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:smm_org_id, :uuid, null: false)
      add(:smm_inserted_at, :utc_datetime, null: false)
      add(:smm_updated_at, :utc_datetime, null: false)
    end

    create(index(:smm_mail_message, [:smm_org_id]))
    create(index(:smm_mail_message, [:smm_org_id, :smm_subject_key, :smm_subject_id]))
    create(index(:smm_mail_message, [:smm_org_id, :smm_company_id]))

    create(
      unique_index(:smm_mail_message, [:smm_org_id, :smm_external_id],
        name: :smm_mail_message_org_external_id_index
      )
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)
    drop(table(:smm_mail_message))
    drop(table(:scm_connection))
  end
end
