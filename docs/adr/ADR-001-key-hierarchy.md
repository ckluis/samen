# ADR-001 — The per-subject external-KMS key hierarchy

- **Status:** Accepted (Phase 0 design; ratified pending GATE 0 / S0.9)
- **Date:** 2026-07-04
- **Deciders:** Samen architecture (CTO-signed layer)
- **Retires risk:** R1 (plan §4) · resolves Open Decision OD-3
- **Feeds spikes:** S0.5 (vault + envelope crypto + `Samen.Kms` behaviour + crypto-shred + `%Masked{}`), T1.4/T1.7 (vault runtime + erasure), T2.9 (destruction oracle), T4.4 (break-glass)
- **Source of truth:** `docs/samen-foundry.txt` — §data (token-only-downstream paragraph), §limits (erasure bullet + break-glass bullet), §runs 4b (pseudonym) and the `no_plaintext_pii` oracle block in §runs 3.

---

## 1 · Context and the problem this key hierarchy must solve

Samen's load-bearing privacy guarantee is **crypto-shred**: destroying one subject's key renders *all* of that subject's vault-tokenized PII permanently undecryptable across every tier at once — live, replica, backup/PITR, CDC mirror, rollups, and the audit log — as a **key-destruction**, not a copy-chasing job. Two sentences from the doc pin the design and cannot be softened:

> "…the per-subject key is not itself a Postgres row — it lives in an external KMS held outside the WAL/PITR surface, so a point-in-time restore of any pre-shred WAL brings back the ciphertext (already useless) but cannot resurrect the destroyed key." (§data)

> "Were the key a row in the same continuously-archived Postgres, a PITR restore would re-decrypt every 'dead' copy — which is exactly why the key store is excluded from the backup surface, and why `no_plaintext_pii` audits the key store and PITR history as tiers, not just the data tables." (§data)

That yields four hard requirements the key hierarchy must satisfy simultaneously — and a naive design fails at least one of each pair:

| # | Requirement | The naive design that fails it |
|---|---|---|
| **RQ1** | The per-subject key lives **outside the app-Postgres WAL/PITR/backup surface**. A PITR restore resurrects ciphertext, **never** the key. | Wrapped per-subject DEK stored as a Postgres row → *inside* PITR → a restore re-decrypts every "dead" copy. **Fails RQ1.** |
| **RQ2** | The key is **destructible** with a **queryable attestation** the destruction oracle (`no_plaintext_pii --tiers all`) reads as system-of-record. | Deleting a file with no durable record of the deletion → oracle can't attest. **Fails RQ2.** |
| **RQ3** | Economically viable at **10⁵–10⁷ subjects**. One AWS KMS CMK per subject at ~$1/CMK/month = **$100k–$10M/month** at scale. **Non-starter.** | One CMK per subject. **Fails RQ3 by 3–7 orders of magnitude.** |
| **RQ4** | **Fail-closed, deny-recoverable availability**: a KMS/store outage **denies decrypts** and never exposes plaintext or resurrects a shredded key; the failure mode is *unavailability*, not *disclosure*. | A local plaintext key cache "for availability" → survives a shred / leaks on node compromise. **Fails RQ4.** |

A fifth requirement follows from §runs 4b: the observability pseudonym `actor_id = HMAC(subject_key, subject_id)` must **key off the same per-subject key**, so destroying that key on erasure makes the trace-sink pseudonym promptly unlinkable — "riding the same KMS destruction the in-Postgres shred already attests rather than waiting on an epoch rollover."

| # | Requirement |
|---|---|
| **RQ5** | The J2 trace-sink pseudonym derives from the **same** per-subject key material, so **one destruction** unlinks the pseudonym *and* shreds the vault ciphertext — no second erasure mechanism, no epoch rollover. |

The rest of this ADR is: the two candidate architectures evaluated against RQ1–RQ5, the decision, and the local-dev stub strategy.

---

## 2 · The key hierarchy (both candidates share this envelope shape)

Both candidates use **envelope encryption with a per-subject DEK** — the difference is *where the wrapped DEK lives and how destruction is attested*. A per-subject CMK is rejected outright (RQ3). The shared shape:

```
                        ┌──────────────────────────────────────────┐
                        │  KMS master keys  (small fixed set, e.g.  │
                        │  1 CMK per region × per data-class)       │  ← never per-subject
                        │  KM_v1, KM_v2 (rotated; old kept for      │
                        │  unwrap only, never destroyed per-subject)│
                        └───────────────────┬──────────────────────┘
                                            │ Wrap / Unwrap (KMS API call)
                                            ▼
   per subject S:  DEK_S  =  32 random bytes generated ONCE at subject creation
                   wrapped = KMS.Encrypt(KM_vN, DEK_S)          ← ciphertext only
                            └──────────────────────┬──────────────────────┘
                                                   ▼
              ┌────────────────────────────────────────────────────────────┐
              │  EXTERNAL WRAPPED-DEK STORE  (NOT app Postgres; NO PITR)     │
              │  row: subject_id → {wrapped_dek, km_version, state,          │
              │        created_at, destroyed_at?, attestation_id?}           │
              │  states: ACTIVE → SHREDDED (tombstone kept; wrapped_dek gone)│
              └────────────────────────────────────────────────────────────┘
                                                   │
        DEK_S (in memory, transient) ─────────────┘  used to:
          (a) AES-256-GCM encrypt/decrypt vault field ciphertext (pii_* tables, live in app Postgres)
          (b) derive the observability pseudonym key:  psk_S = HKDF(DEK_S, info="samen/obs-pseudonym/v1")
              then  actor_id = HMAC(psk_S, subject_id)   ← J2, §runs 4b
```

Key properties of the shape, independent of store choice:

- **The vault ciphertext (AES-GCM output) lives in app Postgres** (`pii_*` tables) and rides PITR/backups freely — it is *useless* ciphertext. RQ1 is about the **key**, not the ciphertext.
- **`DEK_S` is never persisted in the clear anywhere.** It exists only (a) wrapped, in the external store, and (b) transiently in BEAM process memory during an active decrypt/reveal, then is discarded. No plaintext-key cache on disk or in Postgres (RQ4).
- **Shred = make `DEK_S` unrecoverable** by removing the *only* wrapped copy from the external store and recording a tombstone. Because the store is outside PITR, there is no historical snapshot to restore the wrapped DEK from (RQ1/RQ2).
- **The pseudonym key `psk_S` is HKDF-derived from `DEK_S`** — no independent key material, no separate lifecycle. When `DEK_S` is gone, `psk_S` is unreconstructable, so `actor_id = HMAC(psk_S, subject_id)` becomes a one-way handle whose key is destroyed → unlinkable (RQ5). The trace sink is ingress-class (append-only, third-party); we never *scan* it, we make its identifier unlinkable at the source.

### 2.1 Why two DEK tiers and not one master-per-subject

- **Cost (RQ3):** the *master* keys are a small fixed set (order 10s across regions × data-classes), so KMS CMK cost is O(1), not O(subjects). Wrapping a DEK is one `KMS.Encrypt`; unwrapping is one `KMS.Decrypt` — both flat-rate KMS API calls (~$0.03/10k requests), amortized behind a short-TTL **unwrapped-DEK cache in BEAM memory** (see §6, availability).
- **Rotation:** master keys rotate on schedule; a rotated master is retained **unwrap-only** so existing wrapped DEKs still open. Per-subject shred does **not** touch master keys (shredding a master would break every subject under it) — shred operates strictly on the per-subject wrapped-DEK row.
- **Blast radius:** compromise of one master key exposes *wrapped* DEKs, not plaintext PII, unless the attacker also has the app-Postgres ciphertext *and* can call `KMS.Decrypt` under that master — a three-way compromise. Per-subject DEKs bound the *unwrap* surface to KMS-API-authorized callers.

---

## 3 · Candidate A — wrapped per-subject DEKs in a dedicated no-backup store (DynamoDB, PITR off)

**Store:** a dedicated Amazon DynamoDB table `samen_wrapped_deks` (or equivalent single-purpose KV store), **partition key = `subject_id`**, with:

- **Point-in-Time Recovery (PITR) DISABLED** on the table (this is the load-bearing setting — it is the analog of "the key is not a Postgres row under PITR").
- **On-demand backups DISABLED / prohibited by IAM** (an explicit `Deny` on `dynamodb:CreateBackup`, `dynamodb:ExportTableToPointInTime`, and `dynamodb:UpdateContinuousBackups` scoped to this table, so PITR cannot be silently re-enabled and no snapshot can be exfiltrated to a backed-up bucket).
- No DynamoDB Streams to a backed-up sink; no global-table replication into a PITR-enabled region.
- The wrapped DEK ciphertext (`KMS.Encrypt` output) is the item body; master-key encryption of the DynamoDB table itself uses a *distinct* CMK from the wrapping master (defense in depth), but that table-level CMK is **not** per-subject and is not the shred lever.

**Wrap hierarchy:** app generates `DEK_S` → `KMS.Encrypt(KM_region, DEK_S)` → `PutItem` the wrapped bytes keyed by `subject_id`, state `ACTIVE`.

**Destruction semantics:**
1. `UpdateItem subject_id` → set `state = SHREDDED`, `destroyed_at = now()`, **remove the `wrapped_dek` attribute** (or overwrite with a fixed `SHREDDED` sentinel). The row survives as a **tombstone**; the wrapped bytes are gone.
2. Because PITR is off and backups are prohibited, **there is no historical copy** of the wrapped DEK to restore. This is the whole point: DynamoDB with PITR off has *no time-travel*. A `DeleteItem`/attribute-remove is final.
3. The tombstone (`subject_id`, `state=SHREDDED`, `destroyed_at`, `attestation_id`) is the **queryable attestation** (see §5). The tombstone itself contains no key material.

**What a PITR restore of app-Postgres can/cannot resurrect (Candidate A):**
- **Can:** the AES-GCM vault ciphertext in `pii_*` tables (useless without the DEK), the dangling FK tokens in domain rows, the audit-log ciphertext.
- **Cannot:** the wrapped DEK (it was never in Postgres) and thus `DEK_S` (unreconstructable), thus the plaintext, thus the pseudonym key `psk_S`. **RQ1 holds.**

**Cost at scale (RQ3):** DynamoDB on-demand is priced per item + per request. One ~200-byte wrapped-DEK item per subject at 10⁷ subjects ≈ **2 GB** of storage ≈ **$0.50/month** storage. Writes: one `PutItem` at subject creation (amortized negligible). Reads: one `GetItem` per cold decrypt, cached in BEAM. Master-key KMS: O(10s) CMKs ≈ **~$10–$50/month**. **Total O($10s–$100s/month at 10⁷ subjects** — vs $10M/month for per-subject CMKs. Passes RQ3 by 5+ orders of magnitude.

**Availability (RQ4):** DynamoDB is a regional, replicated, multi-AZ managed store with a high SLA; KMS likewise. A store or KMS outage → `GetItem`/`Decrypt` fails → the decrypt/reveal **fails closed** (deny-recoverable). No local plaintext-key fallback exists by construction, so an outage can never leak. Provisioned as multi-AZ; cross-region posture in §6.

**Verdict on Candidate A:** satisfies RQ1–RQ5. The one operational sharp edge is *guarding the PITR-off / no-backup invariant* — a misconfigured "enable PITR on all tables" org policy would silently break RQ1. Mitigated by (a) the explicit IAM `Deny`, (b) an SCP at the org/account level, and (c) the destruction oracle's **backup/PITR-history scan tier asserting PITR is disabled on the store** as a CI check, so a regression fails the build (see §7).

---

## 4 · Candidate B — HashiCorp Vault transit named keys (one named key per subject)

**Store/engine:** HashiCorp Vault's **transit secrets engine**, one **named key per subject** (`transit/keys/subject-<uuid>`). Vault holds the key material; the app calls `transit/encrypt/subject-<uuid>` and `transit/decrypt/subject-<uuid>` — **the plaintext key never leaves Vault** (encryption-as-a-service, like KMS). This is arguably a *cleaner* fit for "the app never holds the key" than Candidate A, because there is no DEK-in-app-memory step at all: Vault does the crypto.

**Wrap hierarchy:** Vault transit is itself envelope-based internally; its keyring is sealed by Vault's own barrier (unseal keys / auto-unseal via a cloud KMS). So the effective hierarchy is: cloud-KMS auto-unseal master → Vault barrier → per-subject transit named key. The "small set of masters" requirement is satisfied by the auto-unseal CMK(s); per-subject granularity is the named key.

**Destruction semantics:**
1. `DELETE transit/keys/subject-<uuid>` — but Vault requires `deletion_allowed=true` on the key first (a deliberate two-step guard). Deleting the named key destroys **all** its key versions; ciphertext encrypted under it becomes permanently undecryptable. This is Vault's native crypto-erase.
2. **Attestation:** a `LIST`/`READ` on the deleted key path returns 404, and Vault's **audit device** (file/syslog sink) records the delete operation with a timestamp and request ID — that audit entry, plus the 404, is the attestation. (Weaker as a *queryable system-of-record* than a purpose-built tombstone table — see below.)

**What a PITR restore can/cannot resurrect (Candidate B):**
- The concern shifts to **Vault's own storage backend** (Raft integrated storage, or Consul, etc.). If Vault's storage backend is itself snapshotted/backed up (Vault snapshots are a standard DR practice), a **Vault snapshot taken before the delete would restore the named key** — re-decrypting "dead" ciphertext. This is the *exact* failure mode §data warns about ("were the key a row in the same continuously-archived store, a restore would re-decrypt every dead copy"), transposed onto Vault snapshots.
- **Mitigation required:** Vault snapshots must be excluded from the erasure-relevant restore surface, *or* a delete must be propagated as an explicit crypto-erase that snapshots cannot undo — which Vault does **not** natively guarantee (a snapshot is a full point-in-time copy of the keyring). You end up re-imposing the same "no time-travel over the key store" discipline as Candidate A, but on a store whose entire operational model *assumes* you take DR snapshots. **This is a direct tension with RQ1.**

**Cost at scale (RQ3):** Vault OSS is free software but **operationally heavy at 10⁷ named keys**: each transit named key is keyring state Vault must hold and seal/unseal; 10⁷ named keys is far outside transit's comfortable operating envelope (transit is designed for O(app-level) keys, not O(subjects)). Vault Enterprise + support + HA cluster (3–5 nodes) + storage is a **fixed five-to-six-figure/year** operational line before the per-key scaling concern. The per-key *marginal* cost is low, but the *aggregate keyring size and seal/unseal/replication cost* at 10⁷ keys is unproven and risky. **RQ3 is met on paper but with real scaling risk.**

**Availability (RQ4):** Vault HA (Raft) with auto-unseal is fail-closed by nature (sealed Vault denies all crypto) — good. But Samen now owns a **stateful, quorum, self-hosted crypto cluster** as a hard dependency for every decrypt, replacing a managed store with an operated one. For a single-builder / small-team foundry (§limits "smaller pond"), operating Vault HA to the availability target of the data tier is significant undifferentiated ops.

**Verdict on Candidate B:** satisfies RQ2/RQ4/RQ5 cleanly and is arguably *architecturally purer* (app never holds the key). But it **strains RQ1** (Vault DR snapshots are a native, expected practice that would resurrect a deleted key unless deliberately excluded — re-creating the exact PITR problem) and **strains RQ3** (10⁷ named keys is outside transit's design envelope; operating Vault HA is heavy for this team). It is a **strong alternative and a fallback**, not the default.

---

## 5 · Attestation API (design, store-agnostic)

The destruction oracle (`no_plaintext_pii --subject <uuid> --tiers all`, check 3) reads the **KMS/key-store as the system of record** for key state. The ADR specifies a **stable attestation contract** the store adapter must implement, so the oracle is decoupled from store choice:

```elixir
# behaviour: Samen.Kms  (see §8 for the full behaviour)
@type subject_id :: String.t()
@type key_state  :: :active | :shredded | :absent

@type attestation :: %{
        subject_id: subject_id,
        state: key_state,          # :shredded is the terminal, attested state
        destroyed_at: DateTime.t() | nil,
        attestation_id: String.t() | nil,  # store-native op id (DynamoDB request id / Vault audit id)
        km_version: String.t() | nil,       # which master wrapped it (nil once shredded)
        checked_at: DateTime.t()            # when the oracle asked
      }

@callback attest(subject_id) :: {:ok, attestation} | {:error, term}
```

Oracle semantics (from §runs 3, check 3):

- `attest(subject_id)` returns `state: :shredded` with a `destroyed_at` **and no recoverable wrapped DEK** → the oracle counts check 3 as **PASS**.
- `state: :active` when the subject was supposed to be erased → **FAIL** (exit 1).
- `state: :absent` (no row at all) is treated as **FAIL for a post-shred assertion** — we require a *positive tombstone*, not mere absence, so "the row was silently dropped" cannot masquerade as "the key was destroyed."
- The oracle **also** asserts (check 2) that the store's PITR/backup is disabled (Candidate A: `DescribeContinuousBackups` == `DISABLED`; Candidate B: the Vault-snapshot-exclusion policy is in force) — a config regression fails the build.

**Crucially, the oracle never trusts a decrypt-attempt as proof of destruction** — it reads the store's attestation. The doc is explicit: "This is an ATTESTATION it reads, NOT a destruction the oracle itself proves — the KMS is the system of record for key state."

---

## 6 · Availability posture — fail-closed, deny-recoverable (RQ4)

From §limits break-glass bullet, made concrete:

- **Every decrypt / reveal / erasure-finality is a synchronous call to the key store + KMS.** The store is therefore its own **availability surface, separate from the control-plane Postgres**, and gets its own posture: run **replicated / multi-AZ (quorum for Vault; multi-AZ managed for DynamoDB+KMS)** with an availability target on the order of the data tier's.
- **A key-store/KMS outage is the wide, all-tenant "no PII renders" failure class** — accepted deliberately because it **fails closed**: a partition **denies decrypts until it heals; it never resurrects a shredded key or exposes plaintext.** The failure mode is *unavailability*, not *disclosure*.
- **No plaintext-key cache on disk or in Postgres.** The only permitted cache is a **short-TTL in-memory (BEAM) unwrapped-DEK cache** to amortize KMS `Decrypt` calls under load. It is process-memory only, TTL-bounded (order seconds–minutes), evicted on shred signal, and **never persisted** — so it neither survives a shred nor lands in a backup. (A shred must also invalidate any live cache entry for that subject; the shred path publishes an eviction over PubSub to all nodes.)
- **Break-glass, reconciled with this decision (§limits):** the *ciphertext* is the row's own data → local and available even if the central audit DB is down; but a reveal **still has to decrypt**, and the key lives in the external store. So break-glass survives the *control-plane* being down (audit anchoring goes deferred to the operator node's fsync'd hash chain, reconciled on reconnect) — but it **does not manufacture plaintext when the KMS/key-store itself is unreachable.** "Decryptability depends on KMS reachability by the same design that makes key-shred final, and there is no degraded path that bypasses it."

---

## 7 · What a PITR restore of the app-Postgres can and cannot resurrect (summary table)

This is the single most-tested claim in the ADR and the reason the store is external.

| Artifact | Lives in app-Postgres WAL/PITR? | A PITR restore resurrects it? | Consequence |
|---|---|---|---|
| Vault field ciphertext (AES-GCM) in `pii_*` | **Yes** | Yes | **Useless** without `DEK_S` |
| Domain-row FK vault tokens | Yes | Yes | Dangling after shred (SHREDDED sentinel) |
| Audit-log ciphertext + hash chain | Yes | Yes | "That an event happened" survives; "who it was about" does not |
| Rollups / matviews / CDC mirror rows | Yes (tokens only) | Yes (tokens only) | Token-only-downstream invariant; governed by rebuild-or-exclude-on-erasure |
| **Wrapped `DEK_S`** | **No — external store** | **No** | **The key is gone; ciphertext stays useless** ✅ RQ1 |
| **`DEK_S` plaintext** | No (never persisted) | No | Unreconstructable ✅ |
| **Pseudonym key `psk_S`** | No (HKDF of `DEK_S`) | No | `HMAC(psk_S, subject_id)` unlinkable ✅ RQ5 |
| KMS master keys | No (in KMS) | No | Not shredded per-subject; unwrap-only after rotation |

The destruction oracle turns this table into three CI-enforceable checks (§runs 3): (1) DB-tier content scan across live·replica·cdc·rollup·audit·registered_non_pii; (2) backup/PITR-history scan asserting **the key is absent from every DB tier and PITR history, and the external store's PITR/backup is disabled**; (3) KMS destruction attestation via `attest/1`.

---

## 8 · Decision

**We adopt Candidate A: per-subject DEKs, envelope-wrapped by a small fixed set of KMS master keys, with wrapped DEKs stored in a dedicated external key store that has backups and PITR disabled — DynamoDB (PITR off) as the first-choice production store.** HashiCorp Vault transit named keys is recorded as the **approved fallback** (adopt it only if a deployment already operates Vault HA and can exclude Vault snapshots from the erasure-relevant restore surface).

Rationale for choosing A over B:

1. **RQ1 is cleaner.** DynamoDB with PITR off has *no native time-travel to defeat*; excluding it from the backup surface is a single, auditable, CI-checkable config (`ContinuousBackups == DISABLED`). Vault's DR snapshots are a *native, expected* practice that would resurrect a deleted key unless deliberately suppressed — re-creating the exact PITR problem the doc calls out, on a store whose whole model assumes you snapshot it.
2. **RQ3 is safer at 10⁷.** DynamoDB stores 10⁷ tiny wrapped-DEK items for pennies; the KMS master set stays O(1). Vault at 10⁷ transit named keys is outside transit's design envelope and adds a stateful quorum cluster to operate.
3. **Operational fit.** A managed store + managed KMS suits the single-builder foundry (§limits) better than operating a Vault HA cluster to the data tier's availability target.

The pseudonym `actor_id = HMAC(psk_S, subject_id)` where `psk_S = HKDF(DEK_S, "samen/obs-pseudonym/v1")` keys off the **same** `DEK_S`, so the single DynamoDB shred (remove wrapped DEK + tombstone) makes both the vault ciphertext undecryptable and the trace-sink pseudonym unlinkable — **one destruction, attested once** (oracle check 3), covering RQ5.

### 8.1 The `Samen.Kms` behaviour and local-dev stub strategy

The vault runtime, the erasure path, and the oracle all program against **one behaviour**, so the production store (DynamoDB+KMS) is swappable with zero-dependency local adapters. **No spike, test, or CI run may require a live AWS account.**

```elixir
defmodule Samen.Kms do
  @moduledoc "The per-subject key hierarchy contract (ADR-001)."

  @type subject_id :: String.t()
  @type plaintext  :: binary()   # a DEK, or bytes to wrap
  @type ciphertext :: binary()

  # --- wrap hierarchy ---
  @callback generate_subject_key(subject_id) :: {:ok, wrapped :: ciphertext} | {:error, term}
  @callback unwrap(subject_id) :: {:ok, dek :: plaintext} | {:error, :shredded | :unavailable | term}

  # --- crypto-shred (destruction) ---
  @callback shred(subject_id) :: {:ok, Samen.Kms.attestation()} | {:error, term}

  # --- attestation (oracle check 3) ---
  @callback attest(subject_id) :: {:ok, Samen.Kms.attestation()} | {:error, term}

  # --- PITR/backup posture assertion (oracle check 2) ---
  @callback backups_disabled?() :: boolean()

  # --- pseudonym key derivation (J2 / §runs 4b), same DEK ---
  @callback pseudonym(subject_id, subject_id) :: {:ok, binary()} | {:error, :shredded | term}
end
```

Two required adapters for local dev / CI (both ship in S0.5), one production adapter (T1.4):

- **`Samen.Kms.InMemory`** — an `Agent`/ETS-backed map `subject_id → {dek, state}`. `shred/1` drops the entry and records a tombstone with `state: :shredded`. Fastest; used by the unit/property test suites. Deliberately loses state on process death (models "no persistence in the app's own durable surface").
- **`Samen.Kms.FileBacked`** — wrapped DEKs written to a **directory outside the Postgres data dir and outside any repo/backup path**, simulating the external store. Master "key" is a local dev key. `shred/1` deletes the wrapped-DEK file and writes a `subject_id.tombstone` JSON (`state`, `destroyed_at`, `attestation_id`). This adapter is what the **S0.5 red-path tests** run against, because it can simulate the load-bearing PITR claim: the vault/Postgres snapshot is taken *without* the key directory, then a restore proves decrypt is impossible.
- **`Samen.Kms.AwsKmsDynamo`** (production, T1.4) — `ex_aws_kms` for wrap/unwrap against master CMK(s); DynamoDB (`ex_aws_dynamo`) for the wrapped-DEK store with PITR off + IAM deny on backup ops. `attest/1` reads the tombstone item; `backups_disabled?/0` calls `DescribeContinuousBackups`.

The behaviour makes the guarantee testable **without cloud dependencies**: S0.5 proves the semantics against InMemory + FileBacked; T1.4 proves the *production adapter* conforms to the *same* behaviour via contract tests, so the guarantee established in the spike carries to prod.

### 8.2 Red-path tests this decision obligates (S0.5 / T1.7 / T2.9 must implement)

A guarantee is only real if its must-fail test fails when the guarantee is broken. This ADR mandates these red paths:

1. **PITR cannot resurrect the key.** Snapshot the vault ciphertext (FileBacked: copy the Postgres data dir *excluding* the key directory), shred the subject, "restore" the snapshot, attempt decrypt → **must raise `:shredded`/`:unavailable`, never return plaintext.** A test that decrypts successfully means the key leaked into the snapshot surface — spike is **not green**.
2. **Post-shred decrypt raises.** After `shred/1`, `unwrap/1` and any `:reveal` **must** return `{:error, :shredded}` / raise — **never** plaintext.
3. **Attestation is positive, not mere absence.** `attest/1` after shred must return `state: :shredded` with `destroyed_at`; a store that returns `:absent` (row silently dropped) must be treated as **FAIL** by the oracle, not pass.
4. **Pseudonym unlinks on shred.** `pseudonym/2` after `shred/1` must fail (`:shredded`) — proving the trace-sink handle can no longer be recomputed for that subject.
5. **KMS/store outage fails closed.** With the store made unreachable, decrypt/reveal **must deny** (`:unavailable`) and **must not** fall back to any cached or local plaintext key.
6. **Backups-disabled assertion fails the build if PITR is on.** `backups_disabled?/0` returning `false` must make the oracle's check-2 exit non-zero.

---

## 9 · Consequences

**Positive**

- Crypto-shred is a **single, attested, O(1) operation** (remove one wrapped-DEK row + tombstone) that shreds *all* of a subject's PII across every tier at once, plus unlinks the trace-sink pseudonym — no copy-chasing, no epoch rollover.
- The "restore brings back ciphertext, never the key" claim is **structurally true** (the key was never in Postgres) and **CI-enforced** (oracle checks 2+3).
- Cost is O(subjects) in pennies, O(1) in CMKs — viable at 10⁷.
- The `Samen.Kms` behaviour lets every spike and CI run offline; production conformance is a contract test.

**Negative / accepted residues**

- **New hard runtime dependency** (KMS + external store) on the decrypt path → its own availability surface; a KMS/store outage is a wide, all-tenant *deny* (accepted: fail-closed, deny-recoverable, never disclosure).
- **The PITR-off / no-backup invariant on the store is load-bearing and must be guarded** (IAM deny + org SCP + oracle check 2). A misconfiguration silently breaks RQ1 — hence it is a CI-asserted tier, not documentation.
- **Master-key rotation must retain old masters unwrap-only**; a master must never be per-subject-shredded (would break every subject under it). Shred operates strictly on the per-subject wrapped-DEK row.
- **DynamoDB is an AWS coupling** for the first-choice store; the behaviour keeps us portable (Vault transit is the recorded fallback), but the production adapter is AWS-specific.

**Follow-ups (tracked in the plan)**

- OD-3 is now resolved to Candidate A (this ADR).
- **ADR-003** (S0.5): AshCloak vs a custom `Cloak.Vault`-per-subject wrapper — AshCloak assumes app-level keys, so the expectation is a custom Cloak vault driven by this behaviour. This ADR fixes the *key hierarchy*; ADR-003 fixes the *encryption-library integration* that consumes `unwrap/1`.
- **T2.9** implements the oracle's three checks against this behaviour; **T4.4** implements break-glass with the KMS-reachability constraint stated in §6.

---

## 10 · Alternatives considered and rejected

| Alternative | Why rejected |
|---|---|
| **One AWS KMS CMK per subject** | ~$1/CMK/month → $10M/month at 10⁷. Fails RQ3 by 5–7 orders of magnitude. This is the design R1/OD-3 exist to replace. |
| **Wrapped DEK stored as a Postgres row** | Inside WAL/PITR → a restore re-decrypts every "dead" copy. Fails RQ1 — the exact anti-pattern §data names. |
| **Per-subject DEK derived from a single master via HKDF(master, subject_id)** | Deterministic derivation means **shred is impossible without destroying the master** (you can always re-derive the DEK from the master + subject_id). No per-subject destruction lever. Fails RQ2. |
| **Local plaintext-key cache "for availability"** | Survives a shred / leaks on node compromise / lands in a node backup. Fails RQ4. Only a TTL-bounded *in-memory unwrapped-DEK* cache (never persisted, evicted on shred) is permitted. |
| **HashiCorp Vault transit named keys (Candidate B)** | Strong and architecturally pure, but **strains RQ1** (Vault DR snapshots resurrect deleted keys unless deliberately excluded) and **RQ3** (10⁷ named keys outside transit's envelope; operating Vault HA is heavy for this team). Kept as the **approved fallback**, not the default. |
