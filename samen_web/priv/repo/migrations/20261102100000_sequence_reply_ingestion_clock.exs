defmodule Samen.WebTest.Repo.Migrations.SequenceReplyIngestionClock do
  @moduledoc """
  Issue #116: sequence reply detection compares our clock with our clock.

    * `wmm_mail_message.wmm_ingested_at` — when the row was written, on the server's clock,
      to the microsecond (`create_timestamp`). Existing rows take their `wmm_inserted_at`:
      the same instant, to the second. Never `now()`: that would make every old reply
      "ingested after" any current cutoff and pause enrollments on it.
    * `woe_enrollment.woe_enrolled_at` / `woe_reply_cutoff_at` — widened to microseconds, so a
      resume in the same second as the reply it follows does not re-pause on that reply.

  The catalog follows the columns in the same transaction.
  """
  use Samen.Migration

  def change do
    alter table(:wmm_mail_message) do
      add(:wmm_ingested_at, :utc_datetime_usec)
    end

    execute("UPDATE wmm_mail_message SET wmm_ingested_at = wmm_inserted_at", "SELECT 1")

    alter table(:wmm_mail_message) do
      modify(:wmm_ingested_at, :utc_datetime_usec, null: false, from: {:utc_datetime_usec, null: true})
    end

    catalog_sync([Samen.WebTest.Mailbox.MailMessage], only: [:ingested_at])

    alter table(:woe_enrollment) do
      modify(:woe_enrolled_at, :utc_datetime_usec, from: :utc_datetime)
      modify(:woe_reply_cutoff_at, :utc_datetime_usec, from: :utc_datetime)
    end

    execute(
      """
      UPDATE fld_field SET fld_type = 'UtcDatetimeUsec'
      WHERE fld_table_name = 'woe_enrollment' AND fld_column_name IN ('woe_enrolled_at', 'woe_reply_cutoff_at')
      """,
      """
      UPDATE fld_field SET fld_type = 'UtcDatetime'
      WHERE fld_table_name = 'woe_enrollment' AND fld_column_name IN ('woe_enrolled_at', 'woe_reply_cutoff_at')
      """
    )
  end
end
