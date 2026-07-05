defmodule Samen.Repo.Migrations.CreateVault do
  use Ecto.Migration

  def change do
    # The pii_email vault table: per-subject-encrypted ciphertext. This rides
    # PITR/backups freely — it is useless ciphertext without the external DEK.
    create table(:pii_email, primary_key: false) do
      add :token, :string, primary_key: true
      add :subject_id, :string, null: false
      add :ciphertext, :binary, null: false
      add :label, :string, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create index(:pii_email, [:subject_id])

    # Domain rows carry the FK vault token, never plaintext.
    create table(:person, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :subject_id, :string, null: false
      add :display_name, :string
      add :pii_email_token, references(:pii_email, column: :token, type: :string)
      timestamps(type: :utc_datetime_usec)
    end

    create index(:person, [:subject_id])
  end
end
