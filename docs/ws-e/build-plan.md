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
  **DONE (shipped 2026-07-17).** All FIVE shipped sabotages landed as patches
  (`scripts/sabotages/01..05`): E1's chokepoint-bypass, S3 fail-honest `{:ok}` lie,
  quarantine-default `:active`, allowlist `*`; E2's byte-serve plane-gate bypass. Harness
  `scripts/sabotage.sh` proves each flips its NAMED tests + restores SHA-256 byte-exact;
  wired into root `ci.sh` as the opt-in `SAMEN_SABOTAGE=1` step (opt-in, unlike the
  unconditional WS-D probes, because it breaks the tree 5x). `CLAUDE.md` at repo root.
  `Samen.MaskingCase` in samen_core lib (sibling of `Samen.RedPath`/`Factory`), back-ported
  into `file_preview_masking_test.exs` (12 tests green, names unchanged so the 05 patch
  still binds). No recorded gaps — all four E1 sabotages reconstructed and proven.

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
- **E2i-P2 (build, recorded):** the sabotage harness asserts the flip on the TARGETED test
  files named in each patch header (fast, named-test-exact), not a whole-app suite run per
  patch; whole-suite green is separately guaranteed by the surrounding root `ci.sh`. Also:
  driftwood's `gate_e2_files_e2e_test.exs` is not bound into patch 05 (the plane gate is
  proven at its samen_web chokepoint by 4 named tests); bind it at E7.2 if the flagship
  probe wants the vertical-mount flip too.
- **E3-P2 (build, resolved — the E3.1 ship note):** CSV parse/serialize is HAND-ROLLED RFC 4180
  (~40 lines in `Samen.Web.Csv`: quoting, escaped quotes, embedded commas/newlines, CRLF; LF-parse
  tolerated) — no parser dependency to audit. No large-export cap added: export is keyset-paged
  (`Reads.page!` clamps every page) so memory is bounded per page; a row-count cap / background
  threshold is deferred to a real operator need — record at E7 if a gate flags it.
- **E3-P2 (gate, recorded):** composite vault plaintext round-trips through the vault in its
  JSON-SERIALIZED form — a tenant-plane export cell for `full_name` is the JSON object string
  (`{"first":…,"last":…}`), which import decodes back through the governed cast. The cell is
  faithful to the resolver's output; if E5's profile surface wants prettier composite rendering,
  add a display serializer THERE (read-side), never a CSV-side unwrap.
- **E3-P2 (gate, recorded):** the operator API-KEY posture (`%Ash.ForbiddenField{}` → empty cell,
  mask-by-omission) is unit-covered in `Samen.Web.Csv.cell/1` but not route-exercised — the mounted
  routes run browser sessions (impersonation posture → `••••`). The API-key CSV path does not exist
  as a route today; if one is added (API export endpoint), bind the omission red-path then.
- **E3-P2 (gate, recorded):** `ImportLive`'s consume→import event flow is engine-covered
  (`Csv.import/3` red-paths) + render-covered (report/error/posture DOM), but the LiveView upload
  consume itself is not driven end-to-end in test (no Endpoint boot in the samen_web harness — the
  same posture as the E2 UploadLive tests). The driftwood E3 gate probe drives the mounted
  ExportController end-to-end; import E2E-via-browser lands with E7.1's vertical sweep if wanted.
- *(Further entries populated by later phase gates.)* Anticipated candidates by design analysis:
  - **E1/E2-P2 (likely):** whether `Local` storage's `/files/:id` byte-serve needs its own rate/size
    guard beyond the upload-time limit (a second read-path bound) — record + decide at E7 if a phase
    gate flags it.
  - **E3-P2 (likely):** the CSV dep-vs-hand-rolled decision (E3.1) and any large-export cap/background
    threshold — record the chosen bound.
  - **E4-P2 (possible):** which existing resources beyond `File` get a tsvector trigger in WS-E vs.
    a documented follow-on (the design bounds it to registry-registered columns).

- **E4-P2 (gate, recorded — the tsvector-trigger bound):** the E4 tsvector-populate trigger + GIN
  functional index is shipped for the FRAMEWORK-OWNED searchable column ONLY — `File`
  (`filename`/`content_type`, both non-PII) — and materialized in **driftwood** (the E4 gate vertical,
  `20260717120000_file_search_tsvector.exs`: `ffl_file_search_vector_trg` + `ffl_file_search_gin_idx`).
  demo + pawchart adopt the identical per-abbrev migration WHEN they mount search (documented follow-on;
  not shipped now to avoid a 5-migration cross-app change for surfaces no demo/pawchart test exercises).
  The kernel `Samen.Search` engine builds its tsvector at QUERY time from the registered NON-PII field
  columns (`to_tsvector(config, coalesce(field₁,'') || …)`), so search is CORRECT on any registered
  resource without a trigger/index — the trigger materializes `search_vector` for observability and the
  functional GIN index backs the common File(filename+content_type) registration. A per-registration
  index for other resources is a documented follow-on if a host registers them at scale.
- **E4-P2 (gate, recorded — display_fields derivation):** `SearchIndex.metadata.display_fields` (the
  bounded non-PII display allowlist) is DERIVED at query time from the registry's registered
  `field_name`s for the resource — which are guaranteed non-PII by `SearchIndexGuard` at register time —
  rather than adding a new `psh_display_fields` column across the 4 primitives-mounting apps + generator.
  The `%Samen.Search.Result{}.display` map is exactly those guard-safe fields taken off the
  PiiResolution-projected record (belt-and-suspenders: the full record is projected, the display subset
  is non-PII by the guard). A richer per-resource display override (display fields BEYOND the searchable
  ones — e.g. a File's `status`) needs the registry column and is a documented follow-on.
- **E4-P2 (build, recorded — ⌘K keybinding):** the palette input is `autofocus`ed; the literal ⌘K
  GLOBAL keyboard shortcut (focus-from-anywhere) needs a client JS hook (the samen_web asset pipeline
  ships CSS + `phx-` bindings, no bespoke hooks). Deferred to E6's kit/asset pass or a documented host
  hook; the search page + per-list `search_box` navigate to it without the shortcut.

- **E5-P2 (build, recorded — the current-user seam):** auth is host-owned (ADR-029), so the settings
  surfaces resolve "who am I" via `Samen.Web.Settings.Reads.current_user_id/3` — `?user=` param →
  `session["samen_current_user"]` → `Mount.label(:current_user_id)` → `nil` (the honest "no user wired"
  card), mirroring the notifications `:recipient_id` precedent. The framework never invents identity.
  Two label keys added to `Samen.Web.Mount`'s whitelist (`current_user_id`, `current_membership_id`) so
  they survive session round-trip on a cold BEAM.
- **E5-P2 (build, recorded — composite reveal form):** revealed composite PII (`full_name`/`emails`)
  arrives in its JSON-serialized vault form (the E3-P2 ship-note posture). `ProfileLive` DECODES it to
  split first/last/email into editable inputs on the tenant plane; the operator plane renders the
  `%Masked{}` read-only via the kit `form_field/1` (no `name` → cannot submit plaintext — the render
  half of MC-1). No CSV-style unwrap on the write side; the governed `User` update re-casts the
  composite map through `Vault.Change`.
- **E5-P2 (build, recorded — token_digest write path):** `ApiKeys.mint/3` sets `token_digest` (a
  `public?: false` attribute) via `force_change_attribute`, never as a public action input — the raw
  key is never a changeset value and cannot be persisted. Mint is admin-gated by the existing `ApiKey`
  create policy; the ApiKeysLive builds the acting scope from the current membership's role so the
  policy sees the real minter authority. `effective_scopes/2` is the mint-time dual of
  `Samen.Scope.ApiKey.authorized?/4`'s use-time ceiling (belt-and-suspenders: bounded at rest AND at use).
- **E5-P2 (gate, recorded — Security sessions source):** the Security surface reads real impersonation
  sessions via `Samen.Impersonation.Sessions.list_for_org/2` (`repo: mount.repo`), rescue-safe to `[]`.
  The samen_web test host has no `imp_impersonation_session` table migrated, so the honesty/read-only
  STRUCTURE (no `phx-click`/`phx-submit`; the "managed by your identity provider" affordance) is the
  load-bearing RP-ST-4 proof, driven green. Bind a positive-sessions render at E7 on a host that
  migrates the impersonation table.
- **E5-P2 (gate, recorded — no Endpoint boot):** the three settings LiveViews' `handle_event` flows
  (`save`/`mint`/`revoke`) are engine-covered (`Profile.update` + `ApiKeys.mint/revoke` per-plane
  red-paths) + render-covered (per-plane DOM via the DataCase harness), but not driven through a booted
  Endpoint — the same posture as the E2 UploadLive / E3 ImportLive tests. The driftwood E5 gate probe
  (`gate_e5_settings_e2e_test.exs`) drives the engines end-to-end over the real `Driftwood.Operator`
  Identity namespace.
- **E6-P2 (gate, recorded — responsive masking is value-blind by construction):** the E6 kit is
  slot-based (`app_shell`/`sidebar`/`data_table`/`list_view`/`skeleton` take slots/opaque ids, never a
  raw field value), and `%Samen.Masked{}` has a hardened `Inspect` (`#Masked<••••>`), so NO firing
  plaintext-leak sabotage exists in the responsive pass — exactly the design claim ("the masking
  invariant is in the value layer, not CSS"). The mask-SURVIVAL proof (`responsive_masking_test.exs`)
  is therefore non-vacuous in-test via `Samen.MaskingCase` (`assert_masked_dom!` GREEN +
  `assert_leak_detected!` refutable twin on a modeled broken resolver) plus a source-scope scan (the
  responsive-touched kit carries no `Vault.reveal`/token-unwrap). The one refutable CODE seam E6 adds
  is `list_view/1`'s `loading` render contract (skeleton INSTEAD OF record rows), bound to the committed
  sabotage `scripts/sabotages/15-e6-list-loading-paints-rows.patch` (flips the `loading-contract` test,
  byte-exact revert).
- **E6-P2 (build, recorded — ⌘K global shortcut is an inline layout script, not an app.js hook):** the
  E4 carry (global focus-from-anywhere ⌘K) shipped as a dependency-free inline `<script>` in the shared
  root layout (`Samen.Web.Layouts.root/1`), because the samen_web asset pipeline is CSS-only (no
  esbuild, so no LiveView JS hook). It focuses `#cmdk-input` → `[data-cmdk]` (the per-list `search_box`)
  → else navigates the search form. Inherited by every host through the shared layout at ≈0 authored
  LOC; carries a `nonce={assigns[:csp_nonce]}` so a host with CSP can nonce it. A host that later adds
  a real esbuild bundle can move this to a `phx-hook` — recorded as an available upgrade, not required.
- **E6-P2 (build, recorded — search_box wiring scope, the E4 carry b):** the framework `search_box`
  was made a real drop-in (magnifier glyph + `⌘K` kbd + `data-cmdk`) and wired into the four TENANT
  list-page sidebars that cleanly carry `@org_id` → `/search` (crm/support/marketing/billing). The two
  OPERATOR sidebars (`operator/live`, `operator/aggregate_live`) keep their static `.search` placeholder:
  their correct target is `/operator/search` with an operator target-org seam (not a bare `@org_id`), a
  documented follow-on to wire when the operator-plane search box gets its own action — recorded rather
  than forced, since operator search wiring is outside E6's responsive design scope.

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
