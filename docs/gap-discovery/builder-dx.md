# Samen Gap Discovery — Builder DX lens

**Lens:** the experience of a developer building a *new* SaaS product on Samen.
**Question:** Samen has the "close-the-first-contract 80%" (governed substrate, verifier gate,
thin-mount reuse). What does a builder still need that Samen is missing or under-serves on the
journey from `mix samen.gen.app` to a shipped, running vertical feature?

**Method.** Read the generator (`samen.gen.app.ex` + engine `samen/gen/app.ex` + templates
`samen/gen/templates.ex`), all three guides (`generators.md`, `llm-grounding.md`,
`scope-authoring.md`), the ADRs, pawchart's actual authored code (the thin-mount probe: ~191
authored lines in `clinic.ex` + a 3-line-per-scope `router.ex`), the JSON:API surface
(`demo/lib/demo_web/api/*`), the webhook stack (`samen_core/lib/samen/webhook/*`), the
observability layer (`metrics.ex` / `wide_event.ex` / `tracer.ex` + `observability-guide.md`),
and the gate reports for DX-relevant residues.

---

## The headline finding: the generator scaffolds a *headless* app

The load-bearing claim of `mix samen.gen.app` is "correct-by-construction, gate-green on first
run" (`samen.gen.app.ex:12`). That claim is real and impressive — but the app it produces is a
**data-and-gate scaffold, not a product**. Evidence from `samen/gen/templates.ex` (the file
list, lines 14–41) and the generated `deps/0` (lines confirmed):

```elixir
defp deps do
  [ {:samen_core, path: "<%= samen_core_path %>"},
    {:jason, "~> 1.4"}, {:stream_data, "~> 1.3"}, {:simple_sat, "~> 0.1"} ]
end
```

The generated app depends on **`samen_core` only**. It does **not** depend on `samen_web`,
`phoenix`, `phoenix_live_view`, or `ash_json_api`. The emitted file set is: `mix.exs`,
`config/{config,dev,test}.exs`, `application.ex`, `repo.ex`, `billing.ex`, `vertical.ex`,
`aggregate.ex`, the substrate migrations, `ci_bootstrap.exs`, `anti_tautology_probe.exs`, a
vault test, `schema.dict.json`, `ci.sh`, and a `README.md`. There is **no** `*_web/` tree, no
router, no endpoint, no LiveView mount, no API endpoint, no seeds, no Dockerfile/fly.toml, no
observability wiring.

So the actual builder journey is: `mix samen.gen.app` gives you a passing gate over a headless
billing scope + one resource. Then to get to a *running product* the builder hand-writes: the
entire `*_web/` layer (endpoint, router, layouts, page controller — see pawchart's
`pawchart_web/` which is ~250 authored lines the generator did **not** produce), the
`samen_module_routes/3` mounts, the JSON:API endpoint + `KeyAuthPlug` + per-resource
`json_api do show_fields end` allowlists (demo's `demo_web/api/` is hand-authored), seeds,
observability setup, and a deploy story. Pawchart's thin-mount is genuinely thin (3 lines per
scope) — but **the generator doesn't emit it**, so the builder copies it from a reference by
hand. The 80% reuse is real at *runtime*; it is not yet real at *scaffold time*.

This finding shapes the ranking below: the single highest-joy move is to make the generator (or
a companion generator) emit the web + API + seed layer that pawchart/demo prove is thin, so the
builder's first `mix phx.server` shows a working product, not a green test run.

---

## Gap catalog

Each gap: what world-class provides · what Samen has today (cited) · the delta · joy impact ·
effort · harden-vs-new.

### G1 — Generator stops at the data layer; no web/API/product scaffold
- **World-class:** `mix phx.new` / `rails new` / `mix ash.gen.*` produce a *runnable app* — you
  `phx.server` and see a page. Laravel/Rails scaffold controllers+views+routes for a resource.
- **Samen today:** `samen.gen.app` emits only samen_core-backed data modules + gate
  (`templates.ex:14–41`; `deps/0` has no `samen_web`/`phoenix`/`ash_json_api`). The runnable
  product surface — `pawchart_web/{endpoint,router,layouts,page_controller}.ex`,
  `samen_module_routes/3` mounts, the `demo_web/api/*` JSON:API — is entirely hand-authored in
  the references, not generated.
- **Delta:** the builder's first output is a green `ci.sh`, not a running UI. To reach a running
  product they reverse-engineer pawchart/demo by copy. Time-to-first-*visible*-feature is high;
  time-to-first-*gate-green* is near zero (asymmetry hides the real onboarding cost).
- **Joy:** H · **Effort:** M (the reference thin-mounts already exist to template from) ·
  **Harden** the existing generator (add `--web` / `--api` flags that emit the samen_web mount +
  AshJsonApi endpoint + a "hello vertical" LiveView).

### G2 — No resource/scope/field generators (only whole-app gen)
- **World-class:** `rails g model`, `mix ash.gen.resource`, `mix phx.gen.live` — incremental
  scaffolds for the *next* resource, not just the first app.
- **Samen today:** the ONLY generators are `samen.gen.app` and `catalog.dump`
  (`ls mix/tasks | grep -v verify`). Adding a resource, a scope, a Tier-0 config resource, a
  Tier-1 custom field, or a Tier-2 custom object is a **manual copy-paste** exercise. The
  `scope-authoring.md` guide is literally a 10-step "copy `identity.ex`, copy the blueprint, copy
  four test files, run the sabotage probe" checklist (§10) — that is a generator-shaped task done
  by hand. Custom-fields/objects exist as runtime modules (`samen/custom_fields.ex`,
  `custom_objects.ex`) but have no scaffold.
- **Delta:** every resource after the first is hand-written against a prose checklist — the exact
  place an LLM or a human forgets the `SameOrgFk` change, the `catalog_sync`, or a red-path test.
- **Joy:** H · **Effort:** M (per-generator) · **New module** (`samen.gen.resource`,
  `samen.gen.scope`, `samen.gen.tier1_field`, `samen.gen.tier2_object`), reusing the pure-engine
  pattern already established in `Samen.Gen.App`.

### G3 — No JSON:API scaffold; the external surface is hand-wired per resource
- **World-class:** Supabase/PostgREST auto-exposes tables; AshJsonApi installers wire the router;
  OpenAPI/Swagger is generated.
- **Samen today:** a real, governed JSON:API exists (`demo_web/api/router.ex` uses
  `AshJsonApi.Router`, URL-versioned `/api/v1`, `KeyAuthPlug` maps api_key→`%Samen.Scope{}`, and
  there's a genuine `samen.verify.api_contract` structural-break verifier). But it is **all
  hand-authored**: the endpoint, the router, the auth plug, and an opt-in
  `json_api do show_fields … end` allowlist on *each* resource. The generator emits none of it.
- **Delta:** every vertical re-derives the API endpoint + auth plug + per-resource allowlists from
  demo by copy. The governance (allowlist-by-default, contract verifier) is excellent; the
  *scaffolding* of it is absent.
- **Joy:** H · **Effort:** M · **Harden** (fold an `--api` path into the generator that emits the
  `_web/api/` triplet + a default `json_api` block on the authored resource).

### G4 — No OpenAPI spec / client SDK generation
- **World-class:** Stripe/Supabase/any modern API ships an OpenAPI doc and generated typed client
  SDKs; `ash_json_api` itself can emit an OpenAPI JSON.
- **Samen today:** grep for `open_api`/`OpenApi`/`swagger` returns **nothing** across the repo.
  The api_contract snapshot (`api_contract.v1.json`) is a Samen-internal diff format, not a
  published OpenAPI doc. No client SDK generation, no typed TS/Python client.
- **Delta:** a builder shipping an API to *their* customers has no machine-readable spec to hand
  out and no SDK story — they'd write and maintain the OpenAPI by hand.
- **Joy:** M · **Effort:** S–M (AshJsonApi has an OpenAPI extension; wiring it + a `mix
  samen.api.openapi` dump is small) · **Harden** (enable the AshJsonApi OpenAPI extension) +
  **New** (SDK gen is a larger follow-on).

### G5 — No fixtures/factories/seed generator for a NEW vertical
- **World-class:** `ex_machina` factories, Rails fixtures, `rails db:seed` scaffolds; Supabase
  seed.sql. Every framework gives you a demo-data on-ramp.
- **Samen today:** the references each hand-roll seeds (`pawchart/lib/pawchart/seeds.ex` is **613
  lines**; `driftwood/lib/driftwood/seeds.ex`; a `<app>.seed` mix task each). The generator emits
  **no** seed module or factory. There is no shared factory helper for PII-vault fields (a
  builder must know to write through the vault, seed a subject key, etc.). samen_core's own
  `test/support/*_fixture.ex` are internal test fixtures, not a builder-facing factory API.
- **Delta:** demo-data for a new vertical is a from-scratch 600-line hand-write; seeding a
  vaulted PII field correctly is non-obvious and unassisted.
- **Joy:** M–H · **Effort:** M · **New module** (a `Samen.Factory` helper that knows vault/subject
  seeding + a `--seed` generator path emitting a starter seeds module).

### G6 — No deploy story (no Fly/Neon/Docker artifacts, no deploy generator)
- **World-class:** `fly launch` generates fly.toml + Dockerfile; Vercel/Render zero-config;
  `mix phx.gen.release`.
- **Samen today:** grep for `fly.toml`/`Dockerfile`/`release.exs` returns **nothing**. Gate
  reports explicitly carry "real Neon/AWS/ClickHouse drills" and Fly/Neon deploy as **operator
  TODOs** (gate-6-report residues; MEMORY confirms). `config/dev.exs` is bare
  localhost/`$USER`/empty-password Postgres. The observability guide's exporter config is a
  documented "Operator TODO: replace :none with a real OTLP exporter".
- **Delta:** the "makes running a SaaS a joy" half of the mission has no generated on-ramp; every
  vertical author writes their own Dockerfile, release config, and Neon/Fly wiring.
- **Joy:** H (running is half the thesis) · **Effort:** M · **New module** (a `mix
  samen.gen.deploy` emitting Dockerfile + fly.toml + release.exs + a Neon-branch runbook, plus a
  reference deploy in one vertical).

### G7 — Observability is a library, not wired by the generator
- **World-class:** `phx.new` wires `Telemetry`, LiveDashboard, and a metrics supervisor out of
  the box; PromEx ships Grafana dashboards.
- **Samen today:** a strong governed observability *library* exists — `Samen.Metrics`,
  `Samen.WideEvent`, `Samen.Tracer`, and a thorough `observability-guide.md` (OTel + Prometheus +
  wide-events, all PII-safe). But the generated app's `application.ex` does **not** attach
  `OpentelemetryEcto.setup`, does not start a metrics supervisor, and does not wire the wide-event
  schema. The guide says "in *your* `Application.start/2`, add…" — i.e. the builder does it by
  hand, and if they forget the `db_statement: :disabled` line the `no_plaintext_pii` tier will
  fail them *later*.
- **Delta:** the PII-safe observability posture is available but opt-in-by-hand; the pit-of-success
  would have the generator wire it so a new vertical is observable-and-safe on day one.
- **Joy:** M · **Effort:** S–M · **Harden** the generator's `application.ex` template + a
  `Samen.Observability.child_specs/1` helper.

### G8 — No getting-started tutorial / cookbook / root README; docs are reference-only
- **World-class:** a "build your first app in 10 minutes" tutorial, a recipes cookbook, an
  onboarding pit-of-success (Rails guides, Phoenix "up and running", Supabase quickstart).
- **Samen today:** `docs/guides/` has exactly **three** files — `generators.md`,
  `llm-grounding.md`, `scope-authoring.md` — all excellent but **reference/explanation**, not
  tutorial. There is **no root README** (`ls README*` → none), no per-app README except the one
  the generator emits, no end-to-end "zero to first vertical feature" walkthrough, no cookbook of
  recipes ("add a billing plan tier", "expose a field on the API", "add a Tier-1 custom field").
- **Delta:** a new builder has no guided on-ramp; they must synthesize the journey from three
  reference docs + reading demo/pawchart source. High time-to-first-productive-hour.
- **Joy:** M–H · **Effort:** S (writing) · **New** (a `docs/guides/getting-started.md` tutorial +
  a `cookbook.md`; a root README).

### G9 — Global abbrev-registry is a documented ergonomic tax on every mount
- **World-class:** naming is local; you never edit a shared global file to add a resource.
- **Samen today:** every scope/resource must reserve a permanent 3-letter abbrev in the ONE global
  `samen_core/priv/abbrev_registry.json`, and the builder must **commit that mutation alongside
  their app** (`generators.md` §"Operator notes", scope-authoring §8). Gate reports name this
  explicitly as an "ergonomic tax + an operator-TODO" residue. It fails compile on collision — good
  safety, but the collision-avoidance burden is on the human/agent, cross-repo.
- **Delta:** a builder in their own vertical repo must reach into samen_core's tree; parallel
  builders race for abbrevs; the coupling breaks the "my vertical is a sibling that only depends on
  core" mental model.
- **Joy:** M (friction every mount) · **Effort:** M · **Harden** (a `mix samen.abbrev.reserve`
  helper that allocates + commits, and/or a per-host namespace in the registry to reduce collision
  surface — this is an ADR-shaped decision, not a quick edit).

### G10 — Red-path / anti-tautology test scaffolding is hand-copied prose, not generated
- **World-class:** generators emit test files alongside code; property-test and factory helpers
  come for free.
- **Samen today:** scope-authoring §9 mandates **four** hand-written test files per scope (policy
  matrix property test, RBAC red path, vault routing, catalog-parity red path) **plus** a manual
  sabotage-probe run stated in the task report (§"Anti-tautology discipline"). The generator emits
  exactly one test (`record_vault_test.exs`) + one probe (`anti_tautology_probe.exs`) for the
  scaffolded resource; every subsequent resource's red-path suite is copied by hand. The verifier
  gate is inheritable (that part is a genuine strength — `ci.sh` is templated), but the
  *resource-level* red-path tests are not.
- **Delta:** the anti-tautology discipline that makes Samen trustworthy is a manual ritual for
  every new resource — easy to skip, hard to get right, unassisted.
- **Joy:** M · **Effort:** M · **New/Harden** (fold red-path test emission into the per-resource
  generator G2; ship a `Samen.RedPath` test-helper library so the four files become a few macro
  calls).

### G11 — Migration / expand-contract ergonomics are manual
- **World-class:** `ecto.gen.migration` + auto-diff from schema; Ash's migration generator
  diffs resources → migrations.
- **Samen today:** migrations are **hand-written** with abbrev-prefixed columns that must match
  what the resource produces — scope-authoring §8 literally says "introspect with `mix run` +
  `Samen.Catalog.fields/1` to get the exact column list — do not guess". `catalog_sync(@resources)`
  must be hand-appended; `@disable_ddl_transaction` is a footgun the guide warns about. Driftwood
  has an `expand_migrations` drill dir, so expand-contract is *practiced* but not *tooled*. No
  generator diffs a changed resource into a migration.
- **Delta:** the most error-prone hand-step (matching physical columns to the resource + not
  forgetting catalog_sync) is exactly what a migration generator should own.
- **Joy:** M · **Effort:** M–L · **Harden** (a `samen.gen.migration` that introspects
  `Samen.Catalog.fields/1` and emits the DDL + `catalog_sync` automatically — closes the
  catalog-parity red path at author time instead of gate time).

### G12 — LLM/agent grounding is strong but the loop is not packaged as tooling
- **World-class (emerging):** MCP servers that expose schema; agent-native "read the dict, propose,
  self-verify" harnesses; structured error output an agent can parse.
- **Samen today:** this is a **relative strength** — `schema.dict.json` is a genuinely good,
  self-contained, PII-flagged grounding artifact (`llm-grounding.md` §1), the gate is a real
  correctness oracle, and there's a runnable `agent_authoring_eval_test.exs` (6 seeded
  wrong/right cases). The residues: (a) no MCP/tool wrapper exposing the dict + verifier to an
  agent as callable tools; (b) verifier diagnostics are human prose, not machine-structured
  (JSON) output an agent can reliably parse to auto-fix; (c) the eval harness is Samen-internal,
  not a reusable "eval-your-agent-against-your-vertical" builder tool; (d) the dict deliberately
  omits vault-name / reveal-action / tier (honest residue in §5), so an agent needs a second
  introspection hop for those.
- **Delta:** the grounding is there; the *packaging* that would make agent-authoring turnkey
  (MCP tool surface, `--format json` on verifiers, reusable eval) is not.
- **Joy:** M–H (this is Samen's differentiator; sharpening it compounds) · **Effort:** M ·
  **Harden** (add `--format json` to verifiers; ship an MCP server over dict+verifiers; extract
  the eval into a builder-runnable form).

### G13 — Error-message quality at compile/gate time is good but uneven
- **World-class:** actionable, "did you mean", link-to-docs error messages (Rust, Elm, Ash's own
  Spark diagnostics).
- **Samen today:** the flagship errors are genuinely good — the missing-abbrev CompileError names
  the resource + says "Abbrevs are permanent and must be reserved" (`generators.md` §red-paths),
  and `llm-grounding.md` §3 documents the *honest boundary* of what each verifier catches. But
  quality is per-verifier and undocumented as a contract; there's no catalog of "here's every gate
  failure and how to fix it" (the analog of a Rails error-index). `pii_classify` being a heuristic
  and `pii_reads` being a non-sound taint match are honestly disclosed but a first-time builder
  hits a confusing "why did/didn't this fire" without a troubleshooting index.
- **Delta:** the pit-of-success needs a gate-failure cookbook so a builder (or agent) maps any
  red exit to a fix without reading verifier source.
- **Joy:** M · **Effort:** S · **New** (a `docs/guides/gate-failures.md` index) + **Harden**
  (standardize a diagnostic shape across verifiers).

---

## Ranking (joy × frequency-hit / effort)

Frequency = how often a builder hits it on the journey to (and past) first feature.

| Rank | Gap | Joy | Freq | Effort | Type |
|---|---|---|---|---|---|
| 1 | **G1** generator stops at data layer — no web/API/product scaffold | H | every app | M | harden |
| 2 | **G2** no resource/scope/field generators (only whole-app) | H | every resource | M | new |
| 3 | **G8** no getting-started tutorial / cookbook / root README | M-H | every builder, day 1 | S | new |
| 4 | **G3** no JSON:API scaffold — external surface hand-wired per resource | H | every API-exposing app | M | harden |
| 5 | **G5** no fixtures/factory/seed generator for a new vertical | M-H | every app | M | new |
| 6 | **G6** no deploy story (Fly/Neon/Docker), all operator-TODO | H | every ship | M | new |
| 7 | **G7** observability is a library, not wired by the generator | M | every app | S-M | harden |
| 8 | **G12** agent grounding strong but not packaged (MCP / --format json / reusable eval) | M-H | every agent-built app | M | harden |
| 9 | **G10** red-path/anti-tautology test scaffolding hand-copied | M | every resource | M | new/harden |
| 10 | **G11** migration/expand-contract ergonomics manual | M | every schema change | M-L | harden |
| 11 | **G9** global abbrev-registry ergonomic tax on every mount | M | every mount | M | harden (ADR) |
| 12 | **G4** no OpenAPI / client SDK | M | every public API | S-M | harden+new |
| 13 | **G13** gate-failure error index / diagnostic contract | M | every gate red | S | new |

**Rank rationale.** G1/G2 sit at the top because the generator asymmetry — instant gate-green,
slow time-to-visible-feature — is the single biggest surprise a builder hits, and it recurs for
*every* resource (G2). G8 is cheap and unblocks everyone on day one, so it out-prioritizes the
larger build items. G3/G5/G6 are all "the reference verticals prove it's thin, but the builder
copies it by hand" — high joy, medium effort, mostly harden-the-generator. The bottom of the
list (G4/G13) is real but lower-frequency or narrower.

---

## Overall assessment

Samen's *governance* substrate is world-class and its *runtime* reuse thesis is proven (pawchart
mounts four scopes' full product UI in ~12 lines of router). The Builder DX gap is almost entirely
one of **scaffolding lag**: everything the reference verticals do thinly at runtime, the generator
does not yet emit, so the builder reconstructs the web layer, API, seeds, observability, and deploy
by hand-copying demo/pawchart against prose checklists. The highest-leverage program is to push the
proven thin-mount patterns *up into generators* — a `--web`/`--api` app-gen path, a family of
per-resource/scope/tier generators that also emit the mandated red-path tests, a seed/factory
helper, and a deploy generator — plus a getting-started tutorial and a gate-failure index to create
a pit of success. Samen's agent-DX (schema.dict.json + gate-as-oracle + runnable eval) is a genuine
differentiator worth sharpening (MCP surface, machine-readable diagnostics) but is already ahead of
the field; the urgent work is closing the human/first-run scaffolding gap that currently makes
time-to-first-*visible*-feature much larger than the near-zero time-to-first-*gate-green*.
