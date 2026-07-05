# ADR-003 — Encryption-library integration for the per-subject vault

- **Status:** Accepted (Phase 0 spike; ratified pending GATE 0 / S0.9)
- **Date:** 2026-07-04
- **Deciders:** Samen architecture (CTO-signed layer)
- **Retires risk:** R12 (plan §4, the AshCloak arm) · follow-up of ADR-001 §9
- **Produced by:** S0.5 (`spikes/s05_vault/`)
- **Depends on:** ADR-001 (fixes the *key hierarchy*; this ADR fixes the
  *encryption-library integration* that consumes `Samen.Kms.unwrap/1`).

---

## 1 · The decision in one line

**We do NOT adopt AshCloak, and we do NOT adopt a `Cloak.Vault`-per-subject
wrapper. We adopt a thin custom vault layer driven directly by the
`Samen.Kms` behaviour (ADR-001), using OTP `:crypto` AES-256-GCM as the AEAD.**
Cloak/AshCloak are recorded as **rejected** for the per-subject-key vault, with
the specific reasons below.

The spike (`spikes/s05_vault/`) implements exactly this custom layer
(`Samen.Kms.Crypto` + `Samen.Vault`) and proves the full guarantee set — mask
by default, single reveal chokepoint, crypto-shred, PITR-restore fail-closed —
with red-path tests.

---

## 2 · What we had to verify (not assume): does AshCloak/Cloak support per-subject keys?

The plan (R12) and ADR-001 §9 flagged an *expectation* that "AshCloak assumes
app-level keys." S0.5's charge was to **verify, not assume**. Findings, from the
primary docs:

### 2.1 Cloak's key model is vault-level (application/config), not per-record

- A `Cloak.Vault` is configured with a `:ciphers` list — a fixed set of cipher
  modules, each holding a **key** (a static binary, or one loaded once in the
  vault's `init/1` GenServer callback from env/config). **The first cipher in
  the list is the default for all new encryption; a per-*field* `label` can
  select a different *configured* cipher, but the key set is fixed at
  vault-init time.**
- Cloak decrypts by trying the configured ciphers/tags — the key material is
  **whatever the vault was configured with at boot**, the same for every row.
  There is no API to say "encrypt/decrypt *this* row under *that subject's*
  key." The vault is the unit of keying, and a vault is an app-level singleton
  (an OTP-app-configured module).
- The idiomatic "rotate keys" story is: add a new cipher with a new key to the
  `:ciphers` list, re-encrypt in the background. That is **app-level key
  rotation**, not per-subject destruction.

**Conclusion: the ADR-001 note is confirmed by the source. Cloak's key is
app-level (vault-level). There is no per-subject / per-row key selection at
encrypt/decrypt time.**

### 2.2 AshCloak inherits Cloak's model

- AshCloak is an Ash extension: a `cloak do ... end` DSL section names a
  **`vault`** (a `Cloak.Vault` module) and a list of attributes to encrypt. It
  transparently encrypts those attributes on write and decrypts them via a
  calculation/`encrypt_and_set` on read.
- The `vault` is **one module per resource configuration** — an app-level
  `Cloak.Vault`. AshCloak adds no per-record key mechanism on top of Cloak; it
  delegates keying entirely to the named vault. So AshCloak is **app-level
  keyed by construction**, exactly like Cloak.

**Conclusion: AshCloak cannot express "one key per subject, destroyable per
subject." Its erasure story would be app-level key rotation, which does NOT
satisfy ADR-001 RQ2 (per-subject destruction lever) — you cannot destroy one
subject's key without re-keying everyone.**

---

## 3 · The three candidates, scored against the ADR-001 requirements

| Candidate | Per-subject key? | Crypto-shred one subject? | KMS envelope / external store fit | Verdict |
|---|---|---|---|---|
| **A. AshCloak** (`cloak do` + `Cloak.Vault`) | **No** — app/vault-level key | **No** — would re-key everyone | Cloak owns keying; bolting `Samen.Kms` under it fights its model | **Rejected** |
| **B. `Cloak.Vault`-per-subject wrapper** (dynamically start/select a vault module per subject, key = `Samen.Kms.unwrap/1`) | Yes (contrived) | Yes (indirectly) | Possible but heavyweight: a vault is a GenServer/config unit; 10⁵–10⁷ of them, or a custom cipher that ignores the vault key and calls KMS, means we're using ~none of Cloak's value | **Rejected** |
| **C. Custom `:crypto` layer driven by `Samen.Kms`** (the spike) | **Yes** | **Yes** — `Kms.shred/1` | Native: DEK from `Kms.unwrap/1`, AES-256-GCM via `:crypto`, ciphertext is a plain `:binary` Ecto column | **Adopted** |

### Why B is rejected even though it "works"

You *can* make a `Cloak.Vault`-per-subject wrapper by either (a) starting a
vault process per subject (untenable at 10⁵–10⁷ subjects — a GenServer and
config entry per subject), or (b) writing a custom `Cloak.Cipher` whose
`encrypt/decrypt` ignore the configured vault key and instead call
`Samen.Kms.unwrap/1` per call. Option (b) technically fits, but at that point
**Cloak contributes nothing** — we've replaced its keying, its rotation story,
and its vault lifecycle with our own KMS calls, and we still inherit its tag
format, its config surface, and a dependency whose mental model actively
contradicts ours (app-level vault). The wrapper is more code and more
conceptual friction than doing the AEAD directly.

### Why C is adopted

- **Per-subject keying is native.** `Samen.Vault.store_email/3` calls
  `Samen.Kms.unwrap/1` to get `DEK_S`, encrypts with `:crypto`
  AES-256-GCM, stores the ciphertext as a plain `:binary` column. Reveal calls
  `Kms.unwrap/1` again. Shred is `Kms.shred/1`. **The key lifecycle is 100%
  the ADR-001 behaviour**, with no second keying system to reconcile.
- **Crypto-shred is exactly RQ1/RQ2:** the key is never in Postgres, so nothing
  in the DB (or its PITR history) can decrypt after shred. Proven physically in
  the spike (`test/pitr_restore_test.exs`: `pg_dump` → shred → restore → deny).
- **Small, auditable trust surface.** The whole crypto core is ~90 lines
  (`Samen.Kms.Crypto`): AEAD wrap/unwrap, AEAD field encrypt/decrypt, HKDF +
  HMAC for the J2 pseudonym. All AEAD — a wrong key or tampered ciphertext fails
  the GCM tag check and returns `{:error, :decrypt_failed}`, never garbage
  plaintext (`test/crypto_test.exs` red paths).
- **The `%Masked{}` default-render property is ours to control**, not filtered
  through AshCloak's calculation machinery. `%Masked{}` holds only the vault
  token, never plaintext, so no serialization path (`to_string`, `inspect`,
  `Jason`, CSV) can leak "by omission" — the doc's load-bearing §control claim.
  AshCloak's decrypt-on-read calculation is the *opposite* default (it
  materializes plaintext into the struct); making it mask-by-default would mean
  fighting the library.

---

## 4 · What we give up by not using AshCloak (accepted residues)

- **We write our own Ecto type/serialization glue** for the vault field
  (`%Masked{}` + the store/reveal functions) instead of getting it from a DSL.
  This is a feature for the masking guarantee (§3, C) but is more code than a
  `cloak do` block. In the platform (Phase 1) this becomes the `pii do` DSL
  (doc D2) — a *Samen* extension, not AshCloak.
- **We do not get Cloak's multi-cipher rotation for free.** Master-key rotation
  is handled at the KMS layer (ADR-001 §2.1: rotated masters kept unwrap-only);
  per-subject DEKs never rotate (they are destroyed, not rotated). So Cloak's
  rotation story is not something we need.
- **No community-audited library boundary.** Mitigated: the crypto core is tiny,
  uses only OTP `:crypto` AES-256-GCM (FIPS-grade primitive) with random 96-bit
  IVs and authenticated AAD, and is covered by property + red-path tests. It is
  reviewable in one sitting.

---

## 5 · Consequences and follow-ups

- The Phase-1 `pii do` DSL (doc D2) generates the same store/reveal/mask
  functions the spike hand-wrote, keyed off `Samen.Kms`. The DSL is the
  productization; the crypto contract does not change.
- The production KMS adapter (`Samen.Kms.AwsKmsDynamo`, T1.4) plugs into the
  same `Samen.Vault` unchanged — the vault layer only knows the behaviour.
- **No dependency on `cloak` or `ash_cloak` is added.** If a future need for
  Cloak's field-format compatibility arises, revisit — but the per-subject-key
  requirement (RQ2) rules it out as the *keying* mechanism regardless.

---

## 6 · Sources

- Cloak `Cloak.Vault` docs (`:ciphers` list, default cipher, `init/1` runtime
  key loading, per-field label selecting a *configured* cipher) —
  <https://hexdocs.pm/cloak/Cloak.Vault.html>,
  <https://github.com/danielberkompas/cloak>.
- AshCloak `cloak do`/`vault` DSL delegating keying to a `Cloak.Vault` —
  <https://ash-cloak.hexdocs.pm/AshCloak.html>,
  <https://github.com/ash-project/ash_cloak>.
- Community pattern confirming app-level env-var key loading via a GenServer
  `init/1` (i.e. one key per vault, not per record) — Elixir Forum discussion on
  Cloak key loading.
