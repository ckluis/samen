---
project: Cannery
url: https://codeberg.org/shibao/cannery
category: Media and Personal
relevance: low
verdict: A plain single-tenant Elixir/Phoenix self-hosted inventory app for firearms/ammo — sound conventional Phoenix craftsmanship but no Ash, no multi-tenancy, no PII-vaulting, nothing in samen's architectural wheelhouse.
---

## What the project is

Cannery is a self-hosted web app for tracking firearm ammunition inventory: containers, ammo types/packs, range-day staging, and shot-record logging. Built in Elixir/Phoenix (81.7% Elixir, 16.3% HTML/HEEx, PostgreSQL), deployed via Docker Compose behind a reverse proxy (Nginx Proxy Manager recommended), with SMTP-based invite/registration auth, an admin-role system (first registered user becomes admin), multi-locale i18n (EN/DE/FR/ES), and an offline "local mailbox" mode. AGPL-3.0-or-later. It does not use Ash (plain Phoenix/Ecto), has no multi-tenant or organization model, no API layer beyond the web UI, and no notion of PII vaulting, masking, or audit — it's a single-operator personal/home-lab tool, not a SaaS substrate.

## What samen could adopt

Nothing rises to a concrete, adoptable pattern. The two items below are minor and only worth a glance if samen's own onboarding/i18n backlog gets prioritized — neither is a differentiated pattern worth studying the source for:

- **What**: Invite-token + public-registration dual mode with "first user becomes admin" bootstrap. **Why it fits samen**: samen's identity spine (ADR-035) already has invites and registration; the "first user is admin" bootstrap convention is a trivial UX nicety samen's onboarding wizard could consider for single-operator/demo installs. **Effort**: S.
- **What**: gettext-based multi-locale i18n wired end-to-end (4 locales, env-configured default). **Why it fits samen**: G24 in samen's gap register is exactly "i18n/timezone/currency (USD+UTC hardcoded, no gettext)" — Cannery is a small, readable reference for how a Phoenix app wires gettext across LiveView templates. **Effort**: S (as a reference to skim, not a dependency to adopt).

## What to ignore and why

Ignore essentially everything else: the domain (firearm/ammo tracking) has zero overlap with samen's SaaS-foundry purpose; the architecture is single-tenant plain Phoenix/Ecto with no Ash, no vault/masking chokepoints, no two-plane model, no verifier/sabotage discipline, and no generative/CI-proof story — none of samen's load-bearing moat (crypto-shred, hash-chained audit, token-blind aggregates, catalog-as-data) has any analog here. It is a well-scoped personal self-hosted app, not a framework or reference architecture, and offers no libraries, OTP/GenServer patterns, or ops practices beyond a standard Docker Compose + reverse-proxy deploy that samen doesn't already exceed.
