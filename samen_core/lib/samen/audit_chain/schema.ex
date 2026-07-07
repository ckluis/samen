defmodule Samen.AuditChain.Entry do
  @moduledoc """
  An `aud_chain` (`ach_`) hash-chain entry — one row per chained audit event
  (T4.3; ADR-002 §2.2).

  This is the tamper-evident, tenant-readable, operator-uneditable chain the doc
  stakes: *"a hash-chained, tenant-readable log the operator cannot edit"* (:890),
  *"the chain stays append-only and tamper-evident … while erasing a subject still
  works"* (:894).

  ## Chain scope: per-org (ADR-002 §2.1)

  The chain is sequenced per org: `(ach_org_id, ach_seq)` is a dense, gap-free
  integer sequence starting at 0. `ach_prior_hash` links entry *n* to entry
  *n-1*'s `ach_hash`; seq 0's prior_hash is the fixed genesis constant. Operator/
  system events with no org ride the reserved `ach_org_id = "__global__"` chain.

  ## Token-only + per-subject key-destroyable ciphertext (ADR-002 §2.3–2.4)

  Every hashed field is a token / bounded id / enum / timestamp / hex digest —
  never plaintext PII. `ach_subject_ciphertext` is OPTIONAL AES-256-GCM(DEK_S,
  subject_payload) under the SAME per-subject DEK the vault uses; the chain hash
  commits only to its SHA-256 digest (`ach_ciphertext_sha256`), so destroying the
  subject key leaves the hash unchanged — the chain still verifies post-shred
  while the ciphertext becomes permanently undecryptable bytes.

  ## Append-only (T2.2 reuse)

  The `aud_chain` migration REVOKEs UPDATE/DELETE from the app role and installs a
  `BEFORE UPDATE OR DELETE` trigger that raises — the same belt-and-braces the
  T2.2 `aud_event` tier uses. The ops/app role literally cannot mutate a chain row.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  # abbrev: "ach" — every column carries the ach_ prefix (self-qualifying storage).
  @primary_key {:id, :binary_id, autogenerate: true, source: :ach_id}
  schema "aud_chain" do
    # The per-org chain key. "__global__" for org-less operator/system events.
    field(:org_id, :string, source: :ach_org_id)

    # Dense per-org sequence, 0-based, gap-free.
    field(:seq, :integer, source: :ach_seq)

    # The prior entry's hash (genesis constant for seq 0). Links the chain.
    field(:prior_hash, :string, source: :ach_prior_hash)

    # SHA256(prior_hash <> canonical_payload), lowercase hex.
    field(:hash, :string, source: :ach_hash)

    # FK reference to the aud_event row this entry seals (opaque UUID).
    field(:aud_id, :binary_id, source: :ach_aud_id)

    # --- the token-only hashed payload fields (mirror aud_event, all tokens) ---
    field(:event_type, :string, source: :ach_event_type)
    field(:subject_id, :string, source: :ach_subject_id)
    field(:actor_id, :string, source: :ach_actor_id)
    field(:correlation_id, :string, source: :ach_correlation_id)
    field(:detail, :string, source: :ach_detail)
    field(:occurred_at, :utc_datetime_usec, source: :ach_occurred_at)

    # SHA-256 (hex) of ach_subject_ciphertext — the chain commits to this digest.
    field(:ciphertext_sha256, :string, source: :ach_ciphertext_sha256)

    # OPTIONAL per-subject key-destroyable ciphertext (AES-256-GCM under DEK_S).
    # Post-shred: undecryptable bytes; the hash (over the digest) is unchanged.
    field(:subject_ciphertext, :binary, source: :ach_subject_ciphertext)

    field(:inserted_at, :utc_datetime_usec, source: :ach_inserted_at)
  end
end
