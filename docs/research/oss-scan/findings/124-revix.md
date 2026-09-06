---
project: Revix
url: https://github.com/curt/revix
category: Media and Personal
relevance: low
verdict: A single-tenant, AGPL-3.0 personal location journal with ActivityPub federation — different domain, different license, no Ash, nothing samen's PII-vaulted multi-tenant SaaS substrate needs.
---

## What the project is

Revix is a self-hosted personal location journal: users log check-ins (place + timestamp + notes), write freeform posts, tag companions, and federate with other instances over ActivityPub (Follow/Accept/Undo, Create/Update/Delete, Like/Undo, custom Ping/Pong handshakes) using per-user RSA keypairs, HTTP Signatures, WebFinger discovery, and JSON-LD/Atom feeds. Stack: plain Phoenix 1.8 + LiveView + Ecto (no Ash), PostgreSQL/PostGIS for geodata, Tailwind v4, Waffle+S3 for media, `cloak_ecto` (AES-256-GCM) for private-key storage, passwordless magic-link auth. Docker-based deploy, AWS (S3/SES) required in production. Licensed AGPL-3.0.

It is a single-user-per-instance social/federated app, not a multi-tenant B2B SaaS framework — the opposite shape from samen (one org per deployment vs. samen's tenant-org-over-operator-org model; no RBAC/org-scoping, no billing, no admin/operator plane, no generative scaffolding, no verification/sabotage discipline).

## What samen could adopt

Nothing rises above a passing note; the domains don't overlap enough to justify effort. Two small observations, not recommendations:

- **PostGIS pattern for future location-heavy verticals** — what: if samen ever ships a logistics/field-service vertical (adjacent to driftwood's freight domain) needing geospatial queries, Revix is a working example of Ecto + PostGIS + Overpass API place lookups. Why it fits: samen already has a `locations` scope blueprint; this shows one lightweight way to layer spatial querying on top. Effort: S (reference only, not a dependency to pull in — samen would need its own vault-aware wrapper since raw coordinates could be quasi-PII).
- **ActivityPub HTTP Signatures pattern** — what: per-user RSA keypair + HTTP Signature verification for authenticating cross-instance calls. Why it fits: loosely analogous to samen's fleet-cockpit cross-app trust problem (opt-in self-registration/heartbeat with secured credentials, ADR-044), though samen's fleet auth is token-based, not signature-based, and there's no stated need to change that. Effort: not worth pursuing — noted only as a pattern that exists, not a gap in samen.

## What to ignore and why

- **cloak_ecto for secret storage** — samen explicitly evaluated and rejected AshCloak/Cloak in ADR-003 in favor of a hand-built vault chokepoint with per-subject external-KMS keys; adopting Revix's Cloak usage would regress samen's crypto-shred/chokepoint invariants.
- **AGPL-3.0 license** — incompatible with samen staying MIT; nothing here is worth a licensing headache even if a snippet looked useful.
- **No Ash, no multi-tenancy, no RBAC/policy layer, no billing, no operator plane** — the entire commercial-SaaS surface samen cares about (tenant lifecycle, entitlements, org-scoping, masked impersonation) has no counterpart in Revix to learn from.
- **ActivityPub federation stack as a whole** (WebFinger, JSON-LD, Atom feeds, inbox/outbox fanout) — solves a social-federation problem samen's roadmap does not have; would be pure surface area with no G-register gap it closes.
- **Passwordless magic-link auth** — samen's identity spine (ADR-035) already ships a more complete self-serve auth flow (registration, email verification, password reset, sessions, invites, OIDC via `assent`, TOTP 2FA); magic-link is a narrower mechanism with nothing to add.
