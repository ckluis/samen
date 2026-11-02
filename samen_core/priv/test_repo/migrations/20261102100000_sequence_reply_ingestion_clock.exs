defmodule SamenCore.TestRepo.Migrations.SequenceReplyIngestionClock do
  @moduledoc """
  Issue #116: sequence reply detection compares our clock with our clock.

    * `smm_mail_message.smm_ingested_at` — when the row was written, on the server's clock,
      to the microsecond (`create_timestamp`). Existing rows take their `smm_inserted_at`:
      the same instant, to the second. Never `now()`: that would make every old reply
      "ingested after" any current cutoff and pause enrollments on it.
    * `soe_enrollment.soe_enrolled_at` / `soe_reply_cutoff_at` — widened to microseconds, so a
      resume in the same second as the reply it follows does not re-pause on that reply.

  The catalog follows the columns in the same transaction.
  """
  use Samen.Migration

  def change do
    alter table(:smm_mail_message) do
      add(:smm_ingested_at, :utc_datetime_usec)
    end

    execute("UPDATE smm_mail_message SET smm_ingested_at = smm_inserted_at", "SELECT 1")

    alter table(:smm_mail_message) do
      modify(:smm_ingested_at, :utc_datetime_usec, null: false, from: {:utc_datetime_usec, null: true})
    end

    catalog_sync([SamenCore.Support.MailboxFixture.MailMessage], only: [:ingested_at])

    alter table(:soe_enrollment) do
      modify(:soe_enrolled_at, :utc_datetime_usec, from: :utc_datetime)
      modify(:soe_reply_cutoff_at, :utc_datetime_usec, from: :utc_datetime)
    end

    execute(
      """
      UPDATE fld_field SET fld_type = 'UtcDatetimeUsec'
      WHERE fld_table_name = 'soe_enrollment' AND fld_column_name IN ('soe_enrolled_at', 'soe_reply_cutoff_at')
      """,
      """
      UPDATE fld_field SET fld_type = 'UtcDatetime'
      WHERE fld_table_name = 'soe_enrollment' AND fld_column_name IN ('soe_enrolled_at', 'soe_reply_cutoff_at')
      """
    )
  end
end
