defmodule Demo.Repo.Migrations.NotificationPreferenceDigestCadence do
  @moduledoc """
  C8 (T30): adds `npr_digest_cadence` / `npr_digest_timezone` to the
  `npr_notification_preference` table (per-user digest cadence pref, c11
  default `:daily`, timezone-aware). Plain additive columns with defaults — no
  `catalog_sync` needed (the `add_org_onboarded_at` / `add_send_provider_message_id`
  precedent: an additive nullable/defaulted column needs no catalog re-sync).
  """
  use Ecto.Migration

  def up do
    alter table(:npr_notification_preference) do
      add(:npr_digest_cadence, :text, null: false, default: "daily")
      add(:npr_digest_timezone, :text, null: false, default: "Etc/UTC")
      add(:npr_digest_last_sent_at, :utc_datetime)
    end
  end

  def down do
    alter table(:npr_notification_preference) do
      remove(:npr_digest_cadence)
      remove(:npr_digest_timezone)
      remove(:npr_digest_last_sent_at)
    end
  end
end
