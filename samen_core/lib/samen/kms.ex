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

  ## Available adapters

  - `Samen.Kms.InMemory` — Agent-backed; used for unit/property tests.
  - `Samen.Kms.FileBacked` — directory-backed; used for the load-bearing PITR
    red-path tests that require `pg_dump` / `psql` round-trips.
  - `Samen.Kms.AwsKmsDynamo` — production adapter skeleton (compiles, passes
    the conformance suite shape, network calls guarded by config flag and NOT
    exercised in CI — no AWS account required).

  ## No plaintext-key cache in T1.4 (ADR-001 §6, Gate-0 report caveats)

  ADR-001 §6 permits a short-TTL in-memory unwrapped-DEK cache to amortize
  KMS Decrypt calls, but explicitly notes it must carry its own red path
  (shred/outage evicts/denies a warm cache). T1.4 ships WITHOUT the cache —
  this is the spike's safer stance. A documented seam is left here:

      # SEAM: TTL cache for unwrapped DEKs
      # If added, it MUST:
      #   - be process-memory only, never persisted
      #   - be evicted on shred/1 (via PubSub broadcast)
      #   - deny on outage (TTL expiry, not a fallback path)
      #   - carry a red-path test: shred must deny even a warm cache entry
      # Red path (ADR-001 §8.2 addendum):
      #   assert {:error, :shredded} = adapter.unwrap(subject) # after shred, even within TTL
      # Until this is implemented, each decrypt is a live KMS call.
  """

  @type subject_id :: String.t()
  @type plaintext :: binary()
  @type ciphertext :: binary()
  @type key_state :: :active | :shredded | :absent

  @typedoc """
  The store-agnostic attestation the destruction oracle reads as
  system-of-record (ADR-001 §5). `:shredded` is the terminal, attested state.

  Oracle semantics (ADR-001 §5):
  - `:shredded` + `destroyed_at` = PASS for post-shred check
  - `:active` when expected erased = FAIL (exit 1)
  - `:absent` for post-shred assertion = FAIL — requires a POSITIVE tombstone,
    not mere absence, so "the row was silently dropped" cannot masquerade as
    "the key was destroyed" (ADR-001 red path 3).
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

  # --- key-material presence (shred defence-in-depth, oracle check 2b) ---
  @doc """
  Whether the wrapped DEK for `subject_id` STILL EXISTS in the store.

  This is the ground-truth for "is the key actually destroyed?" — independent of
  the tombstone. Post-shred it MUST be `false`: a tombstone written while the
  wrapped DEK is left behind is NOT a real shred (the key is still recoverable).
  The erasure orchestrator and the T2.9 oracle assert `key_material_present?/1 ==
  false` after shred, so a tombstone-only "shred" fails closed rather than being
  trusted (Gate-0 vault-stack fix, P2 shred defence-in-depth).
  """
  @callback key_material_present?(subject_id) :: boolean()

  # --- pseudonym key derivation (J2 / §runs 4b), same DEK ---
  @callback pseudonym(subject_id, subject_id) :: {:ok, binary()} | {:error, :shredded | term}

  @doc """
  The configured KMS adapter for this runtime.

  Configured via `Application.put_env(:samen_core, :kms_adapter, SomeModule)`.
  Defaults to the file-backed adapter (the load-bearing PITR red-path adapter).
  """
  @spec adapter() :: module()
  def adapter do
    Application.get_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)
  end
end
