defmodule Samen.Vault.VaultRow do
  @moduledoc """
  An Ecto schema for a generic PII vault table row (doc D3; ADR-001 §2).

  The vault tables (`pii_*`) hold per-subject-encrypted ciphertext. Domain rows
  carry a **FK vault token** into these tables — they never hold plaintext.

  The row stores:
    - `token`      — opaque string PK, the FK the domain row references
    - `subject_id` — whose key encrypts this row (the crypto-shred unit)
    - `vault_name` — which vault this belongs to (`:pii_name`, `:pii_email`, etc.)
    - `field_name` — which pii_attribute field (`:emails`, `:dob`, etc.)
    - `ciphertext` — AES-256-GCM(DEK_S, plaintext) — useless without DEK_S
    - `label`      — human label for auditing/diagnostics

  The ciphertext rides Postgres WAL/PITR/backups freely: it is *useless*
  ciphertext (ADR-001 §7). RQ1 is about the *key*, which is NEVER here.

  ## One table for all vault rows

  The spike used separate Ecto schemas per vault (e.g., `PiiEmail`), which
  mirrors the doc's mention of `pii_*` tables. In production a single physical
  vault table (`pii_vault`) keyed by `(subject_id, vault_name, field_name)` is
  sufficient and simpler to migrate, catalog, and oracle-scan. The schema carries
  a `vault_name` column so rows belonging to `:pii_email` can be distinguished
  from `:pii_name`, etc. This is the T1.4 decision; the doc refers to `pii_*`
  tables generically, not a fixed set of individual tables.
  """
  use Ecto.Schema

  @primary_key {:token, :string, autogenerate: false}
  schema "pii_vault" do
    field(:subject_id, :string)
    field(:vault_name, :string)
    field(:field_name, :string)
    field(:ciphertext, :binary)
    field(:label, :string)
    # T1.7 SHREDDED sentinel: "active" | "shredded". Stamped by Samen.Erasure on
    # crypto-shred. The domain-row token FK then points at a dangling/sentinel row.
    field(:state, :string, default: "active")
    field(:erased_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end
end
