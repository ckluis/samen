---
project: nyght
url: https://gitlab.com/nyght/nyght
category: Business and Collaboration
relevance: medium
verdict: Actively-maintained Swiss production Phoenix app for venue/staff ops — no Ash and AGPL (patterns only, never code), but a strong live reference for i18n (G24), shift-scheduling as a scope, a pluggable integrations marketplace, and DB-backed granular RBAC (G28).
---

# 057 — nyght

## What the project is

Nyght is an **event and staff management platform for music venues** — events with prices/types/attachments, staff **shifts** with volunteer applications, performers, locations (PostGIS), organizations, and third-party integrations. It is a real, revenue-adjacent production app: maintained by Ebullition (a Swiss venue in Fribourg), governed by a steering committee of paying venue members, deployed continuously from `master` to a hosted service, with 2,759 commits, 67 releases (v1.8.1), and sponsorship from the canton of Fribourg, Zulip, and Weblate.

**Stack:** Elixir ~>1.18, Phoenix 1.8 + LiveView 1.1, plain **Ecto contexts (no Ash)**, Bandit, Tailwind, Oban + oban_web, Swoosh + MJML emails, cloak_ecto field encryption, ex_cldr suite + gettext + tz (full i18n), Flop/flop_phoenix pagination, geo_postgis, ex_aws_s3, AppSignal, sobelow + credo + phoenix_test in CI, devenv.sh dev environment. License: **AGPL-3.0-only**.

Domain layout (`lib/nyght/`): accounts, authorizations (DB-backed roles/permissions/resources with per-role policies), events (event + price + type + attachment, each with a `*_policy.ex`), shifts (shift, shift_location, application — staff apply to shifts — each with policies), performers, locations, organizations (multi-org tenancy), integrations (adapter behaviour + installation records + per-adapter config/UI components + buffered integration logs + Oban worker; adapters: generic webhook, in-situ.ch listing sync), v_objects (hand-rolled iCalendar/vCard: VCALENDAR/VEVENT/VCARD), plus vault.ex/crypto.ex/secret.ex (cloak vault) and emails.

## What samen could adopt

**License note first: AGPL-3.0-only vs samen's MIT — adopt patterns and library choices only; never copy code.**

1. **CLDR-first i18n stack as the G24 blueprint** — ex_cldr + ex_cldr_dates_times/calendars/territories/plugs + gettext 1.0 + tz/tz_extra, with Weblate as the community translation pipeline.
   - Why it fits: G24 (i18n/timezone/currency, USD+UTC hardcoded, no gettext) is an open samen gap; nyght is a working multilingual (fr/de/en Swiss) Phoenix 1.8/LiveView 1.1 app proving this exact stack in production, including locale negotiation via ex_cldr_plugs. Samen already wraps ex_money (a CLDR-family lib), so ex_cldr slots in coherently with `Samen.Type.Money`.
   - Effort: **L** (cross-cutting; per the decompose rule this is an ADR + phased items, but nyght de-risks the library selection).

2. **Shifts/staffing as a new universal scope blueprint** (`Samen.Scopes.Shifts` or an extension of `work`/`calendar`) — shift + shift_location + application (worker applies, manager approves) with per-resource policies.
   - Why it fits: samen's scope catalog (work, calendar, locations…) has no staffing/scheduling primitive; shift-with-application is a recurring SaaS vertical need (venues, clinics — pawchart, field service, retail) and nyght gives a proven minimal data model. Application approval maps naturally onto samen's E3 approvals engine, and shift assignments onto calendar + notifications scopes.
   - Effort: **M** (one scope blueprint + generator coverage + policy matrix tests).

3. **Integrations marketplace pattern** — an `Integration` (catalog entry) / `Installation` (per-org config + credentials) split, adapter behaviour with per-adapter config schema *and* per-adapter UI component, buffered integration **logs** (buffer/handler/entry) surfaced to the tenant, and an Oban delivery worker.
   - Why it fits: samen has webhook ingress/egress and fail-honest vendor adapters, but no tenant-facing "install an integration, configure it, see its delivery logs" product surface — a standard SaaS expectation. The Installation-with-policy + tenant-visible log buffer is the adoptable shape; samen would route credentials through the vault and delivery through `Samen.Delivery.Chokepoint`.
   - Effort: **M** (new scope/surface over existing webhook + adapter machinery).

4. **DB-backed granular RBAC** (`authorizations` context: role, permission, resource, role_policy) — org-defined custom roles composed from a permission catalog, rather than a fixed enum.
   - Why it fits: G28 (operator RBAC granularity, P3) is open; nyght shows the minimal table shape for tenant-defined roles that still evaluates through a central policy module — compatible with samen's fail-closed `OrgScope` + policy layer.
   - Effort: **M**.

5. **iCalendar/vCard emission (v_objects)** — small hand-rolled VCALENDAR/VEVENT/VCARD builders with no external dep.
   - Why it fits: samen_web already has an `ics` surface; nyght validates the zero-dependency approach (INV-4-friendly) and adds vCard, useful for CRM contact export. Mostly confirmation, plus a vCard idea.
   - Effort: **S**.

6. **MJML for transactional email templating** (`mjml` NIF-backed compiler) + Swoosh.
   - Why it fits: samen's delivery chokepoint sends through ESP adapters but has no rich responsive-template story; MJML is the industry-standard responsive email DSL. Caveat: it is a Rust NIF, so per INV-4 it belongs in an adapter/web package, never samen_core.
   - Effort: **S/M**.

7. **Ops garnish worth noting**: sobelow in CI (static Phoenix security lint — cheap to add to samen's gate, S); devenv.sh reproducible dev env (S, optional); oban_web dashboard for the operator plane (S, though samen prefers first-party operator surfaces per its ash_admin rejection — same taste question applies).

## What to ignore and why

- **The application code itself** — AGPL-3.0-only is incompatible with samen's MIT publication; ideas and library picks only.
- **Plain-Ecto context architecture** — hand-written contexts, changesets, and per-resource policy modules are exactly what samen's Ash + `Samen.Resource` + generators replace; nothing to learn architecturally there.
- **cloak_ecto for PII** — samen's ADR-003 already rejected Cloak-style app-key encryption in favor of the per-subject-key KMS vault with crypto-shred; nyght's vault is strictly weaker (no per-subject shred, no masking, no reveal grants).
- **Flop pagination** — samen has a deliberate keyset-pagination reads contract; Flop's offset/filter param model would regress it.
- **AppSignal, ex_aws_s3, hackney/req usage in-app** — samen's observability (OTel) and fail-honest S3 skeleton positions are settled; vendor HTTP deps in the app core violate INV-4.
- **Kino/kino_db in :prod deps** — a Livebook-attached-to-prod debugging convenience; clever but contrary to samen's audited, chokepointed operator plane.
- **The domain product itself** — samen is a foundry, not a venue-management product; nyght matters as a pattern donor and as evidence a solo-maintainable Phoenix SaaS in this shape works, not as a component source.
