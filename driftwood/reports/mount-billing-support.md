# Mount Billing + Support scopes in Driftwood

**Task:** Extend Driftwood to inherit the Billing and Support universal scopes (product
thesis "build the 20% freight, inherit the 80% CRM/billing/support"). Mount them exactly
as `Driftwood.Crm` mounts the CRM scope — resources exist, are catalogued, org-scoped, and
PII-routed to vaults.

**Status:** GREEN. Full driftwood `ci.sh` gate passed before and after; all four app suites
(samen_core, demo, driftwood, pawchart) green.

## What shipped

1. **`lib/driftwood/billing.ex`** — `Driftwood.Billing` domain, `use Samen.Scopes.Billing`
   with `otp_app: :driftwood, repo: Driftwood.Repo, namespace: Driftwood.Billing` and a
   fresh-abbrev override (copied the `Driftwood.Crm` pattern).
2. **`lib/driftwood/support.ex`** — `Driftwood.Support` domain, `use Samen.Scopes.Support`,
   same shape + fresh-abbrev override.
3. **`config/config.exs`** — added `Driftwood.Billing` + `Driftwood.Support` to BOTH
   `:ash_domains` lists (`config :driftwood` and `config :samen_core, :ash_domains`, the
   list the verifier gate scans).
4. **`samen_core/priv/abbrev_registry.json`** (the authoritative global registry the
   compile-time `Samen.Verifiers.AbbrevRegistry` reads via `:code.priv_dir(:samen_core)`) —
   appended the 15 new abbrev→module rows (append-only; no samen_core code touched).
5. **`driftwood/priv/abbrev_registry.json`** — mirrored the same 15 rows for Driftwood
   bookkeeping (matches how the CRM mount maintained both) + refreshed the `$comment`.
6. **`priv/repo/migrations/20260708110000_mount_billing_support_scopes.exs`** — creates all
   15 tables with catalog rows in the SAME DDL transaction (`use Samen.Migration` +
   `catalog_sync/1`), FKs via `references(...)`, a partial index for the SLA-breach cron
   query, and a full reverse-FK-ordered `down/0`. `SameOrgFk` on every org-scoped FK is
   declared at the resource layer (in the blueprint), enforced at write time.
7. Regenerated **`schema.dict.json`** (27 tables now) and migrated the dev + test DBs.

## Abbrevs chosen (fresh, `f`-for-freight prefixed — the scope defaults are already owned by the demo mount in the global registry)

Billing:
- `fbc` → `Driftwood.Billing.Customer` (table `fbc_customer`) 🔒
- `fbs` → `Driftwood.Billing.Subscription` (`fbs_subscription`)
- `fbp` → `Driftwood.Billing.Plan` (`fbp_plan`, Tier-0)
- `fbr` → `Driftwood.Billing.Price` (`fbr_price`, Tier-0)
- `fbi` → `Driftwood.Billing.Invoice` (`fbi_invoice`)
- `fby` → `Driftwood.Billing.Payment` (`fby_payment`)
- `fbu` → `Driftwood.Billing.Usage` (`fbu_usage`)
- `fbe` → `Driftwood.Billing.Entitlement` (`fbe_entitlement`)

Support:
- `fsk` → `Driftwood.Support.Ticket` (`fsk_ticket`)
- `fsc` → `Driftwood.Support.Conversation` (`fsc_conversation`)
- `fsm` → `Driftwood.Support.Message` (`fsm_message`) 🔒
- `fsa` → `Driftwood.Support.Agent` (`fsa_agent`) 🔒
- `fsl` → `Driftwood.Support.Sla` (`fsl_sla`, Tier-0)
- `fsn` → `Driftwood.Support.Macro` (`fsn_macro`, Tier-0)
- `fss` → `Driftwood.Support.Csat` (`fss_csat`)

All 15 were verified free across all three registries (samen_core / driftwood / demo) before
reservation.

## PII lands in vaults, never plaintext (verified via runtime introspection + no_plaintext_pii)

- `Driftwood.Billing.Customer.billing_name`  → `Samen.Type.VaultField`, column `pii_fbc_billing_name`
- `Driftwood.Billing.Customer.billing_email` → `Samen.Type.VaultField`, column `pii_fbc_billing_email`
- `Driftwood.Support.Agent.full_name`        → `Samen.Type.VaultField`, column `fsa_full_name` (composite, no `pii_` prefix)
- `Driftwood.Support.Agent.email`            → `Samen.Type.VaultField`, column `pii_fsa_email`
- `Driftwood.Support.Message.body`           → `Samen.Type.VaultField`, column `pii_fsm_body` (scalar free-text)

These render `%Masked{}` (••••) by default; on the tenant plane the org's own rows resolve in
the clear via `Samen.Api.PiiResolution`, and under operator impersonation the SAME rows mask.
No new plaintext-PII column was introduced. No new `non_pii!` clearance was needed — none of
the new plaintext columns hit the `pii_classify` token list (`stripe_*_id`, `last4`, `handle`,
`timezone`, `body_template`, `comments`, etc. are all non-flagging; the PII fields are vaulted).

## Verification

- `mix compile --warnings-as-errors` clean (dev + test).
- Standalone verifiers green: catalog_parity, prefixes, pii_reads, pii_classify (baseline
  schema.dict.json), no_plaintext_pii, vault_declared_parity, same_org_fk, no_pii_columns,
  migrations (down/0), api_contract v1.
- Full `driftwood/ci.sh` gate: ALL 20 steps PASSED (incl. schema.dict drift, default suite
  69 passed / adversarial 4 passed, T5.4 crypto-shred + T5.5 PITR game-days).
- Cross-app: samen_core `mix test` 842 passed; `demo/ci.sh` PASSED; `pawchart/ci.sh` PASSED.
- App boots healthy with the new domains mounted (`/healthz` = 200 on port 4021); existing
  tenant/operator routes still render (no regression).

## Follow-on (out of scope for this mount task)

- No UI page renders billing/support yet — that is the next task (render inherited scopes as
  real UI using `DriftwoodWeb.UIKit`).
- The Support SLA-breach Oban cron (`Samen.Scopes.Support.SlaBreachWorker`) and its
  `:support_sla_breach_ticket_resource` config are NOT wired — mounting the resources does not
  obligate the host to run the cron. Wiring is a follow-on ops/UI concern.
