# Gate — Demo Coherence (Driftwood three-plane, session-resolved current org)

**Decision: GO (with one non-blocking caveat)**

Verified by booting Driftwood in dev (PORT 4036), seeding via `mix driftwood.seed`, and
driving the live app with the headless browser. All five suites are green. The bar —
"a person can SEE how the three-plane system works by clicking, WITHOUT typing a UUID or
hitting a dead-end" — is met. One cosmetic defect found (empty name in the "acting as"
banner); it does not block, does not affect navigation/scoping/masking, and is filed as a
mandatory fix-forward.

---

## What was verified (evidence)

### 1. NAVIGABILITY — landed, drilled, switched, returned. Zero typed UUIDs, zero dead-ends.

Exact click-path driven with the browse tool (no hand-typed `?org=` anywhere the point is
navigability):

1. **`GET /`** → 302 → **`/operator/accounts`** (the Driftwood Ops dashboard). No params.
   Renders 5 tenant accounts with KPI cards: 5 tenant orgs · 3 healthy · 2 at-risk
   (past-due/dunning) · **Platform MRR $6700.00**. (Screenshot: `/tmp/operator_dashboard.png`.)
2. **Click "Open account →" on Summit** (snapshot ref `@e14`, href
   `/session/org/b1112d00-…-002?return_to=%2Fbroker`) → session-write → lands on **`/broker`**
   (clean URL, no `?org=`), Summit's freight console.
3. **Navigate to `/crm/contacts` with NO `?org=`** → session sticky → scoped to **Summit**:
   header reads "Summit Freight Partners" (label bug GONE), contacts are Summit's own
   `@summitfreight.example` emails in the clear, "Summit Capital Factoring" present.
4. **Open the workspace switcher (`<details id="workspace-switcher">`), click "Gulf Stream
   Carriers"** (href `/session/org/…-003?return_to=%2Fcrm%2Fcontacts`) → returns to the SAME
   module for the new org → `/crm/contacts` now scoped to **Gulf Stream**
   (`@gulfstreamcarriers.example`, "Gulf Coast Factoring Group"). Distinct book per tenant.
5. **`/chat` with NO `?org=`** → **inbox with 3 threads** ("Rate confirmation for load
   GS-4415", "Question about our Scale plan invoice", "Onboarding a new carrier on the
   Miami→Newark lane"). The owner's exact "no org selected" complaint is resolved.
6. **`/billing/invoices`, `/support`, `/marketing/leads`, `/crm/pipeline`** — all render
   populated, scoped to the session org, no `?org=`, no dead-end (Billing: $1800 open;
   Pipeline: $30,800 across stages).
7. **Switcher → "← Driftwood Ops (operator)"** returns UP to `/operator/accounts` (the
   operator plane ignores the session current org — it is cross-tenant).

Confirmed: **zero hand-typed UUIDs, zero dead-ends** on the navigability path. `?org=` appears
only in app-GENERATED deep links (thread permalinks, the impersonate link) — never typed.

### 2. THREE PLANES COHERENT

- **Operator** (`/operator/*`): cross-tenant. Accounts (all 5, health/MRR/tenant-admins in
  the clear), Platform billing, Desk (tickets FILED WITH the SaaS by tenant-admins —
  `marlene.okafor@blueridge.example` in the clear, "requester = a tenant-admin · assigned to
  SaaS staff"), Portfolio (token-blind aggregate). No tenant org needed.
- **Tenant** (`/broker`, `/crm/*`, `/billing/*`, `/support`, `/marketing/*`): the freight
  brokerage's own modules over its own data, PII in the clear.
- **Shared** (`/chat`, billing, helpdesk): SAME objects, DIFFERENT purpose per plane —
  demonstrated on chat: the tenant's `/chat` (own console, clear) vs the operator's
  `/operator/desk-chat` (drills into the tenant's threads, masked).
- **Label bug gone**: every tenant/shared page header reads the resolved org NAME
  ("Summit Freight Partners" / "Gulf Stream Carriers"), not the static "Workspace".

### 3. SEED DEPTH — all 5 tenants populated; operator book tells a story. (Live counts.)

Per-tenant (identical shape, DISTINCT data — the "Blue-Ridge-clones" gap is fixed):

| tenant | person | company | opp | invoice | ticket | thread |
|---|---|---|---|---|---|---|
| Blue Ridge / Summit / Gulf Stream / Cascade / Ironline | 12 | 10 | 8 | 12 | 10 | 3 |

- **Opportunity status spread** (Blue Ridge): open 5 · won 1 · lost 1 · on_hold 1 (full enum).
- **Invoice status spread** (all tenants): paid 30 · open 20 · void 10.
- **Operator book**: 10 desk tickets · 7 platform invoices (the past-due/at-risk story lives
  here) · 15 tenant chat threads (3×5). MRR varies $1200–$5200; Gulf Stream shows $0 / "at
  risk" (past-due), Blue Ridge $2500 / healthy — a real healthy-vs-at-risk narrative.
- **FMCSA driver spread**: valid 5 · expiring 5 · expired 5 (the "3rd driver" claim — the
  expiring-but-still-dispatchable case now exists).

### 4. MASKING intact (no regression) — verified per-viewer on the SAME thread.

Thread `e0afbafe-…` (Gulf Stream, disclosure `tenant_wide`):

- **Tenant view** (`/chat/<id>`): participant `gulfstreamcarriers-dispatch` in the CLEAR,
  0 masked bullets, body visible.
- **Operator view** (`/operator/desk-chat/<id>`): 2 masked `••` bullets, message body HIDDEN
  ("Everglades/flatbed" not shown), "operator desk · masked" chrome. (Participant handle
  visible only because the tenant chose `tenant_wide` disclosure — the 3-state model working.)
- **Tenant CRM/broker**: end-customer PII (`@gulfstreamcarriers.example`) in the clear.
- **Operator Desk**: tenant-ADMIN PII in the clear (correct — they are the SaaS's own
  customers, ADR-010 tenant plane), tenant END-customer PII never surfaced.

The masking line is the plane line. CurrentOrg only chooses WHICH org's data a page reads;
`PiiResolution` still decides clear-vs-`••••` by actor plane. No regression.

### 5. GREEN — all suites.

| suite | result |
|---|---|
| samen_web (`ci.sh`) | **184 passed**, PASSED (compile `--warnings-as-errors` clean) |
| demo (`mix test --warnings-as-errors`) | **403 passed** (17 properties, 386 tests) |
| driftwood (`MIX_ENV=test bash ci.sh`) | **ALL PASSED** (full verifier gate + crypto-shred game-day + red-path probe) |
| pawchart (`MIX_ENV=test bash ci.sh`) | **ALL PASSED** — framework nav changes did NOT break the second vertical |

samen_core was not touched (design-honored; abbrev-registry append-only). PawChart green
proves the `Samen.Web.CurrentOrg` / `SessionController` / mount-seam changes are safe for
every inheriting vertical.

---

## Defect found (non-blocking)

**Empty name in the "acting as" banner.** In
`samen_web/lib/samen/web/current_org.ex`, `acting_as_banner/1` declares
`attr :name, :string, default: nil` (line 267). The attr default assigns `assigns.name = nil`
BEFORE the function body runs, so `assign_new(assigns, :name, fn -> name(assigns.mount,
assigns.org_id) end)` (line 276) sees `:name` already present and skips the fallback. Result:
the banner renders `You are viewing <b></b> (acting as tenant)` — empty `<b>`.

- **Impact**: cosmetic. The topbar/breadcrumb header show the org name correctly (they call
  `CurrentOrg.name/2` inline), so the page is never anonymous. Navigation, session-stickiness,
  scoping, and masking are all unaffected.
- **Fix**: drop the `attr :name` default (or compute the name directly in the body without
  `assign_new`) so the fallback fires.
- Secondary observation (nice-to-have): the banner renders whenever `tenant_plane? and
  org_id` is present, including the default-org case where the operator did not explicitly
  "act as" a tenant. Consider gating it on an actual session current-org so it reads as a true
  impersonation banner rather than always-on chrome.

## Notes / caveats (not defects)

- `/operator/impersonate` (the freight-vertical masked drill-in) correctly returns
  "access denied — no active impersonation session" without an active grant — that is its own
  freight-specific session gate, not a coherence break. The framework masked plane
  (`/operator/desk-chat`) is where cross-plane masking is demonstrably shown.
- The Gulf Stream "Onboarding" cross-plane thread rendered its body in the clear (tenant view)
  but showed no unfurl object-cards; the flagship `samen:` object-unfurl thread (ADR-012) is
  seeded elsewhere and is out of scope for demo-coherence. Not a blocker.
- The `<details>` workspace switcher needs its `<summary>` clicked to reveal items — native
  behavior, works for a real user without JS; only the headless driver needed the panel opened
  first.

---

## Fix tasks

**Mandatory (fix-forward, non-blocking to the GO):**
1. Fix the empty-name bug in `Samen.Web.CurrentOrg.acting_as_banner/1`: remove the
   `attr :name` default so the `assign_new` fallback computes the org name.

**Nice-to-have:**
2. Gate `acting_as_banner/1` on an actual session current-org (not the mount default) so it
   only appears during a real act-as, not on the default-org landing.
3. Seed the flagship object-unfurl cross-plane thread (`samen:crm.person` +
   `samen:freight.driver` refs) so the unfurl cards are visible in the demo chat.
