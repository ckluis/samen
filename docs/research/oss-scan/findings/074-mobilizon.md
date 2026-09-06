---
project: Mobilizon
url: https://framagit.org/kaihuri/mobilizon
category: Communication and Social
relevance: medium
verdict: Mature production Elixir/Phoenix reference in an adjacent domain — mine it for i18n/geo/ICS/webpush library choices, not architecture.
---

# 074 — Mobilizon

Note: the manifest URL (`framagit.org/kaihuri/mobilizon`) is a fork; the canonical repo is `framagit.org/framasoft/mobilizon` (Framasoft, AGPL-3.0-or-later, ~6,900 commits, 91 releases, active since 2017, v3.x current).

## What the project is

Mobilizon is Framasoft's federated event and group management platform — an "ethical alternative to Facebook Events." Instances federate over ActivityPub; users create events, groups, discussions, polls, and shared resources. Stack: Elixir ~>1.15, Phoenix ~>1.8 (API-first — the UI is a Vue SPA over an Absinthe GraphQL API with Dataloader), Ecto/Postgres with PostGIS (`geo_postgis`) for geospatial queries, Oban for jobs, Swoosh/gen_smtp for mail, Guardian JWT + Argon2 + a wide Ueberauth OAuth matrix (Google, GitHub, Discord, Keycloak, ...), Sentry, LiveView only marginally. It is a community/consumer product: single-instance multi-user, not multi-tenant SaaS; no Ash; authorization via a forked `rajska` GraphQL middleware rather than a policy engine.

## What samen could adopt

1. **`geospatial` hex package / pluggable geocoder behaviour** — Framasoft extracted Mobilizon's geocoding layer into a standalone library (`Geospatial.Providers.{Nominatim, Addok, Photon, Mimirsbrunn, ...}`, swapped by one config line, per-provider endpoint/API-key config). Why it fits: samen_web already has a `geo` module and samen's fail-honest vendor-adapter pattern (INV-4) is exactly this shape — a `Samen.Geo.Provider` behaviour with Nominatim as the reference impl and `{:error, :not_configured}` skeletons would slot into a `samen_geo` adapter package cleanly, and Mobilizon's provider list is a proven menu of open-source geocoders. Effort: S–M.
2. **`ex_cldr` + `tz_world`/`tzdata` for the G24 i18n gap** — Mobilizon is the best-in-class Elixir example of full localization: ex_cldr for locale/number/date formatting, gettext across backend+frontend (Weblate-driven), tz_world to resolve an event's timezone from its lat/long, timezone-aware scheduling everywhere. Why it fits: samen's gap register G24 (USD+UTC hardcoded, no gettext) is open; Mobilizon shows the exact dependency set and the timezone-from-location trick that any calendar/scheduling scope (samen has `Samen.Scopes.calendar` + ICS) eventually needs. Effort: M (library adoption) to L (full gettext sweep).
3. **ICS/calendar-feed conventions** — per-user and per-group ICS feeds behind unguessable feed tokens, ICS export of events, ATOM feeds, all via a maintained iCalendar fork. Why it fits: samen ships ICS support already; the tokenized private-feed pattern (revocable feed tokens as a distinct credential class) is the piece worth copying, and it composes with samen's grant/audit machinery. Effort: S.
4. **Web push notifications** (`web_push_encryption`, VAPID) — Mobilizon delivers event reminders/participation updates as browser push alongside email. Why it fits: samen's notifications subsystem has inbox + prefs + email; web push is a cheap third channel behind the existing `Samen.Delivery.Chokepoint`, keeping the single-send-path invariant. Effort: M.
5. **HTML sanitization posture** (`fast_sanitize` + Floki, plus `linkify` for safe mention/URL detection) — all user-authored rich text passes one sanitizer. Why it fits: samen's chokepoint-everything philosophy has send/upload/AI chokepoints but rich-text scopes (cms, docs, chat, support) benefit from one named sanitize chokepoint with a sabotage patch proving it can fail. Effort: S.
6. **Anonymous/low-friction participation UX** (email-confirmed anonymous event RSVP, no account required) — a pattern worth noting for samen verticals with end-customer surfaces (pawchart-style booking): capability-token participation without identity, PII (the email) vault-routed. Effort: M, only when a vertical needs it.

## What to ignore and why

- **ActivityPub federation, HTTP signatures, instance moderation/relays** — the heart of Mobilizon, irrelevant to a single-operator multi-tenant SaaS substrate; enormous complexity budget for zero samen value.
- **Absinthe GraphQL + Vue SPA + Dataloader + rajska authz** — samen is deliberately LiveView + JSON:API deny-by-default with Ash policies; adopting a second API paradigm would fork the authz story and break catalog/verifier parity.
- **Guardian JWT + Ueberauth OAuth matrix** — samen's identity spine (assent OIDC, nimble_totp, vaulted credentials, ADR-035) is stronger and already gated; Mobilizon's auth predates modern per-tenant needs and has no PII vaulting.
- **PostGIS dependency** — heavyweight for samen's current geo needs; only revisit if a vertical needs radius search.
- **General architecture** — no multi-tenancy, no masking/vault concept, plaintext PII at rest, no policy engine, no verification harness; Mobilizon is a domain reference, not a substrate reference.
