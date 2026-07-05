# S0.2 — Abbrev Storage Transformer — Spike Report

**Status:** `green_with_caveats`
**Date:** 2026-07-04
**Elixir 1.20.2 / OTP 29 · Ash 3.29.3 · ash_postgres 2.10.0 · spark 2.7.2 · Postgres 14+ local**
**Risk retired:** R2 (Spark `source:` fights AshPostgres codegen — identities, FK naming).

## Verdict

The self-qualifying storage idiom is feasible as designed and cheap — it rides a
single existing Ash field (`Ash.Resource.Attribute.source`) that AshPostgres
already treats as the physical column name everywhere (migrations, SQL,
identities, FK references). No AshPostgres fork, no custom data layer.
`mix ash.codegen` round-trips cleanly and idempotently. All plan acceptance
criteria pass, and the red path fails closed (verified by an anti-tautology
probe, not just asserted).

The one real caveat is transformer ordering (F1) — a footgun, not a blocker, but
it must be encoded in `samen_core` and covered by a test, or FK/relationship
columns silently escape the prefix.

## What was built

- `Samen.Transformers.AbbrevStorage` — a `Spark.Dsl.Transformer` that rewrites
  every attribute's `:source` to `:"<abbrev>_<name>"`.
- `Samen.Resource` — prototype base macro: `use Samen.Resource, abbrev: "com"`
  validates the abbrev, stashes it on a module attribute, layers the transformer
  as an Ash extension over `use Ash.Resource`.
- `Samen.Extension` — the Spark extension carrying the transformer.
- Fixtures: `Crm.Contact` (`abbrev: "com"`, has a `belongs_to`) and
  `Crm.Company` (`abbrev: "cpy"`, has an identity) — exercise FK + identity
  naming under the override.
- Committed `mix ash.codegen` output (`priv/repo/migrations/*_initial_spike.exs`,
  `priv/resource_snapshots/`) as round-trip evidence.

## Mechanism (the whole trick in one field)

AshPostgres uses `attribute.source` verbatim as the DB column name in its
migration generator (`ash_postgres/lib/migration_generator/operation.ex`) and
its SQL data layer. `Ash.Resource.Attribute` defaults `source` to `name` via a
per-entity `transform`. So Samen only overwrites `source` at compile time;
everything downstream (DDL, WHERE/SELECT, identity index columns, FK reference
columns) inherits the prefixed name. Logical `name` is untouched, so
actions/filters/`Ash.read`/`Ash.create`/public API keep speaking `:name`.

## Acceptance results (plan task S0.2)

| Criterion | Result | Evidence |
|---|---|---|
| generated migration contains `com_name` | PASS | `add(:com_name, :text)` in migration; test `generated migration contains the prefixed column com_name` |
| `Ash.create`/`read` work via `:name` | PASS | test `Ash.create/read work via logical :name` |
| emitted SQL WHERE uses the prefixed column | PASS | captured SQL: `... FROM "com_contact" AS c0 WHERE (c0."com_name" = $1) AND (c0."com_org_id"::uuid = $2::uuid)` |
| RED PATH: no `abbrev` fails compile w/ clear diagnostic | PASS (fail-closed proven) | `test/red_path_test.exs`; anti-tautology probe below |
| identities survive the source override | PASS | `unique_index(:cpy_company, [:cpy_org_id, :cpy_slug])` — keys resolved to prefixed columns |
| FK naming survives the source override | PASS (with ordering caveat) | `add(:com_company_id, references(:cpy_company, column: :cpy_id, ...))` |

### Red-path fail-closed verification (anti-tautology)

The red-path assertion is `assert_raise CompileError` for an abbrev-less
resource. To prove it is not tautological, the transformer + macro were
temporarily sabotaged fail-open (accept a missing abbrev, default `"xxx"`).
Under sabotage the abbrev-less resource compiled and the red-path tests FAILED
(2 failed), confirming the guard is what makes them pass. Sabotage reverted; full
suite green (11 passed). A permanent in-suite guard (`control: the identical
resource WITH a valid abbrev compiles fine`) also guarantees the raise isn't from
an unrelated compile error.

Fail-closed enforced in two places (defense in depth):
1. `Samen.Resource.__using__` — caller-local `CompileError` pointing at the
   resource's own `use` line.
2. `Samen.Transformers.AbbrevStorage` via `fetch_abbrev!/1` — a
   `Spark.Error.DslError` naming the module, if a resource is ever built without
   the macro.

## Findings — where the transformer fights AshPostgres codegen (R2)

**F1 — Ordering vs `BelongsToAttribute` is the load-bearing subtlety (must-fix in core).**
`belongs_to` FK attributes (e.g. `company_id`) are synthesized by
`Ash.Resource.Transformers.BelongsToAttribute`, not written by the user. A naive
"run first" transformer (`before?(_) -> true`) prefixes only user-declared
attributes and silently leaves the FK column unprefixed (`company_id` instead of
`com_company_id`) — a real leak of the convention. Fix: the transformer declares
`after?(Ash.Resource.Transformers.BelongsToAttribute) -> true` and
`before?(_) -> true` for everything else (so it still precedes the transformers
that snapshot `source`: primary-key cache, identity/reference resolution,
AshPostgres reference logic). Covered by test `belongs_to FK attribute is also
prefixed`. Recommendation for samen_core: keep this ordering AND add the C2
`prefixes` verifier as a backstop so any future transformer adding an attribute
after Samen cannot slip an unprefixed column through.

**F2 — "user set source" vs "defaulted source" is indistinguishable; resolved by convention.**
Because the entity transform defaults `source` to `name` before our transformer
runs, we cannot tell "user explicitly wrote `source: :name`" from "defaulted".
Rule adopted: prefix when `source in [nil, name]`, honor verbatim otherwise. So
an explicit `source:` is an escape hatch (needed for legacy columns), but a user
who explicitly writes `source: :name` expecting a bare `name` column is
overridden. Correct default for Samen (you cannot accidentally get an unprefixed
column) but document it; legacy/`non_pii!` opt-outs must use a source that
differs from the logical name.

**F3 — No codegen friction on identities or FK references.** Both R2 worries
work: identity `keys` are logical names AshPostgres resolves through
`attribute.source` at migration time (unique index lands on prefixed columns),
and FK references resolve the destination attribute through the target's (also
prefixed) `source` (`migration_generator.ex:201` matches
`attribute.source == destination_attribute`). `mix ash.codegen --check` exits 0
after generation — output is stable across codegen runs (no perpetual-diff).

**F4 — Abbrev provenance is a module attribute, not a first-class DSL entity (spike shortcut).**
The abbrev is passed via `use` opts, stashed on `@samen_abbrev`, read back via
`Transformer.get_persisted(dsl, :module)` + `Module.get_attribute`. Works but is
slightly off the Spark-idiomatic path. For core, consider a real top-level DSL
section (`samen do abbrev "com" end`) so the abbrev is introspectable and
survives fragment composition (relevant to S0.3, where the composing resource's
abbrev must reach folded fragment attributes). Interface decision for S0.3/core,
not a correctness problem here.

**F5 — Abbrev permanence/collision registry is out of scope here.** Plan A5
(permanent, never-recycled, collision-checked abbrevs) is not part of S0.2; this
spike only proves the projection mechanism. Abbrev format is validated
(`~r/\A[a-z][a-z0-9]{1,4}\z/`); cross-resource uniqueness is a core registry
concern.

## Risks / caveats carried forward

- Ordering fragility (F1): every future attribute-adding transformer must run
  before Samen's, or its columns escape the prefix. C2 `prefixes` verifier is the
  required backstop — do not rely on ordering alone.
- Composite/embedded types & fragment folding (F4): S0.3 must confirm the abbrev
  reaches attributes contributed by a `Spark.Dsl.Fragment` base; the
  module-attribute stash may need to become a persisted/DSL value.
- Multitenancy attribute source: not exercised here. When `org_id` is the tenant
  attribute, confirm AshPostgres attribute-multitenancy reads `source` (appears
  to, via the same `source_attribute` plumbing) — add a core test.

## How to reproduce

```
cd spikes/s02_transformer
mix deps.get
mix test                               # 11 tests, incl. red paths (creates samen_spike_s02_test)
MIX_ENV=test mix ash.codegen --check   # exits 0 — round-trip is idempotent
```

Regenerate the migration from scratch:
```
rm -rf priv/repo/migrations/* priv/resource_snapshots
MIX_ENV=test mix ash.codegen initial_spike
```
