# WS-E — "Table Stakes UX" — Build Plan

**Sizing rule (operator standing order):** SMALL serialized units — **one deliverable per `agent()`
call**, each banking in ~10-20 min, each phase independently committable + gate-able. Default agent
fan-out concurrency = 1 (serialize; session-limit hits then strand ≤1 straggler). Model routing per
unit below (`sonnet` = mechanical kit/CSS/LiveView surface + template-shaped ports + tests; `opus` =
the kernel engines, every masking/vault/fail-closed guarantee, the flagship cross-surface probe, and
every adversarial gate). **Any unit bundling two deliverables is split BEFORE launching.**

**Gate discipline:** every phase ends with a phase-gate (adversarial, findings fixed in-phase); the
workstream ends with a round-2 whole-workstream re-gate (`docs/gate-ws-e.md`). All suites + every
`ci.sh` (root/demo/driftwood/pawchart) green before/after each phase.

**Design inputs:** `docs/ws-e/design.md` (ACs), ADR-026 (files) / 027 (search) / 028 (CSV) / 029
(settings) / 030 (responsive). AC IDs referenced per unit.

**Dependency spine:** E1 (files kernel: chokepoint + Storage + Scanner, populates `search_vector`) →
E2 (files web: upload/preview LiveViews + byte-serve) → E4 (search: needs `File.search_vector`
populated by E1) with E3 (CSV) parallel-eligible after E2 in principle but **serialized** per the
one-agent rule → E5 (settings) → E6 (responsive kit pass, last so it restyles shipped surfaces) →
E7 (workstream gate). Search (E4) is placed after Files (E1/E2) because the File engine populates the
first real searchable tsvector; CSV (E3) and Settings (E5) are independent and could interleave but
run serialized. Responsive (E6) is deliberately LAST so it makes the already-shipped WS-E surfaces
mobile-usable in one pass.

---

## Phase E1 — Files kernel: the governed chokepoint (ADR-026)
*Prereq for a running file engine, and it populates the first real `search_vector` E4 needs.*

- **E1.1** `Samen.Files.Storage` behaviour + `Local` impl + `S3` fail-honest skeleton (`configured?/1`,
  `put/get/delete/presign_get`; `S3.put` → `{:error, :not_configured}`, NEVER `{:ok}`). Unit test:
  `Local` round-trips bytes; `S3.configured?` false absent creds; a stub returning `{:ok}` for a no-op
  is detectable. Deps: none. AC: AC-G14-3. Model: **opus** (fail-honest adapter contract, mirrors ADR-014).
- **E1.2** `Samen.Files.upload/3` chokepoint — size/type enforce (deny-by-default) → `Storage.put` →
  governed Ash create (`:quarantined` default) → `file_uploaded/3` audit. `File.status` default flips
  `:active`→`:quarantined`. Test: a governed row is created only through the chokepoint; over-size/
  unknown-type refused before `put`. Deps: E1.1. AC: AC-G14-1/2/6. Model: **opus** (governed-by-
  construction + fail-closed limits).
- **E1.3** `Samen.Files.Scanner` behaviour + `Reject` default + `Noop` explicit opt-in; quarantine→
  active promotion gated on a scan pass; preview/download refused while `:quarantined`. Test:
  fresh upload is `:quarantined` + preview refused; `Noop` promotes; `Reject` holds. Deps: E1.2.
  AC: AC-G14-4. Model: **opus** (quarantine fail-closed default).
- **E1.4** *Phase E1 gate* — adversarial over E1.1-E1.3: sabotage the chokepoint (raw create), the
  fail-honest S3 (return `{:ok}`), the quarantine default (`:active`), the type/size allowlist (`*`)
  — each flips a guarantee; byte-exact revert; all suites green. Deps: E1.1-E1.3. AC: AC-G14-2/3/4/6.
  Model: **opus**.

## Phase E2 — Files web: upload + preview surface (ADR-026)
- **E2.1** Upload LiveView (`allow_upload` → `consume_uploaded_entry` → `Samen.Files.upload/3`) +
  preview LiveView (filename through `PiiResolution`, byte view plane-gated) + `/files/:id` plane-
  gated byte-serve route + `samen_files_routes` mount macro. Deps: E1. AC: AC-G14-1/7. Model: **sonnet**
  (surface over the E1 chokepoint; the load-bearing work is in E1).
- **E2.2** File-preview **per-plane masking red-path**: operator-without-grant preview renders `••••`
  for a vaulted filename; operator byte-download refused; tenant sees plaintext. Sabotaging the plane
  gate FAILS. Deps: E2.1. AC: AC-G14-5. Model: **opus** (masking-watch-list surface).
- **E2.3** *Phase E2 gate* — mount files in a vertical (≈0 LOC), upload→quarantine→preview end-to-end;
  re-run the E2.2 sabotage from clean; all `ci.sh` green. Deps: E2.1-E2.2. AC: AC-G14-5/7. Model: **opus**.

## Phase E2i — One-time gate/agent automation (operator-ratified 2026-07-17, "convert domain knowledge to infra")
*Inserted after E2 lands. One small serialized unit (+gate-less: verified by its own consumers). E3+
phase gates and E7.2 MUST consume these instead of re-deriving the rituals by hand.*

- **E2i.1** Three deliverables, one unit: (a) **sabotage harness** — committed sabotage patches for
  every shipped gate sabotage (E1's four + E2's plane-gate) + `scripts/sabotage.sh` runner: apply
  patch → `mix test` → assert the NAMED tests fail → restore → sha-check zero residue; wired as a
  permanent opt-in CI step (like the WS-D generative probes). Later gates add their sabotages as
  patches, run the harness, and spend judgment only on NEW vacuity hunting. (b) **`CLAUDE.md`** at
  repo root (~60 lines): house conventions — fail-honest adapter contract, per-plane masking-test
  pattern + reference tests, chokepoint/guard rules, abbrev-registry hands-off + SHA, suite/ci
  commands, framework-first + ≈0-LOC vertical mounts, serialized-agent rule. (c) **masking-test
  helper** — `Samen.MaskingCase` (or samen_web equivalent) with per-plane green/red/sabotage
  assertion helpers, back-ported to the E2 preview tests as its first consumer; E3 export, E4
  search, E5 profile reuse it. Model: **opus**.

## Phase E3 — CSV import/export (ADR-028)
- **E3.1** `Samen.Web.Csv.export/3` — catalog-driven columns via `Catalog.fields/1`, keyset-paged via
  `Reads.page!/3`, **every cell through `PiiResolution` on the actor's plane**; CSV serialize (decide:
  one small dep vs. hand-rolled RFC-4180 — record in the ship note). Deps: none (uses shipped
  `Catalog`/`Reads`). AC: AC-G15-1/4. Model: **opus** (export is the highest-risk masking surface).
- **E3.2** Export **mask-by-omission red-path** (NON-NEGOTIABLE): operator-plane export cell = `••••`
  (never `vt_*`, never plaintext), EQUAL to the UI value on that plane; tenant own-org = plaintext.
  Sabotaging export to read the raw row FAILS. Deps: E3.1. AC: AC-G15-2. Model: **opus**.
- **E3.3** `Samen.Web.Csv.import/3` — each row through the governed create action (`WriteGuard` +
  `Vault.Change`); per-row fail-closed error report; bad-mapping (`org_id`/`id`/internal) rejected.
  Import vault-routing + fail-closed red-paths. Deps: E3.1. AC: AC-G15-3/5. Model: **opus** (write
  chokepoint reuse + fail-closed).
- **E3.4** `/export` + `/import` routes + `samen_csv_routes` macro; mount in a vertical (≈0 LOC).
  Deps: E3.1-E3.3. AC: AC-G15-1. Model: **sonnet** (route/macro surface).
- **E3.5** *Phase E3 gate* — export/import round-trip on two resources; re-run the E3.2 (export mask)
  + E3.3 (import vault + insert_all sabotage) red-paths from clean; bounded-read probe; all `ci.sh`
  green. Deps: E3.1-E3.4. AC: AC-G15-2/3/4/5. Model: **opus**.

## Phase E4 — Search engine + ⌘K (ADR-027)
- **E4.1** `Samen.Search.query/2` (kernel) — registry read → `websearch_to_tsquery` over registered
  `vector_column`s only → `ts_rank` → **project every result row through `PiiResolution`** → org-
  scoped + keyset-bounded via `Reads`; fail-closed `[]` on empty/unregistered. tsvector-populate
  trigger migration for searchable columns; `SearchIndex.metadata.display_fields` allowlist. Deps: E1
  (populated `File.search_vector`). AC: AC-G9-1/2/4/5. Model: **opus** (kernel engine + query-time PII
  guarantee).
- **E4.2** Search **per-plane result-masking red-path**: operator-plane result of a vaulted field ⇒
  `••••`; registered-column-only (sabotaging to filter an arbitrary column FAILS, index guard stays
  green); org-scope + bound red-paths. Deps: E4.1. AC: AC-G9-2/3/4. Model: **opus** (masking-watch-
  list surface).
- **E4.3** `Samen.UI.command_palette` LiveComponent (⌘K, debounced) + `samen_search_routes` macro +
  wire the per-list search box into the existing `sidebar/1` `:search` slot. Deps: E4.1. AC: AC-G9-1.
  Model: **sonnet** (kit surface over the E4.1 engine).
- **E4.4** *Phase E4 gate* — mount search in a vertical (≈0 LOC), ⌘K + per-list search return ranked
  org-scoped results; re-run the E4.2 masking + registered-column sabotages from clean; all `ci.sh`
  green. Deps: E4.1-E4.3. AC: AC-G9-2/3/4/5. Model: **opus**.

## Phase E5 — Self-serve settings (ADR-029)
- **E5.1** Profile LiveView — self-edit own `full_name`/`emails`/`handle` through the vault write
  chokepoint on the tenant plane; `%Masked{}` fields render read-only (no `name`, can't submit).
  Profile self-edit **per-plane vault red-path**: tenant writes `vt_*`; operator-impersonation
  plaintext write refused by `WriteGuard`; sabotaging the chokepoint FAILS. Deps: none (reuses
  `User` actions + chokepoint). AC: AC-G18-2. Model: **opus** (masking-watch-list surface).
- **E5.2** API-keys LiveView — list/mint-**show-once**/revoke over existing `ApiKey`; token returned
  once, DB stores only `token_digest`; minted authority bounded by minter role ceiling. Red-paths:
  key never re-read; scope-intersection ceiling. Deps: none. AC: AC-G18-3/4. Model: **opus** (credential
  hygiene + authority ceiling).
- **E5.3** Security LiveView (read-only impersonation-sessions from `Impersonation.Sessions` + auth-
  audit; honest host-auth-boundary affordance) + `/settings/*` routes + `samen_settings_routes`
  macro; mount in a vertical (≈0 LOC). Honesty structural red-path (no faked host-auth toggle). Deps:
  E5.1, E5.2. AC: AC-G18-1/5. Model: **sonnet** (read-only surface + macro; RP-ST-4 is structural).
- **E5.4** *Phase E5 gate* — mount settings in a vertical; re-run the E5.1 (profile vault) + E5.2 (key
  hygiene + ceiling) red-paths from clean; confirm no framework auth invented; all `ci.sh` green.
  Deps: E5.1-E5.3. AC: AC-G18-2/3/4/5. Model: **opus**.

## Phase E6 — Responsive kit pass (ADR-030) — LAST, restyles shipped surfaces
- **E6.1** `samen_ui.css` — two `@media` breakpoints, `.app` single-column collapse, off-canvas
  sidebar drawer + hamburger toggle affordance in `app_shell`/`sidebar`, `data_table` responsive
  variant. **CSS + named kit components ONLY — no vertical LiveView touched** (structural scope guard).
  Deps: E2/E3/E4/E5 (so it restyles the shipped surfaces). AC: AC-G20-1/4. Model: **sonnet** (CSS/kit).
- **E6.2** `Samen.UI.skeleton/1` primitive + keyframes, wired into the framework list surfaces (NOT a
  fleet-wide `assign_async` rewrite — deferred). Deps: E6.1. AC: AC-G20-1. Model: **sonnet**.
- **E6.3** *Phase E6 gate* — masking survives responsive (masked cells `••••` at mobile + desktop —
  value layer untouched); pawchart/driftwood/demo render responsively with zero per-vertical CSS; the
  diff-scope guard (only `samen_ui.css` + named kit components). Deps: E6.1-E6.2. AC: AC-G20-2/3/4.
  Model: **opus** (masking-survival + scope-guard verification).

## Phase E7 — Workstream gate
- **E7.1** Vertical adoption + LOC-leverage proof — driftwood + pawchart + demo mount all five surfaces
  (files/search/CSV/settings/responsive) via one macro each, ≈0 authored LOC, no re-implemented
  framework code (§3 leverage guard). Deps: E1-E6. AC: AC-X-2. Model: **opus**.
- **E7.2** *WS-E flagship cross-surface probe* (AC-X-1) — the single multi-plane probe exercising all
  five surfaces, binding the FOUR new-PII-surface sabotages (search projection, file preview/byte-gate,
  export cell, profile self-edit) each to a flip→byte-exact-revert; fail-honest `S3.put` never `{:ok}`;
  wired into the suite permanently. Deps: E7.1. AC: AC-X-1. Model: **opus** (the flagship proof).
- **E7.3** *WS-E whole-workstream adversarial re-gate* (`docs/gate-ws-e.md`) — all ACs mapped to named
  tests; the flagship probe re-run non-vacuously; cross-phase hunts (export × search projection share
  `PiiResolution`; files quarantine × preview gate; import × profile self-edit share the write
  chokepoint); all suites + every `ci.sh` green with exact counts; carries recorded; roadmap tick +
  memory update. Deps: E7.2. AC: all. Model: **opus**.

**Carries into E7 (P2s from phase gates — resolve, or record explicitly):**
- **E1-P2 (gate, recorded):** audit emit in `Samen.Files` is best-effort (`try/rescue → :ok`) — an
  aud_event-tier failure does not fail the governed create/promote; row still lands
  governed+quarantined. Deliberate posture; re-argue at E7 if a stricter "every governed file has a
  durable audit row" invariant is wanted.
- **E1-P2 (gate, recorded):** full-suite flake watch — 1 of 3 samen_core runs reported 1170/1171
  with no failure header (transient async/sandbox, OUTSIDE the async:false Files units which were
  42/42 across 3 runs). If it recurs in later phase gates, identify + stabilize the flaky async test.
- **E2-P2 (gate, recorded):** the E2.2 vaulted-filename host is MODELED (a `%Masked{}` applied to a
  real seeded File + the resolver seam proven separately on `Notification.rendered_body`), not
  materialized as a DB resource — materializing one needs an `abbrev_registry.json` row the unit
  forbids. At E7, either materialize it properly (registry row via the sanctioned allocator) in the
  flagship probe or re-argue the by-construction join as sufficient.
- **E2-P2 (gate, resolved):** AC-G14-7's real-vertical mount landed in driftwood (demo is API-only,
  no LiveView router) — KEPT as adoption per operator direction; E7.1 mounts the remaining verticals.
- *(Further entries populated by later phase gates.)* Anticipated candidates by design analysis:
  - **E1/E2-P2 (likely):** whether `Local` storage's `/files/:id` byte-serve needs its own rate/size
    guard beyond the upload-time limit (a second read-path bound) — record + decide at E7 if a phase
    gate flags it.
  - **E3-P2 (likely):** the CSV dep-vs-hand-rolled decision (E3.1) and any large-export cap/background
    threshold — record the chosen bound.
  - **E4-P2 (possible):** which existing resources beyond `File` get a tsvector trigger in WS-E vs.
    a documented follow-on (the design bounds it to registry-registered columns).

---

## Model-routing summary
- **opus** (load-bearing): E1.1/1.2/1.3/1.4, E2.2/2.3, E3.1/3.2/3.3/3.5, E4.1/4.2/4.4, E5.1/5.2/5.4,
  E6.3, E7.1/7.2/7.3 — the kernel engines (Files/Search/CSV), every masking/vault/fail-closed
  guarantee, the four masking-watch-list red-paths, the flagship cross-surface probe, and every
  adversarial gate.
- **sonnet** (surface): E2.1, E3.4, E4.3, E5.3, E6.1/6.2 — LiveView/kit/CSS surfaces over opus-built
  engines, route/macro mounts, and the read-only + structural-honesty units (the load-bearing work is
  in the kernel/red-path units the surfaces sit on).

## Estimated workflow-agent count
**~30 agent calls** — 26 build/gate units above + the standard per-phase overhead the operator's
serialized loop adds (re-runs on session-limit strands, ≤1 straggler per phase resumed). Budget
**~30-34** including strand re-runs. (Comparable to WS-D's ~34; WS-E is one phase smaller — 6 build
phases + 1 workstream gate vs. WS-D's 10+1 — but each files/CSV/search phase carries a load-bearing
masking red-path that WS-D's mechanical template ports did not.)
