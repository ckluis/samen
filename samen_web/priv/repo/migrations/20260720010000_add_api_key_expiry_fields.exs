defmodule Samen.WebTest.Repo.Migrations.AddApiKeyExpiryFields do
  @moduledoc """
  F3.4 — bounded API-key expiry + last-use observability on samen_web's operator
  Identity mount (`wok_api_key`). See the demo migration of the same name; columns
  are plain bounded timestamps (no PII), mirroring the add-column precedent.
  """
  use Ecto.Migration

  def up do
    alter table(:wok_api_key) do
      add(:wok_expires_at, :utc_datetime)
      add(:wok_last_used_at, :utc_datetime)
    end
  end

  def down do
    alter table(:wok_api_key) do
      remove(:wok_expires_at)
      remove(:wok_last_used_at)
    end
  end
end
