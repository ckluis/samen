# WS-D — "Builder Joy" — Design

**Workstream:** D (G4 generator catch-up · G26 test scaffolds · G10 docs · G16 deploy).
**Status:** design (no code written by this doc).
**Date:** 2026-07-14.
**Depends on:** WS-A (SHIPPED — `docs/gate-ws-a.md`) and WS-B (SHIPPED — `docs/gate-ws-b.md`).
Both shipped verticals now prove the *real* patterns the generator must emit, so scaffolding
them is scaffolding the right thing (roadmap §"Sequencing logic": D follows A/B on purpose).

**North star (flagship AC, AC-X-1):** generate a fresh app end-to-end, run its full `ci.sh`,
boot it, and the generated tests + verifier gate + red-paths are green **without hand-editing** —
correct-by-construction the way pawchart is, but from zero, *including the web/API/seed/observability
layer*. Today the generator stops at a headless data layer (26 emitted files, no `*_web/`, no API,
no seeds, no observability); WS-D closes that gap. This proof becomes a permanent samen_core
`gen_app` test tier (extend `test/gen_app_test.exs` + `priv/gen_app_gate_probe.exs`).

---

## 0. Evidence base & ground truth (what exists today)

Read `docs/gap-discovery/builder-dx.md` (the ranked gaps) for the full evidence. The load-bearing
facts this design builds on, verified against the live tree this session:

**The generator today** (`samen_core/lib/samen/gen/{app.ex,templates.ex}`, `mix/tasks/samen.gen.app.ex`):
- Emits **26 files** (`templates.ex:14-41`): `mix.exs`, three `config/*.exs`, `application.ex`,
  `repo.ex`, `billing.ex`, `vertical.ex`, `aggregate.ex`, 11 substrate/resource migrations,
  `ci_bootstrap.exs`, `anti_tautology_probe.exs`, `test_helper.exs`, `data_case.ex`,
  `record_vault_test.exs`, `ci.sh`, `.gitignore`, `README.md`, and (dumped) `schema.dict.json`.
- `deps/0` is `samen_core` + `jason`/`stream_data`/`simple_sat` only — **no** `samen_web`,
  `phoenix`, `phoenix_live_view`, `ash_json_api`, `bandit`, `phoenix_pubsub`.
- `application.ex` template (`templates.ex:196-216`) supervises **Repo + Oban only** — no
  `OpentelemetryEcto.setup`, no metrics, no wide-event, no web plane.
- `ci.sh` template runs **17 steps** (compile → bootstrap → drift → 14 `samen.verify.*` →
  `mix test` → anti-tautology probe). It does **not** run `api_contract` (no API is emitted).
- The pure engine is a tiny dependency-free `<%= key %>` substitution (`app.ex:352-356`), a
  fail-closed `validate_against!/2`, and an idempotent append-only `reserve_abbrevs!/2`.
- Test tier: `test/gen_app_test.exs` (engine unit tests) + `priv/gen_app_gate_probe.exs` (the
  non-vacuous "generated gate flips under a `pii_`-on-aggregate sabotage" probe).

**What the reference verticals author by hand** (the templatable surfaces):
- **Web layer.** pawchart's `pawchart_web/` is 5 files / ~237 LOC: `endpoint.ex` (44),
  `router.ex` (113), `layouts.ex` (26), `page_controller.ex` (46, incl. `/healthz`),
  `error_html.ex` (8). The router mounts framework surfaces via **`Samen.Web.Router` macros**
  (`samen_module_routes/3`, `samen_operator_routes/2`, `samen_notifications_routes/3`,
  `samen_flags_routes/3`, `samen_chat_routes/3`, `samen_session_routes/1` —
  defined in `samen_web/lib/samen/web/router.ex`). Both planes mount through these macros; the
  tenant plane is `samen_module_routes`, the operator plane is the single `samen_operator_routes`.
- **JSON:API.** demo's `demo_web/api/` is 4 files: `router.ex` (`use AshJsonApi.Router,
  domains:, prefix: "/api/v1"`), `endpoint.ex` (`Plug.Builder`: KeyAuthPlug → PageLimitClamp →
  Router), `key_auth_plug.ex` (~143 LOC — SHA-256 digest lookup → `%Samen.Scope{}` actor with
  `:plane`/`:api_key`), and a local `page_limit_clamp.ex` mirror. The canonical
  `Samen.Web.Api.PageLimitClamp` lives in samen_web; samen_core-only apps mirror it. Per-resource
  `json_api do type/show_fields/routes/derive_filter?(false) end` blocks are **allowlist-by-default**
  (a field absent from `show_fields` is absent from every payload). `api_contract.v1.json` is the
  committed structural-break snapshot per vertical (verified by `mix samen.verify.api_contract`).
- **Seeds.** pawchart's `seeds.ex` is 613 LOC, driftwood's 1313. The **non-obvious** part is
  vaulted PII: a `full_name: %Samen.Type.FullName{first:, last:}` / `emails: [%{label:, address:}]`
  passed to `Ash.Changeset.for_create` routes through the vault chokepoint automatically — **no**
  subject-key or reveal boilerplate. The SHIPPED idiom to match EXACTLY is
  `samen_web/lib/samen/web/sample_data.ex:94-121` (WS-A A5): writes through the same create actions
  via `Mount.resource/scope`, so red-path tests scan raw rows and find no plaintext. **No
  `Samen.Factory` exists today** — a builder-facing vault-aware factory is a new module.
- **Observability.** No reference vertical wires it in `application.ex`. `Samen.Metrics`,
  `Samen.WideEvent`, `Samen.Tracer` are a library; `observability-guide.md:23-49` says the builder
  must add `OpentelemetryEcto.setup([:app, :repo], db_statement: :disabled)` to `start/2` by hand.
  **The trap:** forgetting `db_statement: :disabled` fails the `no_plaintext_pii` tier *later*.
  No `Samen.Observability.child_specs/1` helper exists.

**ADR-006 (abbrev registry) — the constraint that governs G4's registry work.** ADR-006 §4 already
**adopts Option B (per-host-namespaced ownership in ONE registry file) as the TARGET, explicitly
deferred behind the T6.4 generator** — i.e. WS-D is the sanctioned place to implement it. The
"one-owner-forever" invariant it protects is *permanence + collision-safety* (an abbrev, once owned,
is never recycled or reassigned). Per-host namespacing does **not** violate that rule — it makes
permanence *host-scoped* (demo's `cmp` and driftwood's `cmp` become distinct owners), which is
exactly the invariant the shared-global file over-constrains today. So WS-D may soften the tax via
(a) a `mix samen.abbrev.reserve` allocator that the generators call, and/or (b) Option-B host
namespacing — **provided** the global cross-host collision net stays as a safety layer and
append-only permanence holds within each host namespace.

---

## 1. Architecture — the shape of "Builder Joy"

WS-D is **scaffolding lag**, not architecture lag: every surface it emits is *already proven thin
at runtime* by pawchart/demo. The design rule is **push the proven thin-mount up into generators,
byte-for-byte matching the shipped idiom** — any drift between generated and reference code is a
finding (non-negotiable). Four scope pillars:

### 1.1 G4 — Generator catch-up (the running product)

Two moves: (a) make `mix samen.gen.app` emit a **running** product (web + API + seeds +
observability), gated behind opt-in flags so the headless path stays available; (b) add **post-app
generators** (`samen.gen.scope`, `samen.gen.resource`) so *every resource after the first* is
scaffolded, not hand-copied against a prose checklist.

**Emission model.** The generator stays a pure `<%= key %>` substitution engine over a file-set
list (`Samen.Gen.Templates.files/0`). WS-D grows that list conditionally on new flags, adds new
template functions, and adds new bindings (endpoint salts, pubsub server, port, API prefix,
per-resource `show_fields`). No new template *engine* — the existing substitution + fail-closed
validate + append-only reserve pattern is reused for the new generators.

**Flags on `samen.gen.app`:**
- `--web` (default **on**): emit the `*_web/` tree (endpoint, router with framework mounts, layouts,
  page controller with `/healthz`, error html), add `phoenix`/`phoenix_live_view`/`phoenix_html`/
  `bandit`/`phoenix_pubsub`/`samen_web` deps, wire the web plane + PubSub into `application.ex`,
  add endpoint/live_view/pubsub config. Router mounts the authored resource's scope plus the
  operator plane (`samen_operator_routes`) and notifications.
- `--api` (default **on** when `--web`): emit `*_web/api/{router,endpoint,key_auth_plug}.ex`, a
  local `page_limit_clamp.ex` mirror (samen_core-only apps) OR reuse `Samen.Web.Api.PageLimitClamp`
  (when `samen_web` is a dep), a per-resource `json_api do … end` allowlist on the authored
  resource, the committed `api_contract.v1.json` snapshot, and the `api_contract` ci.sh step.
- `--seeds` (default **on**): emit a `Samen.Factory`-backed `seeds.ex` + a `<app>.seed` mix task,
  vault-aware by construction.
- `--observability` (default **on**): wire `Samen.Observability.child_specs/1` (new helper) into
  `application.ex` incl. the un-forgettable `db_statement: :disabled`, plus the config keys the
  `no_plaintext_pii`/`metric_labels` tiers check.
- `--headless`: the escape hatch that reproduces today's 26-file data-only output (all four above off).

**New helpers in the framework (so verticals inherit, not copy):**
- `Samen.Observability.child_specs/1` (new, samen_core) — returns the OTel-Ecto setup +
  metrics/wide-event child specs a builder splices into `start/2`; owns the `db_statement: :disabled`
  default so it is *un-forgettable*. The generator calls it; existing verticals may adopt it.
- `Samen.Factory` (new, samen_core, builder-facing) — vault-aware create helpers
  (`Factory.create!(resource, attrs, scope)`, `Factory.person/…` convenience) that write PII
  through the same Ash create actions `SampleData` uses, so seeds match the shipped idiom EXACTLY.
- **Optional** endpoint/layout convenience: evaluate whether a `Samen.Web.Endpoint` `__using__`
  and a shared `Samen.Web.Layouts` reduce the 5-file web tree to fewer authored lines. Design
  bias: **emit thin files** rather than hide the endpoint behind a macro (a builder must own their
  endpoint's salts/port); a shared layout IS worth extracting (already a candidate — pawchart's
  `layouts.ex` is generic). Decision recorded in ADR-022.

**Post-app generators (`samen.gen.scope` / `samen.gen.resource`).** These automate the
`scope-authoring.md` §10 checklist: emit the scope mount macro + blueprint (org-scope policy,
RBAC, `pii do`, `SameOrgFk` on FKs), reserve abbrevs (via the new allocator, ADR-023), emit the
`Samen.Migration` with abbrev-prefixed columns + `catalog_sync`, regenerate `schema.dict.json`,
register the domain in both `:ash_domains` configs, and emit the **four G26 test files**. Tier
awareness (scope-authoring §7): Tier-0 config resources (org-scoped bounded-enum + admin-gated
writes) are the default; the generator does **not** scaffold Tier-1 custom-field / Tier-2
custom-object *mechanisms* (those are substrate, not authored resources — scope-authoring §7-8) but
it DOES emit the Tier-2 catalog-parity red-path test when the authored resource opts into a
custom-object bag (matching pawchart's `vaccine_lot_tier2_test.exs`).

**Registry-tax softening (ADR-023).** `mix samen.abbrev.reserve --host <app> --abbrev <abc> --owner
<Module>` allocates + commits an abbrev append-only; the gen.scope/gen.resource generators call it
so the human never hand-edits `abbrev_registry.json`. Whether to also land Option-B host namespacing
now (vs. keep the interim global file + allocator) is the ADR-023 decision — **scoped to not exceed
this workstream** per the "decompose cross-cutting changes" rule (Option B's registry+verifier
partition is a 50+ file change; if it exceeds a phase it ships as an ADR + phased follow-on, and
WS-D lands only the allocator + the namespaced *schema* the allocator writes).

### 1.2 G26 — Test scaffolds (the anti-tautology discipline, encoded)

The sabotage/red-path pattern is now well-established across 15+ gates. WS-D encodes it as a
**`Samen.RedPath` test-helper library** (new, samen_core `test/support` published for host use) so
the four mandated files (`scope-authoring.md` §9) become a few macro calls, and folds their emission
into `samen.gen.resource`/`samen.gen.scope`. The four files, per resource/scope, matching the
canonical Identity references (`demo/test/identity_*_test.exs`) and the pawchart vertical proofs:
1. **policy matrix** (property: cross-org read/write denied, org-less fail-closed, positive controls,
   PII masked-by-default) — `demo/test/identity_policy_matrix_test.exs` is the template.
2. **RBAC red path** (escalation denied through authorizer + pure decision fns, positive controls).
3. **vault routing** (each 🔒 field writes a `vt_*` token, plaintext nowhere in the domain row,
   `VaultField` last-line guard refuses a raw write).
4. **catalog-parity red path** (green when catalogued, deleting a catalog row flips the verifier).

Plus the emitted per-resource `anti_tautology_probe.exs` (the generator already emits one for the
scaffolded resource — G26 generalizes it so each new resource gets a probe binding a real guarantee
to a real sabotage).

### 1.3 G10 — Docs (verified against reality, no aspirational prose)

Four docs, every command **executed by CI or a test** where feasible (claim-evidence parity ethos):
1. **root `README.md`** (repo top level — none exists today): what Samen is, the app/vertical model,
   the 30-second `mix samen.gen.app` quickstart, links to the guides.
2. **zero-to-first-feature tutorial** (`docs/guides/getting-started.md`): the pawchart journey but
   **generated-app-first** — `mix samen.gen.app` → `mix ecto.setup` → `mix <app>.seed` →
   `mix phx.server` → see a working product → `mix samen.gen.resource` for the second resource →
   green `ci.sh`. Every command is exercised by the gen_app CI probe (AC-X-1) so the tutorial cannot
   drift from reality.
3. **cookbook** (`docs/guides/cookbook.md`): the top recipes — add a scope, bend billing (Tier-0
   config rows), add a feature flag, mount the operator cockpit, expose a field on the API. Each
   recipe cites the generator command or the exact framework macro, with the file it lands in.
4. **gate-failure index** (`docs/guides/gate-failures.md`): error message → which verifier fired →
   what it means → the fix. Sourced from the 14 `samen.verify.*` tiers + the drift/api_contract
   checks. This is the Rails-error-index analog builder-dx.md G13 asks for.

### 1.4 G16 — Deploy (Fly/Neon, generated, honest about operator-TODO)

A `mix samen.gen.deploy` (or a `--deploy` flag on gen.app) emitting, per app:
- `fly.toml` (app name, region, `[http_service]` on the endpoint port, health check hitting
  `/healthz`, release command running migrations).
- `Dockerfile` + `rel/env.sh.eex` / release config (`mix release` shape; the app already has the
  supervision tree the release boots).
- `config/runtime.exs` (new template) reading `DATABASE_URL`, `SECRET_KEY_BASE`, `PHX_HOST`, and
  the **KMS env** (`SAMEN_KMS_*`) — the crypto keystore the vault needs in prod.
- `docs/runbooks/deploy.md` per app: Neon per-product DB provisioning notes (branch-per-env), the
  secrets checklist (incl. KMS + `SECRET_KEY_BASE` generation), and an **explicit
  operator-TODO block** naming what stays human: real Fly account, real Neon project, real KMS
  keys, real OTLP exporter (mirrors the standing operator-TODO carries).

**Honesty rule:** the deploy templates are *fail-honest* — they compile and are structurally
correct, but they do NOT claim a live deploy. `config/runtime.exs` raises a clear error if a
required secret is absent (fail-closed), and the runbook is explicit about the human steps. No
aspirational "just run `fly deploy`" without the operator prerequisites named.

---

## 2. Generator emission inventory — file-by-file (today vs. after WS-D)

`[T]` = emitted today · `[NEW]` = new emission this workstream · `[MOD]` = existing template
modified. Flag column shows which flag gates the emission.

### 2.1 `mix samen.gen.app` — data layer (unchanged, `[T]`)
| File | Status |
|---|---|
| `mix.exs`, `config/{config,dev,test}.exs`, `application.ex`, `repo.ex`, `billing.ex`, `vertical.ex`, `aggregate.ex` | `[MOD]` — deps/config/supervision grow with flags |
| 11 substrate + resource migrations, `ci_bootstrap.exs`, `anti_tautology_probe.exs`, `test_helper.exs`, `data_case.ex`, `record_vault_test.exs`, `.gitignore`, `README.md`, `schema.dict.json` | `[T]` (README `[MOD]`) |
| `ci.sh` | `[MOD]` — adds `api_contract` step under `--api`; adds gen'd-resource red-path test runs |

### 2.2 `--web` (new, default on) — the running product
| File | Status | Templated from |
|---|---|---|
| `lib/<app>_web/endpoint.ex` | `[NEW]` | pawchart `endpoint.ex` (Bandit, live socket, session opts, port) |
| `lib/<app>_web/router.ex` | `[NEW]` | pawchart `router.ex` — `samen_module_routes` for the authored scope, `samen_operator_routes`, `samen_notifications_routes` |
| `lib/<app>_web/layouts.ex` | `[NEW]` | pawchart `layouts.ex` (or `use Samen.Web.Layouts` if extracted, ADR-022) |
| `lib/<app>_web/page_controller.ex` | `[NEW]` | pawchart — landing + `/healthz` |
| `lib/<app>_web/error_html.ex` | `[NEW]` | pawchart |
| `lib/<app>/application.ex` | `[MOD]` | add web plane: `{Phoenix.PubSub, name: <app>.PubSub}`, `<app>Web.Endpoint`, guarded by `start_repo?` |
| `mix.exs` | `[MOD]` | add `samen_web`, `phoenix`, `phoenix_live_view`, `phoenix_html`, `bandit`, `phoenix_pubsub` |
| `config/config.exs`, `config/dev.exs` | `[MOD]` | endpoint (adapter/http/secret_key_base/live_view salt/pubsub_server/render_errors), `server: true` in dev |

### 2.3 `--api` (new, default on with `--web`) — external surface
| File | Status | Templated from |
|---|---|---|
| `lib/<app>_web/api/router.ex` | `[NEW]` | demo — `use AshJsonApi.Router, domains:, prefix: "/api/v1"` |
| `lib/<app>_web/api/endpoint.ex` | `[NEW]` | demo — `Plug.Builder`: KeyAuthPlug → PageLimitClamp → Router |
| `lib/<app>_web/api/key_auth_plug.ex` | `[NEW]` | demo `key_auth_plug.ex` — SHA-256 digest → `%Samen.Scope{}` actor with `:plane`/`:api_key` |
| `lib/<app>_web/api/page_limit_clamp.ex` | `[NEW]` | demo local mirror (samen_core-only) OR reuse `Samen.Web.Api.PageLimitClamp` under `--web` |
| authored resource `json_api do type/show_fields/routes/derive_filter?(false) end` | `[MOD]` | demo Contact allowlist — allowlist-by-default |
| `api_contract.v1.json` | `[NEW]` | dumped via `mix samen.verify.api_contract --update` post-compile |
| `ci.sh` `api_contract` step | `[MOD]` | demo/driftwood ci.sh |

### 2.4 `--seeds` (new, default on)
| File | Status | Templated from |
|---|---|---|
| `lib/<app>/seeds.ex` | `[NEW]` | `samen_web/sample_data.ex` idiom via `Samen.Factory` — vault-aware creates |
| `lib/mix/tasks/<app>.seed.ex` | `[NEW]` | pawchart `pawchart.seed.ex` |
| `Samen.Factory` (framework) | `[NEW]` | new samen_core module — not per-app, shared |

### 2.5 `--observability` (new, default on)
| File | Status | Templated from |
|---|---|---|
| `lib/<app>/application.ex` | `[MOD]` | splice `Samen.Observability.child_specs(:<app>)` incl. `db_statement: :disabled` |
| `config/config.exs` | `[MOD]` | `:opentelemetry_ecto` `db_statement: :disabled` + exporter stub with operator-TODO |
| `Samen.Observability` (framework) | `[NEW]` | new samen_core helper module |

### 2.6 `--deploy` / `mix samen.gen.deploy` (new, default off — opt-in)
| File | Status | Templated from |
|---|---|---|
| `fly.toml`, `Dockerfile`, `rel/env.sh.eex` (release config) | `[NEW]` | new (Fly/Elixir release conventions) |
| `config/runtime.exs` | `[NEW]` | new — `DATABASE_URL`/`SECRET_KEY_BASE`/`PHX_HOST`/`SAMEN_KMS_*`, fail-closed on missing |
| `docs/runbooks/deploy.md` (in app) | `[NEW]` | new — Neon branch-per-env, secrets checklist, operator-TODO block |

### 2.7 `mix samen.gen.scope` / `mix samen.gen.resource` (new tasks)
| File | Status |
|---|---|
| `lib/samen/scopes/<scope>.ex` mount macro + `blueprint.ex` (org-scope, RBAC, `pii do`, `SameOrgFk`) | `[NEW]` |
| migration (abbrev-prefixed cols + `catalog_sync`), domain registration in both `:ash_domains` | `[NEW]` |
| the **four G26 test files** + `anti_tautology_probe.exs` for the resource | `[NEW]` |
| abbrev reservation via `mix samen.abbrev.reserve` (no hand-edit) | `[NEW]` |
| `schema.dict.json` regenerated | `[MOD]` |

---

## 3. What stays inherited (must NOT be re-emitted — drift guard)

These are provided by samen_web/samen_core and are mounted/called, never copied into the generated
app (re-emitting them is a finding): the `Samen.Web.Router` macros; `Samen.Web.Api.PageLimitClamp`
(when `samen_web` is a dep); `Samen.Api.PiiResolution`; the kit (`list_view`, form/modal,
`empty_state`, `ListLive`); `Mount`/`Reads`; `SampleData`/`FirstRun`; the operator cockpit
surfaces; the flag engine; the `pae` `track/1` emission; every `samen.verify.*` verifier;
`Samen.Metrics`/`WideEvent`/`Tracer`. The generated resource's `use Samen.Resource` write-guard,
bounded reads, and masking are inherited too. **AC-G4-9 measures this:** the generated app's
*authored* web/API/seed LOC must be within a small delta of pawchart's proven thin-mount (no
re-implemented framework code).

---

## 4. The gen_app CI probe (flagship proof, AC-X-1)

Extend the existing `gen_app` tier:
- `priv/gen_app_gate_probe.exs` today generates a headless app into a scratch sibling, runs `ci.sh`,
  sabotages a `pii_`-on-aggregate column, proves the gate flips, reverts. WS-D **extends** it to
  generate with `--web --api --seeds --observability` (the full running product), run the full
  `ci.sh` (now incl. `api_contract` + the gen'd red-path tests), **boot the endpoint** (start the
  supervision tree in `:test`-with-repo mode, hit `/healthz` → 200 and one framework route → 200),
  then run **two additional sabotages** binding the new surfaces to real correctness:
  (a) delete a field from an API `show_fields` allowlist → `api_contract` step must flip to fail;
  (b) drop `db_statement: :disabled` from the wired observability → `no_plaintext_pii` tier must
  flip to fail. Revert both, prove green recovery, byte-exact, zero scratch residue.
- `test/gen_app_test.exs` gains cases for the new bindings, new flags, and the new generators
  (`samen.gen.resource` emits four red-path files that pass; `samen.abbrev.reserve` is idempotent +
  fail-closed on cross-owner collision within a host namespace).

**Non-vacuity is the whole point:** a green that only asserts `ci.sh exits 0` proves nothing if the
gate is toothless — every new proof carries its sabotage→flip→revert.

---

## 5. Acceptance criteria (numbered, testable)

### G4 — Generator catch-up
- **AC-G4-1** `mix samen.gen.app --web` emits the 5-file `*_web/` tree; the generated router mounts
  the authored scope + operator plane + notifications via `Samen.Web.Router` macros only (zero
  hand-authored LiveView modules). *Test:* gen_app_test asserts the emitted router's macro calls;
  the CI probe boots and gets 200 on a framework route.
- **AC-G4-2** `mix samen.gen.app --api` emits `*_web/api/{router,endpoint,key_auth_plug,page_limit_clamp}.ex`
  + a per-resource allowlist + a committed `api_contract.v1.json`; the generated `ci.sh` runs
  `samen.verify.api_contract` and it passes. *Test:* CI probe.
- **AC-G4-3** The generated API allowlist is **deny-by-default**: a field not in `show_fields` is
  absent from every payload (incl. `?fields=`). *Test:* red-path in the gen'd suite — request a
  non-allowlisted vault column, assert absent; positive control asserts an allowlisted field present.
- **AC-G4-4** `mix samen.gen.app --seeds` emits `seeds.ex` + `<app>.seed`, vault-aware: seeded 🔒
  fields route through the vault (raw domain row holds `vt_*`, plaintext nowhere). *Test:* the
  gen'd vault-routing test scans raw rows for seeded plaintext and finds none.
- **AC-G4-5** `Samen.Factory` writes PII through the same Ash create actions as `SampleData`
  (byte-identical vault path). *Test:* a samen_core test proves a `Factory.create!` and a
  `SampleData` create produce the same at-rest token shape; sabotage: a raw-column write attempt
  is refused by the WriteGuard.
- **AC-G4-6** `mix samen.gen.app --observability` wires `Samen.Observability.child_specs/1` into
  `application.ex` with `db_statement: :disabled` present; the generated `no_plaintext_pii` +
  `metric_labels` tiers pass. *Test:* CI probe sabotage (b) — dropping `db_statement: :disabled`
  flips `no_plaintext_pii` to fail.
- **AC-G4-7** `mix samen.gen.scope` / `samen.gen.resource` emit a scope/resource that compiles,
  catalogs (`catalog_parity` green), reserves its abbrev via `samen.abbrev.reserve`, and passes the
  full gate — no hand-edit. *Test:* a gen_app_test scenario generates a second resource into the
  scratch app and runs its `ci.sh`.
- **AC-G4-8** `mix samen.abbrev.reserve` is idempotent, fail-closed on cross-owner collision within
  a host namespace, and never recycles an abbrev (ADR-006 permanence holds). *Test:* engine unit
  tests (idempotent re-run no-op; different-owner raises; permanence preserved).
- **AC-G4-9** The generated running app's *authored* (non-framework) web+API+seed LOC is within a
  small delta of pawchart's proven thin-mount (framework code is inherited, not re-emitted).
  *Test:* an LOC-parity assertion in gen_app_test comparing emitted authored LOC to a pinned bound.
- **AC-G4-10** `--headless` reproduces today's 26-file data-only output exactly (the escape hatch;
  no regression to the existing correct-by-construction claim). *Test:* the existing headless probe
  still passes unchanged.

### G26 — Test scaffolds
- **AC-G26-1** `samen.gen.resource`/`samen.gen.scope` emit the four mandated test files (policy
  matrix property, RBAC red path, vault routing, catalog-parity red path) + a resource
  `anti_tautology_probe.exs`, structurally matching the Identity canonical references. *Test:* the
  emitted files run green in the scratch app; gen_app_test asserts their presence + shape.
- **AC-G26-2** `Samen.RedPath` reduces each of the four files to a few macro calls; a red-path
  macro's guarantee flips under sabotage. *Test:* a samen_core test sabotages a `RedPath` assertion
  target (e.g. `OrgScope.filter → expr(true)`) and proves the generated matrix test fails.
- **AC-G26-3** The emitted catalog-parity red-path test flips when a catalog row is deleted (the
  anti-tautology probe is real, not vacuous). *Test:* mirrors
  `identity_catalog_parity_red_path_test.exs` — delete a `fld_field` row → verifier fails.

### G10 — Docs
- **AC-G10-1** A root `README.md` exists with a runnable `mix samen.gen.app` quickstart. *Test:* a
  CI step (or gen_app probe) runs the quickstart command block and it succeeds.
- **AC-G10-2** `getting-started.md` is generated-app-first; **every** command in it is executed by
  the gen_app CI probe (no aspirational command). *Test:* a doc-command extractor asserts each
  fenced command appears in the probe's executed set (or is explicitly marked operator-TODO).
- **AC-G10-3** `cookbook.md` covers ≥5 recipes (add a scope, bend billing, add a flag, mount the
  cockpit, expose a field on the API), each citing the exact generator command or framework macro +
  the file it lands in. *Test:* a structural doc test asserts each recipe names a real task/macro
  that exists in the tree.
- **AC-G10-4** `gate-failures.md` maps every `samen.verify.*` tier + drift + api_contract to
  {message → verifier → meaning → fix}. *Test:* a doc test asserts every `mix/tasks/samen.verify.*`
  task has a corresponding entry (no verifier undocumented).

### G16 — Deploy
- **AC-G16-1** `mix samen.gen.deploy` (or `--deploy`) emits `fly.toml`, `Dockerfile`, release
  config, and `config/runtime.exs` for the generated app; the app still compiles + passes `ci.sh`
  (deploy artifacts don't break the gate). *Test:* CI probe runs with `--deploy` and `ci.sh` stays
  green.
- **AC-G16-2** `config/runtime.exs` is fail-closed: a missing required secret (`SECRET_KEY_BASE`,
  `DATABASE_URL`, or `SAMEN_KMS_*`) raises a clear, named error rather than booting insecurely.
  *Test:* a unit test loads runtime.exs with a secret unset and asserts it raises naming the secret.
- **AC-G16-3** The emitted `docs/runbooks/deploy.md` contains an explicit operator-TODO block naming
  the human prerequisites (Fly account, Neon project, KMS keys, OTLP exporter) — honest, not
  aspirational. *Test:* a structural doc test asserts the operator-TODO section exists with the four
  named items.

### Cross-cutting
- **AC-X-1 (flagship)** Generate a fresh app with `--web --api --seeds --observability`, run its
  full `ci.sh`, boot it (`/healthz` + one framework route → 200), and the generated tests + verifier
  gate + red-paths are **green without hand-editing**; the two new sabotages (API allowlist,
  observability `db_statement`) each flip the gate and revert clean, byte-exact, zero scratch
  residue. *Test:* the extended `priv/gen_app_gate_probe.exs`, run by the `gen_app` samen_core tier.
- **AC-X-2** All suites + every `ci.sh` (root, demo, driftwood, pawchart, and the generated scratch
  app) green before and after; verifier gates + destruction-oracle equivalents green; an adversarial
  gate is run per phase and workstream-wide.

---

## 6. Explicitly out of scope (WS-D does NOT do these)

- **G4 (OpenAPI/client SDK)** from builder-dx.md — enabling the AshJsonApi OpenAPI extension + a
  `mix samen.api.openapi` dump and any TS/Python SDK gen. Deferred (roadmap G22-adjacent).
- **G22 agent-grounding packaging** (MCP server over dict+verifiers, `--format json` on verifiers,
  reusable eval) — WS-D uses the existing grounding assets but does not repackage them; that is a
  separate P2 workstream.
- **G11 migration/expand-contract generator** (`samen.gen.migration` diffing `Samen.Catalog.fields/1`
  into DDL) — the resource generator emits a migration *for the resource it creates*, but a general
  schema-diff migration generator is out of scope (builder-dx.md G11, larger effort).
- **Full Option-B registry+verifier host-partition** if it exceeds a single phase — WS-D lands the
  `samen.abbrev.reserve` allocator + the namespaced schema it writes; a full partition of the
  registry file + `Samen.Verifiers.AbbrevRegistry` ships as an ADR + phased follow-on (per the
  "decompose cross-cutting changes" rule) rather than being forced into this workstream.
- **Real deploy execution** — no live Fly/Neon/KMS provisioning; those stay operator-TODO. WS-D
  emits structurally-correct, fail-honest artifacts + runbooks only.
- **New product surfaces** — WS-D scaffolds the surfaces WS-A/WS-B already shipped; it introduces no
  new tenant/operator features.

---

## 7. Non-negotiables (baked into the ACs above)

- **The proof is generative** (AC-X-1): correct-by-construction from zero, incl. web/API/seed/obs.
- **Generated == reference, byte-for-byte** (AC-G4-9 + §3 drift guard): any drift is a finding.
- **Docs verified against reality** (AC-G10-2): every tutorial command run by the probe/CI.
- **Fail-closed proof** (AC-X-2 + every red-path AC): guarantees green + red-path + anti-tautology
  probed; all suites + every `ci.sh` green; adversarial gate per phase; ADRs for load-bearing
  decisions.

## 8. New abbrev registry entries

**None.** WS-D emits *generators* and *docs*; it introduces no new samen_core scope/resource that
owns an abbrev. The generated apps reserve their own abbrevs at generation time (via the new
allocator), and the gen_app probe cleans them up. The `Samen.Factory` / `Samen.Observability` /
`Samen.RedPath` helpers are behavior modules, not abbrev-owning resources. Confirmed.
