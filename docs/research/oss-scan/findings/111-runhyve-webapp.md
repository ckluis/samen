---
project: Runhyve Webapp
url: https://gitlab.com/runhyve/webapp
category: Infrastructure and Operations
relevance: low
verdict: A single-admin Elixir/Phoenix panel for managing bhyve hypervisors and VMs — real and actively developed, but single-tenant ops tooling with no PII/multi-tenancy/vault concerns, so it offers only a handful of narrow library/pattern notes for samen.
---

## What the project is

Runhyve is a two-part open-source project: a **hypervisor** side (FreeBSD + ZFS + `vm-bhyve` + nginx, provisioned via the companion `chef-hypervisor` repo, HTTP endpoints wrapping `vm-bhyve` CLI commands) and this **webapp** — an Elixir/Phoenix control panel that talks to those HTTP endpoints to create/manage virtual machines and networks (bridged switches, image distribution, VM lifecycle). It is early-stage but under active development (changelog shows releases through January 2025, upgrade to Phoenix 1.7, in-progress job-status/telemetry work), BSD-2-Clause licensed, ~388 commits across 18 branches since 2018.

Stack confirmed from `mix.exs`: Phoenix ~1.8 + LiveView ~1.2 + LiveDashboard, Ecto SQL/Postgrex + `ecto_network`/`ecto_psql_extras`, **Cloak Ecto** for at-rest encryption, **Canary** for authorization, Argon2 for password hashing, Bandit as the web server, Finch for HTTP client, Sentry for error tracking, Swoosh/gen_smtp for email, a **K8s** client library, Tailwind/ESBuild for assets, and **Tidewave** (an AI-assisted Phoenix dev tool) as a dev dependency.

Functionally it is a single-organization admin panel (an "Admin → Hypervisors" screen, one authorization token per hypervisor) for a homelab/small-fleet VM manager — not a multi-tenant SaaS product, and it carries none of samen's core concerns (PII vaulting, tenant/operator plane separation, crypto-shred erasure, hash-chained audit, catalog-as-data).

## What samen could adopt

- **Note the Cloak Ecto choice as a contrast, not an adoption.** Runhyve uses `cloak_ecto` directly for encryption-at-rest on sensitive fields. Samen's ADR-003 already evaluated and rejected AshCloak/Cloak in favor of a custom vault chokepoint (per-subject KMS keys, crypto-shred). Runhyve is a real-world data point that Cloak is still a live, commonly-reached-for option in the Phoenix ecosystem — useful as an external reference point if ADR-003's rationale is ever revisited, but not something to adopt. Effort: N/A (reference only).
- **Canary (authorization library) as a comparison for the policy layer.** Canary provides simple per-resource `can?/3` authorization checks tied to Ecto schemas/Plug. Samen's `Samen.Policy` (OrgScope + fail-closed) is already far more sophisticated (org-scoping, SAT-solver-backed via `simple_sat`), so there's nothing to port — just a confirmation that samen's policy layer is already ahead of the ecosystem baseline. Effort: N/A.
- **Bandit as the web server is already samen's likely default** (Phoenix 1.8 ships Bandit-first); Runhyve's use of Bandit ~1.0 is a mild confirming data point, not new information. Effort: N/A.
- **`k8s` client library** — if samen's Fleet cockpit (ADR-044) ever wants to manage fleet member apps running in Kubernetes (as opposed to purely HTTP-heartbeat self-registration), Runhyve's use of the `k8s` Elixir library for talking to a K8s API is a small, low-risk pattern to look at (Elixir K8s client conventions, auth via service-account tokens). This is speculative — samen's roadmap doesn't currently call for direct K8s orchestration. Effort: S (if ever needed, just a library evaluation, not a rewrite).
- **Tidewave dev dependency** — worth a passing mention: Tidewave is an AI-pairing tool for Phoenix apps (runtime introspection MCP-style tool for LLM coding assistants). Given samen's own AI-authored development process and MCP server (ADR-043), Tidewave could be worth a five-minute look as prior art for exposing a live-app introspection MCP surface to a coding assistant — distinct from samen's own operator-facing MCP server, but same idea in a dev-tooling context. Effort: S (evaluate only, unlikely to be adopted directly since samen's MCP server already serves a different audience).

## What to ignore and why

- **Everything about VM/bhyve/hypervisor provisioning** — orthogonal domain, no transferable pattern for a SaaS foundry.
- **Single-tenant admin-panel structure** (one "Admin → Hypervisors" screen, single auth token model) — the opposite of samen's two-plane, multi-tenant-by-construction design; nothing to learn from here since Runhyve doesn't attempt multi-tenancy at all.
- **No PII handling, no vault, no audit chain, no erasure story** — Runhyve stores infra credentials/tokens conventionally (Cloak-encrypted columns) with no reveal-grant, no hash-chained audit, no crypto-shred; this is strictly less rigorous than samen's existing vault chokepoint, so there is no upgrade path to pull from it.
- **Early-stage/small scope** — no generators, no verifier-tier discipline, no sabotage harness, no catalog-as-data concept; nothing structural to compare against samen's verification story.
