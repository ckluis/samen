# SEED — 5 fully-populated brokerages + operator book of business (ADR-013 §8)

Rewrote the Driftwood dev seed so `mix driftwood.seed` stands up **five named, fully-populated,
VARIED** freight brokerages plus the operator org's book of business over all five. One command,
idempotent, prints the tenant list + ids. Every module on every plane is non-empty, and each
tenant shows its OWN branded book (carriers/shippers/contacts/emails/loads) — no Blue-Ridge clones.

## What changed (Driftwood-local only; samen_core + samen_web UNTOUCHED)

- `driftwood/lib/driftwood/seeds.ex` — the bulk. `@brokerages` extended with per-tenant BRANDING
  (`domain`, own `carriers`/`shippers`/`factoring` company names, `prefix`, `origin`/`dest`/
  `equipment`, `size`). New `spec_for/1` (org_id → spec, Blue-Ridge default for test orgs). Every
  generator is now spec-driven: `companies_for/1`, `seed_people/3` (deterministic per-org name
  window via `name_offset/1`, tenant-domain emails), `seed_opportunities/3` (spec lane/prefix +
  load-status variety open/won/lost/on_hold), `customers_for/1`, `agents_for/2` (tenant-domain
  agent emails), `tickets_for/2` (own load numbers + carriers), `do_seed_marketing/2` (spec copy +
  own contacts as subscribers), `do_seed_chat/2` (now **3 threads/tenant** incl. the cross-plane
  object-unfurl thread, via new `seed_thread/4`). Mix-task output prints the tenant list + ids.
- `driftwood/lib/driftwood/dogfood_scenario.ex` — `build/1` now takes carrier/shipper/lane/prefix
  branding (defaults preserve the historical scenario for no-option test callers) and seeds a
  THIRD driver: **valid / expiring (medical +14d, still dispatchable) / expired** — the full
  valid/expiring/expired FMCSA spread. Fleet carrier/shipper use dedicated names
  ("<Brokerage> Fleet Services" / "<Origin> Regional Distribution") so they never duplicate the
  demo_all book.
- `driftwood/lib/mix/tasks/driftwood.seed.ex` — prints the 5-tenant table (id · name · lane · tier
  · MRR) + the operator org id.
- Tests updated to the new realistic data (no behavior change, just literals + the driver count):
  `crm_ui_test` (first company → "Appalachian Freight Lines"), `billing_ui_test` (first customer →
  "Asheville Brewing Supply Inc"), `dogfood_walkthrough_test` + `web_red_paths_test` (driver count
  2 → 3).

## The five brokerages (fixed uuids, varied size/health/lane/tier)

| id …    | name                    | lane   | tier    | MRR     | health  |
|---------|-------------------------|--------|---------|---------|---------|
| …001    | Blue Ridge Logistics    | TX→CA  | growth  | $2,500  | healthy |
| …002    | Summit Freight Partners | IL→GA  | growth  | $3,000  | healthy |
| …003    | Gulf Stream Carriers    | FL→NY  | scale   | $4,800  | at-risk (past-due) |
| …004    | Cascade Freightways     | WA→AZ  | starter | $1,200  | healthy |
| …005    | Ironline Brokerage      | OH→TX  | scale   | $5,200  | at-risk (dunning)  |

Operator org (Driftwood Ops / Samen SaaS, Inc.): `0f000000-0000-4000-8000-0000000000aa`.

## Per-tenant counts (identical shape across all 5; VARIETY is in the names/lanes/health)

Freight: 10 companies · 12 contacts · 36 activities · 8 loads (statuses: open/won/lost/on_hold) ·
3 drivers (valid/expiring/expired FMCSA) · 1 settlement.
Billing: 6 customers · 12 invoices (6 paid / 4 open / 2 void) · 6 payments · 3 plans · 3 prices.
Support: 10 tickets (open/pending/on_hold/resolved × urgent/high/normal/low) · 3 agents · 4
conversations · 8 messages · 1 SLA · 1 macro · 2 CSATs.
Marketing: 1 campaign · 1 template · 1 segment · 6 subscribers · 1 suppression (red-path).
Chat: 3 threads · 3 messages — thread 1 is the flagship **cross-plane object-unfurl** thread
(pastes `samen:crm.person:<id>` + `samen:freight.driver:<id>` refs referencing THIS tenant's own
rows), thread 2 a platform-billing question, thread 3 a tenant-internal onboarding thread.

## Operator book of business over all 5 (OPERATOR plane)

5 accounts (mixed health: 3 healthy, 2 at-risk) · 5 platform subscriptions (3 active + 2 past-due:
Gulf Stream + Ironline) · 7 platform invoices (2 past-due for dunning) · 10 SaaS desk tickets
(2/tenant) · 4 operator-CRM Leads/prospects (not-yet-customers).

## Verification

- `mix driftwood.seed` — one command, prints the tenant table + ids, idempotent (re-run keeps
  Summit at 10 companies; per-org markers guard freight/CRM/marketing/chat).
- No clone leak: Summit renders Summit's own book (Great Lakes Line Haul, Midwest Cold Storage,
  Peachtree Foods, SF-prefixed Chicago→Atlanta reefer loads), Gulf Stream its own, etc.
- **Masking intact** (dev server, PORT=4036): tenant `/crm/contacts?org=Summit` → 12 rows, all
  `@summitfreight.example` emails IN THE CLEAR, header "Summit Freight Partners", no vault-token
  leak, no ••••; operator desk-chat over Summit → threads listed "masked"; agent email column at
  rest is a `vt_…` vault token (no plaintext). `/` → 302 `/operator/accounts` (5 accounts, mixed
  health). `/chat` (no org param) → session-default inbox lists 3 threads (owner's "no org
  selected" complaint fixed); `/chat?org=Summit` → Summit's 3 threads.

## Gates — all green (before + after)

- Driftwood full CI gate (`ci.sh`, all 20 steps incl. crypto-shred + PITR game-days): **ALL
  PASSED**. New rows pass `catalog_parity` / `pii_classify` / `no_plaintext_pii` / `pii_reads` /
  `sink_schema` / `vault_declared_parity` (no new columns → `schema.dict.json` unchanged; PII
  still vault-routed through the same Ash attributes).
- Driftwood default suite 89 passed + adversarial 4 passed; `--warnings-as-errors` clean.
- samen_web 184 passed (framework untouched). demo/pawchart unaffected (framework + kernel
  unchanged).
