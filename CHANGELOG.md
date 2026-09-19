# Changelog

All notable changes to Samen are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); Samen aims to follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) from 1.0 onward.

## [Unreleased]

### Added

- **Mutation testing as a gate** (ADR-049): `scripts/mutate.sh` enumerates mutation sites
  **mechanically from the AST** (`scripts/mutation/mutate.exs` — `Code.string_to_quoted/2` with
  `columns: true` plus a literal encoder, never a regex) over four deliberately-chosen operator
  families (`EQ` `==`/`!=`/`===`/`!==`, `REL` `>`/`>=`/`<`/`<=`, `BOOLOP` `and`/`or`/`&&`/`||`,
  `BOOLLIT` `true`/`false`), splices each at its exact line:column, and requires it to be killed by
  that file's **OWNING** test files only — so a kill is attributed by construction, not counted.
  This answers the converse of the question the 328-patch sabotage corpus answers: that corpus
  proves every guarantee the repo *claims* is still guarded, but each sabotage is a claim someone
  thought to make, so it cannot report what it is missing. Where the owning-test column is derived
  from the sabotage `APP:`/`TEST_FILES:` headers, the attribution is already gate-proven. Five
  non-weakenable contracts: **baseline green before scoring** (against a red suite every mutant
  "dies" and the gate reports a confident 100%); **a kill is a NAMED test failure** — a non-zero
  exit with no `N) test` header means the *compiler* refused the mutant, scored `BUILD-REFUSED`
  and never a kill (the owning suites deliberately run **without** `--warnings-as-errors` so a
  warning masquerades as neither); **byte-exact SHA-256 restore** on every exit path including
  SIGINT/SIGTERM; **an unexempt survivor fails the run**; and **the full report before the
  failure** (a mutation run's value is the complete survivor list). Selection mirrors
  `sabotage.sh`'s grammar (`--app`, `--file`, `--family`, `--changed [<ref>]` with the same
  load-bearing untracked-file union, `--list`/`--dry-run`; same-flag-twice is an error; different
  flags intersect; a filtered run's success line is distinct from a full run's) and adds
  `--corpus` (derive the target set from the sabotage corpus — 163 (file, app) rows over 155 distinct lib files / 2,852 mutants, a soak
  not a gate step), `--shard <i>/<n>` (a deterministic partition, proven disjoint **and** total, so
  a soak is schedulable without overlap or gaps), and `--emit-patches <dir>` (write each survivor
  as a sabotage-format patch with `MUST_FAIL` left TODO — the promotion path that turns a
  mechanically-found hole into a permanent hand-named guarantee).
- **The mutation gate's exemption ledger is content-pinned, not line-pinned** (ADR-049 §3):
  `scripts/mutation/ledger.tsv` keys each exemption on the SHA-256 of the **exact source line** it
  excuses, so inserting lines above a justified survivor keeps it valid while **editing that line
  expires it** — `scripts/mutation_lint.sh` then fails the row as STALE. Exactly two classes are
  allowed (`EQUIVALENT` with a specific proof; `ACCEPTED_GAP` with a mandatory `ref=` naming the
  ADR/backlog item that owns the hole) and an exemption whose mutant is now **killed** fails the
  gate as obsolete, so the ledger shrinks by construction as tests land. Exempt and unexempt
  survivors are counted separately, so no report can round a ledgered hole into a clean number.
- **The mutation gate is itself refutable** (ADR-049 §6): `scripts/mutation_selection_test.sh`
  drives the gate's scoring logic against a throwaway probe module with stub runners — 30
  assertions, ~15s, no database, no real mutant applied — with a negative control for each way a
  mutation gate can lie rather than crash: a runner that always passes (every mutant survives, the
  gate must FAIL — a gate that cannot report a survivor reports 100% forever), a failure with no
  test header (must be `BUILD-REFUSED`, zero kills), a RED baseline (must fail **and print no
  score**), a stale ledger hash, an `ACCEPTED_GAP` with no `ref=`, a three-character "reason", an
  exemption whose mutant is now killed, a zero-site watch-list row, a missing owning test file, a
  splice at a column that does not hold the expected token, and `--shard` shards proven both
  disjoint and total. Wired into `ci.sh` as **two unconditional steps** (preflight + self-test,
  ~17s, no DB, nothing mutated) plus one **opt-in** replay tier, `SAMEN_MUTATION=1 ./ci.sh`,
  matching the sabotage harness's posture.

### Fixed

- **`samen_core/test/test_helper.exs` no longer blows up as a bare `MatchError` when a previous
  run's connections defeat the test-DB drop** (found by ADR-049's gate, which runs `mix test`
  dozens of times back to back and so loses that race regularly): `storage_down` cannot drop the
  database, the following `storage_up` answers `{:error, :already_up}`, and the helper crashed with
  no explanation. The drop is now retried briefly and then fails **loudly** with the reason and the
  fix. `{:error, :already_up}` is deliberately **not** tolerated — the drop is what makes the
  schema match the generated migrations, so accepting an un-dropped database would quietly run the
  suite against a stale schema.

### Changed

- **Six real holes found by the mutation gate's first run are closed with tests** (ADR-049 §7,
  MG-01…MG-06): `Samen.Pii.Classification.pii?/1` — the public "is this type PII" predicate —
  could be **fully inverted** with nothing noticing, because its owning suite tested `classify/1`
  exclusively and `pii?/1` had zero coverage (an inverted `pii?` is a total fail-open);
  `classified?/1`'s unknown-type branch answered on **atom-ness** rather than non-PII-registry
  membership under `and`→`or`, calling every atom "classified"; `Samen.ScopeMaskCase`'s own
  anti-vacuity guard (`names == [] and handles == []`) survived `and`→`or`, which would have
  refused every **one-sided** call — the normal shape of a real mask proof — while every test in
  its suite stayed green; `Samen.Delivery.Chokepoint.resolve_provider/3` returned `{nil, %{}}`
  (which reads downstream as a *resolved* provider — a fail-open onto a nil adapter) because
  `is_atom(nil)` is `true` and the `and not is_nil(...)` half was the entire guard; and
  `suppressed?/2`'s `== true` strict coercion and its documented **fail-closed-on-raise** promise
  ("a broken check must never silently let a send through") both had no test at all. The remaining
  16 survivors are ledgered as individually-referenced `ACCEPTED_GAP`s — highest severity being the
  approval gate's `authorize?: true`, whose loss turns the gate into a policy **bypass** its owning
  suite does not notice — and 1 as a proven `EQUIVALENT`.

- **Canonical Work scope — `Project` + the self-referential `Task`** (ADR-041 §3, F1): a new
  `Samen.Scopes.Work` blueprint ships one canonical Work item (`kind`/`title`/`body`/`status`/
  `priority`/`due_at`/`completed_at`, a generic CRM-agnostic `(subject_key, subject_id)`
  object-ref anchor, `custom`, `owner_id`, and the self-referential `parent_id` Subtask tree
  with cycle refusal), archivable with a subtree cascade. Every vertical inherits Project +
  Task at ≈0 authored LOC; no PII (the scope's catalog PII map is empty).
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
- **E7 audit-on-write — the `versioned` blueprint opt-in** (ADR-040 §6, T119): a resource
  declares `use Samen.Resource, versioned: true` (mode `:changes_only`, the default) or
  `versioned: :snapshot` and ash_paper_trail (ADR-037 §5.4 ADOPT) generates a governed
  `<Resource>.Version` recording every create/update/destroy as an attributable, token-only
  diff. The generated version resource gets FULL samen governance (INV-3, §6.2): an
  allocator-owned abbrev injected into its `samen do abbrev end` section at build time (the
  first auto-allocated abbrev on a generated resource; registry stays HANDS-OFF), prefixed
  columns, a mirrored `org_id`, OrgScope policies, catalog registration, and the
  `no_plaintext_pii` roster. INV-1 holds by construction: a vault-routed (🔒) attribute
  versions as its `vt_*` token, NEVER plaintext, for BOTH `:changes_only` and the full-row
  `:snapshot` reconstruction (`store_action_inputs?` is `false` forever; `:full_diff` is
  refused substrate-wide). The four audit tiers stay disjoint (§7.4): a versioned +
  impersonated write produces BOTH a Version row (E7) and a separate §6.6 `impersonation_write`
  governance `aud_event` — never one row serving both (the impersonation-write audit no-ops on
  version resources).

### Removed

- **BREAKING (pre-1.0): the CMS `ContentVersion` resource is retired** (ADR-040 §6.5, T119).
  The bespoke `content_version` ledger (`define_content_version`, the `<abbrev>_content_version`
  table, the admin-gated `:create_version` action) is removed in favor of E7 audit-on-write:
  CMS `Page`/`Post`/`Block` now declare `versioned: :snapshot`, so ash_paper_trail records a
  full-row `<Resource>.Version` snapshot on EVERY tracked write (create/update/publish/
  mark_archived/archive/restore) — fixing the long-standing gap where status transitions
  promised a version but only `set_attribute`'d (nothing ever appended a `ContentVersion` row).
  Content history now reads `Demo.CmsScope.{Page,Post,Block}.Version`; demo's `:create_version`
  smoke/test call sites are rewired to assert the automatic version rows. Zero data drop: the
  ledger held only dev/fixture data (no lifecycle hook ever wrote it, no production host mounts
  the CMS scope), so a clean drop/create produces the paper_trail-backed shape — the historical
  `add_cms_scope` migration no longer creates the table, and a guarded, idempotent
  `DROP TABLE IF EXISTS` + catalog cleanup (T97 move-then-drop convention) sweeps any lingering
  dev DB. The retired `cvr` abbrev stays in the registry (never recycled — permanence). PITR
  is not needed (no data).
- **BREAKING (pre-1.0): the CRM `Activity` resource is removed** (ADR-041 §5, operator ruling
  M5). `Activity` (call/email/meeting/note) was **destructively migrated into the canonical
  Work-scope `Task`** and its table dropped on every host (`act_activity`/`fac_activity`/
  `vce_activity`/`swa_activity` → `<work>_task`). A contract-phase, idempotent, per-host
  `INSERT … ON CONFLICT DO NOTHING` + `DROP TABLE` copies **every** Activity field onto Task
  field-for-field (§5.1) with **zero data drop**: `type→kind`, `subject→title`, body/status/
  due_at/completed_at/custom/id/org_id/timestamps verbatim; the ≤3 CRM foreign keys collapse to
  the primary subject anchor by precedence (`opportunity ▸ person ▸ company`) **and** the full
  non-null ref set is preserved in `custom.crm_refs`. The CRM detail timeline + composer now
  read/write the Work `Task` through the object-ref anchor (OR-matching `custom.crm_refs`), so a
  user sees the identical event stream. Cross-org protection moves from the belongs-to
  `SameOrgFk` to the org-scoped `Samen.Web.ObjectRef.resolve` write boundary — a cross-org
  reference is now **inert** (unresolvable) rather than a `SameOrgFk` validation error.
  Driftwood's `CheckCall` ubiquitous-language alias now re-identifies `Driftwood.Work.Task`.
  PITR is the production control for the contract phase (no `down/0` round-trip).

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
