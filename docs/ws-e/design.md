# WS-E — "Table Stakes UX" — Design

**Workstream:** E (G9 search+⌘K · G14 files engine · G15 CSV import/export · G18 self-serve settings · G20 responsive).
**Status:** design (no code written by this doc).
**Date:** 2026-07-16.
**Depends on:** WS-A (SHIPPED — `docs/gate-ws-a.md`: kit, `Reads` keyset pagination, `PiiResolution`-to-pixel masking, `WriteGuard`/`Vault.Change` chokepoint, empty-states), WS-B (SHIPPED — flag engine as the kernel-engine/web-UI split precedent), WS-D (SHIPPED — `Samen.Catalog.fields/1` runtime enumeration, generator emits the real patterns). WS-E is the **last planned workstream** and closes the end-user P1s.

**North star (flagship AC, AC-X-1):** a tenant can **find** anything (⌘K + per-list search), **attach** anything (upload → quarantine → preview a file), **move data in and out** (CSV import/export), **manage their own account** (profile/API-keys/security), and **use it on a phone** — and EVERY new value-render or value-write path (search results, file preview, export cells, profile self-edit) is **masked per-plane by construction**, with a red-path proving an operator can never pull plaintext the tenant plane wouldn't already show. Four of the six flagged mask-by-omission surfaces (search results, file preview, export, profile self-edit) land in WS-E; each ships a per-plane masking test — non-negotiable.

---

## 0. Evidence base & ground truth (what exists today)

Read `docs/gap-discovery/end-user.md` (G2/G5/G6/G7/G8, the ranked end-user gaps) and `harden-existing.md` H-10 ("primitives are scaffolds, not services") for the full evidence. The load-bearing facts this design builds on, verified against the live tree this session:

**Search (G9).** The **hard part is already done.** `SearchIndex` resource (`psh`: `resource_name`, `field_name`, `vector_column`, `enabled`, `ts_config`; org-scoped reads, admin-gated writes) in `samen_core/lib/samen/scopes/primitives/blueprint.ex:349-432`. `search_index_guard.ex:38-54` REFUSES registering a vault-routed column into a tsvector index (the T3.7 PII-column red-path — real and green). Real `pfl_search_vector` tsvector columns exist on the `File` resource across verticals (migrations populate a `:text` column, GIN-indexable). **Missing:** no `Search.query/2`, no `:search` action, no ⌘K, no search box — the `Samen.UI.sidebar/1` has a `:search` slot PLACEHOLDER that nothing feeds. Result rendering would go through `Samen.Api.PiiResolution` (the same seam the kit uses; `%Masked{}` renders `••••` via `Phoenix.HTML.Safe`).

**Files (G14).** `File` resource (`pfl`: `filename`, `content_type`, `size_bytes`, `storage_key`, `status[:active|:archived|:deleted|:quarantined]`, `search_vector`, `metadata`; org-scoped, member+ writes) in the primitives blueprint (`:262-342`), with a `file_uploaded/3` audit writer (status-only, no filename/key). `storage_key` is a **bare string the host populates** — NO upload action, NO `allow_upload`, NO storage adapter, NO preview (harden H-10). Four adapter-behaviour precedents to mirror: **`Samen.Delivery.Adapter`** (the fail-honest gold standard: `configured?/1`, stub NEVER returns `{:ok}` for a no-op — ADR-014), `Billing.SyncAdapter`, `Webhook.HttpAdapter`, `Samen.Anchor`. **No `ex_aws`/`req`/`finch` dep in the tree** — HTTP is Erlang `:httpc`; an S3 impl stays operator-TODO.

**CSV import/export (G15).** **Nothing exists.** Two shipped capabilities make a GENERIC mapper feasible: `Samen.Catalog.fields/1` (`samen_core/lib/samen/catalog.ex:54-68`) enumerates any resource's `{table, column, logical_name, type}` at RUNTIME via `Ash.Resource.Info.attributes()`; `Samen.Web.Reads.page!/3` (`samen_web/lib/samen/web/reads.ex:144-195`) gives keyset-bounded, org-scoped iteration (default_limit 50, max 200, ALWAYS a limit). Export is flagged the **highest-risk mask-by-omission vector** — it must render every cell through `PiiResolution`; import must route through the `WriteGuard`/`Vault.Change` chokepoint (the same path `sample_data.ex:80-121` proves).

**Settings (G18).** Identity resources exist in `samen_core/lib/samen/scopes/identity/blueprint.ex`: `User` (`usr`; vaulted `full_name`→`:pii_name`, `emails`→`:pii_email`; `handle`, `status`), `ApiKey` (`key`; `token_digest` SHA-256 one-way `public?: false`, `plane`, `scopes`, `minter_role`, `revoked_at`), `Membership` (`mbs`), `Invitation` (`inv`; vaulted `email`). **No `/settings` route, no profile/API-key/session UI.** Auth is **HOST-OWNED**: `router.ex` derives org from the session (`current_org.ex:77-82` resolution order), there is **no framework login LiveView**. The vault write chokepoint (`WriteGuard` refuses operator-plane plaintext PII writes; `Vault.Change` encrypts → `vt_*`; `VaultField.dump_to_native/2` is the last-line guard) is what a profile self-edit MUST reuse.

**Responsive (G20).** `samen_web/priv/static/assets/samen_ui.css` (500 lines): `@media` count = **0**; `.app { grid-template-columns: 252px 1fr }` fixed two-pane; zero skeleton/keyframes. The kit (`Samen.UI`: `app_shell/1`, `sidebar/1`, `topbar/1`, `data_table/1`, `list_view/1`) is inherited by every vertical — so ONE kit-level CSS pass fixes the whole fleet. The masking invariant is in the value layer, not CSS, so responsive changes cannot touch it (ADR-030).

**The unifying insight:** in every one of these five gaps the GOVERNANCE foundation already exists (PII-index guard, vault chokepoint, PiiResolution seam, catalog-as-data, bounded reads) — WS-E builds the missing user-facing ENGINE on top, framework-first, and every new PII surface inherits masking correctness rather than re-deriving it. This is the same "the hard part is done, ship the surface privacy-correct-by-construction" moat WS-B exploited.

---

## 1. Architecture — the shape of "Table Stakes UX"

WS-E is **surface-engine lag, not architecture lag**: for each gap the kernel/governance layer is proven; WS-E adds the engine + kit surface. The design rule is **framework-first — the capability lands in `samen_core` (kernel engine) or `samen_web` (kit/route), and verticals prove it at ≈0 LOC** (one router-macro mount). Any new value-render/value-write path ships a per-plane masking test (non-negotiable rider). Five scope pillars, each with a load-bearing ADR:

### 1.1 G14 — Files engine (ADR-026)

A `Samen.Files.Storage` behaviour (kernel, web-dep-free, fail-honest) with a working `Local` impl + an `S3` skeleton (operator-TODO, no new dep). Upload routes through a single kernel chokepoint `Samen.Files.upload/3` (size/type enforce → `Storage.put` → governed Ash create → audit) — the ONLY create path, so "no ungoverned file row" is true by construction. New files are **quarantine-by-default** (fail-closed: unscanned ⇒ quarantined ⇒ not previewable; a `Samen.Files.Scanner` behaviour with `Reject` default / `Noop` explicit-opt-in). Preview is a **new PII render surface**: filename rendered through `PiiResolution` (operator-without-grant ⇒ `••••`), byte download **plane-gated** (operator refused, not masked — bytes have no partial reveal). Type/size limits are bounded config, deny-by-default. Mounted via a new `samen_files_routes` macro + a plane-gated `/files/:id` byte-serve route. **Framework-first:** the `File.search_vector` this populates feeds ADR-027.

### 1.2 G9 — Search engine (ADR-027)

A kernel `Samen.Search.query/2` over the existing non-PII tsvector (`websearch_to_tsquery` → `ts_rank`), reading the `SearchIndex` registry to discover searchable `(resource, vector_column)` pairs — mirroring ADR-020's kernel-engine/web-UI split. PII-safe at BOTH ends: index-time is already guarded (`SearchIndexGuard`); WS-E adds the QUERY-time guarantee — the engine filters ONLY registered columns (never arbitrary), and every result row is projected through `PiiResolution` (a masked field can neither be a match nor leak as a display field). Results reuse the shipped bounded-reads path (org-scoped, keyset-bounded — search can't be cross-org or unbounded). The ⌘K palette is a single framework `Samen.UI.command_palette` LiveComponent mounted via `samen_search_routes`; the per-list box fills the existing `:search` slot. **Framework-first:** zero authored search LiveViews per vertical.

### 1.3 G15 — CSV import/export (ADR-028)

A generic catalog-driven `Samen.Web.Csv` (samen_web) over `Catalog.fields/1` — one framework module every resource inherits, no per-vertical CSV code. **Export is a first-class masking surface** (the highest-risk WS-E surface): every cell rendered through `PiiResolution` on the actor's plane, so the CSV cell and the pixel show the SAME masked value on the same plane — export can never leak what the UI wouldn't. **Import routes through the SAME governed Ash create/update actions** the UI forms use (`WriteGuard` + `Vault.Change` per row) — bulk import is not a new PII-write trust surface, it's the existing chokepoint in a loop, with a per-row fail-closed error report. Export is **bounded/streamed** via `Reads.page!/3` keyset iteration (never an unbounded `Ash.read!`). Column allowlisting deny-by-default, plane-aware. Mounted via `samen_csv_routes`.

### 1.4 G18 — Self-serve settings (ADR-029)

A `/settings` framework route group (`samen_settings_routes`) with three sub-surfaces: **Profile** (self-edit own `full_name`/`emails`/`handle`), **API keys** (list/mint/revoke), **Security** (read-only impersonation-session + auth-audit view). Profile self-edit routes through the vault write chokepoint on the TENANT plane (the "profile self-edit of own vaulted PII" masking-watch-list surface): a user edits their own PII vault-routed; an operator impersonating is refused a plaintext write by `WriteGuard`. API keys are **show-once** (token returned once, DB stores only `token_digest` — can't leak what it never persists), authority bounded by the minter's role ceiling. The Security surface is **read-only and honest about the host-auth boundary** — no framework login/2FA/session-revocation is invented (auth is deliberately host-owned; host-managed items render as an honest "managed by your identity provider" affordance). **Framework-first:** zero authored settings LiveViews; reuses existing Identity actions + `Impersonation.Sessions`.

### 1.5 G20 — Responsive pass (ADR-030)

**Kit-and-CSS-only** — the entire fleet's layout is one stylesheet + a few kit components, so ONE bounded diff makes every vertical mobile-usable (the highest-leverage cosmetic fix in the fleet). Two breakpoints, mobile-first: `.app` grid collapses to one column, sidebar becomes an off-canvas drawer behind a hamburger toggle (a small kit affordance, no new JS framework), `data_table` gets a responsive variant (bounded horizontal-scroll or label:value card-stack). The masking invariant is UNTOUCHED (CSS changes layout, never value resolution — a `%Masked{}` value renders `••••` at every breakpoint). A `Samen.UI.skeleton/1` primitive + keyframes ships, wired into the framework list surfaces — the fleet-wide `stream`/`assign_async` perf rewrite is **explicitly deferred** (per-page, decompose rule). No vertical LiveView is touched (structural scope guard, RP-RE-3).

---

## 2. Emission / surface inventory — file-by-file (today vs. after WS-E)

`[NEW]` = new module/file · `[MOD]` = existing modified · `[MACRO]` = new router mount macro (verticals mount, don't author). Framework layer in brackets: `[kernel]` = samen_core, `[web]` = samen_web.

### 2.1 G14 Files (ADR-026)
| Surface | Status | Layer |
|---|---|---|
| `Samen.Files` (chokepoint: `upload/3`, `preview/2`, size/type enforce, audit) | `[NEW]` | kernel |
| `Samen.Files.Storage` behaviour + `Local` impl + `S3` skeleton (fail-honest) | `[NEW]` | kernel |
| `Samen.Files.Scanner` behaviour + `Reject` default + `Noop` opt-in | `[NEW]` | kernel |
| `File.status` default `:active` → `:quarantined` | `[MOD]` | kernel |
| Upload LiveView (`allow_upload` → `consume_uploaded_entry` → `Files.upload/3`) + preview LiveView | `[NEW]` | web |
| `/files/:id` plane-gated byte-serve route + `samen_files_routes` mount macro | `[NEW][MACRO]` | web |

### 2.2 G9 Search (ADR-027)
| Surface | Status | Layer |
|---|---|---|
| `Samen.Search` (`query/2`: registry read → tsquery → ts_rank → PiiResolution project → bounded) | `[NEW]` | kernel |
| tsvector-populate trigger migration for searchable columns | `[NEW]` | kernel |
| `SearchIndex.metadata.display_fields` (bounded non-PII display allowlist) | `[MOD]` | kernel |
| `Samen.UI.command_palette` LiveComponent (⌘K) + `samen_search_routes` macro | `[NEW][MACRO]` | web |
| per-list search box wired to the existing `sidebar/1` `:search` slot | `[MOD]` | web |

### 2.3 G15 CSV (ADR-028)
| Surface | Status | Layer |
|---|---|---|
| `Samen.Web.Csv` (`export/3` via `Reads.page!` + PiiResolution per cell; `import/3` via governed create actions per row) | `[NEW]` | web |
| per-row import error-report struct | `[NEW]` | web |
| `/export` + `/import` routes + `samen_csv_routes` macro | `[NEW][MACRO]` | web |
| CSV parse/serialize (one small dep OR hand-rolled RFC-4180 — decided E3) | `[NEW]` | web |

### 2.4 G18 Settings (ADR-029)
| Surface | Status | Layer |
|---|---|---|
| Profile LiveView (self-edit own PII via vault chokepoint) | `[NEW]` | web |
| API-keys LiveView (list/mint-show-once/revoke over existing `ApiKey`) | `[NEW]` | web |
| Security LiveView (read-only impersonation-sessions + auth-audit) | `[NEW]` | web |
| `/settings/*` routes + `samen_settings_routes` macro | `[NEW][MACRO]` | web |

### 2.5 G20 Responsive (ADR-030)
| Surface | Status | Layer |
|---|---|---|
| `samen_ui.css` — two `@media` breakpoints, drawer, grid collapse, keyframes | `[MOD]` | web |
| `data_table/1` responsive variant + sidebar-drawer toggle in `app_shell`/`sidebar` | `[MOD]` | web |
| `Samen.UI.skeleton/1` primitive wired into framework list surfaces | `[NEW]` | web |

---

## 3. What stays inherited (must NOT be re-implemented — leverage guard)

These are provided by samen_web/samen_core and mounted/called, never re-authored per vertical (re-implementing them is a finding): the `PiiResolution` masking seam (every new render path calls it, never a plaintext bypass); the `WriteGuard`/`Vault.Change` write chokepoint (every new write path routes through it); `Reads.page!/3` bounded keyset (search + export reuse it); `Catalog.fields/1` (CSV reuses it); the kit components + `%Masked{}` rendering. **The leverage measure (AC-X-2):** each of the five surfaces is mounted by ONE router macro in each vertical — driftwood/pawchart/demo prove all five at ≈0 authored LOC, no re-implemented framework code.

---

## 4. The WS-E flagship proof (AC-X-1)

A cross-surface adversarial probe (extends the samen_web + samen_core suites) that, on a seeded multi-plane fixture, exercises all five surfaces and BINDS each new PII path to a real sabotage→flip→revert:
- **Search:** operator-plane ⌘K result of a vaulted field renders `••••`; sabotaging the result projection → the masking test fails; revert.
- **Files:** upload → row is `:quarantined` (preview refused); operator-plane preview of a vaulted filename → `••••`; operator-plane byte download → refused; sabotaging the plane gate → fails; revert. `S3.put` returns `{:error, :not_configured}` (fail-honest, never `{:ok}`).
- **Export:** operator-plane CSV export cell = `••••` (never a `vt_*` token, never plaintext), EQUAL to the UI value; sabotaging export to read the raw row → the mask-by-omission test fails; revert.
- **Import:** tenant-plane CSV import writes `vt_*` (plaintext nowhere); operator-plane import refused row-by-row; sabotaging to `insert_all` → the vault-routing test fails; revert.
- **Profile:** tenant self-edit writes `vt_*`; operator-impersonation plaintext write refused; sabotaging the chokepoint → fails; revert.
- **Responsive:** masked cells render `••••` at mobile + desktop widths (CSS-only, value layer untouched).

**Non-vacuity is the whole point:** every new masking guarantee carries its own sabotage that must flip the gate; byte-exact revert; zero residue. This is the WS-A/B/D house pattern (the object-unfurl / suppression-render / db_statement probes) applied to WS-E's four new PII surfaces.

---

## 5. Acceptance criteria (numbered, testable)

### G14 — Files
- **AC-G14-1** `Samen.Files.upload/3` uploads bytes via `Storage.put`, creates a governed `File` row, writes the audit event; a LiveView `allow_upload` flow round-trips to a stored file. *Test:* an integration test uploads → row exists with a `storage_key` → `Storage.get` returns the bytes.
- **AC-G14-2** No `File` row can carry a `storage_key` except through `Samen.Files.upload/3` (governed-by-construction). *Test:* RP-FI-1 — a direct create bypassing the chokepoint is refused; sabotaging the guard FAILS.
- **AC-G14-3** `Storage.Local` is a real working impl (CI/dev); `Storage.S3` is fail-honest (`configured?/1` false absent creds, `put/3` → `{:error, :not_configured}`, never `{:ok}`). *Test:* RP-FI-6 — a stub returning `{:ok}` for a no-op FAILS (mirrors the delivery-no-op probe).
- **AC-G14-4** A freshly uploaded file is `:quarantined`; preview/download refused until scanned; `Scanner.Reject` is the fail-closed default, `Noop` an explicit opt-in. *Test:* RP-FI-3 — defaulting a new file to `:active` FAILS.
- **AC-G14-5** File preview renders `filename` through `PiiResolution` (operator-without-grant ⇒ `••••`); byte download is plane-gated (operator refused). *Test:* RP-FI-4 per-plane — sabotaging the plane check FAILS (masking watch-list surface).
- **AC-G14-6** Type/size limits enforced at the chokepoint before `Storage.put`, deny-by-default (empty/unknown content_type refused). *Test:* RP-FI-5 — widening the allowlist to `*` FAILS.
- **AC-G14-7** Every vertical mounts files via one `samen_files_routes` call, ≈0 authored LOC. *Test:* a mount test in a vertical proves upload+preview work with no vertical file-engine code.

### G9 — Search
- **AC-G9-1** `Samen.Search.query/2` returns org-scoped, ranked, bounded results over the registered tsvector columns; the ⌘K palette + per-list box call it. *Test:* an integration test seeds searchable rows and asserts a term returns the right ranked, org-scoped set.
- **AC-G9-2** The engine filters ONLY registry-registered columns (never arbitrary/PII). *Test:* RP-SE-1 — sabotaging the engine to filter an arbitrary column FAILS; the index guard's PII refusal stays green.
- **AC-G9-3** Every result row is projected through `PiiResolution`: operator-plane result of a vaulted field ⇒ `••••`; tenant-plane own-org ⇒ plaintext. *Test:* RP-SE-2 per-plane — sabotaging the projection FAILS (masking watch-list surface).
- **AC-G9-4** Results are org-scoped and `limit`-bounded (reuses `Reads`). *Test:* RP-SE-3 — a cross-org leak or unbounded read FAILS.
- **AC-G9-5** Empty/ambiguous/unregistered term returns `[]`, never a full-table dump. *Test:* RP-SE-4 — "match all" FAILS.

### G15 — CSV import/export
- **AC-G15-1** `Samen.Web.Csv.export/3` and `import/3` operate generically over `Catalog.fields(resource)` (one module, all resources). *Test:* export+import round-trip on two different resources with no per-resource CSV code.
- **AC-G15-2 (NON-NEGOTIABLE)** Export renders every cell through `PiiResolution` on the actor's plane: operator-plane vaulted cell ⇒ `••••` (never `vt_*`, never plaintext), EQUAL to the UI value; tenant-plane own-org ⇒ plaintext. *Test:* RP-CSV-1 per-plane — sabotaging export to read the raw row FAILS (THE mask-by-omission red-path).
- **AC-G15-3** Import routes each row through the governed create action (`WriteGuard` + `Vault.Change`): tenant import writes `vt_*`; operator import refused row-by-row. *Test:* RP-CSV-2 — sabotaging to `insert_all` FAILS the vault-routing test.
- **AC-G15-4** Export iterates keyset pages (`Reads.page!`), never an unbounded `Ash.read!`. *Test:* RP-CSV-3 — replacing paged iteration with a raw full read FAILS the bounded-read probe.
- **AC-G15-5** Import is fail-closed on bad mapping (a column mapped to `org_id`/`id`/internal is rejected; a policy-violating row fails that row with an error). *Test:* RP-CSV-4 — allowing a cross-org `org_id` write FAILS.

### G18 — Settings
- **AC-G18-1** `/settings/{profile,api-keys,security}` mount via `samen_settings_routes`; every vertical inherits at ≈0 LOC. *Test:* a mount test proves the three surfaces render in a vertical with no authored settings code.
- **AC-G18-2** Profile self-edit routes through the vault chokepoint on the tenant plane (writes `vt_*`); an operator-impersonation plaintext write is refused by `WriteGuard`. *Test:* RP-ST-1 per-plane — sabotaging the chokepoint FAILS (masking watch-list surface).
- **AC-G18-3** API-key mint shows the raw token once, stores only `token_digest`, never re-displays it. *Test:* RP-ST-2 — persisting/re-reading the raw key FAILS.
- **AC-G18-4** A minted key's authority never exceeds the minter's role ceiling. *Test:* RP-ST-3 — sabotaging the scope intersection FAILS.
- **AC-G18-5** The Security surface is read-only and honest (no invented framework password/2FA/session-revoke; renders real impersonation sessions). *Test:* RP-ST-4 — faking a host-auth toggle FAILS the honesty structural test.

### G20 — Responsive
- **AC-G20-1** `samen_ui.css` gains ≥2 `@media` breakpoints; `.app` collapses to one column with a sidebar drawer at mobile width; `data_table` has a responsive variant; a `skeleton/1` primitive exists. *Test:* a CSS/DOM assertion at mobile + desktop widths (design-review screenshot diff) confirms the collapse + drawer.
- **AC-G20-2** Masked values render `••••` at every breakpoint (the responsive change is CSS-only, value layer untouched). *Test:* RP-RE-1 — masked cells stay masked at both widths; any change touching `PiiResolution` FAILS review.
- **AC-G20-3** pawchart + driftwood + demo render responsively through the SAME kit change, zero per-vertical CSS. *Test:* RP-RE-2 — a two-width check on each vertical.
- **AC-G20-4** The WS-E responsive diff touches only `samen_ui.css` + named kit components — no vertical LiveView. *Test:* RP-RE-3 — a structural diff-scope check (decompose guarantee).

### Cross-cutting
- **AC-X-1 (flagship)** The cross-surface probe (§4) exercises all five surfaces on a multi-plane fixture; the four new-PII-surface sabotages (search projection, file preview/byte-gate, export cell, profile self-edit) each flip the gate and revert byte-exact, zero residue; the fail-honest `S3.put` never returns `{:ok}`. *Test:* the WS-E flagship probe, wired into the suite permanently.
- **AC-X-2** Every surface is mounted by one router macro per vertical (≈0 authored LOC, no re-implemented framework code); all suites + every `ci.sh` (root/demo/driftwood/pawchart) green before and after each phase; verifier gate + destruction oracle stay green; adversarial gate per phase + workstream-wide.

---

## 6. Explicitly out of scope (WS-E does NOT do these)

- **Real S3/GCS storage + AV scanning** — `Storage.S3` and `Scanner` real impls are operator-TODO (fail-honest skeletons ship; no `ex_aws`/scanner dep added). WS-E ships the working `Local`/`Reject` defaults + honest skeletons.
- **Framework auth (login/password/2FA/session store/SSO/SCIM)** — deliberately host-owned (ADR-029); WS-E builds settings ON TOP of host auth, honest about the boundary. Sessions view is read-only.
- **Fleet-wide `stream`/`assign_async` perf rewrite** (end-user.md G12) — WS-E ships the `skeleton/1` primitive + wires the framework list surfaces; the per-page async conversion is deferred (decompose rule).
- **a11y pass** (end-user.md G11 / roadmap G25) — separate P2 (kit-level, but distinct from responsive; the responsive drawer/toggle will use semantic markup but a full WCAG-AA pass is out).
- **i18n / timezone / multi-currency** (end-user.md G10 / roadmap G24) — separate P2; WS-E does not add gettext/Cldr.
- **xlsx / column-transform / full merge-dedupe import UI** — CSV only, straight header→field map, upsert-on-key or create-only.
- **Semantic/vector search** — Postgres FTS only (dependency-free).
- **Webhook/flag tenant-admin UI** (end-user.md G13) — flag admin shipped WS-B; webhook admin is a separate small item.
- **Operator Cockpit v2 items** (G8 lifecycle, G11 status/SLA, G13 billing depth) — the next workstream, not WS-E.

---

## 7. Non-negotiables (baked into the ACs above)

- **Every new value-render/value-write path is masked per-plane by construction** — four masking-watch-list surfaces close in WS-E (search results, file preview, export cells, profile self-edit), each with a per-plane red-path where sabotaging the projection/chokepoint flips the gate (AC-G9-3, AC-G14-5, AC-G15-2, AC-G18-2).
- **Fail-closed / fail-honest proof** — quarantine-by-default, deny-by-default type/size, import fail-closed on bad mapping, export bounded, `S3`/`Scanner` fail-honest (never claim a no-op succeeded); every guarantee green + red-path, anti-tautology probed.
- **Framework-first, ≈0-LOC inheritance** (AC-X-2 + §3 leverage guard) — capability lands in samen_core/samen_web; verticals mount via one macro; re-implementing framework code is a finding.
- **Adversarial gate per phase + workstream-wide** (`docs/gate-ws-e.md`); commit each gated milestone; all suites + every `ci.sh` green before/after; verifier gate + destruction oracle green; ADRs (026-030) for load-bearing decisions.

## 8. New abbrev registry entries

**None.** WS-E builds ENGINES and UI over EXISTING resources (`File` `pfl`, `SearchIndex` `psh`, `User` `usr`, `ApiKey` `key`) — it introduces no new samen_core scope/resource that owns an abbrev. `Samen.Files`, `Samen.Search`, `Samen.Web.Csv`, and the settings/kit surfaces are behavior/UI modules, not abbrev-owning resources. Confirmed — no `abbrev_registry.json` change; the flagship probe (if it touches the registry at all) snapshot-restores byte-exact per the standing registry-hygiene rule.
