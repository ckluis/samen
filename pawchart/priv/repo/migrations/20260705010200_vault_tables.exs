defmodule PawChart.Repo.Migrations.VaultTables do
  @moduledoc "Creates the pii_vault table for the demo app."
  use Ecto.Migration

  def up do
    create table(:pii_vault, primary_key: false) do
      add(:token, :string, null: false, primary_key: true)
      add(:subject_id, :string, null: false)
      add(:vault_name, :string, null: false)
      add(:field_name, :string, null: false)
      add(:ciphertext, :binary, null: false)
      add(:label, :string)
      add(:state, :string, null: false, default: "active")
      add(:erased_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:pii_vault, [:subject_id]))
    create(index(:pii_vault, [:subject_id, :vault_name]))
    create(index(:pii_vault, [:subject_id, :state]))
  end

  def down do
    drop(table(:pii_vault))
  end
end
