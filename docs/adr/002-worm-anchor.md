# ADR-002 — Hash-chained audit + WORM anchor

- **Status:** Accepted (T4.3, Phase 4)
- **Date:** 2026-07-07
- **Deciders:** T4.3 (opus design / sonnet impl)
- **Supersedes / relates:** ADR-001 (per-subject KMS key hierarchy — the same key
  destroys the chain's per-subject ciphertext); the T2.2 `aud_event` append-only tier
  (this ADR reuses its role-revocation + trigger enforcement); the T1.6 reveal-grant
  audit writers; risk R9 (plan §4).
- **Vision doc:** "Running the business" — *"Immutable and crypto-shreddable don't
  contradict, because the audit log never stores plaintext: each entry holds vault-FK
  token references and per-subject key-destroyable ciphertext, plus the hash chain over
  those tokens. So the chain stays append-only and tamper-evident … while erasing a
  subject still works … The record of that an event happened is preserved (which is the
  point of WORM); who it was about becomes unrecoverable. The destruction oracle covers
  this tier too: mix samen.verify.no_plaintext_pii asserts the audit log holds tokens
  only."* (:894); *"a hash-chained, tenant-readable log the operator cannot edit"* (:890);
  the break-glass *"deferred-anchor"* bullet (:951).

---

## 1 · Context

Phase 4 makes the operator plane cross the reveal/impersonation seam. Every reveal,
impersonation, and erasure event already lands on the append-only `aud_event` tier (T2.2,
T1.6). Two properties the doc stakes are not yet built:

1. **Tamper-evidence** — an operator (or a compromised app role) must not be able to
   silently *edit or delete* a past audit entry, and any such attempt must be *detectable*
   by a tenant reading their own log. Append-only role-revocation + a DB trigger (T2.2)
   stop the app role from issuing UPDATE/DELETE, but they do not by themselves detect a
   *wholesale rewrite* (drop the table, rebuild it from scratch with a doctored history) by
   a party that CAN run DDL (a DBA, or an attacker who gained the DB out-of-band).

2. **Immutable AND crypto-shreddable** — the same log must survive a subject erasure: the
   *record that an event happened* is preserved, but *who it was about* becomes
   unrecoverable. This is only non-contradictory if the log stores **tokens + per-subject
   key-destroyable ciphertext, never plaintext**, and the hash chain is computed over those
   tokens (so destroying the key does not break chain verification).

The hash chain gives (1) *within the DB*. The WORM anchor gives (1) *even if the DB is
wholesale replaced* — it seals the chain head into an external write-once store the app
role cannot rewrite, so a rebuilt-from-scratch chain diverges from the last sealed head.

---

## 2 · Decision — chain design

### 2.1 Chain scope: **per-org** (with a reserved `__global__` partition)

The log is **tenant-readable**: a tenant verifies *their org's* chain. A single global chain
was rejected for three reasons:

- **Independence** — a tenant verifying a global chain would have their verification depend
  on rows belonging to *other* orgs. A gap or tamper in org B's slice would make org A's
  `verify_chain` fail, coupling unrelated tenants.
- **Confidentiality** — a global chain's sequence numbers and prior-hash links leak the
  *existence, ordering, and rate* of other orgs' audit events to any tenant who reads the
  chain to verify it. Per-org chains expose nothing cross-org.
- **Contention / scale** — a global chain serializes every write in the platform behind one
  `prior_hash` tip (a single hot row). Per-org chains parallelize by org.

Operator-plane / system events that carry **no org** (e.g. a platform-wide cron seal, an
operator login) ride a reserved `org_id = "__global__"` chain partition — a distinguished
chain, not a null. This keeps every event on *some* chain (no un-chained audit rows) while
preserving the per-org independence for real tenant orgs.

The cost of per-org chains is honestly stated: a *cross-org ordering* guarantee is NOT
provided (there is no total order across orgs). The doc does not claim one — the tenant
guarantee is "your org's log is tamper-evident and complete," which per-org chains give
exactly.

### 2.2 Chain storage: a **linked table** `aud_chain` (abbrev `ach`), not columns on `aud_event`

`aud_event` is a RANGE-partitioned parent (T2.2). Adding chain columns to it would (a) force
the `prior_hash`/`seq` to be assigned across partition boundaries (a row's partition is
chosen by `occurred_at`, not by chain position), and (b) entangle the chain's per-org
sequencing with the time-partition routing. Instead, `aud_chain` is a **separate
non-partitioned table**, one row per chained audit entry, referencing the `aud_event` row it
seals via `ach_aud_id`. The chain sequence is `(ach_org_id, ach_seq)` — a dense per-org
integer sequence. This is the plan's sanctioned "chain rows live on aud_event or a linked
table, your call": we choose the linked table.

`aud_chain` reuses **exactly** the T2.2 append-only enforcement: `REVOKE UPDATE, DELETE …
FROM <app_role>` + a `BEFORE UPDATE OR DELETE` trigger that raises. The ops/app role cannot
mutate a chain row.

### 2.3 Hash content — token-only, ciphertext-covering

For chain entry *n* in org *O*:

```
canonical_n = canonical_json({
  org_id, seq, aud_id, event_type, subject_id, actor_id,
  correlation_id, detail, occurred_at, ciphertext_sha256
})
hash_n = SHA256( prior_hash_n <> canonical_n )
```

- `prior_hash_0` for a new org chain is the fixed **genesis** constant
  `SHA256("samen/audit-chain/genesis/v1")`.
- Every field in `canonical_n` is a **token / bounded id / enum / timestamp** — never
  plaintext PII. `subject_id` is the subject's opaque UUID (the same token `aud_event`
  already carries). `detail` is operator-authored metadata (the T2.2 allow-listed field).
- `ciphertext_sha256` is `SHA256(ciphertext)` of the entry's optional **per-subject
  key-destroyable ciphertext** column (see §2.4). The chain commits to the *hash of the
  ciphertext*, NOT the plaintext. So destroying the subject's key leaves `ciphertext_sha256`
  (and therefore `hash_n`) unchanged — **the chain still verifies post-shred**. This is the
  crux of "immutable AND shreddable": verification is over tokens and a ciphertext digest,
  neither of which the shred touches.

Canonical JSON is deterministic (sorted keys, no whitespace, explicit null encoding) so the
hash is reproducible for verification. `verify_chain/1` recomputes every `hash_n` from the
stored fields and asserts (a) `hash_n` matches the stored `ach_hash`, (b)
`prior_hash_{n} == hash_{n-1}` (link continuity), (c) `seq` is dense and gap-free from 0, and
(d) `prior_hash_0 == genesis`. Any edit (a changed field → recomputed hash mismatches the
stored hash AND the next entry's prior_hash), any delete (→ seq gap + broken link), and any
gap are detected.

### 2.4 Per-subject key-destroyable ciphertext

Each chain entry MAY carry `ach_subject_ciphertext`: AES-256-GCM(DEK_S, subject_payload)
under the **same per-subject DEK** the vault uses (ADR-001). The `subject_payload` is any
subject-linked detail an event wants to preserve *decryptably-until-shred* (e.g. the exact
field revealed, a subject-scoped note). Post-shred it becomes permanently undecryptable bytes
— the event survives, the subject is unrecoverable. The chain hash covers only its SHA-256
digest (§2.3), so the shred does not break verification. Entries without subject-linked detail
leave the column NULL (and `ciphertext_sha256` is the digest of the empty binary — a fixed
constant).

The oracle's audit tier (`Samen.NoPlaintextPii.Tiers.AuditChain`, CI mode) asserts `aud_chain`
carries only bounded-id/token/enum/hash/ciphertext columns — never a plaintext PII column —
via the same allow-list + PII-name-heuristic used by the `AudEvent` tier.

---

## 3 · Decision — the WORM anchor

### 3.1 The `Samen.Anchor` behaviour

Periodically (Oban cron, `Samen.Anchor.SealWorker`) the chain **head** for each org (the
highest `(seq, hash)`) is sealed into an **external write-once store**. An anchor record is
`{org_id, seq, hash, sealed_at}`. The behaviour:

```
@callback seal(anchor :: map()) :: {:ok, receipt} | {:error, term}
@callback read_head(org_id :: String.t()) :: {:ok, anchor | :none} | {:error, term}
@callback list_heads() :: {:ok, [anchor]} | {:error, term}
@callback worm?() :: boolean()   # true = the store is genuinely append/write-once
```

### 3.2 Adapters

- **`Samen.Anchor.LocalWorm`** (faithful for tests) — an **append-only file** (`O_APPEND`),
  one JSON line per seal, **fsync'd** on every append, with **verify-on-read** (each line's
  own content hash is checked on read; a truncated/edited line is rejected). A seal never
  overwrites a prior line — the newest head for an org is the last matching line. This is a
  faithful WORM stand-in: it is append-only at the file layer and detects in-file edits on
  read. It is NOT a true compliance-mode object lock (a local root can still `rm` the file);
  the anchor's job is to detect a **rewritten DB chain**, and for that a fsync'd append-only
  file the DB-rewriting attacker does not also control is sufficient in the test/dev seam.

- **`Samen.Anchor.S3ObjectLock`** (production skeleton, config-flagged, NOT exercised) — seals
  each anchor as an S3 object under **Object Lock in COMPLIANCE mode** with a retention period,
  so even the account root cannot delete/overwrite it before retention expires. Compiles,
  implements the behaviour shape, and every network call is guarded behind
  `config :samen_core, :anchor_s3_enabled` (default false) and raises a clear
  `operator TODO` if invoked without credentials. No AWS account is required in CI (plan HARD
  rule: WORM/S3 gets a behaviour + faithful local adapter + production skeleton, seams
  documented, never a faked pass).

### 3.3 Anchor verification — the wholesale-rewrite defense

`Samen.AuditChain.verify_against_anchor/2` reads the org's sealed head from the anchor store
and asserts the **live DB chain agrees with it**: the live chain must contain an entry at the
sealed `seq` whose `hash` equals the sealed `hash`, and the live head `seq` must be `>=` the
sealed `seq` (the chain only grows). A **rewritten-history attack** — drop `aud_chain`, rebuild
it from scratch with a doctored past — produces a live chain whose entry at the sealed `seq`
has a *different* hash (the doctored history hashes differently), so
`verify_against_anchor` fails **even though the rebuilt chain internally `verify_chain`s
clean**. The anchor is the out-of-band root of trust: the attacker cannot rewrite the sealed
head (it is in the WORM store they do not control), so their rebuilt chain cannot match it.

The honest residue (documented, monitored): events written *after* the last seal and *before*
detection are not yet anchored — a rewrite that only appends fabricated *future* entries past
the sealed head is caught by the next seal's divergence, not instantly. The seal cadence bounds
this window (the same "detection-latency RPO" honesty the plan states for bad contracts, K3).

---

## 4 · Consequences

- Tenants get a tamper-evident, tenant-readable, operator-uneditable log they can verify
  themselves (`Samen.AuditChain.TenantView.for_org/2` returns their chain entries + a
  `verify_chain` + `verify_against_anchor` status), with zero cross-org leakage.
- The chain survives crypto-shred: verification is over tokens + a ciphertext digest, so a
  post-shred chain still verifies while the subject's ciphertext is undecryptable bytes.
- The oracle covers this tier (`AuditChain` CI tier asserts tokens-only), honoring the doc's
  "the destruction oracle covers this tier too."
- The wholesale-DB-rewrite attack is caught by the anchor comparison; the local-file WORM is
  a faithful test stand-in and the S3 Object Lock compliance-mode skeleton is the production
  seam (operator TODO, config-flagged, never faked).
- Break-glass deferred-anchor (T4.4) builds directly on this: the operator-node local chain
  is anchored into this same WORM chain on reconnect, and the gap/tamper detection reuses
  `verify_chain`.
