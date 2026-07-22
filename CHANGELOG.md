# Changelog

All notable changes to Samen are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); Samen aims to follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) from 1.0 onward.

## [Unreleased]

### Added

- **Tier-1 custom fields gain five new bounded types** (ADR-036 H6): `money`, `url`, `phone`,
  `email`, `address` join `Samen.CustomFields`'s existing `string`/`integer`/`number`/
  `boolean`/`date`/`enum` set, reusing the matching `Samen.Type.*` module's own cast/
  validation logic and bounded constraints (`currencies` allowlist for money; `schemes`/
  `max_length` for url; `max_length` for phone/email; `allowed_countries` for address). A
  non-`pii_declared` custom field of type `email`/`phone`/`address` is refused BY TYPE, not
  merely by value-shape heuristic (closing a gap the heuristic alone can't reach for a
  MAP-valued `address` field) — "a Tier-1 custom field can never be a vault bypass" now holds
  for all eleven types.
- **`mix samen.gen.resource --field-type` — the full rich-type menu** (ADR-036 H7): the
  generator's scaffolded resource's ONE scalar `pii do` vault field can now be declared as
  any of `string | money | percent | score | duration | priority | url | email | phone |
  address` (default `string`, byte-identical to pre-existing output). Every menu entry still
  materializes as a `Samen.Type.VaultField` `vt_*` token column regardless of its declared
  logical type — only the resource's `pii_attribute` declaration and the generated G26 test
  files' sample values vary per entry.
- **`Samen.Web.Csv` gains a Duration cell clause** (ADR-036 D5/H7): the canonical export form
  is ISO-8601 (e.g. `"PT5400S"`), matching the H2 contract table — `Samen.Type.Duration`'s Ash
  value is a bare integer (no wrapper struct), so the cell serializer now consults the
  column's declared Ash type before falling back to the generic value-shape dispatch every
  other cell already used.

### Changed

- **BREAKING (pre-1.0): CRM Opportunity + Billing Price money columns.** `Samen.Type.Money`
  (ADR-036 H1, a thin wrapper over `AshMoney.Types.Money` — ADR-037 §5.2 ADOPT) replaces the
  paired `value_cents`/`unit_amount_cents :integer` + `currency :string` convention with ONE
  `money_with_currency` Postgres composite column (`Opportunity.value`, `Price.unit_amount`).
  A destructive, single data-copy migration (no deprecation window — the integer-cents → composite
  transform is a lossless bijection) ships in every host (`demo`, `driftwood` — both the tenant and
  operator Billing mounts, `pawchart`) and in the `mix samen.gen.app` generator templates. Every
  production reader/writer of the old columns (the kernel MRR source, the raw-SQL revenue rollups,
  the `samen_web`/vertical UI, seeds/test-support) was repointed in the same change (ADR-036 §4.5).
  Money self-classifies non-PII behind a foundry-shipped `Samen.NonPii.TypeClearance` entry
  (ADR-034 gate). `Samen.Web.Csv` gained a Money cell clause (`"USD 12.34"`, ISO-4217).

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
