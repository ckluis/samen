defmodule SamenCore.TestRepo.Migrations.PiiClassifyFixture do
  @moduledoc """
  T1.8c fixture table: `pcl_person_record`.

  A Samen.Resource with AshPostgres that carries deliberately un-vaulted
  PII-named columns (`pcl_ssn`, `pcl_email_addr`, `pcl_mobile`, `pcl_dob`)
  so the `pii_classify` red-path tests can exercise the scanner against a
  real resource with a real physical table.

  The columns ARE plain (no vault routing) — this is the RED PATH fixture.
  In production, these would need to be either in a `pii do` block or cleared
  by a review-gated `non_pii!` override. Here they exist specifically to prove
  the verifier flags them.
  """
  use Samen.Migration

  @resources [SamenCore.Support.PiiClassify.PersonRecord]

  def up do
    create table(:pcl_person_record, primary_key: false) do
      # The injected universal columns (Samen.Resource).
      add(:pcl_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:pcl_org_id, :uuid, null: false)
      add(:pcl_inserted_at, :utc_datetime, null: false)
      add(:pcl_updated_at, :utc_datetime, null: false)

      # RED PATH: PII-named plain string/date columns.
      add(:pcl_ssn, :text)
      add(:pcl_email_addr, :text)
      add(:pcl_mobile, :text)
      add(:pcl_dob, :date)

      # GREEN PATH: safe plain string columns.
      add(:pcl_notes, :text)
      add(:pcl_status, :text)
    end

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)
    drop(table(:pcl_person_record))
  end
end
