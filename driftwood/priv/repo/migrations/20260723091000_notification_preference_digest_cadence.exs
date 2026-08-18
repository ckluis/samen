defmodule Driftwood.Repo.Migrations.NotificationPreferenceDigestCadence do
  @moduledoc """
  C8 (T30): adds `fnp_digest_cadence` / `fnp_digest_timezone` to the
  `fnp_notification_preference` table. Plain additive columns with defaults —
  no `catalog_sync` needed (the `add_org_onboarded_at` precedent).
  """
  use Ecto.Migration

  def up do
    alter table(:fnp_notification_preference) do
      add(:fnp_digest_cadence, :text, null: false, default: "daily")
      add(:fnp_digest_timezone, :text, null: false, default: "Etc/UTC")
      add(:fnp_digest_last_sent_at, :utc_datetime)
    end
  end

  def down do
    alter table(:fnp_notification_preference) do
      remove(:fnp_digest_cadence)
      remove(:fnp_digest_timezone)
      remove(:fnp_digest_last_sent_at)
    end
  end
end
