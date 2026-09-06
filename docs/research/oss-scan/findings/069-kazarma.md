---
project: Kazarma
url: https://gitlab.com/technostructures/kazarma/kazarma
category: Communication and Social
relevance: low
verdict: Elixir/Phoenix Matrix-to-ActivityPub federation bridge — unrelated to SaaS-foundry concerns; nothing samen should adopt, and AGPL-3.0 blocks code reuse anyway.
---

# 069 — Kazarma

## What the project is

Kazarma is an AGPL-3.0-only Elixir/Phoenix service that bridges the Matrix messaging protocol and the ActivityPub federation standard, letting users on Matrix homeservers interact with fediverse instances (tested against Pleroma). It runs as a Matrix Application Service alongside a Matrix server and an ActivityPub service behind a reverse proxy (Traefik). Actively maintained (~850 commits, CI/CD, Weblate translations, semver, NLnet NGI0 Entrust funding). Key libraries: Phoenix, `matrix_app_service.ex` and `polyjuice_client` (Matrix), the CommonsPub `ActivityPub` library. Ships as Erlang release, Docker Compose, or Helm chart.

## What samen could adopt

Nothing concrete. Evaluated angles, all rejected:

- **Matrix app-service / bridge patterns** — samen's chat is a deliberately first-party, catalog-driven, masking-aware cross-plane surface with no federation requirement; bridging to external protocols would create an ungoverned PII egress path that contradicts the chokepoint model. Not a fit at any effort level.
- **ActivityPub federation** — a multi-tenant SaaS foundry has no federation story on any samen roadmap (G1–G28, WS-A..WS-L); out of domain.
- **Deployment artifacts (Helm/Compose)** — generic Elixir-release packaging samen already understands; Kazarma adds nothing samen's fail-honest deploy artifacts (ADR-038) don't cover.
- **License** — AGPL-3.0-only is incompatible with copying anything into MIT-licensed samen even if a pattern were wanted.

## What to ignore and why

Ignore the entire project for samen's purposes: it solves protocol federation between two decentralized messaging networks, a domain orthogonal to samen's trust kernel (vault/masking/audit), two-plane architecture, and commercial SaaS surfaces. Its dependencies (Matrix SDKs, CommonsPub ActivityPub) would pull vendor/HTTP deps that violate INV-4 if they ever touched core, and the AGPL license forecloses adoption regardless.
