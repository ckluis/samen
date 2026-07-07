defmodule Driftwood.Repo.Migrations.Erasure do
  @moduledoc "T1.7 crypto-shred: non_pii! registry + erasure report table."
  use Ecto.Migration

  def up do
    create table(:npi_non_pii, primary_key: false) do
      add(:npi_id, :uuid, primary_key: true, null: false, default: fragment("gen_random_uuid()"))
      add(:npi_table_name, :text, null: false)
      add(:npi_column_name, :text, null: false)
      add(:npi_cleared_by, :text, null: false)
      add(:npi_reviewed_by, :text, null: false)
      add(:npi_reason, :text, null: false)
      add(:npi_subject_column, :text, null: false)
      add(:npi_redaction, :text, null: false, default: "[REDACTED]")
      add(:npi_registered_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create(
      unique_index(:npi_non_pii, [:npi_table_name, :npi_column_name],
        name: "npi_non_pii_table_column_index"
      )
    )

    create table(:era_erasure_report, primary_key: false) do
      add(:era_id, :uuid, primary_key: true, null: false, default: fragment("gen_random_uuid()"))
      add(:era_subject_id, :string, null: false)
      add(:era_attestation_id, :text)
      add(:era_outcome, :text, null: false)
      add(:era_tiers, :map, null: false)
      add(:era_vault_rows_sealed, :integer, null: false, default: 0)
      add(:era_non_pii_rows_redacted, :integer, null: false, default: 0)
      add(:era_recorded_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create(index(:era_erasure_report, [:era_subject_id]))
  end

  def down do
    drop(index(:era_erasure_report, [:era_subject_id]))
    drop(table(:era_erasure_report))
    drop(constraint(:npi_non_pii, "npi_non_pii_table_column_index"))
    drop(table(:npi_non_pii))
  end
end
