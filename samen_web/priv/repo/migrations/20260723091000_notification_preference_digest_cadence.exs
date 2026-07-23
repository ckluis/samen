defmodule Samen.WebTest.Repo.Migrations.NotificationPreferenceDigestCadence do
  @moduledoc """
  C8 (T30): adds `wnp_digest_cadence` / `wnp_digest_timezone` to the
  `wnp_notification_preference` table. Plain additive columns with defaults —
  no `catalog_sync` needed (the `add_org_onboarded_at` precedent).
  """
  use Ecto.Migration

  def up do
    alter table(:wnp_notification_preference) do
      add(:wnp_digest_cadence, :text, null: false, default: "daily")
      add(:wnp_digest_timezone, :text, null: false, default: "Etc/UTC")
      add(:wnp_digest_last_sent_at, :utc_datetime)
    end
  end

  def down do
    alter table(:wnp_notification_preference) do
      remove(:wnp_digest_cadence)
      remove(:wnp_digest_timezone)
      remove(:wnp_digest_last_sent_at)
    end
  end
end
