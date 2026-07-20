defmodule Driftwood.Repo.Migrations.AddApiKeyExpiryFields do
  @moduledoc """
  F3.4 — bounded API-key expiry + last-use observability on Driftwood's operator
  Identity mount (`dok_api_key`). See the demo migration of the same name; columns
  are plain bounded timestamps (no PII), mirroring the add-column precedent.
  """
  use Ecto.Migration

  def up do
    alter table(:dok_api_key) do
      add(:dok_expires_at, :utc_datetime)
      add(:dok_last_used_at, :utc_datetime)
    end
  end

  def down do
    alter table(:dok_api_key) do
      remove(:dok_expires_at)
      remove(:dok_last_used_at)
    end
  end
end
