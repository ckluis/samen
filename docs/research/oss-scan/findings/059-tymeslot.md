---
project: Tymeslot
url: https://github.com/Tymeslot/tymeslot
category: Business and Collaboration
relevance: medium
verdict: Active same-stack (Elixir 1.20/Phoenix 1.8/LiveView/Oban) self-hosted Calendly with the best open Elixir calendar-sync adapter family and availability engine — mine it as a patterns-only reference (AGPL) for a samen scheduling scope, outbound-URL hardening, and credential-rotation workers.
---

# 059 — Tymeslot

## What the project is

Tymeslot is a self-hosted, open-source Calendly alternative: booking pages, multiple named availability schedules (hours, breaks, buffers, booking windows, minimum notice), custom per-meeting-type questions, embeds, and optional Stripe Connect payments. It is the backbone of a real managed cloud (tymeslot.app, free + €9/mo Pro), actively developed (v1.11.1, ~3,300 commits, 174 stars, not archived), owned by Diletta Luna OÜ (Estonia), licensed **AGPL-3.0**.

Stack is unusually close to samen's: **Elixir ~1.20 / OTP 28, Phoenix 1.8, LiveView 1.1, PostgreSQL, Oban, Bandit/Finch/Req, Hammer, gettext + `tz`**, Tailwind, Swoosh + MJML email, stripity_stripe, caldav_client. It is plain Ecto (schema/query-module separation), not Ash, single-tenant-per-instance, no operator plane, no PII vault.

Distinguishing depth:
- **Calendar sync engine** (`lib/tymeslot/integrations/calendar/`): behaviour-based adapters for Google, Outlook, Apple iCloud, generic CalDAV, Nextcloud, Radicale, Zimbra, Baikal, mailbox.org; `sync.ex`/`sync_broadcast.ex`, `reconnection.ex` (token refresh/repair), a `recurrence/` dir, bidirectional sync with cross-calendar conflict detection.
- **Availability engine** (`lib/tymeslot/availability/`): weekly patterns → overrides → breaks → buffers, layered slot computation (`calculate.ex`, `time_slots.ex`, `conflicts.ex`, `free_busy`), each schema paired with a queries module, plus `input_validation.ex` and an `audit.ex`.
- **Security module** (`lib/tymeslot/security/`): `encryption.ex` + `encrypted_storage.ex` for credentials at rest, **`credential_reencryption*` (online key-rotation workers)**, signed tokens (no-login cancel/reschedule links), account lockout, rate limiter, and a full **SSRF guard suite** (`ssrf_guard.ex`, `dns_resolution.ex`, private IPv4/IPv6 detection, `url_validation.ex`, `ip_normaliser.ex`) protecting webhook/CalDAV outbound fetches.
- Ops/quality: Docker-first deploy (also Cloudron/Railway), runtime `/admin` settings, sobelow + mix_audit + excellent_migrations + credo + dialyxir in CI, Wallaby e2e, test-affected selection, 6 UI locales, HMAC-signed webhooks (`meeting_created/cancelled/rescheduled`), Slack/Telegram notifiers, Google Meet/Teams/Zoom/MiroTalk video adapters.

## What samen could adopt

**License gate first: AGPL-3.0 code cannot be copied into MIT samen. Everything below is design/pattern adoption or dependency adoption (the Hex deps themselves are separately licensed), implemented cleanroom.**

1. **Calendar-sync adapter family as a `samen_calendar_*` vendor package.** What: `Samen.Calendar.Provider` behaviour + Google/Outlook/CalDAV adapters (adopt `caldav_client ~2.0` hex lib), a sync engine with reconnection/token-refresh handling, recurrence expansion, and free-busy merge. Why it fits: samen already ships `Samen.Scopes.calendar` + ICS emit but has no external calendar sync; Tymeslot's provider matrix is the proven Elixir map of what a real sync engine needs (per-provider quirks, reconnection, conflict detection), and it slots directly into samen's INV-4 vendor-adapter + fail-honest pattern (unconfigured provider → `{:error, :not_configured}`). OAuth refresh tokens are textbook vault-class PII/credentials for samen's chokepoint. Effort: **L**.

2. **Availability/booking engine design for a scheduling scope.** What: the layered model — weekly schedule → date overrides → breaks → buffers/min-notice → conflict merge against synced calendars → slot generation — plus public booking page with custom questions. Why: "bookable resource" is a near-universal SaaS vertical need (pawchart the vet vertical is an obvious first consumer: appointment booking); Tymeslot's schema decomposition (four schema/query pairs + pure computation modules) is a direct blueprint for `Samen.Scopes.scheduling` blueprint macros with samen's rich `Duration`/tz types. Effort: **M** (engine) on top of item 1.

3. **Signed no-login action links (cancel/reschedule).** What: HMAC-signed, expiring, single-purpose tokens letting a counterparty act without an account. Why: samen's tenant end-customers are exactly this persona (masked, no login); the pattern composes with samen's existing grant/expiry discipline and audit chain — a "capability URL" primitive in samen_web usable by notifications, DSAR confirmations, approvals. Effort: **S**.

4. **SSRF guard suite at the outbound-HTTP chokepoint.** What: URL validation + DNS resolution pinning + private-IPv4/IPv6/link-local rejection + IP normalization before any user-configured URL fetch (webhooks, BYO CalDAV/Nextcloud endpoints). Why: samen has tenant-configurable webhooks today and item 1 would add user-supplied CalDAV URLs; samen's chokepoint-everything doctrine says this belongs as one guard in the delivery/webhook egress path, with a sabotage patch proving it fires. Effort: **S/M**.

5. **Online credential re-encryption (key-rotation) workers.** What: `credential_reencryption.ex`-style Oban-driven rolling re-encryption of stored secrets under a new key, with query support for finding stale-key rows. Why: samen's vault has per-subject keys behind a `Samen.Kms` behaviour but key *rotation* is not a shipped drill; a modeled, resumable rotation job + verifier tier (`samen.verify.key_rotation`?) is squarely on samen's WS-L real-infrastructure roadmap. Effort: **M**.

6. **i18n/timezone evidence stack for gap G24.** What: `gettext` + `tz` (+ `flagpack` for locale UI) with 6 shipped locales, and MJML (`mjml ~6.0` Rust NIF) + Swoosh for responsive transactional email. Why: samen's G24 (USD+UTC hardcoded, no gettext) is an acknowledged open gap and its email templates are plain; Tymeslot proves this exact stack works on Elixir 1.20/Phoenix 1.8. MJML compile belongs at samen's delivery chokepoint so masked rendering still holds. Effort: **M**.

7. **CI static-gate additions.** What: `excellent_migrations` (unsafe-migration lint), `sobelow`, `mix_audit` wired into ci.sh. Why: cheap, complements samen's own `samen.verify.migrations` with community-maintained unsafe-op rules; sobelow/mix_audit cover Phoenix-specific and dep-CVE classes samen's bespoke verifiers don't. Effort: **S**.

8. **Stripe Connect reference.** What: a working `stripity_stripe ~3.3` payments + Connect integration in production. Why: samen's G13 Stripe sync is a stub; when the operator turns on live keys, Tymeslot is a same-stack reference for webhook handling and payment lifecycle (read as reference only — AGPL). Effort: reference, no direct work item.

## What to ignore and why

- **Any direct code reuse** — AGPL-3.0 vs samen's MIT; patterns and hex deps only, cleanroom implementations.
- **Plain-Ecto schema/query architecture** — samen is Ash-native; Tymeslot's context layout is informative but its data layer doesn't transfer (samen's blueprint macros + policies supersede it).
- **Auth stack** (bcrypt + oauth2 + Keycloak/Okta wiring) — samen's identity spine (assent OIDC, TOTP, vaulted credentials) is already deeper; nothing to take.
- **Themes/white-label, embeds, Slack/Telegram bots, video-provider adapters (Meet/Zoom/Teams/MiroTalk)** — product-surface features for a scheduling *product*, not substrate; only worth revisiting if a samen vertical ships booking pages publicly.
- **Single-container Docker + bundled Postgres deploy** — contradicts samen's Fly/Neon posture and two-plane multi-app model.
- **Its rate limiting/account lockout** — samen already has ash_rate_limiter + hammer on auth/webhook ingress; lockout is a minor delta at best.
- **`nodejs` bridge and asset pipeline details** — samen_web has its own UI kit and no Node runtime dependency; keep it that way.
