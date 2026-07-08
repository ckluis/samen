# Generators — `mix samen.new` / `mix samen.gen.app` (T6.4)

The foundry ships a **generator** that scaffolds a new Samen vertical app shaped exactly
like the proven references (`demo`, `driftwood`, `pawchart`). The generated app is
**correct-by-construction**: it passes the full `samen_core` verifier gate on its first
`bash ci.sh`, with zero hand-editing. That is the load-bearing claim of this task — the
generator's output *is* the gate's own reference for "shaped right."

> **Naming.** The task is spelled `mix samen.new` in the plan. It is implemented as
> `mix samen.gen.app` (the Ash-ecosystem `<domain>.gen.<thing>` convention). A thin
> `mix samen.new` alias could be added later; the engine is `Samen.Gen.App`.

## Why plain `Mix.Generator`, not Igniter

`igniter` is an **optional** dependency of `ash` / `ash_postgres` / `spark` and is **not
installed** in this repo (`mix.lock` lists it only as `optional: true` under those deps).
An Igniter installer would compose cleanly *if* Igniter were a hard dep, but pulling it in
solely for scaffolding is not worth the dependency surface. The generator is therefore a
plain Mix task (`Mix.Tasks.Samen.Gen.App`) driving a pure engine (`Samen.Gen.App`) over a
templated file set (`Samen.Gen.Templates`). No template runtime is added: substitution is a
trivial `<%= key %>` string replace (`Samen.Gen.App.render/2`), so the generator itself
compiles with `--warnings-as-errors` and carries no EEx dependency.

## Usage

```bash
cd samen_core
mix samen.gen.app --module Widgetco --prefix wg --abbrev wid
```

| flag | required | meaning |
|---|---|---|
| `--module` | yes | app base module, e.g. `Widgetco` (otp_app = `:widgetco`) |
| `--prefix` | yes | **2-letter** app prefix; derives the 8 Billing abbrevs (`<p>c/<p>s/<p>l/<p>p/<p>i/<p>y/<p>u/<p>e`) + the aggregate abbrev (`<p>a`) |
| `--abbrev` | yes | **3-letter** abbrev for the authored vertical resource |
| `--target` | no | parent dir the app is created under (default: parent of the `samen_core` source root, so the app is a sibling and `path:` resolves) |
| `--no-reserve-abbrevs` | no | do **not** append the abbrevs to the registry — produces an app that fails compile fail-closed (the red-path fixture) |
| `--no-compile` | no | emit files only; skip the compile + schema-dict dump post-steps |

## What it produces

A sibling Mix project depending on `samen_core` via a **computed relative path** (`../samen_core`
for a direct sibling; deeper `../../samen_core` if nested), containing:

```
<app>/
  mix.exs                    # {:samen_core, path: <computed>} + jason/stream_data/simple_sat
  config/{config,dev,test}.exs
  lib/<app>/application.ex    # Repo + Oban children, start_repo? gate
  lib/<app>/repo.ex          # AshPostgres.Repo (uuid-ossp, citext)
  lib/<app>/billing.ex       # Samen.Scopes.Billing mounted AS-IS (the "80%")
  lib/<app>/vertical.ex      # the authored resource with a `pii do` scalar vault field (the "20%")
  lib/<app>/aggregate.ex     # a token-blind aggregate projection (no pii_ columns)
  priv/repo/migrations/…     # the substrate tables + a catalog-in-tx resource migration
  priv/ci_bootstrap.exs      # recreate + migrate the test DB for the standalone verifiers
  priv/anti_tautology_probe.exs  # the per-app vault-path flip probe
  test/…                     # test_helper + data_case + the vault round-trip red-path test
  schema.dict.json           # committed drift baseline, dumped from the compiled app
  ci.sh                      # the FULL verifier gate, wired to the app
```

### The one scope mount, one authored resource, one aggregate

- **Scope mount (AS-IS):** `use Samen.Scopes.Billing` expands into the eight host-owned
  Billing resources (Customer🔒 → Subscription → Plan/Price → Invoice → Payment → Usage →
  Entitlement) with zero vertical billing code — the doc's easy-additive case.
- **Authored resource:** `<Module>.Vertical.Record` (`use Samen.Resource`) carries a scalar
  `pii_<abbrev>_secret` vault field (masked `••••` by default, `:reveal_<abbrev>` chokepoint,
  crypto-shreddable) + plain `name`/`segment` columns + OrgScope policies.
- **Aggregate plane:** `<Module>.Aggregate.RecordCountBySegment` (`use Samen.Aggregate.Resource`)
  — a cross-tenant projection with a fail-closed `aggregate_cohort_spec/0`, no `pii_` columns,
  default-deny to the token-blind actor. Present so the `no_pii_columns` (C7) and
  `aggregate_privacy` (T4.5) gate steps scan a real aggregate.

## The global abbrev registry (the deliberate coupling)

Storage abbrevs are **permanent, ticker-like, never recycled** and live in ONE global file:
`samen_core/priv/abbrev_registry.json` (`Samen.AbbrevRegistry`). The compile-time verifier
`Samen.Verifiers.AbbrevRegistry` reads that exact file (`:code.priv_dir(:samen_core)`, which
symlinks to the source `priv`). A generated app's abbrevs must therefore be reserved **there**,
not in the app's own tree — this is the global-registry reality the T6.1 extraction retro
documents. The generator handles it:

- `Samen.Gen.App.reserve_abbrevs!/2` appends the app's 10 abbrevs (8 billing + aggregate +
  resource) to the registry, **idempotently** (a re-run is a no-op; an abbrev already owned by
  a different resource is refused), preserving the `$comment` and pretty formatting.
- `validate!/1` fails closed on: a non-2-letter prefix, a non-3-letter abbrev, an invalid
  module alias, an **internal** collision (e.g. resource abbrev == derived aggregate abbrev),
  or an abbrev already owned by a **different** resource in the registry.

## Correct-by-construction: the post-steps

With `--compile` (the default), after writing files the generator, in the new app dir:

1. `mix deps.get`
2. `mix compile --warnings-as-errors`
3. `mix samen.catalog.dump --output schema.dict.json` — so the gate's step-1b drift check is
   green (`catalog.dump` reads only compile-time introspection; no DB needed).

## The gate the generated app runs

`<app>/ci.sh` runs the full 17-step gate (identical shape to `pawchart/ci.sh`):

```
1   mix compile --warnings-as-errors
1a  DB bootstrap (recreate + migrate the test DB)
1b  schema.dict.json drift check
2   samen.verify.catalog_parity        10  samen.verify.vault_declared_parity
3   samen.verify.prefixes              11  samen.verify.tnt_catalog
4   samen.verify.pii_reads             12  samen.verify.tnt_boundary
5   samen.verify.pii_classify          13  samen.verify.same_org_fk
6   samen.verify.no_plaintext_pii      14  samen.verify.no_pii_columns
7   samen.verify.migrations            15  samen.verify.aggregate_privacy
8   samen.verify.sink_schema           16  mix test --warnings-as-errors
9   samen.verify.metric_labels         17  anti-tautology probe (vault path)
```

## Red paths (must-fail) + anti-tautology probe

The generator's guarantees each ship a red path, per the repo's hard rules:

1. **Generated gate PASSES (green path, correct-by-construction).**
   Scaffold an app, run its `ci.sh`, assert exit 0. Verified in the T6.4 workflow by
   generating `Widgetco` and running `widgetco/ci.sh` (all 17 steps green).

2. **Missing abbrev → the gate/compile catches it (red path).**
   `mix samen.gen.app --module Noabbrevco --prefix nb --abbrev nbx --no-reserve-abbrevs
   --no-compile` emits an app whose abbrevs are **not** in the registry. Compiling it fails
   closed at the `use Samen.Resource` expansion:

   > `** (CompileError) … abbrev "nbc" for Noabbrevco.Billing.Customer is not in the abbrev
   > registry … Abbrevs are permanent and must be reserved …`

3. **Anti-tautology probe on the generated-gate-passes assertion.**
   `samen_core/priv/gen_app_gate_probe.exs` proves the "generated app passes its own gate"
   claim is **non-vacuous**. In a project-local scratch dir (`_gen_probe_scratch/`, a sibling
   of `samen_core`, removed on exit, never added to root `ci.sh`) it:
   - generates an app and runs `ci.sh` → **exit 0** (baseline PASS);
   - **sabotages** the generated app by adding a `pii_`-shaped column to the token-blind
     aggregate table (the exact leak the C7 `no_pii_columns` step forbids), re-dumps the dict,
     and re-runs `ci.sh` → **non-zero** (the FLIP);
   - **reverts** to the pristine app and re-runs `ci.sh` → **exit 0** (recovery).

   If the sabotaged app still passed, the gate would be a tautology and the probe halts
   non-zero. Confirmed flip:

   ```
   baseline gate exit: 0    (MUST be 0 — correct-by-construction)
   sabotaged gate exit: 1   (MUST be non-zero — the flip)
   reverted gate exit: 0    (MUST be 0 — green again)
   RESULT: PROBE CONFIRMED
   ```

   The probe restores the committed registry and removes the scratch dir on every exit path
   (including a mid-run crash — the flow is wrapped in `try/rescue`).

## Unit coverage

`samen_core/test/gen_app_test.exs` (15 tests) covers the pure engine hermetically (temp
registry file + temp target, never touching the committed registry): spec derivation, the
computed `samen_core` relative path (sibling vs nested), every `validate_against!/2`
fail-closed rule, idempotent reservation, and `$comment`/formatting preservation.

## Operator notes / TODOs

- **Root `ci.sh` is NOT modified.** Generated apps (and the probe's scratch app) are
  deliberately kept out of the root gate; the root gate covers the fixed set
  (`samen_core`, `demo`, `driftwood`, `pawchart`). Add a generated vertical to root `ci.sh`
  only once it becomes a maintained, committed vertical.
- **Registry is append-only + global.** Reserving abbrevs mutates
  `samen_core/priv/abbrev_registry.json`. Commit that change alongside the new app. The
  generator refuses to recycle an abbrev owned by another resource.
- **`mix samen.new` alias.** If the plan's exact spelling is desired as an entry point, add a
  `Mix.Tasks.Samen.New` that delegates to `Mix.Tasks.Samen.Gen.App`.
