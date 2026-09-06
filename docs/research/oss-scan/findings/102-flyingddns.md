---
project: FlyingDdns
url: https://gitlab.com/timopallach/FlyingDdns
category: Infrastructure and Operations
relevance: low
verdict: Active, well-built Elixir/Phoenix Dynamic DNS service, but single-purpose and Ash-free — a couple of ops/CI hygiene ideas worth borrowing, nothing architectural.
---

## What the project is

FlyingDdns is a Dynamic DNS (DDNS) middleware server written in Elixir/Phoenix that sits between clients with changing IPs and a PowerDNS backend: it validates client credentials, updates DNS zone records via PowerDNS's REST API (with retry/exponential-backoff), and exposes three update paths — the legacy DynDNS protocol, a modern JSON REST API (OpenAPI/Swagger-documented), and a Phoenix LiveView + Tailwind/DaisyUI web console with role-based access and Bcrypt-hashed credentials. It's a mature, actively maintained project (thousands of commits, 100+ tagged releases since 2018), targeting self-hosted/homelab DNS management rather than any multi-tenant SaaS use case. Stack: Phoenix 1.8, Ecto/Postgres, Finch/Mint for HTTP, Swoosh/Gen SMTP for email, Hammer for rate limiting, OpenAPI Spex for API docs, plus a CI security toolchain (Sobelow, Trivy, OSV Scanner, mix_audit).

It has no relationship to Ash, no multi-tenancy, no PII vault/masking concept, no two-plane architecture — it's a focused single-purpose network-ops utility, not a framework or foundry.

## What samen could adopt

1. **OpenAPI Spex for auto-generated API docs** — what: FlyingDdns generates a live OpenAPI/Swagger spec (`/api/v1/openapi`) directly from its Phoenix API controllers/schemas, consumable by Swagger UI/Redoc/Postman. Why it fits samen: samen's `samen_web/api` already runs a deny-by-default JSON:API surface and the roadmap explicitly calls out "G22 agent-grounding packaging for builders" (P2) — a generated OpenAPI spec alongside the existing machine-readable catalog would give external builders/LLM tooling a standard, importable contract with near-zero hand-maintenance drift risk. Effort: **M** (wiring OpenAPI Spex or an Ash-JSON:API-native equivalent across generated resources, keeping it in sync with `catalog_parity`-style verification).

2. **Sobelow static security scan in CI** — what: a Phoenix-specific static analyzer that flags XSS, SQLi, CSRF, insecure config, and known Phoenix CVE patterns. Why it fits samen: cheap, orthogonal defense-in-depth layer on top of samen's already-extensive custom verifier suite (20 `samen.verify.*` tiers) and AST anti-bypass probes — catches generic Phoenix framework-level footguns that a bespoke PII/vault-focused verifier set wouldn't specifically target. Effort: **S** (add as a root `ci.sh`/`ci-fast.sh` step, `mix sobelow` per app).

3. **Trivy / OSV Scanner dependency-vulnerability scanning in CI** — what: automated scanning of the dependency tree (Hex + any transitive) for known CVEs, run in CI alongside `mix_audit` (which samen likely already has via its dev/test deps). Why it fits samen: samen pins versions carefully (ADR-037 Ash package gate, `ash_rate_limiter` pinned 1.0.0) but doesn't appear to have a documented supply-chain-vulnerability CI gate; this is a low-cost addition that matches samen's "fail-honest, verification-obsessed" posture and is worth a line in `docs/compliance-story.md`. Effort: **S**.

## What to ignore and why

- **PowerDNS/DDNS domain logic, Domainatrex, net_address, DynDNS protocol compatibility** — entirely domain-specific to DNS record management; samen has no DNS-serving surface and no plan for one.
- **Bcrypt/Comeonin password auth, RBAC model** — samen already ships a purpose-built, generator-emitted identity spine (ADR-035: registration → email verify → OIDC via assent → TOTP via nimble_totp → session management) that is deeper (masked PII vaulting on credentials, audit-logged) than FlyingDdns's plain Bcrypt+role check. Adopting FlyingDdns's simpler auth would be a regression.
- **Phoenix LiveView + Tailwind/DaisyUI admin console pattern** — samen already has its own `ui/` function-component kit and token CSS system (ADR-driven, masking-aware rendering via `%Masked{}` Phoenix.HTML.Safe). FlyingDdns's UI kit choice is generic and not masking-aware; no reason to cross-pollinate.
- **RobotFramework acceptance tests** — samen's verification story (285-patch sabotage harness, destruction oracle, generative CI proof) is far more rigorous and specific to its trust-kernel guarantees; a generic acceptance-test framework adds nothing samen's ExUnit + sabotage discipline doesn't already cover.
- **Multi-platform release binaries (30+ OS targets)** — samen is explicitly monorepo/host-deployed (ADR-033, no Hex packages, no standalone binary distribution); irrelevant to its distribution model.
