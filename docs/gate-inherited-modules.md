# Gate — Inherited CRM / Billing / Support Modules

**Decision: GO** (re-gated after the sidebar fix round — 2026-07-08)

Driftwood renders the three inherited universal scopes (CRM, Billing, Support) as
real, seeded LiveViews, and the primary `/broker` tenant console now exposes all three
in its sidebar (plus cross-module nav on every module page). All four app suites and the
full `driftwood/ci.sh` verifier gate are green, and the load-bearing masking invariant
holds (tenant-clear verified live + operator-masked via PiiResolution + tests, no plaintext
bypass). The one MANDATORY fix from the prior round (Defect C2 — sidebar coverage) is
CLOSED and now has a dedicated regression test. One nice-to-have display defect (C1 —
CRM contacts Email/Phone columns) remains OPEN; it is display-only, fails safe, and leaks
no PII, so it does not gate.

Seeded org: `b1112d00-0000-4000-8000-000000000001` (Blue Ridge Logistics), via
`mix driftwood.seed` (wraps `Driftwood.Seeds.dev_seed/0`).

---

## Re-gate summary (2026-07-08)

The prior round's single MANDATORY directive was:

> Expose CRM, Billing, and Support in the `/broker` tenant-console sidebar (and add
> cross-module nav on each module page) so all three inherited modules are reachable
> from the sidebar without typing URLs.

**Status: DONE.** The fix landed as a single shared `DriftwoodWeb.UIKit.module_nav/1`
component (`lib/driftwood_web/ui_kit.ex:170`) that renders four `nav_group`s — Operations
(freight 20%) + CRM + Billing + Support (inherited 80%) — with every href threaded through
the `?org=` selector. EVERY page with a sidebar (the `/broker` console and all
`/crm/*`, `/billing/*`, `/support/*` module pages) renders THIS component, so the three
inherited modules are reachable from every module, cross-linked, without typing URLs.

Verified LIVE (PORT=4021, `/healthz`=200):

- `/broker?org=…` sidebar renders `Operations / CRM / Billing / Support` groups; the
  CRM (`/crm/companies?org=…`), Billing (`/billing?org=…`), and Support (`/support?org=…`)
  links are each `is visible`.
- `/billing?org=…` (a module page) renders the SAME four groups — cross-module nav confirmed
  (Operations → Dispatch board, CRM → Companies, Support → Tickets all present).

Regression test: `test/dogfood_walkthrough_test.exs` — *"the /broker tenant console sidebar
exposes CRM, Billing, AND Support (thesis in nav)"* asserts all three group labels plus the
seven real module hrefs AND the freight `Operations` group / `/broker?panel=loads` href are
present in the rendered `/broker` HTML.

---

## (1) Coverage — all three modules render seeded data

Verified live (PORT=4021, `/healthz`=200) by reading rendered text on every gate route:

| Route | Result |
|-------|--------|
| `/crm/companies` | 9 companies (Acme, Harbor Foods, Piedmont Steel, Riverbend, Cascade, Summit, Blue Ridge Carriers…) |
| `/crm/contacts` | 12 contacts; `full_name` in the clear (e.g. "Dana Whitfield", "Amara Boone") |
| `/crm/pipeline` | BR-44xx loads grouped across pipeline stages with $ values |
| `/billing` | 6 customers in the clear (Acme Manufacturing Inc …), MRR $2,394, 6 active subs, plan pills |
| `/billing/invoices` | INV-10xx rows with paid/open/overdue/void status pills, $1,800 outstanding |
| `/billing/plans` | Starter/Growth/Scale Tier-0 plans + prices ($99/$299/$799) |
| `/support` | 10 tickets (detention/BOL/no-show disputes), open/pending metrics, CSAT 4.5 |
| `/support/tickets/:id` | Conversation thread with message bodies + agent "Sofia Marchetti" in the clear |
| `/broker`, `/operator/aggregate`, `/operator/impersonate` | boot + render (aggregate & impersonate are pre-existing planes) |

All three modules render REAL seeded rows, not empty shells.

### Defect C1 (minor, non-security) — CRM contacts Email/Phone columns render "—"

On `/crm/contacts`, the tenant plane resolves `full_name` correctly, but the **Email and
Phone columns render em-dash `—` for every row** even though the data is seeded and
resolved in the clear. Root cause: the PiiResolution resolver returns `emails`/`phones` as
a **JSON string** (e.g. `[{"label":"work","address":"amara.boone@…"}]`), but
`render_email/1` and `render_phone/1` in `lib/driftwood_web/crm_contacts_live.ex` only match
`when is_list(...)`, so they fall through to `—`. `render_full_name/1` already `Jason.decode`s
the same shape, which is why names work. This is a display bug that **hides** data — it fails
safe, never leaks — but the two columns are effectively dead on the tenant plane. Billing's
customer email renders fine (different resolver output shape), so this is CRM-contacts-specific.

### Defect C2 (moderate, thesis/UX) — sidebar does not expose all three modules — CLOSED (2026-07-08)

**RESOLVED.** The gate requires "the sidebar must expose all three modules (no dead links)".
It now does, on EVERY page:

- `/broker` (the primary tenant console) sidebar renders the shared `module_nav/1` with four
  groups — `Operations / CRM / Billing / Support`. All three inherited modules are reachable
  from the default landing page without typing URLs (verified live + regression test).
- Each module page (`/crm/*`, `/billing/*`, `/support/*`) renders the SAME four-group
  `module_nav/1`, so cross-module navigation (CRM → Billing → Support → Operations) works
  from anywhere (verified live on `/billing`).

No links are broken (each resolves 200) and none are missing. Thesis clause (4) below is now
legible in navigation.

---

## (2) Masking per plane — LOAD-BEARING CHECK — PASS

For each PII-bearing module, the tenant-clear direction was verified LIVE, and the
operator-masked direction via the module's masking test + code path.

| Module | Tenant plane (live) | Operator plane (test + code) |
|--------|--------------------|------------------------------|
| CRM `/crm/contacts` | "Dana Whitfield" renders in the clear; no `vt_`/`vault:` token | `operator_scope` → `%Masked{}`; test asserts `••••` present AND "Whitfield"/email absent |
| Billing `/billing` | "Acme Manufacturing Inc", `ap@acmemfg.example` in the clear | test asserts `••••` present AND "Acme Manufacturing Inc"/"Harbor Foods" absent (overview + invoices) |
| Support `/support/tickets/:id` | agent "Sofia Marchetti" + message bodies in the clear; no token leak | test asserts `••••` present AND "Marchetti"/"sofia.marchetti" absent |

- All three read layers (`CrmReads`, `BillingReads`, `SupportReads`) route PII through
  `Samen.Api.PiiResolution.resolve/4` after the Ash read. None call `Samen.Vault.reveal/3`,
  none unwrap `%Masked{}`, none introduce a "show plaintext" branch (grep-verified: all such
  strings are docstrings). A `%Masked{}` renders `••••` via `Phoenix.HTML.Safe`.
- `mix test` masking suites (CRM 7, Billing 11, Support 14 → 32 total) all pass, including the
  operator-plane `••••` assertions and the synthetic `%Masked{}` UIKit-invariant tests.
- The `driftwood/ci.sh` `no_plaintext_pii` + `pii_classify` + `pii_reads` verifiers pass over
  the new billing (`pii_fbc_*`) and support (`pii_fsa_*`, `pii_fsm_body`) surfaces; the
  `pii_reads` "LAUNDERED" lines are advisories (render helpers on the sink-schema allow-list),
  not failures.

**No page renders a vault token or unmasked PII where it should mask.** No `no_go` trigger.

---

## (3) Gate + suites — PASS

- `driftwood/ci.sh` — **ALL 20 steps PASSED** (compile --warnings-as-errors, schema.dict.json
  drift, catalog_parity, prefixes, pii_reads, pii_classify, no_plaintext_pii, migrations,
  sink_schema, metric_labels, vault_declared_parity, tnt_catalog, tnt_boundary, api_contract v1,
  same_org_fk, no_pii_columns, aggregate_privacy, never_read_current, default + adversarial
  suites, T5.4 crypto-shred game-day, T5.5 PITR game-day + red-path probe).
- `mix compile --warnings-as-errors` (dev) — clean.
- App suites — all green (re-run 2026-07-08): **samen_core 842 · demo 403 · driftwood 110
  (1 property, 109 tests; +5 vs prior round for the sidebar regression + module coverage) ·
  pawchart 19**.
- New resources (billing 8 + support 7) are catalogued, prefixed with Driftwood's `f`-family
  abbrevs (`fbc/fbs/fbp/fbr/fbi/fby/fbu/fbe`, `fsk/fsc/fsm/fsa/fsl/fsn/fss`), and PII-routed.
  No schema/registry drift.

---

## (4) Thesis — freight 20% + inherited 80%

**Fully realized (2026-07-08).** The MODULES exist and read as inherited scopes rendered as
first-class UI (Operations = freight vertical; CRM/Billing/Support = inherited universal
scopes) — the substance of the thesis — AND the sidebar now tells that story: every page,
starting with the default `/broker` landing console, renders a single `module_nav/1` with the
freight `Operations` group alongside the inherited `CRM / Billing / Support` groups. The
"freight 20% + inherited 80%" split is now legible in the primary navigation, not just at the
code/module level. (Was: partially realized — the prior round's sidebar showed only
Operations; see Defect C2, now CLOSED.)

---

## Fix tasks

**Mandatory (before clean GO):** — NONE remaining.
1. ~~Expose CRM, Billing, and Support in the sidebar of the `/broker` tenant console (and add
   cross-module nav on each module page)~~ — **DONE** via the shared `module_nav/1` component
   (`ui_kit.ex:170`), used by `/broker` + every module page; regression test in
   `test/dogfood_walkthrough_test.exs`. Defect C2 CLOSED.

**Nice-to-have (still OPEN — does not gate):**
2. Fix `/crm/contacts` Email/Phone columns: make `render_email/1` and `render_phone/1` in
   `lib/driftwood_web/crm_contacts_live.ex` `Jason.decode` the JSON-string shape the resolver
   returns (mirror `render_full_name/1`), so seeded emails/phones render in the clear on the
   tenant plane instead of `—` (Defect C1; display-only, fails safe, no PII leak). Confirmed
   still present on the 2026-07-08 re-gate: contact NAMES render in the clear
   ("Amara Boone", "Dana Whitfield"), but the Email/Phone columns render no address.
