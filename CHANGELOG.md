# Changelog

All notable changes to Samen are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); Samen aims to follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) from 1.0 onward.

## [0.1.0] — 2026-07-20

First tagged release — the public snapshot of the Samen foundry.

### Included

- **Kernel (`samen_core`)** — per-subject vault + KMS key hierarchy, crypto-shred with a
  destruction oracle, two-plane PII masking, token-blind cross-tenant aggregates, a
  hash-chained append-only audit log, the self-qualifying catalog, and the verifier gate.
- **Web framework (`samen_web`)** — inherited LiveView surfaces (CRUD + list ergonomics,
  notifications inbox, operator cockpit, global search, files, CSV import/export, self-serve
  settings) with per-plane masking by construction.
- **Generators** — `mix samen.gen.*` emit a running, correct-by-construction product with
  web / API / seed / observability / deploy scaffolds, including a readiness (`/readyz`)
  probe over Postgres, the KMS store, and Oban.
- **Verticals** — `driftwood` (freight) and `pawchart` (vet clinic) prove the substrate.
- Workstreams A / B / D / E shipped and adversarially gated — see
  [`docs/saas-gap-roadmap.md`](docs/saas-gap-roadmap.md).

### Notes

- **AI-authored.** Every commit is `Co-Authored-By: Claude` (see the README authorship note).
- Several adapters ship as documented **fail-honest stubs** (SMTP/ESP, S3, Stripe sync): they
  return `{:error, :not_configured}` or a labeled no-op, never a false success. End-user auth
  is **host-owned** — Samen governs the identity and billing you bring.

[0.1.0]: https://github.com/ckluis/samen/releases/tag/v0.1.0
