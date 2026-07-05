# S0.5 — Spike report: PII vault + KMS + crypto-shred + `%Masked{}`

- **Spike:** S0.5 (`spikes/s05_vault/`)
- **Status:** GREEN
- **Date:** 2026-07-04
- **Implements:** ADR-001 (per-subject external-KMS key hierarchy) with dev stubs
- **Records:** ADR-003 (`docs/adr/003-encryption-lib.md`) — AshCloak vs custom → custom
- **Result:** 50 tests, all passing; every claimed guarantee has a red-path test
  verified to FAIL when the guarantee is deliberately broken.

---

## 1 · What was built (ADR-001's Decision, with dev stubs)

- **`Samen.Kms` behaviour** — the exact contract from ADR-001 §8.1:
  `generate_subject_key/1`, `unwrap/1`, `shred/1`, `attest/1`,
  `backups_disabled?/0`, `pseudonym/2`, plus the `attestation` type.
- **`Samen.Kms.InMemory`** — Agent-backed `subject_id => {dek, state}`; loses
  state on process death (models "no persistence in the app's durable surface").
- **`Samen.Kms.FileBacked`** — the external-store simulator. Wrapped DEKs and the
  dev master key live in a directory **outside the Postgres data dir and outside
  the repo** (`:s05_vault, :kms_key_dir`, under the system temp root). `shred/1`
  deletes the `.dek` file and writes a positive `.tombstone` JSON. This is the
  adapter the load-bearing PITR red path runs against.
- **Envelope crypto (`Samen.Kms.Crypto`)** — AES-256-GCM DEK wrap/unwrap (KMS
  stand-in) + AES-256-GCM vault-field encrypt/decrypt + HKDF-SHA256 →
  HMAC-SHA256 pseudonym, all via OTP `:crypto`.
- **Vault (`Samen.Vault`)** — write PII → per-subject-encrypted `pii_email` row
  + FK token on the domain row; default read → `%Masked{}`; a single `reveal/2`
  chokepoint → plaintext; `shred/1` → `Kms.shred/1`.
- **`%Masked{}`** — carries only the vault token + label, **never plaintext**;
  renders `••••` via `String.Chars`, `Inspect`, `Jason.Encoder`, and CSV.
- **Real Postgres** (`Samen.Repo`, Ecto) backs the vault + domain tables so the
  PITR red path runs a physical `pg_dump`/`psql` restore, not a mock.

---

## 2 · Acceptance criteria (plan row S0.5) — status

| Acceptance clause | Test | Status |
|---|---|---|
| Write PII → vault row ciphertext + token on domain row | reveal_test, masking_test | PASS |
| Default read = `%Masked{}` → `••••` in JSON encode | masking_test | PASS |
| … in a CSV dump | masking_test | PASS |
| … in `inspect`/`to_string` | masking_test | PASS |
| Masked value survives changeset round-trip | masking_test | PASS |
| `:reveal` returns plaintext exactly through the one chokepoint | reveal_test | PASS |
| Shred → decrypt denies; oracle-style scan finds no decryptable bytes | crypto_shred_test | PASS |
| **RED (a)** post-shred decrypt raises/denies | crypto_shred_test | PASS + verified fails when broken |
| **RED (b)** simulated PITR restore cannot decrypt (key store not in dump) | pitr_restore_test | PASS + verified fails when broken |
| **RED (c)** second decrypt path / accidental plaintext interpolation detectable | plaintext_leak_test | PASS (structural) |
| RQ4 KMS/store outage fails closed | outage_test | PASS + verified fails when broken |
| RQ5 pseudonym unlinks on shred | crypto_shred_test | PASS |
| Attestation positive (not mere absence) | crypto_shred_test, kms_conformance_test | PASS |
| Both adapters conform to `Samen.Kms` | kms_conformance_test | PASS |

---

## 3 · Red-path verification (the critical evidence)

Each guarantee was broken deliberately and its red-path test was observed to
FAIL, then restored and the suite returned to green.

### (b) PITR restore — the load-bearing claim
Sabotage: `FileBacked.shred/1` made a complete no-op (DEK survives, no
tombstone). The PITR test failed exactly where it must:

    7) test PITR restore of the DB dump cannot decrypt ... (Samen.PitrRestoreTest)
       code:  assert {:error, :shredded} = Vault.reveal(person.email)
       left:  {:error, :shredded}
       right: {:ok, "dave.restore@example.com"}   # plaintext leaked → test caught it

Same run also caught: post-shred `unwrap` returned `{:ok, <dek bytes>}`;
post-shred `reveal` returned plaintext; attestation stayed `:active`. Restoring
the real `shred/1` → all green.

### RQ4 outage fail-closed
Sabotage: `unwrap`/`effective_dir` made to ignore the outage flag:

    1) test key-store outage denies reveal ... (Samen.OutageTest)
       code:  assert {:error, :unavailable} = Vault.reveal(person.email)
       left:  {:error, :unavailable}
       right: {:ok, "frank.outage@example.com"}   # leaked during outage → caught

Restored → green. Surfaced a defense-in-depth property: both the `unwrap`
early-return AND `effective_dir` had to be sabotaged to leak.

### masking render
Sabotage: `Masked` `String.Chars.to_string` leaked the token instead of `••••`
→ the to_string + CSV masking tests failed. Restored → green.

### (c) structural single-decrypt-path
`plaintext_leak_test` scans `lib/**/*.ex` and asserts `Crypto.decrypt(` appears
at exactly one call site (`Samen.Vault.do_decrypt/2`, invoked only by
`reveal/2`). Includes a non-vacuity check proving its scanners fire on a planted
violation.

---

## 4 · Findings and honest caveats

1. **Deny is tombstone-gated in the stub, not purely dek-absence-gated.**
   `unwrap/1` denies when the `.tombstone` exists, checked before reading the
   `.dek`. In a real DB-only restore neither is present (both are in the
   non-restored key dir). The strongest PITR assertion (in pitr_restore_test)
   points the key store at a fresh empty directory and confirms decrypt still
   denies — both "key destroyed" and "key store entirely absent" restore
   scenarios fail-closed.

2. **`attest/1` on a never-seen subject returns `:absent`.** ADR-001 oracle
   semantics require `:absent` to be treated as FAIL for a post-shred assertion
   (a silently-dropped row must not masquerade as a destroyed key). The adapters
   report `:absent` vs `:shredded` faithfully; enforcing "absent == FAIL for
   post-shred" is the ORACLE's job (T2.9), out of S0.5 scope — noted.

3. **This is a stub, not production.** The KMS master is a local dev key; the
   external store is a directory. The behaviour + its semantics carry to
   production via the T1.4 `AwsKmsDynamo` adapter and the same
   `kms_conformance_test`. `backups_disabled?/0` is trivially true for a
   directory; in prod it is a real `DescribeContinuousBackups == DISABLED` check.

4. **No plaintext-key cache exists** in the spike (strictly safer than ADR-001
   §6, which permits only a short-TTL in-memory unwrapped-DEK cache). If T1.4
   adds the cache, it must carry its own red path: shred/outage must evict/deny
   even a warm cache.

5. **Ecto, not Ash.** The spike proves the guarantee with an Ecto changeset
   round-trip and a real Postgres table (needed for the physical `pg_dump`). The
   Phase-1 `pii do` DSL (doc D2) productizes the same functions over Ash;
   ADR-003 records why no Cloak/AshCloak dependency is introduced.

---

## 5 · ADR-003 verdict (verified, not assumed)

Confirmed from primary docs that Cloak/AshCloak key at the vault
(application/config) level — no per-subject/per-row key selection at
encrypt/decrypt time — so their erasure story is app-level key rotation, which
cannot destroy one subject's key without re-keying everyone (fails ADR-001 RQ2).
Decision: a thin custom `:crypto` vault layer driven by `Samen.Kms`, which is
what the spike implements. Full reasoning + sources in
`docs/adr/003-encryption-lib.md`.

---

## 6 · Recommendation for GATE 0

GO on the ADR-001 key hierarchy and the vault/mask/reveal/shred design. The
load-bearing PITR claim ("restore brings back ciphertext, never the key") is
proven physically with a real `pg_dump` + restore, and the red path fails when
the key survives. No contradiction with a doc passage was found. Carry-forwards:
oracle `:absent == FAIL` policy (T2.9); production adapter + optional DEK cache
with its own eviction red path (T1.4).
