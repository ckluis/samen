---
project: Plural Console
url: https://github.com/pluralsh/console
category: Infrastructure and Operations
relevance: medium
verdict: Mature production Elixir/Phoenix control plane (no Ash) for Kubernetes fleet GitOps — domain (K8s CD/IaC) is out of samen's lane, but its pull-based agent architecture, MCP library, and ops-libraries are worth stealing patterns from; AGPL-3.0 means patterns only, never code.
---

# 109 — Plural Console

## What the project is

Plural Console (pluralsh/console, AGPL-3.0 source / MIT vendor binaries + Plural license required, ~5,465 commits, actively maintained) is the core control plane for Plural's Kubernetes fleet-management platform. It gives an organization one place to manage many Kubernetes clusters: GitOps-driven continuous deployment, Terraform/Pulumi execution, pull-request automation, notification routing (Slack/Teams/email), a Kubernetes dashboard, and AI-assisted operations, all fronted by a GraphQL API.

Architecture is a three-part, polyglot system:
- **Server core (Elixir/Phoenix + Absinthe GraphQL)** — the control plane itself; sharded git-cache and Helm-repo-cache processes on the BEAM.
- **React frontend**, bundled straight into the Elixir Docker image for one-artifact self-hosting.
- **Go `deployment-operator`** — a thin agent installed on each managed cluster. Critically, it is a **pull-based agent**: it perpetually polls the control plane for new services/state and *reverse-tunnels* back to Console to service k8s API requests, so Console never needs inbound network access to any managed cluster. This lets Plural manage clusters in any cloud, on-prem, on the edge, or on a laptop, with no cluster-side ingress.

It is not Ash-based at all — vanilla Ecto/Phoenix/Absinthe, Guardian+Joken+oidcc for auth, Nebulex for caching, GenStage/Flow for pipelines, ex_aws for cloud, Hammer for rate limiting, Sentry + prom_ex + OpenTelemetry-style telemetry for observability, and a notable `anubis_mcp` dependency (an actual open-source Elixir MCP server library) plus `req_llm` (multi-provider LLM request lib) and `google_api_ai_platform` for its AI-assisted-ops features. The domain — Kubernetes GitOps/IaC/cluster fleet management — is fundamentally different from samen's "SaaS product foundry" domain, so most of its feature surface (Terraform/Pulumi execution, K8s CRDs, Helm) doesn't transfer. What's relevant is the small set of Elixir/Phoenix ops patterns and libraries a mature multi-tenant control plane converged on independently of samen.

## What samen could adopt

1. **Pull-based agent + reverse-tunnel model for the fleet cockpit.**
   - *What*: `deployment-operator` agents never receive inbound connections; they poll Console and reverse-tunnel back for any command execution, so the control plane needs zero network reachability into tenant infrastructure.
   - *Why it fits samen*: samen's ADR-044 fleet cockpit already does opt-in self-registration/heartbeat (pull-shaped), but its "fleet directives" language ("unreachable app = observability without fleet flags, never a fake applied") leaves the transport model implicit. Explicitly committing to poll+reverse-tunnel (rather than any future push/webhook-to-tenant path) would keep the fleet cockpit's zero-trust posture honest as it grows past observability into actual directive execution, and gives a concrete failure semantics for "unreachable" that matches what samen already promises.
   - *Effort*: **S** — it's a stance/naming clarification on an architecture samen already leans toward, not new code.

2. **`anubis_mcp`** as a reference (not a dependency) for samen's hand-built MCP server.
   - *What*: an open-source Elixir MCP server implementation Plural adopted as a library rather than hand-rolling their own, per the current MCP spec.
   - *Why it fits samen*: samen's MCP server (ADR-043, HTTP+SSE in `samen_web`, protocol 2025-03-26) was hand-built specifically because generic MCP libraries don't understand samen's masking chokepoint. Worth a quick diff-read of `anubis_mcp`'s transport/session-handling code as a second implementation to sanity-check samen's own protocol-compliance edges (SSE reconnect, per-operator token scoping) — but it should stay a reference, not a swap-in, since it has no concept of chokepoint-minted `%MaskedPayload{}` egress.
   - *Effort*: **S** — read-only comparison pass, no adoption.

3. **`prom_ex`** for Phoenix/Ecto-aware Prometheus metrics.
   - *What*: a metrics library purpose-built for Phoenix apps (auto-instruments Ecto query time, Phoenix request latency, BEAM VM stats, Oban queue depth) rather than hand-wiring `telemetry_metrics`.
   - *Why it fits samen*: samen already emits `telemetry_metrics` + OpenTelemetry (with `db_statement` disabled to keep PII tokens out of spans) but its metrics/observability module is hand-built. `prom_ex` is additive (a Prometheus exporter layered on the same `:telemetry` events samen already emits) and would give samen's fleet cockpit and per-tenant ops dashboards a standard `/metrics` endpoint without touching the masking-sensitive OTel span path.
   - *Effort*: **S** — new dep + config module, no core kernel changes; verify it doesn't leak `pii_`-prefixed labels into default metric names (samen already has `samen.verify.metric_labels` to catch that).

4. **Notification routing to multiple channels (Slack/Teams/email) with per-rule fan-out.**
   - *What*: Console lets operators define fine-grained routing rules that fan a single event out to Slack, Teams, and email concurrently, decoupled from the event source.
   - *Why it fits samen*: samen's `samen_web` notifications module currently covers inbox + prefs; as the fleet cockpit matures into a real "SaaS holding company in a box" (ADR-044), an operator watching N tenant apps will want the same event routed to more than one channel by rule, not by per-adapter plumbing. samen already has `samen_stripe`/`samen_postmark`/etc. as isolated vendor packages (INV-4), so a `samen_slack`/`samen_teams` adapter pair following the same fail-honest, path-dep-on-core-only shape is a natural, low-risk extension — Plural's routing-rule *shape* (event → matching rules → fan-out) is the transferable idea, not its code (AGPL).
   - *Effort*: **M** — new vendor adapter package(s) + a routing-rule resource in `samen_core`'s notifications subsystem.

## What to ignore and why

- **GitOps / Terraform-Pulumi execution / Kubernetes CRD management / Go `deployment-operator` / Helm caches** — this is Plural's actual product and the bulk of the codebase; it solves "manage many k8s clusters," not "run many SaaS tenants," and has no analog in samen's problem space. Out of domain, skip entirely.
- **Ash ecosystem — none exists here.** Plural uses raw Ecto/Phoenix/Absinthe throughout; there is nothing to compare against samen's Ash-blueprint/scope-mount architecture (universal scopes, `Samen.Resource` sugar, rich declared types). No transferable Ash pattern.
- **Guardian/Joken/oidcc auth stack** — samen deliberately hand-built its identity spine (ADR-035) around the vault/masking chokepoint (credential PII vaulted, session eviction, TOTP via `nimble_totp`, OIDC via `assent`); swapping in Plural's auth stack would mean re-deriving all of that masking-aware behavior from scratch for no benefit — samen's own auth libraries (`assent`, `nimble_totp`) are already the leaner, purpose-fit choice for a single-tenant-identity-per-org model vs. Plural's operator-facing SSO-heavy needs.
- **`req_llm` / `google_api_ai_platform` for multi-provider AI calls** — a generic multi-provider LLM client is exactly what ADR-043's "AI kernel is hand-built, ash_ai rejected" reasoning already argues against: any generic client that isn't built around chokepoint-minted `%MaskedPayload{}` egress is a PII-egress bypass risk by construction. samen's one-provider-per-adapter-package pattern (`samen_anthropic`) is the correct shape here; don't generalize it just because Plural did.
- **AGPL-3.0 licensing** — Console's source is AGPL (vendor-built binaries are MIT but require a Plural license). Any code lift, not just pattern inspiration, would create a license-compliance problem for samen's MIT-published monorepo. Treat this project as read-only architecture reference, never a copy source.
- **Nebulex distributed caching, GenStage/Flow pipelines, `kazan` k8s client, ex_aws suite** — all exist to solve Plural's sharded git/Helm-cache and cloud-provisioning problems, which samen doesn't have. No current samen subsystem needs a distributed cache or a k8s API client.
