defmodule Samen.Vault.PiiEmail do
  @moduledoc """
  A `pii_email`-style vault table (ADR-001 §2; doc D3).

  Holds per-subject-encrypted ciphertext. Domain rows carry the `token` as an
  FK into this table; they never hold plaintext. The row stores:

    - `token`     — opaque FK the domain row references (the "vault token")
    - `subject_id`— whose key encrypts this row (the crypto-shred unit)
    - `ciphertext`— AES-256-GCM(DEK_S, plaintext email) — useless without DEK_S
    - `label`     — the declared field label (`:email`)

  This ciphertext rides Postgres WAL/PITR/backups freely: it is useless
  ciphertext (ADR-001 §7). RQ1 is about the *key*, which is never here.
  """
  use Ecto.Schema

  @primary_key {:token, :string, autogenerate: false}
  schema "pii_email" do
    field :subject_id, :string
    field :ciphertext, :binary
    field :label, :string
    timestamps(type: :utc_datetime_usec)
  end
end
