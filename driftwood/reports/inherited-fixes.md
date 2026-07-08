# Inherited-Modules Fix Round

Bounded, one-pass fix round landing the mandatory navigation fix from
`docs/gate-inherited-modules.md` (Defect C2). Gate + all four app suites green
before and after.

---

## Fix R1 (MANDATORY, Defect C2) — sidebar exposes all three inherited modules

**Problem.** The gate requires the sidebar to expose all three inherited universal
scopes (CRM, Billing, Support). The `/broker` tenant console — the default landing
page — had ONLY an "Operations" `nav_group`, so a broker could not reach any inherited
module from the sidebar without typing a URL. Module pages (`/crm/*`, `/billing/*`,
`/support/*`) each showed "Operations" + their OWN module group only, with no
cross-module navigation. The "freight 20% + inherited 80%" thesis was true at the
module level but illegible in navigation.

**Fix.** Added a single shared `module_nav/1` component to the UI kit
(`lib/driftwood_web/ui_kit.ex`) — the ONE source of truth for the sidebar's
"20% + 80%" story. It renders four `nav_group`s:

- **Operations** (Dispatch board / Loads / Drivers / Settlements) — the freight vertical (the 20%).
- **CRM** (Companies / Contacts / Pipeline) — inherited.
- **Billing** (Customers / Invoices / Plans) — inherited.
- **Support** (Tickets) — inherited.

It takes `org_id` (threaded into every `href`, preserving the dogfood `?org=` selector)
and an `active` atom key that highlights exactly one item. Every page that has a sidebar
now renders `<.module_nav ... />` in place of its bespoke, duplicated `nav_group`s:

| File | active key |
|------|-----------|
| `broker_live.ex` (the `/broker` tenant console) | `broker_active(@panel)` → `:dashboard`/`:loads`/`:roster`/`:settlements` |
| `crm_companies_live.ex` | `:crm_companies` |
| `crm_contacts_live.ex` | `:crm_contacts` |
| `crm_pipeline_live.ex` | `:crm_pipeline` |
| `billing_live.ex` | `:billing_overview` |
| `billing_invoices_live.ex` | `:billing_invoices` |
| `billing_plans_live.ex` | `:billing_plans` |
| `support_live.ex` | `:support_tickets` |
| `support_ticket_live.ex` (detail) | `:support_tickets` |

This both (a) exposes all three inherited modules in the `/broker` sidebar and (b) adds
full cross-module navigation on every module page, and it removes ~9 copies of the
duplicated Operations/module nav markup.

**Tests.**

- `test/ui_kit_test.exs` — new `describe "module_nav/1"` block: renders ALL FOUR groups;
  every inherited module reachable via a resolvable `href` (no dead links); the `active`
  key highlights exactly one `.on` item and threads `org_id`; `active: nil` highlights none.
- `test/dogfood_walkthrough_test.exs` — new test: the rendered `/broker` (`BrokerLive`)
  sidebar exposes CRM + Billing + Support with real hrefs, alongside the freight
  Operations group.

**Live self-verification** (PORT=4021, `/healthz`=200, gstack `browse`):

- `/broker?org=…` rendered text contains: Operations, CRM, Billing, Support + all nav
  items (Dispatch board, Companies, Contacts, Pipeline, Customers, Invoices, Plans, Tickets).
- `browse is visible` asserted the `/billing`, `/support`, and `/crm/companies` anchors
  are present on `/broker`.
- `/billing?org=…` and `/support?org=…` rendered text each show all four groups
  (Operations + CRM + Billing + Support) — cross-module nav confirmed live.

No PII/read path was touched — this is additive navigation markup only. A `%Masked{}`
still renders `••••` (the module masking suites remain green).

---

## Gate + suites (before and after)

- `driftwood/ci.sh` — **ALL PASSED** (compile --warnings-as-errors, schema.dict drift,
  catalog_parity, prefixes, pii_reads, pii_classify, no_plaintext_pii, migrations,
  sink_schema, metric_labels, vault_declared_parity, tnt_catalog, tnt_boundary,
  api_contract v1, same_org_fk, no_pii_columns, aggregate_privacy, adversarial suite,
  T5.4 crypto-shred game-day, T5.5 PITR game-day #2 + red-path probe).
- `mix compile --warnings-as-errors` — clean.
- App suites — all green: **samen_core 842 · demo 403 · driftwood 110 · pawchart 19**
  (driftwood 105 → 110: +2 new nav tests here; remainder are pre-existing).

Status: **GREEN**. Defect C2 closed; the "freight 20% + inherited 80%" thesis is now
legible in the sidebar of every page, including the `/broker` landing console.
