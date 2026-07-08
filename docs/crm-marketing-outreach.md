# CRM email/sequences + prospecting (ADR-011 Phases 4–5) — Build report

**Task:** Build the framework email/sequences + prospecting surface per ADR-011 (§7 email/
sequences, §8 prospecting) — mount the previously-unmounted Marketing scope, ship an OUTREACH
surface (campaigns/sequences list + a compose page that targets a segment and enqueues
Oban-backed sends, consent/suppression enforced), a segments/PROSPECTING view + a leads list,
with the send path reading subscriber emails via `PiiResolution` on the TENANT plane and NEVER
exposing them on the operator plane. Framework-level in `samen_web`; Driftwood + the samen_web
test host prove it. `samen_core` code UNTOUCHED (only the abbrev-registry data file appended).

**Status:** GREEN. All four suites + every ci.sh gate green before and after;
`--warnings-as-errors` clean; `samen_core` code untouched (registry-only append is the
sanctioned change).

- samen_web: **102 passed** (was 86; +16 marketing render/red-path/operator-isolation).
- driftwood default: **89 passed** (was 82; +7 marketing UI). driftwood 20-step `ci.sh`: ALL
  PASSED (incl. catalog_parity / prefixes / pii_reads / pii_classify / no_plaintext_pii /
  same_org_fk / vault_declared_parity / migrations / api_contract / crypto-shred + PITR
  game-days).
- samen_core: **842 passed** (code untouched). demo: **403 passed** + demo CI gate ALL PASSED.
  pawchart CI gate ALL PASSED.

## Routes added (framework `Samen.Web.Router.__routes__(:marketing, path)`)

- `GET {mkt}/campaigns`      → `Samen.Web.Marketing.CampaignsLive`  (campaigns/sequences list)
- `GET {mkt}/campaigns/:id`  → `Samen.Web.Marketing.CampaignLive`   (compose + send — the
  load-bearing outreach surface)
- `GET {mkt}/segments`       → `Samen.Web.Marketing.SegmentsLive`    (prospecting: segments +
  subscribers + suppression list)
- `GET {mkt}/leads`          → `Samen.Web.Marketing.LeadsLive`       (leads lens: CRM contacts
  by lifecycle_stage)

Default path `/marketing`. Host mounts in ONE line:
`samen_module_routes(:marketing, <Host>.Marketing, repo: <Host>.Repo, labels: %{crm_namespace: <Host>.Crm})`.
`Samen.Web.Mount.scope_kind` + `Samen.Web.Router.{default_path,__routes__}` gained `:marketing`
(bounded framework enum — a one-line append). `Samen.UI.module_nav/1` gained a Marketing nav
group (Campaigns · Segments · Leads) with a `marketing_path` attr — every vertical inherits it.

## What shipped (all in `samen_web`, the framework)

- **Mounted the Marketing scope.** `Samen.WebTest.Marketing` (abbrevs `wm*`) + `Driftwood.Marketing`
  (abbrevs `fm*`) each `use Samen.Scopes.Marketing` — seven host-owned resources materialized,
  catalogued via a catalog-in-tx migration (`mount_marketing_scope`), abbrevs reserved in
  `samen_core/priv/abbrev_registry.json` (append-only, 14 rows). `subscriber.email` vault-routed
  (`pii_<abbrev>_email`).
- **`Samen.Web.Marketing.Reads`** — the read + send layer. Reads campaigns/templates/segments/
  subscribers/events/suppressions through `Mount.resource/2` (host-agnostic). `Subscriber.email`
  resolved through `Samen.Api.PiiResolution` (tenant clear / operator ••••). `enqueue_send/3`
  enforces consent/suppression, `send_campaign_to_segment/6` + `send_to_subscribers/6` fan out
  per-recipient with a visible result, `add_subscriber/3` enrolls a CRM contact (refuses a
  masked email).
- **`CampaignsLive` / `CampaignLive` / `SegmentsLive` / `LeadsLive`** + a shared
  `Samen.Web.Marketing.Live` (sidebar + plane note). Compose page: template + segment selects,
  "Send to segment", per-recipient result pills ("queued" / "suppressed — skipped"),
  email_event count pills, a recipients list (email PiiResolution-resolved).
- **`Samen.Web.CRM.Reads.leads/3`** — the leads lens read (contacts filtered by
  `custom["lifecycle_stage"]`, PII-resolved). `contacts/2` now selects `:custom`.

## The load-bearing consent/suppression + Oban design (a real finding)

**The kernel `Send.:create_checked` suppression query hardcodes the table `msp_suppression`**
(the demo-abbrev table) and does NOT enqueue the Oban job (its moduledoc claims it does; the
code only builds the changeset). Abbrevs are globally unique (`msp` is owned by
`Demo.MarketingScope.Suppression`), so ANY host mounting Marketing with fresh abbrevs
(required) gets a suppression check that queries the wrong/absent table — a silent bypass. Since
`samen_core` code is untouched, the framework `Reads.enqueue_send/3` enforces suppression at the
FRAMEWORK layer (an Ash read of the host's OWN `Suppression` resource — works for ANY abbrev),
fail-closed, THEN creates the send via the kernel `:create_checked` (keeping its same-org-FK
guard), THEN enqueues `Samen.Scopes.Marketing.SendWorker` with TOKEN-ONLY args
(`send_id`/`org_id`/`subscriber_id` — never the email). Order: suppression → consent/status →
create → enqueue.

## Consent result (the red path)

- **RED PATH proven** (samen_web + driftwood): `enqueue_send` to a SUPPRESSED subscriber →
  `{:error, :suppressed}`, **no send row created** (asserted before/after count). An
  unsubscribed/bounced subscriber → `{:error, <status>}`. A mixed batch surfaces per-recipient:
  active `{:ok, _}`, suppressed `{:error, :suppressed}`; the compose page renders
  "suppressed — skipped".
- **GREEN PATH proven**: `enqueue_send` to an ACTIVE subscriber → `{:ok, send}` (status
  `:queued`), a send row + an Oban job (driftwood test env, `testing: :manual`).
- Seeded (samen_web test host + driftwood dogfood): a campaign + template + segment + an ACTIVE
  and a SUPPRESSED subscriber + a `Suppression` row, so the pages populate and the red path is
  demonstrable.

## Operator-isolation result

- **The operator plane cannot enumerate a tenant's contact/subscriber emails.** Proven in both
  suites: on `plane: :operator` the subscriber `email` renders `••••` (masked) on
  `SegmentsLive` and `CampaignLive`, the plaintext is ABSENT (`refute html =~ <email>`), no
  vault token / `pii_` column leaks, and the compose/send controls are HIDDEN (an operator does
  not dispatch a tenant's outreach). `Reads.subscribers` returns `%Samen.Masked{}` for every
  email on the operator plane and the clear string on the tenant plane. The SEND ITSELF carries
  only the opaque `subscriber_id` — never the email — so nothing leaks even in the send row.

## Driftwood (proves it — no LiveView code)

`Driftwood.Marketing` domain (one `use`) + `samen_module_routes(:marketing, …)` + a
`mount_marketing_scope` migration + `schema.dict.json` refreshed + `seed_marketing` (a Q3
lane-offer campaign, a Carrier-onboarding template, an Active-carriers segment, 6 subscribers
from the seeded contacts, 1 suppression). Dogfood (PORT 4034): `/marketing/campaigns`,
`/marketing/campaigns/:id`, `/marketing/segments`, `/marketing/leads` all returned 200 with the
seeded data, recipient emails clear on the tenant plane, the suppressed subscriber flagged.
Screenshot `/tmp/mkt_campaign_compose.png`.

## Catalog-parity / prefixes / pii_classify / no_plaintext_pii

The 7 new `fm*` (driftwood) tables pass every driftwood verifier — catalogued in the same
migration transaction, correct `<abbrev>_<col>` prefixes, `pii_fms_email` classified as the one
vault column, no plaintext PII, no schema.dict.json drift. Same for the `wm*` tables in the
samen_web test host (its own vault-routing test asserts `pii_wms_email` is a `vt_` token).

## Not in this build (noted, not gold-plated)

A real ESP `SendWorker.Adapter` (the stub marks `:delivered`); email_event ingestion webhook; a
richer segment filter language (Phase-4 minimal targets subscribers by `status`); an inline
"Add to audience" button wired on the contact detail (the `Reads.add_subscriber` path is built +
tested, the affordance is a follow-up); a first-class send-scheduling/sequence-step engine.
