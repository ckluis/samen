defmodule Samen.Kms do
  @moduledoc """
  The per-subject key hierarchy contract (ADR-001).

  This is the single behaviour the vault runtime, the erasure path, and the
  destruction oracle program against. The production store (AWS KMS + DynamoDB
  with PITR off) is swappable with zero-dependency local adapters, and *no
  spike, test, or CI run may require a live AWS account* (ADR-001 §8.1).

  ## The wrap hierarchy (ADR-001 §2)

      KMS master keys (small fixed set)  ── never per-subject
             │ Wrap / Unwrap
             ▼
      per subject S:  DEK_S = 32 random bytes generated ONCE
                      wrapped = KMS.Encrypt(KM_vN, DEK_S)
             │
             ▼
      EXTERNAL WRAPPED-DEK STORE  (NOT app Postgres; NO PITR)

  `DEK_S` is never persisted in the clear anywhere: only (a) wrapped, in the
  external store, and (b) transiently in memory during an active decrypt.

  `shred/1` removes the only wrapped copy and writes a tombstone. Because the
  store is outside PITR, there is no historical snapshot to restore it from.
  """

  @type subject_id :: String.t()
  @type plaintext :: binary()
  @type ciphertext :: binary()
  @type key_state :: :active | :shredded | :absent

  @typedoc """
  The store-agnostic attestation the destruction oracle reads as
  system-of-record (ADR-001 §5). `:shredded` is the terminal, attested state.
  """
  @type attestation :: %{
          subject_id: subject_id,
          state: key_state,
          destroyed_at: DateTime.t() | nil,
          attestation_id: String.t() | nil,
          km_version: String.t() | nil,
          checked_at: DateTime.t()
        }

  # --- wrap hierarchy ---
  @callback generate_subject_key(subject_id) :: {:ok, wrapped :: ciphertext} | {:error, term}
  @callback unwrap(subject_id) :: {:ok, dek :: plaintext} | {:error, :shredded | :unavailable | term}

  # --- crypto-shred (destruction) ---
  @callback shred(subject_id) :: {:ok, attestation} | {:error, term}

  # --- attestation (oracle check 3) ---
  @callback attest(subject_id) :: {:ok, attestation} | {:error, term}

  # --- PITR/backup posture assertion (oracle check 2) ---
  @callback backups_disabled?() :: boolean()

  # --- pseudonym key derivation (J2 / §runs 4b), same DEK ---
  @callback pseudonym(subject_id, subject_id) :: {:ok, binary()} | {:error, :shredded | term}

  @doc """
  The configured KMS adapter for this runtime.

  Defaults to the file-backed adapter, which is the one the load-bearing
  red-path tests (PITR restore) run against, because it stores wrapped DEKs on
  disk *outside* the Postgres data directory.
  """
  @spec adapter() :: module()
  def adapter do
    Application.get_env(:s05_vault, :kms_adapter, Samen.Kms.FileBacked)
  end
end
