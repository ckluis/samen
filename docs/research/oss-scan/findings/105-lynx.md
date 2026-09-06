---
project: Lynx
url: https://github.com/Clivern/Lynx
category: Infrastructure and Operations
relevance: low
verdict: Elixir/Phoenix stack overlaps samen's runtime, but Lynx is a plain-Phoenix (no Ash) Terraform state backend with generic multi-tenancy and no PII/vault story — nothing structural to lift beyond a couple of small ops/deploy reference points.
---

# Lynx — evaluation vs samen

## What the project is

Lynx (MIT, ~366 stars, 11 forks, active — latest release 0.13.0) is a self-hosted Terraform remote-state backend: an alternative to Terraform Cloud for teams that want to own their state storage. It is built in Elixir with the Phoenix framework, backed by PostgreSQL (no object storage required), and ships a REST API, a dashboard UI, and a companion Terraform provider for automation. Its domain model is a straightforward hierarchy — Team → Project → Environment → Snapshot — with state versioning/rollback and Terraform-style state locking to prevent concurrent-apply corruption. Deployment is Docker/Docker Compose, either standalone, behind Nginx, or as a 3-node cluster behind an Nginx load balancer. SSO (OAuth2 against Azure AD, Keycloak, Okta) is on the roadmap but not yet shipped; current auth is unspecified in the README (no confirmation of `assent`, `ash_authentication`, or any Ash usage at all — this reads as plain Phoenix/Ecto, not Ash).

`grep`-ing samen for "terraform" turns up nothing — samen has no IaC/state-backend surface today, and this is not a gap in samen's spec (`samen-digest.md` §11) either.

## What samen could adopt

1. **Docker Compose deployment topology (standalone / behind-Nginx / clustered) as an ops reference** — What: Lynx's three ready-made compose profiles (single node, Nginx-fronted, 3-node cluster + LB) are a clean, minimal example of packaging a Phoenix+Postgres app for self-hosted multi-node deployment. Why it fits samen: samen's own production deploy story (Fly.io) is explicitly operator-TODO (`samen-digest.md` §11, WS-L), and samen already proves multi-node Oban locally — a documented Docker Compose fallback path (for operators who don't want Fly) could de-risk that gap cheaply. Effort: S (it's a reference to skim, not code to port — no library dependency).

2. **State-locking-as-a-resource pattern (advisory lock row + holder/expiry columns)** — What: Lynx models Terraform's state lock as a DB row with holder ID and lock metadata to prevent concurrent writers, rather than a session-level Postgres advisory lock. Why it fits samen: samen already has stronger primitives for this class of problem (Oban uniqueness, DB `CHECK` constraints, hash-chained audit), so this is not a gap-filler — noted only because it's a small, legible pattern if samen ever needs an explicit "this record is checked out" resource-level lock outside of Oban's job-level guarantees (e.g., a long-running operator workflow). Effort: S, and likely unnecessary — evaluate only if a concrete need surfaces.

## What to ignore and why

- **Everything domain-specific (state snapshots, Terraform provider, state versioning/rollback)** — Lynx solves infrastructure-as-code state management; samen is a multi-tenant SaaS application substrate with PII vaulting at its core. No product surface overlaps.
- **Multi-tenancy model (Team/Project/Environment)** — a flat, unmasked hierarchy with no PII classification, no reveal-grant workflow, no crypto-shred, no token-blind aggregate plane. samen's two-plane + `OrgScope`/`PiiResolution` model (ADR-010) is categorically more sophisticated; nothing to backport.
- **Auth/SSO roadmap (planned OAuth2 against Azure AD/Keycloak/Okta)** — samen's identity spine (ADR-035) already ships OIDC via `assent` plus TOTP 2FA; Lynx is *behind* samen here, not ahead.
- **REST API design** — a conventional CRUD REST surface with no stated contract discipline; samen's `/api/v1` is deny-by-default JSON:API with `PageLimitClamp` and a catalog-driven parity verifier. No pattern worth importing.
- **No Ash, no verification/sabotage discipline, no fail-honest adapter convention** — Lynx shows no evidence of property-based testing, adversarial gates, or the vault-chokepoint/masking concerns that are samen's actual moat. The shared "Elixir/Phoenix" label is surface-level; there is no deep architectural kinship (contrast with same-stack projects like AlexClaw, which do have transferable AI-plane/security patterns — see `000-alexclaw.md`).
