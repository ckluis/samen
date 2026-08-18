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

  @typedoc """
  A RESERVED SYNTHETIC subject — a KMS-purpose key, not a real PII subject (ADR-035
  §4.1). `"sys:bidx"` provisions `k_bidx`, the org-independent HMAC key the blind-index
  email lookup is keyed under, through the ordinary `generate_subject_key/1` +
  `unwrap/1` callbacks (no new behaviour callback, no adapter change). Reserved
  subjects are permanently EXCLUDED from erasure sweeps and the destruction oracle:
  shredding one would break a shared mechanism (every login lookup), not destroy one
  subject's data. See `reserved_subject?/1` and `shred/1` below.
  """
  @type reserved_subject :: subject_id

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

  # --- (OPTIONAL) the wrong-key-decrypt oracle probe (T2.9) ---
  @doc """
  The subject ids whose DEK is CURRENTLY LIVE (state `:active`) in the store.

  OPTIONAL — used ONLY by the destruction oracle's wrong-key probe (T2.9): to
  prove no ciphertext for an erased subject decrypts "under any key other than
  the destroyed one", the oracle attempts each of the subject's vault rows under
  every OTHER live key. A store that cannot cheaply enumerate its keys (the
  production `AwsKmsDynamo` — one would not `Scan` DynamoDB per oracle run) may
  return `{:error, :unsupported}`; the oracle then records the wrong-key probe as
  a documented seam (operator TODO) rather than faking a pass. The local dev
  adapters (`InMemory`, `FileBacked`) implement it so the red path is real in the
  demo/kernel suites.
  """
  @callback list_active_subjects() :: {:ok, [subject_id]} | {:error, :unsupported | term}
  @optional_callbacks [list_active_subjects: 0]

  @doc """
  The configured KMS adapter for this runtime.

  Configured via `Application.put_env(:samen_core, :kms_adapter, SomeModule)`.
  Defaults to the file-backed adapter (the load-bearing PITR red-path adapter).
  """
  @spec adapter() :: module()
  def adapter do
    Application.get_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)
  end

  @doc """
  FAIL-SECURE KMS boot guard (ADR-045 §4.2, O5) — the crypto-keystore twin of the `--deploy`
  `runtime.exs` prod-secret raise (ADR-024) and the tenant-gate boot guard
  (`Samen.Web.TenantGate.assert_prod_armed!/1`). REFUSES TO BOOT a production host whose
  configured `:kms_adapter` is an UNIMPLEMENTED SKELETON — rather than boot green and then 500
  on every vault operation (the O5/X6 defect: the generated `--deploy` posture selected
  `Samen.Kms.AwsKmsDynamo`, a raise-only skeleton, so the app booted and every encrypt/decrypt
  crashed).

  An adapter is treated as an unimplemented skeleton iff it DECLARES itself one via
  `__kms_skeleton__?/0 == true`. The shipped `Samen.Kms.AwsKmsDynamo` declares this until its
  real AWS KMS + DynamoDB calls are wired (the ADR-001 §8.2 obligations are listed in its
  `@moduledoc` and reproduced in the raise below). A working adapter (`FileBacked`, `InMemory`,
  or a fully-wired production one) does not declare the marker, so the guard admits it.

  Dev/test NEVER raise (the guard is a no-op unless the runtime is production). Call it at the
  framework boot seam — a mount-bearing host's `Application.start/2`, alongside the ADR-024
  prod-secret raise and the tenant-gate boot guard — so it fires before the endpoint accepts a
  request. `env_reader` is a test-only seam (default `&Mix.env/0`) so a suite can prove the prod
  refusal inside a `:test` run.
  """
  @spec assert_prod_adapter_ready!((-> atom())) :: :ok
  def assert_prod_adapter_ready!(env_reader \\ &Mix.env/0) do
    adapter = adapter()

    if prod?(env_reader) and skeleton_adapter?(adapter) do
      raise """
      Samen.Kms refuses to boot: the configured KMS adapter #{inspect(adapter)} is an
      UNIMPLEMENTED SKELETON in PRODUCTION.

      This host was started in a production environment with

          config :samen_core, :kms_adapter, #{inspect(adapter)}

      but that adapter's real keystore calls are NOT wired — it would boot green and then FAIL
      every vault operation (encrypt / decrypt / shred). A vaulted Samen SaaS must NEVER come up
      with a non-functional keystore (ADR-045 §4.2 O5; the crypto twin of the ADR-024 prod-secret
      raise). It refuses to boot rather than 500 on the first PII read.

      To fix, EITHER:

        1. Implement #{inspect(adapter)}'s ADR-001 §8.2 obligations (see its @moduledoc) and then
           REMOVE its `__kms_skeleton__?/0` marker (or make it return false):
             a. PITR cannot resurrect the key — DynamoDB PITR disabled; backups_disabled?/0.
             b. Post-shred unwrap/1 raises :shredded.
             c. attest/1 returns a POSITIVE :shredded tombstone (not mere :absent).
             d. pseudonym/2 unlinks on shred.
             e. KMS/store outage fails closed (:unavailable, never plaintext).
             f. key_material_present?/1 is false after shred (the wrapped DEK is DELETED).
             g. list_active_subjects/0 (the oracle wrong-key probe) wired or documented.

        2. OR select a working adapter. The file-backed keystore is real, but is NOT durable
           across an ephemeral release filesystem — provision a real KMS before trusting it:
             config :samen_core, :kms_adapter, Samen.Kms.FileBacked

      See docs/runbooks/deploy.md ("Operator TODO" — wire a real KMS adapter).
      """
    end

    :ok
  end

  @doc false
  @spec prod?((-> atom())) :: boolean()
  def prod?(env_reader \\ &Mix.env/0), do: resolved_env(env_reader) == :prod

  # Release-safe env resolution (the `Samen.AI.resolved_env/0` precedent, mirrored in
  # `Samen.Web.TenantGate`): a compiled release has no `:mix` application, so Mix is absent at
  # boot — treat an unknowable environment as :prod (fail-SECURE: the guard ARMS rather than
  # silently admitting an unimplemented adapter).
  defp resolved_env(env_reader) do
    if Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0) do
      env_reader.()
    else
      :prod
    end
  rescue
    _ -> :prod
  end

  # An adapter is an unimplemented skeleton iff it opts IN by exporting `__kms_skeleton__?/0`
  # returning true. A fully-wired / working adapter never carries the marker, so the guard
  # admits it. This keeps the refusal a property the adapter declares about ITSELF, not a
  # hardcoded denylist the boot guard has to keep in sync.
  defp skeleton_adapter?(adapter) when is_atom(adapter) do
    Code.ensure_loaded?(adapter) and function_exported?(adapter, :__kms_skeleton__?, 0) and
      adapter.__kms_skeleton__?()
  end

  defp skeleton_adapter?(_), do: false

  # ADR-035 §4.1 — the reserved synthetic subject set. "sys:bidx" is the blind-index
  # HMAC purpose key (Samen.Auth.BlindIndex). Adding a future FIXED reserved subject
  # is a one-line append here — every caller routes through `shred/1` below, so the
  # refusal is structural, not per-caller discipline.
  @reserved_subjects MapSet.new(["sys:bidx"])

  # ADR-044 §16.2 (T82) — the fleet's PER-PRODUCT `fleet_subject_key(app_id)` HMAC
  # purpose keys, one per registered app, namespaced "flt:subject:<app_id>". Same
  # class as "sys:bidx": a purpose key gating a shared per-product mechanism (every
  # tenant's fleet_handle in that product), never a real PII subject — shredding one
  # would break the whole product's handle relation, not destroy one subject's data.
  # A PREFIX match (not a fixed set) because app_id is per-app, not enumerable here.
  @reserved_subject_prefixes ["flt:subject:"]

  @doc """
  Whether `subject_id` is a RESERVED SYNTHETIC subject (ADR-035 §4.1) — a KMS-purpose
  key, never a real PII subject. `"sys:bidx"` is the blind-index HMAC key; every
  `"flt:subject:<app_id>"` id (ADR-044 §16.2) is a per-product fleet-handle HMAC key.
  Both are provisioned like any other subject (`generate_subject_key/1` / `unwrap/1`)
  but are never a valid `shred/1` target (see below).
  """
  @spec reserved_subject?(subject_id) :: boolean()
  def reserved_subject?(subject_id) when is_binary(subject_id) do
    MapSet.member?(@reserved_subjects, subject_id) or
      Enum.any?(@reserved_subject_prefixes, &String.starts_with?(subject_id, &1))
  end

  def reserved_subject?(_), do: false

  @doc """
  The GOVERNED shred chokepoint (ADR-035 §4.1). Refuses a reserved synthetic subject
  BEFORE delegating to the configured adapter, so no caller — the erasure
  orchestrator, the destruction oracle, an ad-hoc script — can shred `"sys:bidx"` by
  construction: shredding it would break every login lookup, not erase one subject.
  Every other subject delegates unchanged to `adapter().shred/1`.

  `Samen.Vault.shred/1` and `Samen.Erasure.shred/2` both ride this chokepoint (they no
  longer call `adapter().shred/1` directly) — this is the ONE place the refusal lives.
  """
  @spec shred(subject_id) :: {:ok, attestation} | {:error, :reserved_subject | term}
  def shred(subject_id) do
    if reserved_subject?(subject_id) do
      {:error, :reserved_subject}
    else
      adapter().shred(subject_id)
    end
  end
end
