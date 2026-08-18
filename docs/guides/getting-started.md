# Getting started — zero to first feature

**The generated-app-first journey** (WS-D G10, AC-G10-2): generate a running product,
tour what you got, add a second scope + resource with the post-app generators, bend one
thing to watch the gate flip, and finish green.

> **This tutorial cannot lie to you.** Every fenced command below is verified by
> `samen_core/test/doc_commands_test.exs` (the doc-command extractor) against the two
> generative CI probes — `samen_core/priv/gen_app_flagship_probe.exs` and
> `priv/gen_post_probe.exs` — which execute these exact commands against a freshly
> generated app on every root `ci.sh` run. A command added here that CI does not
> execute fails the build.

**Prerequisites:** Elixir 1.20 / OTP 29 (pinned in `spikes/s00_smoke/VERSIONS.md`),
local PostgreSQL trusting `$USER` on localhost. All commands start from the repo root.

---

## 1 · Generate the app

```bash
cd samen_core
mix samen.gen.app --module Harbor --prefix hb --abbrev hrb
```

Three inputs, one running product:

- `--module Harbor` — the app's base module (otp_app `:harbor`, emitted as a sibling
  directory `harbor/` next to `samen_core/`).
- `--prefix hb` — the 2-letter app prefix. It derives the app's *permanent* storage
  abbrevs: the nine Billing-scope resources (`hbc/hbs/hbl/hbp/hbi/hby/hbu/hbe/hbv`),
  the aggregate plane (`hba`), the Primitives mount (`hnt/hnp/hfl/hsh/hwh/hff`) and the
  operator namespace (`ho*/hp*/hq*`).
- `--abbrev hrb` — the 3-letter abbrev for your first authored resource
  (`Harbor.Vertical.Record`, table `hrb_record`).

The generator **fails closed**: a malformed prefix/abbrev, or a collision with any
abbrev already owned in `samen_core/priv/abbrev_registry.json`, refuses to generate.
On success it appends your abbrevs to that registry (append-only, permanent — commit
the registry change alongside your app), then compiles the new app with
`--warnings-as-errors` and dumps its two committed baselines: `schema.dict.json` (the
drift check) and `api_contract.v1.json` (the API structural-break snapshot).

## 2 · Run the gate

```bash
cd ../harbor
MIX_ENV=test bash ci.sh
```

All 18 steps pass on first run — that is the load-bearing claim of the generator
(*correct-by-construction*), and it is exactly what the flagship CI probe proves on
every root `ci.sh`: compile → DB bootstrap → `schema.dict.json` drift check → the
`samen.verify.*` tiers (catalog parity, prefixes, PII reads/classify, no-plaintext-PII,
migrations, sink schema, metric labels, vault parity, tenant-catalog/boundary,
same-org FK, no-PII-columns, aggregate privacy, api_contract) → the generated test
suite (vault round-trip, the API bounded/clamp/allowlist red paths, the seeds
vault-routing red path) → the per-app anti-tautology probe.

## 3 · Tour what you got

```text
harbor/
  mix.exs                        # deps: samen_core + samen_web/phoenix/bandit + ash_json_api
  config/{config,dev,test}.exs   # endpoint, pubsub, :ash_domains, db_statement: :disabled
  lib/harbor/
    application.ex               # Repo + Oban + PubSub + endpoint supervision
    repo.ex  billing.ex          # Billing scope mounted AS-IS (9 resources, zero code)
    vertical.ex                  # YOUR resource: pii do … end vault field + json_api allowlist
    aggregate.ex                 # token-blind cross-tenant projection
    primitives.ex  operator.ex   # notifications/flags + the ADR-010 operator plane
    seeds.ex                     # vault-aware dev seeds via Samen.Factory
  lib/harbor_web/                # 5 thin files: endpoint, router (framework macro
                                 #   mounts ONLY — zero authored LiveViews), layouts,
                                 #   page_controller (/healthz), error_html
  lib/harbor_web/api/            # /api/v1 JSON:API: router, endpoint, key_auth_plug
  lib/mix/tasks/harbor.seed.ex   # `mix harbor.seed`
  priv/repo/migrations/          # substrate + catalog-in-tx resource migrations
  priv/{ci_bootstrap,anti_tautology_probe}.exs
  test/                          # record_vault, record_api, seeds_vault + support
  schema.dict.json  api_contract.v1.json  ci.sh
```

Everything framework-shaped is **inherited, never copied**: the router mounts
`Samen.Web.Router` macros, the API clamps through `Samen.Web.Api.PageLimitClamp`, the
seeds write through `Samen.Factory` (the same vault path as `SampleData`). Your app owns
only the thin authored surface — the same shape as `pawchart`.

## 4 · Boot it

```bash
mix deps.get
MIX_ENV=dev mix ecto.create && MIX_ENV=dev mix ecto.migrate
MIX_ENV=dev mix harbor.seed
mix phx.server
```

`mix harbor.seed` prints the seeded dev tenant's org id — the seeded 🔒 secrets are at
rest as `vt_*` vault tokens, never plaintext (the gate's `seeds_vault_test` proves it).
Open `http://localhost:4050`:

- `/` — the landing page, linking every mounted surface; `/healthz` — liveness
- `/billing?org=<the printed org id>` — the inherited Billing pages
- `/notifications?org=<org id>` — the notifications inbox
- `/operator/accounts` — the ADR-010 operator plane
- `/api/v1/records` — the JSON:API: key-less requests fail closed; a tenant API key
  serves data; the vault field `secret` and `org_id` are **not** in the `show_fields`
  allowlist, so they appear in no payload (deny-by-default)

Each of those routes is HTTP-probed (→ 200, with the deny-by-default payload
assertions) by the flagship probe on every root CI run.

## 5 · Add your second scope + resource

Every resource after the first is scaffolded, not hand-copied. From `harbor/`:

```bash
mix samen.gen.scope --scope Marina
mix samen.gen.resource --scope Marina --resource Slip --abbrev hsl
```

`gen.scope` emits the empty `Harbor.Marina` domain and registers it in both
`:ash_domains` lists. `gen.resource` emits a Tier-0 config resource
(`Harbor.Marina.Slip`, table `hsl_slip`: org-scoped reads, admin-gated writes, a
bounded-enum `status`, one `pii do` vault field), its `Samen.Migration`, the permanent
`hsl` registry reservation — and the **four mandated red-path test files** plus a
per-resource anti-tautology probe:

- `test/marina_slip_policy_matrix_test.exs` — cross-org denied, org-less fail-closed,
  PII masked by default, positive controls
- `test/marina_slip_rbac_red_path_test.exs` — a member cannot write, an admin can
- `test/marina_slip_vault_routing_test.exs` — the 🔒 field writes `vt_*`, plaintext nowhere
- `test/marina_slip_catalog_parity_red_path_test.exs` — deleting a catalog row flips the verifier
- `priv/marina_slip_anti_tautology_probe.exs` — proves the catalog red path is non-vacuous

Then do what the post-app CI probe does: recompile, re-baseline the drift dict, re-run
the gate — and, if you want the new table in your dev DB, migrate dev too:

```bash
mix compile --warnings-as-errors
mix samen.catalog.dump --output schema.dict.json
MIX_ENV=test bash ci.sh
MIX_ENV=dev mix ecto.migrate
```

Green again — whole gate, four new red paths included, zero hand-edits. (That exact
sequence, plus a sabotage that removes the resource's admin gate and proves the RBAC
red path flips, is `priv/gen_post_probe.exs` — permanent in root CI.)

You can also focus-run just the new files:

```bash
mix test test/marina_slip_policy_matrix_test.exs test/marina_slip_rbac_red_path_test.exs
```

## 6 · Bend one thing — and watch the gate flip

The gate is not a formality; prove it to yourself. De-allowlist a field from your API in
`lib/harbor/vertical.ex`:

```diff
-        show_fields([:id, :name, :segment])
+        show_fields([:id, :name])
```

```bash
MIX_ENV=test bash ci.sh
```

The gate now **fails at the `api_contract` step**: the committed `api_contract.v1.json`
still promises `segment`, and the compiled app no longer serves it — an un-versioned
structural break. (This exact sabotage → flip → byte-exact revert is the flagship
probe's sabotage (a); the probe halts CI if the flip ever stops happening.)

Two honest ways out:

1. **Revert the edit** — restore `:segment`; the gate is green again.
2. **Version the break** — you meant it, so re-dump the contract and re-gate:

```bash
MIX_ENV=test mix samen.verify.api_contract --version v1 --update
MIX_ENV=test bash ci.sh
```

That is the whole development loop: bend the app, let the gate name what broke, either
revert or commit the new baseline.

## 7 · What stays human

Real deploys (Fly account, Neon project, production KMS keys, a real OTLP exporter) are
deliberately **not** claimed by this tutorial — they are operator work. The deploy
scaffolding decision is [ADR-024](../adr/ADR-024-generated-deploy-fail-honest.md):
fail-honest artifacts + explicit operator-TODO runbooks, never an aspirational
"just run `fly deploy`".

## Where next

- [Generators reference](generators.md) — every `mix samen.gen.app` flag (incl.
  `--headless`, the data-only escape hatch), the red paths, the registry mechanics
- [Scope authoring](scope-authoring.md) — when you outgrow Tier-0 scaffolds and author
  a full universal scope
- [LLM grounding](llm-grounding.md) — pointing agents at `schema.dict.json` + the verifiers
- [Observability guide](../observability-guide.md) — what the generated
  `db_statement: :disabled` posture protects, and the exporter operator-TODO
