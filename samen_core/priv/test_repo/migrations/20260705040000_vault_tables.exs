defmodule SamenCore.TestRepo.Migrations.VaultTables do
  @moduledoc """
  Creates the `pii_vault` table — the single vault table holding all
  per-subject-encrypted ciphertext for every `pii_attribute` across all
  resources (T1.4; doc D3; ADR-001 §2).

  The ciphertext rides Postgres WAL/PITR/backups freely: it is USELESS
  ciphertext without the wrapped DEK (which lives in the external KMS store,
  NEVER in Postgres — ADR-001 RQ1). A `pg_dump` captures the ciphertext;
  a PITR restore resurrects the ciphertext; but decryption is permanently
  impossible because the key was never here.

  ## Why one physical table

  The doc refers to `pii_*` tables (plural) generically. In production the
  simplest viable shape is ONE table keyed by `(subject_id, vault_name, field_name)`
  with a `vault_name` discriminator column — avoids a migration per new vault
  declaration, keeps the oracle scan simple (one table to scan), and keeps the
  catalog registration simple (one `tam_table` row for `pii_vault`). This is
  the T1.4 decision; T1.9/demo can validate it, and the oracle (T2.9) scans it
  as one tier.

  ## Token column (FK into domain rows)

  The `token` is the primary key of this table and the FK value that domain rows
  carry. Tokens are opaque `"vt_*"` strings generated at write time.

  ## Domain row convention (Gate-0 vault-stack fix — reconciled)

  The vault-routed `pii_attribute` column on the DOMAIN table IS the token column
  (a `:string`/`:text` column named exactly as `Samen.Pii.Info.storage_name`
  reports — e.g. `pat_full_name`, `pii_pat_dob`). It holds the `vt_*` token, never
  plaintext. `Samen.Vault.Change` intercepts create/update and replaces the
  plaintext value with the token before insert; `Samen.Type.VaultField` presents
  `%Masked{}` on read. There is NO separate `<field>_token` side column and NO
  plaintext column — that alongside-plaintext shape was the leak the Gate-0 audit
  flagged. This migration therefore only creates `pii_vault`; the domain columns
  are the token columns already created by the resource migration.
  """

  use Ecto.Migration

  def up do
    # The pii_vault table: one row per encrypted PII field value.
    create table(:pii_vault, primary_key: false) do
      # Opaque FK token — the value domain rows reference.
      add(:token, :string, null: false, primary_key: true)

      # Crypto-shred unit: whose key encrypts this row.
      add(:subject_id, :string, null: false)

      # Which vault (e.g., "pii_email", "pii_name", "pii_dob").
      add(:vault_name, :string, null: false)

      # Which field within the vault (e.g., "emails", "full_name", "dob").
      add(:field_name, :string, null: false)

      # AES-256-GCM(DEK_S, plaintext). Useless without the DEK.
      add(:ciphertext, :binary, null: false)

      # Optional human label for auditing/diagnostics.
      add(:label, :string)

      timestamps(type: :utc_datetime_usec)
    end

    # Index for oracle scan: "all vault rows for this subject" — the primary
    # query pattern of the destruction oracle (T2.9 DB-tier content scan).
    create(index(:pii_vault, [:subject_id]))

    # Index for vault routing: "all rows for this subject/vault" — the query
    # Samen.Vault.store_fields uses when batching writes per vault.
    create(index(:pii_vault, [:subject_id, :vault_name]))

    # NOTE (Gate-0 vault-stack fix): no `<field>_token` side columns are added to
    # the domain resources. The vault-routed PII column on the domain table IS the
    # token column (created by the resource migration as a :text column named per
    # Samen.Pii.Info.storage_name). No plaintext column exists on the domain table.
  end

  def down do
    drop(index(:pii_vault, [:subject_id, :vault_name]))
    drop(index(:pii_vault, [:subject_id]))
    drop(table(:pii_vault))
  end
end
