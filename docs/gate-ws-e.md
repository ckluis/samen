# GATE — WS-E "Table Stakes UX" (workstream gate, phase E7)

**Decision: GO**

Date: 2026-07-18

Scope gated: the ENTIRE WS-E workstream — six shipped build phases + the E2i automation unit
across seven committed commits, each already phase-gated GO, plus the E7 units (E7.1 vertical
adoption, E7.2 flagship cross-surface probe, E7.3 this gate + roadmap re-rank), now
adversarially re-gated as a whole (round 1).

| Phase | Commit | Scope |
|---|---|---|
| E1 | `1ce78f3` | Files kernel — `Samen.Files.Storage` (`Local`+fail-honest `S3`) + `upload/3` chokepoint + `Scanner` quarantine |
| E2 | `fdc3cce` | Files web — Upload/Preview LiveViews + plane-gated byte-serve + `samen_files_routes` |
| E2i | `2647c14` | Gate automation — `scripts/sabotage.sh` harness + repo `CLAUDE.md` + `Samen.MaskingCase` |
| E3 | `2f64f18` | CSV — `Samen.Web.Csv` + per-plane-masked export + governed import + `samen_csv_routes` |
| E4 | `9a45cfa` | Search — `Samen.Search` kernel + `command_palette` + `samen_search_routes` |
| E5 | `4dbf160` | Settings — Profile/ApiKeys/Security LiveViews + `samen_settings_routes` |
| E6 | `94c1bf8` | Responsive kit — breakpoints + off-canvas drawer + skeleton loading + global ⌘K |
| E7 | *uncommitted* | Vertical adoption (E7.1) + flagship cross-surface probe (E7.2) + this gate + roadmap re-rank (E7.3) |

Inputs: `docs/ws-e/design.md` (all 28 ACs, §5), `docs/ws-e/build-plan.md` (E7 units + the full
carry section incl. the E5 positive-sessions carry), ADR-026/027/028/029/030, the seven phase
commits, and the live tree.

---

## Verdict in one line

WS-E workstream-wide adversarial gate (round 1): **GO**. All **28 ACs** map to a named covering
test/probe in the tree; all five suites reproduce their counts with `--warnings-as-errors` clean;
every `ci.sh` green; the standing `scripts/sabotage.sh` harness re-runs all **15** committed
sabotages non-vacuously with byte-exact restore; the E7.2 flagship cross-surface probe binds the
FOUR new-PII-surface sabotages (files byte-serve, export cell, search projection, profile write)
into that harness and each flips a NAMED flagship test + reverts byte-exact; the E5 positive-
sessions carry is RESOLVED in code (driftwood renders a real impersonation session). Two P2
findings (§Findings), no P0/P1, neither blocking.

**Tree state:** HEAD = `94c1bf8` (E6); the uncommitted set is the E7 delta — pawchart's three
router mounts + its 3 mount-proof assertions, the samen_web flagship probe, the four sabotage-patch
header bindings, the driftwood positive-sessions render, and the three doc updates (this gate, the
build-plan carries, the roadmap re-rank) — awaiting the commit that follows this gate.

---

## Green — suite counts (exact, all green, reproduced this gate with `SAMEN_SABOTAGE=1 ./ci.sh`)

| Suite | Result |
|---|---|
| samen_core | **1179 passed** (13 properties, 1166 tests), `--warnings-as-errors` clean |
| samen_web | **598 passed** (1 property, 597 tests) — incl. the new `ws_e_flagship_probe_test.exs` (7 tests) |
| demo | **454 passed** (17 properties, 437 tests), 52 excluded — API-only, unchanged by E7 |
| driftwood | **110 passed** (1 property, 109 tests), 4 excluded — incl. gate_e5 positive-sessions render (+1) |
| pawchart | **49 passed** — incl. the 3 E7.1 mount-proof assertions (+3, was 46) |
| root `ci.sh` spikes | s00:4 · s02:11 · s03:15 · s04:6 · s05:50 · s07:13 — all green |
| gen_app flagship + post-app + deploy probes + verifier gates | all green (non-vacuous, byte-exact restore) |
| `SAMEN_SABOTAGE=1` harness | **15/15 sabotages flipped named tests; byte-exact restores** |
| ci.sh final line | `==> ROOT CI: ALL PASSED` |

---

## AC coverage — all 28 mapped to a named covering test/probe

The design (`docs/ws-e/design.md §5`) defines **exactly 28 ACs**: AC-G14-1..7 (7), AC-G9-1..5 (5),
AC-G15-1..5 (5), AC-G18-1..5 (5), AC-G20-1..4 (4), AC-X-1..2 (2). Each maps to a named test verified
this gate; masking-watch-list ACs additionally bind a committed sabotage.

### G14 Files (ADR-026)
| AC | Covering test | Sabotage bind |
|---|---|---|
| AC-G14-1 | `files_surface_test`: "a successful upload creates a :quarantined File row"; driftwood `gate_e2_files_e2e_test` (upload→promote→serve) | — |
| AC-G14-2 | `samen_core` chokepoint-guard tests (`ChokepointGuard`) | `01-e1-chokepoint-bypass` |
| AC-G14-3 | `samen_core/test/files_storage_test`: S3 fail-honest; flagship "S3: put never returns ok" | `02-e1-s3-fail-honest-lie` |
| AC-G14-4 | `files_surface_test`: "quarantine is fail-closed … NOT :active" | `03-e1-quarantine-default-active` |
| AC-G14-5 | `file_preview_masking_test` (per-plane) + flagship "files byte-serve … REFUSED 403" | `05-e2-plane-gate-bypass` |
| AC-G14-6 | `files_surface_test`: content-type/oversize refused before storage | `04-e1-allowlist-wildcard` |
| AC-G14-7 | driftwood `gate_e2_files_e2e_test`; pawchart `samen_web_mount_test` files route-proof | — |

### G9 Search (ADR-027)
| AC | Covering test | Sabotage bind |
|---|---|---|
| AC-G9-1 | `search_surface_test`: "ranked, org-scoped results"; driftwood `gate_e4_search_e2e_test` | — |
| AC-G9-2 | `search_masking_test` (registered-column-only) + `SearchIndexGuard` PII refusal | (index guard, green) |
| AC-G9-3 | `search_masking_test` (per-plane) + flagship "search … masks full_name" | `10-e4-search-projection-plane-bypass` |
| AC-G9-4 | `search_surface_test`: "org A never renders org B rows" (org-scoped + `Reads`-bounded) | — |
| AC-G9-5 | `search_surface_test`: "an empty term renders … no result rows (fail-closed)" | — |

### G15 CSV (ADR-028)
| AC | Covering test | Sabotage bind |
|---|---|---|
| AC-G15-1 | `csv_surface_test` + driftwood `gate_e3_csv_e2e_test` (export+import round-trip, two resources) | — |
| AC-G15-2 | `csv_masking_test` (per-plane) + `csv_surface_test` masked route + flagship "export … the mask" | `06-e3-export-plane-bypass` |
| AC-G15-3 | `csv` import vault-routing tests | `07-e3-import-insert-all` |
| AC-G15-4 | `csv` bounded-export test | `08-e3-unbounded-export` |
| AC-G15-5 | `csv` bad-mapping fail-closed tests | `09-e3-mapping-allow-forbidden` |

### G18 Settings (ADR-029)
| AC | Covering test | Sabotage bind |
|---|---|---|
| AC-G18-1 | `settings_surface_test`: "one macro mounts the three surfaces"; driftwood `gate_e5_settings_e2e_test` | — |
| AC-G18-2 | `profile_masking_test` (per-plane) + flagship "profile … REFUSED" | `11-e5-profile-plaintext-write` |
| AC-G18-3 | `settings` api-keys show-once/digest tests | `12-e5-apikey-store-raw` |
| AC-G18-4 | `settings` api-key ceiling tests | `13-e5-apikey-ceiling-bypass` |
| AC-G18-5 | `settings_surface_test` honesty + `gate_e5` positive-sessions render (E5-P2 carry resolved) | `14-e5-security-fake-toggle` |

### G20 Responsive (ADR-030)
| AC | Covering test | Sabotage bind |
|---|---|---|
| AC-G20-1 | `responsive_masking_test` (data_table/list_view/skeleton) + E6 CSS `@media`/drawer | — |
| AC-G20-2 | `responsive_masking_test`: "%Masked{} cell renders •••• through the responsive data_table"; flagship "responsive … renders the mask" | `15-e6-list-loading-paints-rows` (loading contract) |
| AC-G20-3 | pawchart/driftwood inherit the SAME kit change (mount tests; zero per-vertical CSS) | — |
| AC-G20-4 | `responsive_masking_test`: "the responsive-touched Samen.UI kit carries no unmasking path" (scope guard) | — |

### Cross-cutting
| AC | Covering test | Sabotage bind |
|---|---|---|
| AC-X-1 | **`ws_e_flagship_probe_test`** (7 tests: 4 surface binds + S3 + cross-surface unification + responsive) | 05/06/10/11 (+02 at samen_core) |
| AC-X-2 | E7.1 mount matrix (driftwood full set; pawchart files/CSV/search; demo API-only) + every `ci.sh` green | — |

---

## The E7.2 flagship cross-surface probe (AC-X-1) — non-vacuous, harness-bound

`samen_web/test/samen/web/ws_e_flagship_probe_test.exs` seeds ONE org's fixture across every new
PII surface (a CRM `Person` for export+search, an identity `User` for profile, a `File` for
byte-serve) and proves they share the ONE `PiiResolution` seam: on the operator plane every surface
renders the shared secret as `••••`; on the tenant plane every surface renders it CLEAR (the
"same-pixel across every export/preview/search/profile" guarantee). The probe does NOT re-derive
flips — each surface assertion is BOUND into the standing harness by naming a flagship test in the
committed patch header, so `scripts/sabotage.sh` proves refutability:

| Surface | Flagship test (MUST_FAIL bound) | Patch | Harness result |
|---|---|---|---|
| Files byte-serve | "flagship files byte-serve … REFUSED 403" | `05-e2` | flip confirmed + byte-exact restore |
| Export cell | "flagship export … the mask" | `06-e3` | flip confirmed + byte-exact restore |
| Search projection | "flagship search … masks full_name" | `10-e4` | flip confirmed + byte-exact restore |
| Profile write | "flagship profile … REFUSED" | `11-e5` | flip confirmed + byte-exact restore |
| S3 fail-honest | "flagship S3: put never returns ok" | `02-e1` (samen_core) | flip proven at `files_storage_test` (one-app-per-patch; see carry) |

The 7th probe test is the cross-surface unification (all four surfaces mask the SAME secret on the
operator plane ∧ clear on the tenant plane, one fixture) — the AC-X-1 "flagship" whole. Green in every
`mix test`; the flips are the opt-in `SAMEN_SABOTAGE=1` step.

---

## The sabotage harness (re-run this gate — 15 patches, non-vacuous, byte-exact restore)

`SAMEN_SABOTAGE=1 ./ci.sh` ran `scripts/sabotage.sh`: all **15** committed sabotages
(`scripts/sabotages/01..15`) applied → their NAMED tests FAILED (including the four newly-bound
flagship tests) → reverted byte-exact (sha-256 verified, zero residue). `SABOTAGE HARNESS: ALL
PASSED`. No new sabotage patches were derived at E7 (the four PII-surface flips already existed as
05/06/10/11; E7.2 bound the flagship into them rather than re-deriving — the standing discipline).

---

## Cross-phase hunts (round-1 focus — all pass)

1. **Export × search share `PiiResolution` — SAFE.** The flagship cross-surface test asserts the CSV
   export cell, the search hit's `full_name`, the Person read, and the User read ALL resolve to the
   same `••••` on the operator plane and all go clear on the tenant plane — proving no surface has a
   private unmasking path; sabotaging either projection (06/10) flips the shared assertion.
2. **Files quarantine × preview gate — SAFE.** `files_surface_test` proves a fresh upload is
   `:quarantined` (preview refused) AND the operator-plane byte gate is independent (403 even on an
   `:active` file); patches 03 (quarantine) and 05 (plane) flip independently.
3. **Import × profile self-edit share the write chokepoint — SAFE.** Both route through
   `WriteGuard`/`Vault.Change`; patch 07 (import `insert_all`) and patch 11 (profile scope-drop) each
   flip their own governed-write red-path; neither weakens the other.
4. **Responsive is value-blind — SAFE.** `responsive_masking_test` + the flagship responsive test
   prove `%Masked{}` stringifies to the mask with a hardened `Inspect` at every layout; the only
   refutable code seam E6 added (the list `loading` contract) is bound to patch 15.

---

## E7.1 — the vertical adoption / mount matrix (honest, verified against the live tree)

| Surface | driftwood | pawchart | demo |
|---|---|---|---|
| Files (`samen_files_routes`) | ✅ mounted (E2) | ✅ **mounted (E7.1)** | ✗ API-only |
| CSV (`samen_csv_routes`) | ✅ mounted (E3) | ✅ **mounted (E7.1)** | ✗ API-only |
| Search (`samen_search_routes`) | ✅ mounted (E4) | ✅ **mounted (E7.1)** | ✗ API-only |
| Settings (`samen_settings_routes`) | ✅ mounted (E5) | ✗ no Identity namespace | ✗ API-only |
| Responsive (CSS/kit) | ✅ inherited | ✅ inherited | n/a (no HTML UI) |

**demo is API-only by construction** — `DemoWeb.Router` is a `Plug.Router` (forwards `/api/v1` to the
AshJsonApi endpoint), with no Phoenix router / `:browser` pipeline / `live_session`. All five WS-E
surfaces are LiveView-or-CSS over an HTML UI demo does not have, so NONE can mount there — the same
reason demo carried none of the notifications/chat/operator LiveView mounts since WS-A. Demo's PII
masking rides its JSON:API surface, covered by demo's own suite. Not a gap.

**pawchart mounts three of four LiveView surfaces at ≈0 LOC** (files/CSV/search over its existing
`PawChart.Primitives`/`PawChart.Crm`; route-proofed by +3 assertions in `samen_web_mount_test.exs`).
**Settings is NOT mounted:** `samen_settings_routes` requires a mounted Identity namespace
(`User`/`ApiKey`/`Membership`) and pawchart materializes no `Samen.Scopes.Identity` scope. Mounting it
would first require materializing an Identity scope (new abbrev-owning resources via the sanctioned
allocator + migrations) — well beyond an ≈0-LOC adoption and outside E7.1's "mount EXISTING framework
surfaces" scope. **driftwood remains the full-set reference host** (all four LiveView surfaces +
CSS-inherited responsive), and the leverage guard holds everywhere: every mounted surface is one
router-macro line over an existing namespace, zero re-implemented framework code.

---

## Carry dispositions (the "Carries into E7" list)

| Carry | Disposition |
|---|---|
| E5-P2 (bind a positive-sessions render at E7) | **RESOLVED** — `gate_e5_settings_e2e_test` opens a real governed `Impersonation.Sessions.open/1` session on driftwood (migrates `imp_impersonation_session` + `:impersonation_repo`) and renders `SecurityLive`, asserting the session row present + empty-state absent + no `phx-click`/`phx-submit`. The positive control the samen_web host could not provide. |
| E2i-P2 (bind driftwood `gate_e2` into patch 05 for the vertical-mount flip) | **DECLINED (recorded)** — harness is one-app-per-patch; a driftwood test cannot bind into the `samen_web` patch 05 without a NEW driftwood patch that re-derives the SAME byte-serve flip — a re-derivation the discipline forbids. The plane-gate flip is now bound at samen_web by TWO named files (file-preview + flagship). |
| E4-P2 (tsvector-trigger bound to driftwood; demo/pawchart follow-on) | **CARRIED** — pawchart's E7.1 search mount ships WITHOUT the trigger migration; the kernel engine builds its tsvector at QUERY time from registered non-PII columns, so search is correct without it. The per-abbrev trigger/GIN index remains the documented follow-on. |
| E1/E3/E6-P2 recorded items (audit best-effort, hand-rolled CSV, value-blind responsive, ⌘K inline script) | **CARRIED unchanged** — deliberate postures re-affirmed; none flagged by a cross-phase hunt. |

---

## Findings

### WS-E-E7-P2-1 — the flagship S3 fail-honest flip binds at samen_core, not in the same harness step (P2)

The E7.2 flagship binds four of AC-X-1's five clauses (files/export/search/profile) into the
`samen_web` patches so the harness flips a NAMED flagship test for each. The fifth clause —
fail-honest `S3.put` never `{:ok}` — is asserted GREEN in the flagship but its HARNESS FLIP stays
bound to `02-e1-s3-fail-honest-lie` (`APP: samen_core`, `files_storage_test.exs`), because
`scripts/sabotage.sh` runs one app per patch and a `samen_web` flagship test cannot be listed under a
`samen_core` patch. The S3 guarantee is therefore doubly proven (green in the flagship, refutable in
patch 02) — just not in the same harness step. No correctness gap; a binding-locality precision item.
Fix (optional): split the S3 fail-honest into a samen_core flagship member if a single-step bind is
wanted, or leave as recorded (patch 02 already covers the flip).

### WS-E-E7-P2-2 — pawchart settings unmounted for lack of an Identity namespace (P2)

AC-X-2's "every surface mounted by one router macro per vertical" holds for files/CSV/search on
pawchart but NOT settings: pawchart has no `Samen.Scopes.Identity` mount, so `samen_settings_routes`
has no `User`/`ApiKey`/`Membership` to serve. This is a structural precondition, not a leverage-guard
failure (mounting would be one line the day pawchart grows an Identity scope). driftwood proves the
settings mount at ≈0 LOC. Recorded so the mount matrix is not overclaimed as "all five in every
vertical". Fix: materialize a pawchart Identity scope via the sanctioned allocator if a second
settings host is wanted, or narrow the claim (done here + in the roadmap).

No P0/P1.

---

## Carries forward (this gate's P2s + WS-E follow-ons + standing items)

1. **WS-E-E7-P2-1** — S3 fail-honest single-step bind (optional; doubly proven today).
2. **WS-E-E7-P2-2** — pawchart Identity scope to unlock its settings mount (or keep the narrowed claim).
3. **Real `Storage.S3` + `Scanner` impls** — operator-TODO; fail-honest skeletons shipped, never `{:ok}`
   for a no-op (ADR-026 §6). No `ex_aws`/scanner dep added.
4. **Framework auth (login/2FA/session-store/SSO)** — deliberately host-owned (ADR-029); the Security
   surface is read-only and honest about the boundary. Not a WS-E gap.
5. **Fleet-wide `assign_async`/`stream` perf rewrite** — deferred (decompose rule); the `skeleton/1`
   primitive + list-surface loading contract shipped.
6. **Per-abbrev tsvector trigger/GIN index for demo/pawchart search-at-scale** (E4-P2 follow-on).
7. **⌘K global shortcut** ships as a dependency-free inline layout `<script>` (no esbuild in the
   samen_web asset pipeline); movable to a `phx-hook` if a host adds a bundle (E6-P2).
8. **Standing (pre-WS-E):** SMTP/ESP adapter = operator TODO (fail-honest) · `PageLimitClamp` until
   upstream Ash fixes `to_page` · ADR-025 verifier host-partition · demo `mk_agent` → `Samen.Factory`
   optional tightening · WS-C `:non_pii` self-classify escape hatch · G17b health-activity fidelity ·
   real Neon/AWS/ClickHouse/Fly drills = human operator.

---

## Fix tasks

**Mandatory: none.** The gate is GO; both P2s are non-blocking and carried forward above. WS-E is the
last planned workstream — with this gate, all four planned workstreams (A/B/D/E) are gated GO and all
six flagged mask-by-omission PII surfaces are closed with per-plane red-paths bound into the standing
sabotage harness. The immediate next step is the E7 commit banking the uncommitted set this gate
verified (pawchart mounts + the flagship probe + the four patch bindings + the driftwood positive-
sessions render + the three doc updates).
