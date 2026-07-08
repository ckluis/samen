# Gate — Samen UI Kit + Marketing Doc

**Decision: GO**

Date: 2026-07-08. Reviewer: gate subagent (real-effort review — booted the server, hit all
three live routes with seeded data, ran the full CI gate + all four app suites, spot-checked
5 load-bearing claims against `docs/claim-evidence.md`, screenshotted doc + app for the
consistency check).

---

## Verdict summary

| Area | Result |
|---|---|
| (1) DOC `samen.html` — house style | MATCHES kern/eigen; own indigo identity |
| (1) DOC — embedded UI quality | Mockup quality; two-plane thesis rendered explicitly |
| (1) DOC — no `<script>` / `<img>` | 0 / 0 confirmed |
| (1) DOC — claims grounded | 5/5 spot-checks MET in claim-evidence.md; honest-edges owns residues |
| (2) KIT — real + reusable | Yes; assigns/slots only, no domain import, lives per ADR-008 |
| (2) KIT — masking invariant | Preserved BY CONSTRUCTION; 5 dedicated component tests |
| (2) APP — 3 routes render at quality | Operator/Broker/Aggregate all 200, mockup quality |
| (2) APP — masking regression | **NONE** — operator masks, broker clears, aggregate no-PII |
| (2) CI gate + 4 suites | driftwood ci.sh ALL PASSED; 842 / 403 / 69+4 / 19 green |
| (3) Consistency | Doc-embedded UI and real app share the design language |

No masking regression. No blocking issues.

---

## (1) DOC — /Users/clank/Desktop/projects/experimentalArchitectures/samen.html

**House style — MATCHES, with its own identity.** Same `:root` token system, same
Fraunces + Inter + JetBrains Mono stack, same `.fade` rise animation, same nav
wordmark+tag / hero / `sec-label` → `h2-em` → `prose` rhythm, same 12-section count as
kern.html (12) and eigen.html. Own accent identity confirmed by comparison:

- kern.html: `--accent:#6D3BD6` (purple)
- eigen.html: `--accent:#0E8A5F` (green)
- samen.html: `--accent:#3B4CCA` / `--accent-deep:#2C3AA6` / `--accent-wash:#EEF0FD` (indigo)

on warm paper (`--paper:#F6F5F2`). Restraint holds — no slop, tight measure (`62ch`),
bespoke per-section diagrams.

**Embedded UI — mockup quality.** All three planes re-created inline as HTML/CSS with
bespoke `ui-*` classes (360 occurrences), self-contained, no external asset dependency.
Verified via screenshot at 1440px:
- Operator plane: masked driver roster — name + CDL render `••••` (4 masked rows), one
  revealed row (Marcus Vale) at the bottom, FMCSA badges + settlement bars in the clear.
- Tenant plane: same Blue Ridge dispatch board with names in the clear (Marcus Vale, Dana
  Whitfield, Carol Barnett) + the reshaped **Net payable $4,494.00** carrier-settlement card
  citing `settlement_math_test.exs`.
- Aggregate plane: token-blind Portfolio (MRR $284,900, metric cards) with a `no reveal
  path · k ≥ 5 · l-diversity` chip and org-level-only tables.

The two-plane contrast IS rendered explicitly — **Marcus Vale appears masked on the
operator plane and in the clear on the tenant plane** (confirmed: the name string appears
exactly twice in the DOM, once after 4 masked rows, once with an "MV" avatar). That is the
product thesis, on the page.

**No `<script>` (0), no `<img>` (0).** Confirmed by grep.

**Claims grounded — 5/5 spot-checks MET** against `docs/claim-evidence.md`:

| Doc claim | Evidence row | Status |
|---|---|---|
| Destruction oracle EXITS 0 with 15 attestations (`--tiers all`, separate OS process) | D2 (T5.4 crypto-shred game-day) | MET |
| Second-party reveal: DB `CHECK (granted_by <> requestor_id)`, self-approval refused | C3 (web_red_paths RED PATH 2) | MET |
| Settlement reshaped: `$4800−$500−$156−$50 = $4494` to the cent + 200-run property | DW3 (settlement_math_test) | MET (+ verified LIVE on broker route) |
| Hash-chained audit log immutable, operator cannot edit | C7 (DB append-only trigger refused raw UPDATE) | MET |
| 900+ tests across four hosts | 842 + 403 + 69+4 + 19 = 1,333 actually ran | MET (conservative under-claim) |

The **honest-edges section is a genuine steelman-of-the-critic**, not decoration. It names
10 residues, each labeled as a limitation not a breach, and it owns exactly the things a
reviewer would flag as oversell: "inherit the 80%" is qualified to infrastructure-not-nouns
(measured on 2 self-built hosts, not 3); KMS/PITR/RTO are "local-sim floors, real-cloud
wiring is an operator TODO"; token-blind is "not inference-blind" (deterministic read
budget, not formal ε-DP); the abbrev registry is global-not-per-host; the webhook
storage-name guard over-strictness is named as a P1. No un-evidenced, un-labeled claim
found.

---

## (2) KIT + APP — the load-bearing check

**Kit is real and reusable.** `DriftwoodWeb.UIKit`
(`driftwood/lib/driftwood_web/ui_kit.ex`, 14KB): 14 function components (app_shell,
sidebar, nav_group, nav_item, topbar, button, tabs/tab, data_table, pill, progress, metric,
mask_bar, token_blind_bar). Every one takes `attr`/`slot` assigns; **nothing imports a
Driftwood domain module** (grep: 0). Paired CSS asset
`driftwood/priv/static/assets/samen_ui.css` (17KB) served via a **scoped `Plug.Static`**
(`only: ["assets"]`, endpoint.ex:27) and linked from the root layout (layouts.ex:20). Lives
driftwood-local per **ADR-008** (`docs/adr/008-ui-kit.md`), documented as a file-move +
namespace-rename extraction to a shared `samen_ui` lib on Rule-of-Three. samen_core stays
free of phoenix_live_view/phoenix_component — its 842-test suite + verifier gate untouched.

**Masking invariant — preserved BY CONSTRUCTION.** The kit is a dumb renderer. Verified:
- 0 calls to `Samen.Vault.reveal/3` in code (the only "reveal" strings are in the moduledoc
  documenting that it *never* calls reveal, and a docstring for the aggregate banner chip).
- 0 pattern-matches destructuring a token out of `%Masked{}`.
- No "show plaintext" branch. A `%Samen.Masked{}` renders `••••` through the existing
  `Phoenix.HTML.Safe` impl.
- `test/ui_kit_test.exs` (11 tests, all pass) has 5 dedicated masking tests asserting
  pill/data_table-cell/progress each render `••••` when handed a `%Masked{}` and **refute
  the vault token ever appearing**.

**Three routes render at quality, masking holds LIVE.** Booted the dev server on :4020
(healthz 200), seeded the dev DB with `Driftwood.DogfoodScenario.build_fleet/1` +
`Samen.Impersonation.open`, then hit each route:

- **ROUTE 1 `/operator/impersonate` (MASKED)** — 200. Driver **name + CDL both render
  `••••`** (6 masked cells), non-PII fields in the clear (state TX, expiry, status, FMCSA
  "OK" / "BLOCKED: medical card expired"), per-row "Reveal CDL" second-party control. **0
  plaintext leaks** (no `CDL-OK-`/`CDL-EXP-`/`vault:`/`vt_`). Cell inspection confirms the
  driver-name and CDL `<td>`s contain only `••••`.
- **ROUTE 2 `/broker?org=<uuid>` (tenant plane, CLEAR)** — 200, **0 mask bullets**. Real
  name **Rosa Medina** renders in the clear; dispatch board shows Net payable **$4,494.00**
  (matches the settlement claim to the cent).
- **ROUTE 3 `/operator/aggregate` (token-blind, NO PII)** — 200, **0 mask bullets, 0 PII
  leaks**. Token-blind banner (`no reveal path · k ≥ 5 · l-diversity`); k-anonymity
  **suppression visibly working** — sub-floor cohorts render `⊘` with the footnote "4
  cohorts below the k-anonymity floor — suppressed … to prevent re-identification."

**CI gate + suites — ALL GREEN.**
- `driftwood/ci.sh`: **"driftwood CI gate: ALL PASSED"** — all 20 verifier steps
  (incl. step 6 no_plaintext_pii, step 15 no_pii_columns, step 16 aggregate_privacy) +
  crypto-shred + PITR game-days (both arms, incl. corrupt-restore red-path fail-closed).
- samen_core: **842 passed** (9 properties). demo: **403 passed** (52 excluded).
  driftwood: **69 passed** (4 excluded) + **4 adversarial**. pawchart: **19 passed**.
  Matches the claimed baseline exactly — no regression, no weakened assertions.

---

## (3) Consistency — doc-embedded UI vs real app

Same design language, confirmed by side-by-side screenshots. The real app's product UI
(`samen_ui.css`: `.app/.side/.main/.mask-bar/.tb-bar/.pill/.metric/.prog/.supp/.settle`)
and the doc's embedded re-creation (bespoke `ui-*` classes) render the identical visual
system: two-plane sidebar shell, masked data table, mask-bar / token-blind banners, metric
cards with sparklines, k-anon suppression footnote, reshaped two-sided settlement card. The
mockup source files (`_mockup-samen-*.html`) use the same product-UI classes as the app, so
the app and mockups share literal CSS and the doc faithfully re-creates them self-contained.

Note (not a defect): the DOC page-chrome uses the **marketing house-style** token system
(indigo `--accent`, Fraunces, `--paper`) shared with kern/eigen, while the **product app**
uses its own product palette (`--brand/--canvas/--panel/…`). This is intentional — a
marketing sibling page that *embeds* re-creations of the product UI. The two are correctly
distinct; the embedded UI still matches the real product UI.

---

## Fix tasks

### Mandatory (blocking)
None.

### Nice-to-have (non-blocking)
1. `/operator/impersonate` returns **HTTP 500** when handed a *present-but-invalid*
   `operator_id`/`org_id` (e.g. an org that doesn't exist), because `load/3` only matches
   `{:error, :session_inactive | :operator_suspended}` and any other `Impersonation.scope`
   error tuple / raise falls through the `case`. The no-params path already fails closed to
   "access denied" (F3, 200) — extend that graceful denial to the invalid-ID path (catch-all
   `{:error, _}` → `denied/3`, and rescue a bad-org read) so an invalid ID denies rather than
   500s. No PII leak either way; this is availability hygiene, not a masking hole.
2. The dev DB is not seeded by default, so the operator route only renders with a
   `DogfoodScenario`-seeded org. Consider a dev seed (or a `?demo=1` self-seeding path) so
   the documented routes are one-URL reproducible without a manual `mix run` seed step.
3. Doc hero says "900+ passing tests" — the actual total is 1,333 (842+403+69+4+19). Fine
   as a conservative floor; optionally update to the real number for a stronger claim.
4. The honest-edges section already names it: the webhook storage-name guard over-strictness
   is a tracked P1 (`cdl_number` dropped from webhook bodies by a blanket regex — absent by
   omission, never a leak). Land the "key on declared abbrev" fix when convenient.
