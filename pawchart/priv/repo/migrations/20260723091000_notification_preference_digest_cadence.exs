defmodule PawChart.Repo.Migrations.NotificationPreferenceDigestCadence do
  @moduledoc """
  C8 (T30): adds `vnp_digest_cadence` / `vnp_digest_timezone` to the
  `vnp_notification_preference` table. Plain additive columns with defaults —
  no `catalog_sync` needed (the `add_org_onboarded_at` precedent).
  """
  use Ecto.Migration

  def up do
    alter table(:vnp_notification_preference) do
      add(:vnp_digest_cadence, :text, null: false, default: "daily")
      add(:vnp_digest_timezone, :text, null: false, default: "Etc/UTC")
      add(:vnp_digest_last_sent_at, :utc_datetime)
    end
  end

  def down do
    alter table(:vnp_notification_preference) do
      remove(:vnp_digest_cadence)
      remove(:vnp_digest_timezone)
      remove(:vnp_digest_last_sent_at)
    end
  end
end
