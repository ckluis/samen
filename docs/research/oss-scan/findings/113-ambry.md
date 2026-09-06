---
project: Ambry
url: https://github.com/ambry-app/ambry
category: Media and Personal
relevance: low
verdict: A single-user, plain-Phoenix (no Ash) self-hosted audiobook server — domain and architecture barely overlap with samen's multi-tenant Ash SaaS substrate.
---

## What the project is

Ambry is a self-hosted personal audiobook library and streaming server, written in Elixir with Phoenix + LiveView. A single admin account is provisioned on first boot; optional user registration exists for small multi-user deployments, but there is no tenant/org model, no RBAC, no PII vaulting, and no multi-tenant data isolation concept at all. It reads audio metadata (durations, tags, chapter markers) via `ffprobe`, serves files untouched, and ships as a container image (Docker/Podman) with PostgreSQL as its only external dependency; configuration is via env vars (`BASE_URL`, `DATABASE_URL`, `SECRET_KEY_BASE`, pool sizing, etc.). It has a web client plus native mobile clients, transactional email (Mailjet), and basic admin/audit capabilities. Active (88 stars, pushed today), not archived, but small in scope — a personal media server, not a SaaS product.

Critically for comparison purposes: Ambry does **not** use Ash Framework, has no multi-tenant/org architecture, no PII masking or vaulting, no policy/authz layer beyond simple auth, and no verification/sabotage discipline. It is architecturally closer to a typical single-purpose Phoenix app than to samen's kernel+scopes+verticals foundry model.

## What samen could adopt

Nothing rises above trivial/incidental overlap. The two closest surface-level touchpoints:

- **What**: ffprobe-based audio metadata extraction pattern (read-only external tool shelling out for file introspection at upload time).
  **Why it fits samen**: samen's `files` subsystem (LiveView upload chokepoint, quarantine-by-default) could eventually want a reference pattern for safely invoking external media-processing binaries if a vertical ever needs rich-media metadata — but no current samen vertical (driftwood/pawchart/demo) has this need.
  **Effort**: S (if ever needed, trivial to reimplement from first principles; not worth studying Ambry's code for it).

- **What**: Simple container-image + compose-based deploy story (single Postgres dependency, env-var config).
  **Why it fits samen**: broadly consistent with how samen already expects to be deployed, but offers nothing samen doesn't already have more rigorously (fail-honest adapters, `/readyz`, ADR-032 posture) via its own WS-L work.
  **Effort**: N/A — no adoption action.

## What to ignore and why

- **Everything architectural**: no Ash, no multi-tenancy, no policy/RBAC, no PII masking/vaulting, no audit chain, no verification/sabotage harness. Samen's entire differentiator (governance-by-construction for multi-tenant SaaS) has no analog here to learn from.
- **Auth/registration flow**: Ambry's registration is a simple single/few-user toggle, far shallower than samen's ADR-035 identity spine (OIDC, TOTP, session management, org invites) — nothing to backport.
- **Mailjet integration**: samen already has first-party ESP adapters (`samen_postmark`, `samen_ses`, `samen_resend`) at a more rigorous fail-honest standard; no reason to look at Ambry's transactional email code.
- **Mobile client work**: out of scope for samen, which is web/API-first with a two-plane architecture, not a personal media consumption app.

Recommendation: no further evaluation time warranted. This is a personal/media-hobbyist project, not a SaaS-substrate reference.
