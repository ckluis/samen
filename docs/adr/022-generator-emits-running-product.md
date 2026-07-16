# ADR-022 — The generator emits a running product (flagged web/API/seed/observability), not a headless data layer

**Status:** Accepted (WS-D design, 2026-07-14)
**Context workstream:** WS-D "Builder Joy" (G4)
**Supersedes:** nothing; extends the T6.4 `mix samen.gen.app` contract.

## 1. Context

`mix samen.gen.app` is "correct-by-construction, gate-green on first run" — a real, load-bearing
claim (`samen.gen.app.ex:12`). But the app it emits is a **headless data-and-gate scaffold**: 26
files, `deps/0` = `samen_core` + jason/stream_data/simple_sat only, `application.ex` supervising
Repo + Oban, no `*_web/`, no API, no seeds, no observability wiring (verified against
`templates.ex:14-41,196-216`). The builder's first output is a green `ci.sh`, not a running UI.
To reach a running product they reverse-engineer pawchart/demo by hand: the 5-file `*_web/` tree,
the 4-file JSON:API tree, a 600-line seeds module, and the observability wiring — each proven
*thin at runtime* (pawchart mounts its full product UI in a ~113-line router of macro calls) but
**not emitted**. builder-dx.md ranks this the #1 builder gap.

Now that WS-A (kit/CRUD/notifications/empty-states) and WS-B (operator cockpit/flags/analytics)
have shipped, the framework surfaces the generator would scaffold are *real*, so scaffolding them
is scaffolding the right thing (the reason WS-D deliberately follows A/B).

## 2. Decision

**`mix samen.gen.app` emits a RUNNING product by default, via opt-in flags that gate each layer,
with `--headless` reproducing today's exact 26-file output.** Specifically:

- `--web` (default **on**): the 5-file `*_web/` tree (endpoint, router mounting framework surfaces
  via `Samen.Web.Router` macros, layouts, page controller with `/healthz`, error html) + the web
  deps (`samen_web`, `phoenix`, `phoenix_live_view`, `phoenix_html`, `bandit`, `phoenix_pubsub`) +
  the web plane in `application.ex` + endpoint/live_view/pubsub config.
- `--api` (default **on** with `--web`): the 4-file `*_web/api/` tree (AshJsonApi router, Plug
  endpoint, KeyAuthPlug, PageLimitClamp) + a per-resource **deny-by-default** `json_api` allowlist +
  the committed `api_contract.v1.json` + the `api_contract` `ci.sh` step.
- `--seeds` (default **on**): a `Samen.Factory`-backed `seeds.ex` + `<app>.seed` mix task,
  vault-aware by construction.
- `--observability` (default **on**): `Samen.Observability.child_specs/1` spliced into
  `application.ex` with `db_statement: :disabled` made **un-forgettable** (owned by the helper's
  default), plus the config keys the `no_plaintext_pii`/`metric_labels` tiers check.
- `--headless`: all four off → today's data-only output, unchanged.

**Emission mechanism:** the existing pure `<%= key %>` substitution engine + fail-closed
`validate!` + append-only reserve is reused as-is. WS-D only *grows the file-set list conditionally*
and adds template functions + bindings. No new template engine.

**Two new framework helpers so verticals inherit rather than copy:**
- `Samen.Observability.child_specs/1` (samen_core) — owns the `db_statement: :disabled` default.
- `Samen.Factory` (samen_core, builder-facing) — vault-aware creates matching the shipped
  `SampleData` idiom byte-for-byte.

**Endpoint/layout extraction (the sub-decision):** the endpoint is emitted as a thin file (the
builder must own their salts/port/secret_key_base — hiding it behind a macro would be a footgun);
the generic root **layout IS extracted** into `Samen.Web.Layouts` (pawchart/driftwood layouts are
already generic), so the emitted `layouts.ex` is a one-liner `use Samen.Web.Layouts` or is dropped
entirely. This keeps the "framework code is inherited, not re-emitted" invariant.

## 3. Consequences

**Positive.** The builder's first `mix phx.server` shows a working product; time-to-first-*visible*-
feature collapses to match the near-zero time-to-first-gate-green. The correct-by-construction claim
now covers the *whole* product, provable by the extended gen_app CI probe (AC-X-1) that boots the
app and hits `/healthz`. The `db_statement: :disabled` trap becomes un-forgettable. Existing
verticals may adopt `Samen.Observability`/`Samen.Factory` to shed their own hand-wiring.

**Negative / accepted.** The generator's dependency surface grows (it now emits apps with
phoenix/ash_json_api deps) and the CI probe gets slower (it compiles + boots a web app, not just a
data layer). The generated app is bigger, so the "generated == reference byte-for-byte" drift guard
(AC-G4-9) matters more. RESOLUTION (D11 gate WS-D-G1-P2-2): the numeric LOC-parity
assertion named in build-plan D6.2 was superseded by STRUCTURAL drift-guard tests, which
bind the guarantee more strongly than an LOC bound: gen_app_test asserts the emitted router
mounts framework macros ONLY with zero authored LiveViews (:366), shell HTML is inherited
never re-emitted (:400), and PageLimitClamp is inherited never re-emitted (:530/:552). A
regression re-implementing framework code while still mounting the macros is caught by
these; a pinned LOC number would only drift with legitimate template growth.

**Neutral.** `--headless` preserves the existing narrow claim for callers that want only the data
layer; no existing behavior is removed.

## 4. Alternatives considered

- **Keep the generator headless; ship only docs telling builders how to hand-wire web/API/seeds.**
  Rejected — this is exactly the status quo builder-dx.md indicts; docs do not remove the
  hand-copy tax or the `db_statement` trap.
- **A separate `mix samen.gen.web` companion generator (never fold into gen.app).** Rejected as the
  *default* — a new builder should get a running product from one command; but the flags make the
  layers composable, which captures most of the benefit of a companion without a second entrypoint.
  (The post-app `samen.gen.scope`/`samen.gen.resource` generators DO exist separately — see
  ADR-023/design §1.1 — because they operate on an *existing* app.)
- **Hide the endpoint behind a `use Samen.Web.Endpoint` macro.** Rejected — the builder must own
  their endpoint's secrets/port; a hidden endpoint is a security footgun and a debugging black box.
