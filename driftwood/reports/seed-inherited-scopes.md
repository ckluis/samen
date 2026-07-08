# Seed the inherited-scope pages (CRM · Billing · Support)

## Task

Extend the Driftwood dev seed so the INHERITED universal-scope pages are populated
with realistic freight-flavored data for the Blue Ridge Logistics tenant org (and
enough for the operator aggregate). Product thesis: "build the 20% (freight), inherit
the 80% (CRM/billing/support)."

## Callable

`Driftwood.Seeds.demo_all/1` — seeds EVERYTHING (CRM · Billing · Support) for a given
`org_id` (default: the fixed Blue Ridge org), returns the `org_id`, idempotent-ish
(guarded by the Support-agent `claims-desk` handle marker).

`Driftwood.Seeds.dev_seed/0` — the full DEV path: builds the freight fleet (fixed org +
a second org for the aggregate k-anon floor) via `DogfoodScenario.build/1`, then layers
`demo_all/1` on top, then rebuilds the cross-tenant aggregate. Returns the org id.

One-liner / mix task: `MIX_ENV=dev mix driftwood.seed` (wraps `dev_seed/0`; prints the
org id + the `/broker?org=<uuid>` URL).

## Seeded org id (fixed)

`b1112d00-0000-4000-8000-000000000001` (Blue Ridge Logistics tenant). A second org
`…0002` is seeded freight-only so the token-blind aggregate plane has >1 tenant/cohort.

The org id is fixed so the dev one-liner and the LiveView `?org=<uuid>` param agree
without ceremony (a real deploy derives it from the authenticated session).

## Row counts (fixed org, after `mix driftwood.seed`)

| Scope   | Resource      | Count |
|---------|---------------|-------|
| CRM     | companies     | 10 (8 demo + 2 from fleet build) |
| CRM     | people        | 12 (dispatchers/carrier reps/shipper contacts, WITH full_name/emails/phones PII) |
| CRM     | opportunities | 8 (6 BR-44xx loads across stages + 2 fleet loads) |
| CRM     | pipeline stages | 6 |
| Billing | customers     | 6 (WITH billing_name/billing_email PII) |
| Billing | plans / prices| 3 / 3 (Starter/Growth/Scale) |
| Billing | subscriptions | 6 |
| Billing | invoices      | 12 (6 paid, 4 open incl. overdue, 2 void) |
| Billing | payments      | 6 |
| Support | tickets       | 10 (detention/BOL/no-show disputes, open/pending/on_hold/resolved) |
| Support | agents        | 3 (WITH full_name + email PII) |
| Support | conversations | 4 |
| Support | messages      | 8 (vault-routed body PII) |
| Support | SLA / macro   | 1 / 1 |
| Support | CSAT          | 2 |

`demo_all/1` in isolation (no fleet) seeds exactly 8 companies / 6 opportunities — the
extra 2 each come from the freight fleet build in `dev_seed/0`.

## PII masking (verified)

Person `emails`/`full_name`, Customer `billing_name`/`billing_email`, Agent
`full_name`/`email`, and Message `body` are VAULT-ROUTED. Raw Postgres columns hold
`vt_…` tokens at rest — no plaintext email/name in the column (asserted in
`test/demo_seeds_test.exs`). On the tenant plane the resolver returns cleartext; under
operator impersonation the SAME rows render `%Masked{}` (••••). The seed introduces NO
plaintext-PII path.

## Files

- `lib/driftwood/seeds.ex` — added `demo_all/1`, `dev_seed/0`, `blue_ridge_org_id/0`,
  and the CRM/Billing/Support builders + Tier-1 custom-field definitions.
- `lib/mix/tasks/driftwood.seed.ex` — the `mix driftwood.seed` dev task.
- `test/demo_seeds_test.exs` — counts, invoice mix, idempotency, PII vault routing.

## Gate (green before AND after)

- `driftwood/ci.sh` — ALL PASSED (catalog_parity, prefixes, pii_reads, pii_classify,
  no_plaintext_pii, no_pii_columns, same_org_fk, api_contract, schema.dict drift,
  crypto-shred + PITR game-days).
- `mix compile --warnings-as-errors` — clean (dev + test).
- Suites: samen_core 842 · demo 403 · driftwood 73 · pawchart 19 — all green.
- Self-verified by booting dev (PORT=4021, healthz=200) and reading rendered text:
  `/broker?org=…&panel=loads` shows the BR-44xx loads; `&panel=roster` shows the
  driver roster in clear (tenant plane owns its PII).

No schema/catalog/registry changes were needed — Billing + Support were already mounted
(`config/config.exs` :ash_domains + `lib/driftwood/{billing,support}.ex`).
