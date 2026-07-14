# WS-D — "Builder Joy" — Build Plan

**Sizing rule (operator standing order):** SMALL serialized units — **one deliverable per `agent()`
call**, each banking in ~10-20 min, each phase independently committable + gate-able. Default agent
fan-out concurrency = 1 (serialize; session-limit hits then strand ≤1 straggler). Model routing per
unit below (`sonnet` = mechanical scaffolding/template port + tests; `opus` = load-bearing framework
helpers, the registry-schema change, the flagship probe, and every adversarial gate).

**Gate discipline:** every phase ends with a phase-gate (adversarial, findings fixed in-phase); the
workstream ends with a round-2 whole-workstream re-gate (`docs/gate-ws-d.md`). All suites + every
`ci.sh` (root/demo/driftwood/pawchart + the generated scratch app) green before/after each phase.

**Design inputs:** `docs/ws-d/design.md` (ACs), ADR-022/023/024. AC IDs referenced per unit.

**Dependency spine:** D1 (framework helpers) → D2 (web) → D3 (API) → D4 (seeds) → D5 (obs) →
D6 (flagship probe binds D2-D5) → D7 (post-app generators + G26) → D8 (registry allocator) →
D9 (docs) → D10 (deploy) → D11 (workstream gate). D8 can start after D7's generators exist but must
land before D9's cookbook documents it. Docs (D9) come late so they document shipped reality.

---

## Phase D1 — Framework helpers (the inheritable pieces)
*Prereq for the generator emitting inheritable code, not copies.*

- **D1.1** `Samen.Observability.child_specs/1` (samen_core) — OTel-Ecto setup +
  metrics/wide-event child specs, owning the `db_statement: :disabled` default (un-forgettable).
  Unit test proves the returned specs carry `db_statement: :disabled` and a sabotage removing it is
  detectable. Deps: none. AC: AC-G4-6. Model: **opus** (load-bearing PII-safety default).
- **D1.2** `Samen.Factory` (samen_core, builder-facing) — vault-aware create helpers matching the
  `SampleData` idiom byte-for-byte. Test: a `Factory.create!` and a `SampleData` create produce the
  same at-rest token shape; WriteGuard refuses a raw-column write. Deps: none. AC: AC-G4-5.
  Model: **opus** (vault-path correctness).
- **D1.3** `Samen.RedPath` test-helper library (samen_core test/support, published for host use) —
  macros collapsing the four mandated test files to a few calls; a `RedPath` macro's guarantee flips
  under sabotage. Test: sabotage `OrgScope.filter → expr(true)` and prove a `RedPath` matrix assertion
  fails. Deps: none. AC: AC-G26-2. Model: **opus** (anti-tautology machinery).
- **D1.4** Extract the generic root layout into `Samen.Web.Layouts` (samen_web); prove pawchart +
  driftwood still render through it (adopt or keep-compat). Deps: none. AC: AC-G4-1 (drift guard).
  Model: **sonnet**.
- **D1.5** *Phase D1 gate* — adversarial gate over D1.1-D1.4: sabotage each helper's load-bearing
  guarantee, prove flip + byte-exact revert; all suites green. Deps: D1.1-D1.4. Model: **opus**.

## Phase D2 — Generator emits the web layer (`--web`)
- **D2.1** Add `--web`/`--headless` flags + the web bindings (endpoint salts, port, pubsub server) to
  the gen engine; grow `Templates.files/0` conditionally. `--headless` reproduces the 26-file output
  exactly. Test: gen_app_test asserts headless output byte-identical to today + web adds the tree.
  Deps: D1. AC: AC-G4-1, AC-G4-10. Model: **opus** (engine change, must not regress the existing claim).
- **D2.2** Template the 5-file `*_web/` tree (endpoint, router with `Samen.Web.Router` macro mounts +
  operator plane + notifications, layouts via D1.4, page controller + `/healthz`, error html) + the
  web deps + web-plane `application.ex` + endpoint/config wiring. Ported from pawchart byte-for-byte.
  Deps: D2.1. AC: AC-G4-1. Model: **sonnet** (mechanical port).
- **D2.3** *Phase D2 gate* — generate a `--web` app in scratch, run `ci.sh`, **boot it, hit `/healthz`
  + one framework route → 200**, prove the router mounts only framework macros (zero authored
  LiveViews). Deps: D2.1-D2.2. AC: AC-G4-1. Model: **opus**.

## Phase D3 — Generator emits the JSON:API (`--api`)
- **D3.1** Template the 4-file `*_web/api/` tree (AshJsonApi router, Plug endpoint, KeyAuthPlug,
  PageLimitClamp mirror OR `Samen.Web.Api.PageLimitClamp` reuse) + `ash_json_api` dep + the `api_contract`
  `ci.sh` step. Ported from demo. Deps: D2. AC: AC-G4-2. Model: **sonnet**.
- **D3.2** Emit the per-resource **deny-by-default** `json_api do type/show_fields/routes/derive_filter?(false)`
  allowlist on the authored resource + dump `api_contract.v1.json`. Emit a gen'd red-path proving a
  non-allowlisted vault column is absent + a positive control. Deps: D3.1. AC: AC-G4-3. Model: **opus**
  (deny-by-default is a masking-adjacent guarantee).
- **D3.3** *Phase D3 gate* — generate `--web --api`, run `ci.sh` incl. `samen.verify.api_contract`;
  sabotage: delete a `show_fields` entry → `api_contract` flips to fail; revert. Deps: D3.1-D3.2.
  AC: AC-G4-2, AC-G4-3. Model: **opus**.

## Phase D4 — Generator emits seeds (`--seeds`)
- **D4.1** Template `seeds.ex` (via `Samen.Factory`) + `<app>.seed` mix task, vault-aware. The gen'd
  vault-routing test scans raw rows for seeded plaintext and finds none. Deps: D1.2, D2. AC: AC-G4-4.
  Model: **sonnet** (Factory does the load-bearing work; this is a port).
- **D4.2** *Phase D4 gate* — generate `--web --api --seeds`, run seed, prove raw rows hold `vt_*`,
  plaintext nowhere; positive control reads clear on the tenant plane. Deps: D4.1. AC: AC-G4-4.
  Model: **opus**.

## Phase D5 — Generator wires observability (`--observability`)
- **D5.1** Splice `Samen.Observability.child_specs/1` into the `application.ex` template + the config
  keys (`db_statement: :disabled` + exporter stub w/ operator-TODO). Deps: D1.1, D2. AC: AC-G4-6.
  Model: **sonnet** (helper does the work; this wires it).
- **D5.2** *Phase D5 gate* — generate full, run `ci.sh`; sabotage: drop `db_statement: :disabled` →
  `no_plaintext_pii` tier flips to fail; revert. Deps: D5.1. AC: AC-G4-6. Model: **opus**.

## Phase D6 — Flagship gen_app CI probe (the generative proof)
- **D6.1** Extend `priv/gen_app_gate_probe.exs`: generate `--web --api --seeds --observability`, run
  full `ci.sh`, boot + `/healthz` + a framework route → 200, run the two new sabotages (API allowlist,
  observability `db_statement`) with byte-exact revert + zero scratch residue. Extend
  `test/gen_app_test.exs` for the new flags/bindings. Wire the probe into the samen_core `gen_app`
  test tier permanently. Deps: D2-D5. AC: **AC-X-1**, AC-G4-9. Model: **opus** (the flagship proof).
- **D6.2** LOC-parity assertion — the generated running app's authored web+API+seed LOC is within a
  pinned bound of pawchart's thin-mount (framework inherited, not re-emitted). Deps: D6.1. AC: AC-G4-9.
  Model: **sonnet**.
- **D6.3** *Phase D6 gate* — adversarial re-run of the full probe from clean; confirm non-vacuity of
  both new sabotages; all `ci.sh` green. Deps: D6.1-D6.2. AC: AC-X-1, AC-X-2. Model: **opus**.

## Phase D7 — Post-app generators + G26 test scaffolds
- **D7.1** `mix samen.gen.scope` — emit scope mount macro + blueprint (org-scope, RBAC, `pii do`,
  `SameOrgFk`), migration + `catalog_sync`, domain registration in both `:ash_domains`, `schema.dict`
  regen. Automates scope-authoring §10. Deps: D6 (proven app to add into). AC: AC-G4-7. Model: **opus**
  (correctness-critical scaffold).
- **D7.2** `mix samen.gen.resource` — emit a resource into an existing scope + the **four G26 test
  files** (via `Samen.RedPath`) + a resource `anti_tautology_probe.exs`, matching the Identity
  canonical shape. Deps: D7.1, D1.3. AC: AC-G4-7, AC-G26-1, AC-G26-3. Model: **opus**.
- **D7.3** *Phase D7 gate* — generate a second resource into the scratch app, run its `ci.sh`
  (all four red-paths green); sabotage: delete a catalog row → catalog-parity flips; revert. Prove
  no hand-edit needed. Deps: D7.1-D7.2. AC: AC-G4-7, AC-G26-1/2/3. Model: **opus**.

## Phase D8 — Abbrev allocator + host-namespaced schema (ADR-023)
- **D8.1** `mix samen.abbrev.reserve` allocator + host-namespaced registry schema + read-compat shim +
  one-time migration of existing flat rows; route the generators' reserve path through it. Idempotent,
  fail-closed on cross-owner collision within a host namespace, global cross-host net retained. If the
  full verifier host-partition exceeds this unit, land allocator + schema + shim and file the
  verifier-partition follow-on ADR (decompose rule). Deps: D7 (generators call it). AC: AC-G4-8.
  Model: **opus** (registry invariant + schema migration).
- **D8.2** *Phase D8 gate* — allocator idempotency + permanence + collision red-paths; a registry
  JSON↔reader round-trip test; verticals still compile against the namespaced schema. Deps: D8.1.
  AC: AC-G4-8. Model: **opus**.

## Phase D9 — Docs (verified against reality)
- **D9.1** Root `README.md` with a runnable `mix samen.gen.app` quickstart; a CI step runs the
  quickstart block. Deps: D6. AC: AC-G10-1. Model: **sonnet**.
- **D9.2** `docs/guides/getting-started.md` — generated-app-first tutorial; a doc-command extractor
  asserts every fenced command is in the gen_app probe's executed set (or marked operator-TODO). Deps:
  D6, D7. AC: AC-G10-2. Model: **sonnet**.
- **D9.3** `docs/guides/cookbook.md` — ≥5 recipes (add scope, bend billing, add flag, mount cockpit,
  expose API field), each citing a real task/macro + the file it lands in; a structural doc test
  asserts each names a real symbol. Deps: D7, D8. AC: AC-G10-3. Model: **sonnet**.
- **D9.4** `docs/guides/gate-failures.md` — {message → verifier → meaning → fix} for every
  `samen.verify.*` + drift + api_contract; a doc test asserts no verifier is undocumented. Deps: D6.
  AC: AC-G10-4. Model: **sonnet**.
- **D9.5** *Phase D9 gate* — run every doc-verification test; confirm no aspirational command. Deps:
  D9.1-D9.4. AC: AC-G10-1/2/3/4. Model: **sonnet**.

## Phase D10 — Deploy (fail-honest, ADR-024)
- **D10.1** `mix samen.gen.deploy` (or `--deploy`) — emit `fly.toml`, `Dockerfile`, release config,
  `config/runtime.exs` (fail-closed on missing `SECRET_KEY_BASE`/`DATABASE_URL`/`SAMEN_KMS_*`), and a
  per-app `docs/runbooks/deploy.md` with a named operator-TODO block. Deps: D6. AC: AC-G16-1/2/3.
  Model: **opus** (fail-closed runtime + KMS env correctness).
- **D10.2** *Phase D10 gate* — generate with `--deploy`, `ci.sh` still green; runtime.exs raises on a
  missing secret (named); runbook has the operator-TODO block. Deps: D10.1. AC: AC-G16-1/2/3.
  Model: **opus**.

## Phase D11 — Workstream gate
- **D11.1** Vertical adoption proof — driftwood + pawchart demonstrate the new inheritable helpers
  (`Samen.Observability`/`Samen.Factory` adopted or compat-proven; zero re-implemented framework code).
  Deps: D1-D10. AC: AC-G4-9, AC-X-2. Model: **opus**.
- **D11.2** *WS-D whole-workstream adversarial re-gate* (`docs/gate-ws-d.md`) — all ACs mapped to named
  tests; the flagship probe re-run non-vacuously; cross-phase hunts (e.g. `--deploy` × observability
  wiring; gen.resource × abbrev allocator); all suites + every `ci.sh` green with exact counts; carries
  recorded. Deps: D11.1. AC: all. Model: **opus**.

---

## Model-routing summary
- **opus** (load-bearing): D1.1/1.2/1.3/1.5, D2.1/2.3, D3.2/3.3, D4.2, D5.2, D6.1/6.3, D7.1/7.2/7.3,
  D8.1/8.2, D10.1/10.2, D11.1/11.2 — framework helpers, engine change, deny-by-default, every
  vault/masking/registry guarantee, the flagship probe, every adversarial gate.
- **sonnet** (mechanical): D1.4, D2.2, D3.1, D4.1, D5.1, D6.2, D9.1/9.2/9.3/9.4/9.5 — template ports
  of proven reference code, LOC assertion, and the doc units (docs are verified by tests written
  under opus gates, so the writing itself is sonnet-appropriate).

## Estimated workflow-agent count
**~34 agent calls** — 27 build/gate units above + the standard per-phase overhead the operator's
serialized loop adds (re-runs on session-limit strands, ≤1 straggler per phase resumed). Budget
~34-38 including strand re-runs.
