defmodule SamenCore.TestRepo.Migrations.Erasure do
  @moduledoc """
  T1.7 crypto-shred orchestration storage (doc D7/D8; §data; §limits carve-out).

  Three concerns:

    1. **SHREDDED sentinel on vault rows.** After a subject's key is destroyed,
       the ciphertext rows are *undecryptable* but still physically present. We
       add a `state` + `erased_at` column to `pii_vault` so the erasure path can
       stamp `state = 'shredded'` (the SHREDDED sentinel). The token FK the domain
       row carries now points at a *dangling / sentinel* vault row — exactly the
       doc's "crypto-shreddable down to a dangling token." The oracle (T2.9) reads
       this sentinel as one tier signal alongside the KMS attestation.

    2. **`npi_non_pii` registry (D8).** Review-gated `non_pii!` exceptions:
       columns that are plaintext-at-rest by design (a 2nd reviewer signed off).
       Because key-shred does NOT reach plaintext columns, erasure must redact
       these rows by row-level deletion/redaction and RECORD that it ran. The
       registry row carries the who/why review metadata AND the redaction recipe
       (table, column, redaction sentinel) the erasure arm executes.

    3. **`era_erasure_report` artifact (D7 report).** One row per `shred(subject)`
       call — the attestation id, which tiers were touched, and the redaction
       tally — the artifact the T2.9 oracle consumes.
  """
  use Ecto.Migration

  def up do
    # --- (1) SHREDDED sentinel columns on the vault table ------------------
    alter table(:pii_vault) do
      # 'active' | 'shredded'. The SHREDDED sentinel (doc D7). Default 'active';
      # erasure stamps 'shredded'. A dangling token points at a 'shredded' row.
      add(:state, :string, null: false, default: "active")
      add(:erased_at, :utc_datetime_usec)
    end

    create(index(:pii_vault, [:subject_id, :state]))

    # --- (2) non_pii! registry (D8) ---------------------------------------
    create table(:npi_non_pii, primary_key: false) do
      add(:npi_id, :uuid, primary_key: true, null: false, default: fragment("gen_random_uuid()"))
      # The physical table + column this override applies to (self-qualifying,
      # storage names — abbrev-prefixed).
      add(:npi_table_name, :text, null: false)
      add(:npi_column_name, :text, null: false)
      # Review metadata — the 2nd-reviewer sign-off (T1.8c enforces the GATE; the
      # registry just records it). who cleared it, who reviewed it, why.
      add(:npi_cleared_by, :text, null: false)
      add(:npi_reviewed_by, :text, null: false)
      add(:npi_reason, :text, null: false)
      # The erasure recipe: how a row is redacted on erasure. `subject_column` is
      # the column carrying the subject id to match on; `redaction` is the value
      # written into the plaintext column (a non-reversible sentinel).
      add(:npi_subject_column, :text, null: false)
      add(:npi_redaction, :text, null: false, default: "[REDACTED]")
      add(:npi_registered_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    # One override per (table, column) — the registry is a set, not a log.
    create(
      unique_index(:npi_non_pii, [:npi_table_name, :npi_column_name],
        name: "npi_non_pii_table_column_index"
      )
    )

    # --- (3) erasure report artifact (D7) ---------------------------------
    create table(:era_erasure_report, primary_key: false) do
      add(:era_id, :uuid, primary_key: true, null: false, default: fragment("gen_random_uuid()"))
      add(:era_subject_id, :string, null: false)
      # The KMS attestation id (system of record for key destruction).
      add(:era_attestation_id, :text)
      # 'shredded' | 'already_shredded' | 'absent'. Idempotent second call is
      # 'already_shredded' and still a positive report.
      add(:era_outcome, :text, null: false)
      # Which tiers this erasure touched — a JSON array of tier descriptors the
      # oracle (T2.9) consumes: vault sentinel count, non_pii! redaction tally.
      add(:era_tiers, :map, null: false)
      add(:era_vault_rows_sealed, :integer, null: false, default: 0)
      add(:era_non_pii_rows_redacted, :integer, null: false, default: 0)
      add(:era_recorded_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create(index(:era_erasure_report, [:era_subject_id]))

    # --- non_pii! demo fixture column -------------------------------------
    # A plaintext-at-rest column on the patient fixture the T1.7 tests register as
    # a non_pii! override and prove redaction against. `pat_care_note` is a free
    # text field a reviewer cleared (it is operational, not identity, PII by the
    # host's judgment) — the exact carve-out D8 governs.
    alter table(:pat_patient) do
      add(:pat_care_note, :text)
      # subject id column so the erasure arm can match rows for a subject.
      add(:pat_subject_id, :string)
    end
  end

  def down do
    alter table(:pat_patient) do
      remove(:pat_subject_id)
      remove(:pat_care_note)
    end

    drop(index(:era_erasure_report, [:era_subject_id]))
    drop(table(:era_erasure_report))

    drop(constraint(:npi_non_pii, "npi_non_pii_table_column_index"))
    drop(table(:npi_non_pii))

    drop(index(:pii_vault, [:subject_id, :state]))

    alter table(:pii_vault) do
      remove(:erased_at)
      remove(:state)
    end
  end
end
