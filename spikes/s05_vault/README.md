# S0.5 — PII vault + envelope crypto + KMS behaviour + crypto-shred + `%Masked{}`

Implements **ADR-001** (the per-subject external-KMS key hierarchy) with dev
stubs, and records **ADR-003** (AshCloak vs custom vault → custom).

## What this proves

- A `pii_email`-style vault table holding per-subject-encrypted ciphertext;
  domain rows carry FK vault tokens, never plaintext.
- Default read materializes `%Masked{}` → renders `••••` in JSON, CSV,
  `inspect`, and `to_string` (the doc §control "no CSV/API/log path leaks by
  omission" claim).
- A single `:reveal` chokepoint (`Samen.Vault.reveal/2`) returns plaintext
  exactly once, through the one place `Kms.unwrap/1` + `Crypto.decrypt/2` run
  for a read.
- Crypto-shred (`Samen.Vault.shred/1` → `Kms.shred/1`) destroys the subject key,
  after which every decrypt path denies.
- The J2 trace-sink pseudonym (`actor_id = HMAC(psk_S, subject_id)`) rides the
  same DEK, so one shred also unlinks it (ADR-001 RQ5).

## Layout

```
lib/samen/
  kms.ex                 # the Samen.Kms behaviour (ADR-001 §8.1)
  kms/crypto.ex          # AES-256-GCM wrap/encrypt + HKDF/HMAC pseudonym
  kms/in_memory.ex       # InMemory adapter (Agent map; loses state on death)
  kms/file_backed.ex     # FileBacked adapter = the EXTERNAL store simulator
  masked.ex              # %Masked{} — the field's normal value, renders ••••
  vault.ex               # store / read→masked / reveal chokepoint / shred
  vault/pii_email.ex     # pii_email vault table (ciphertext)
  vault/person.ex        # domain row carrying the FK token
  repo.ex                # Ecto repo (real Postgres, for the pg_dump PITR test)
test/
  masking_test.exs       # masked survives changeset round-trip + renders ••••
  reveal_test.exs        # reveal = the one plaintext chokepoint
  crypto_shred_test.exs  # RED PATH (a): post-shred deny; attestation; pseudonym
  pitr_restore_test.exs  # RED PATH (b): pg_dump → shred → restore → deny
  plaintext_leak_test.exs# RED PATH (c): single-decrypt-path structural check
  outage_test.exs        # RQ4 fail-closed, deny-recoverable
  kms_conformance_test.exs # both adapters satisfy the behaviour
  crypto_test.exs        # AEAD/HKDF unit + red paths (wrong key, tamper)
```

## The key store is OUTSIDE Postgres — on purpose

`Samen.Kms.FileBacked` writes the dev master key and every wrapped DEK to a
directory under the system temp root (`:s05_vault, :kms_key_dir`), **never under
the Postgres data dir or this repo**. That is the whole point of the PITR red
path: `pg_dump` captures the ciphertext but *cannot* capture the key store, so a
restore of the dump alone provably cannot decrypt.

## Running

```sh
# Postgres must be up on localhost:5432, role = OS user, no password.
mix deps.get
mix test          # creates samen_spike_s05_test + a transient restore DB
```

The PITR test (`pitr_restore_test.exs`) shells out to `pg_dump` / `psql` and
creates/drops `samen_spike_s05_restore_test`.

See `REPORT.md` for the full findings and the red-path failure evidence.
