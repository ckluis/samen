defmodule Samen.NonPii.Entry do
  @moduledoc """
  A registered `non_pii!` override row (doc D8; §limits carve-out (b); T1.7 (b)).

  A `non_pii!` exception is a review-gated declaration that a specific physical
  column is **plaintext-at-rest by design** — a 2nd reviewer signed off that this
  column, despite being a plain (unvaulted) string/date, is *not* subject PII in
  the host's judgment (an operational note, a system enum, etc.).

  Two things ride on the registry:

    * **Catalog registration (D8).** Every accepted override is recorded here so
      the catalog (the `fld_field` machine dictionary) can flag the column as a
      reviewed exception with who/why metadata. The T1.8c `pii_classify` verifier
      is the *enforcement UX* (it fails the build until a flagged column has an
      entry with a distinct 2nd reviewer); this schema is the *registry* it reads.

    * **The erasure arm (T1.7 (c)).** Because key-shred does NOT reach plaintext
      columns, `Samen.Erasure` must redact these rows on erasure and record that
      it ran. The registry carries the redaction recipe: which subject column to
      match on and what sentinel to write. This is the row-level
      deletion/redaction the oracle's `registered_non_pii` tier asserts.

  Abbrev-prefixed (`npi_*`) per the self-qualifying-storage idiom.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true, source: :npi_id}
  schema "npi_non_pii" do
    field(:table_name, :string, source: :npi_table_name)
    field(:column_name, :string, source: :npi_column_name)
    # Review metadata — the distinct-party sign-off (who cleared / who reviewed).
    field(:cleared_by, :string, source: :npi_cleared_by)
    field(:reviewed_by, :string, source: :npi_reviewed_by)
    field(:reason, :string, source: :npi_reason)
    # Erasure recipe: match rows on this subject column, write this redaction.
    field(:subject_column, :string, source: :npi_subject_column)
    field(:redaction, :string, source: :npi_redaction, default: "[REDACTED]")
    field(:registered_at, :utc_datetime_usec, source: :npi_registered_at)
  end
end

defmodule Samen.Erasure.Report do
  @moduledoc """
  The erasure report artifact (doc D7; T1.7 (d)) — one row per `Samen.Erasure.shred/2`
  call. The T2.9 destruction oracle consumes this: it names the KMS attestation id
  (system of record for key destruction), the outcome, which tiers were touched,
  and the redaction tally for the `registered_non_pii` tier.

  Abbrev-prefixed (`era_*`).
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true, source: :era_id}
  schema "era_erasure_report" do
    field(:subject_id, :string, source: :era_subject_id)
    field(:attestation_id, :string, source: :era_attestation_id)
    # "shredded" | "already_shredded" | "absent"
    field(:outcome, :string, source: :era_outcome)
    # JSON array of tier descriptors the oracle reads.
    field(:tiers, :map, source: :era_tiers)
    field(:vault_rows_sealed, :integer, source: :era_vault_rows_sealed, default: 0)
    field(:non_pii_rows_redacted, :integer, source: :era_non_pii_rows_redacted, default: 0)
    field(:recorded_at, :utc_datetime_usec, source: :era_recorded_at)
  end
end
