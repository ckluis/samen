# S0.5 — resolved dependency versions

Permanent record of what compiled and passed for the PII vault / KMS /
crypto-shred spike. Do not delete.

## Toolchain

- Elixir 1.20.2 (compiled with Erlang/OTP 29)
- Erlang/OTP 29 [erts-17.0.3], JIT
- PostgreSQL 16.13 (Homebrew), localhost:5432, role = OS user (no password)

## Direct deps (mix.exs)

| dep | requirement | resolved |
|---|---|---|
| ecto_sql | `~> 3.13` | 3.14.0 |
| postgrex | `~> 0.19 or ~> 1.0` | 0.22.2 |
| jason | `~> 1.4` | 1.4.5 |
| nimble_csv | `~> 1.2` | 1.3.0 |

## Full resolved lock

| package | version |
|---|---|
| db_connection | 2.10.1 |
| decimal | 3.1.1 |
| ecto | 3.14.0 |
| ecto_sql | 3.14.0 |
| jason | 1.4.5 |
| nimble_csv | 1.3.0 |
| postgrex | 0.22.2 |
| telemetry | 1.4.2 |

## Deliberately NOT depended on

- **`cloak` / `ash_cloak`** — rejected for the per-subject vault (see
  `docs/adr/003-encryption-lib.md`). AshCloak/Cloak are app-level (vault-level)
  keyed and cannot destroy one subject's key without re-keying everyone.
- **`ash` / `ash_postgres`** — the vault crypto + KMS behaviour is standalone;
  the spike uses Ecto for a real changeset round-trip and a real Postgres table
  (needed for the physical `pg_dump` PITR red path). Ash integration (the
  `pii do` DSL) is Phase 1.

## Crypto primitives

All via OTP `:crypto` (no third-party crypto lib):
- AES-256-GCM (`:aes_256_gcm`) with random 96-bit IV + authenticated AAD, for
  both DEK wrap/unwrap and vault field encryption.
- HKDF-SHA256 (RFC 5869, hand-rolled over `:crypto.mac/4`) for the J2 pseudonym
  key derivation.
- HMAC-SHA256 for `actor_id = HMAC(psk_S, subject_id)`.
