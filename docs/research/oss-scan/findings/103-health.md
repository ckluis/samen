---
project: Health
url: https://codeberg.org/ppatrzyk/health
category: Infrastructure and Operations
relevance: high
verdict: Elixir uptime/status-page monitor (Bandit+Plug, no Phoenix/Ecto/Ash) that directly targets samen's explicitly open G11 status-page gap and models the pull-mode active probing samen's push-only fleet heartbeat currently lacks — adopt the patterns, not the code (AGPL-3.0).
---

## What the project is

**Health** (ppatrzyk/health, Codeberg, AGPL-3.0) is a self-hosted infrastructure/cron-job health monitor. It is Elixir (80.9%) but deliberately **not** Phoenix, Ecto, or Ash — it runs on **Bandit + Plug** directly, talks to Postgres with raw **Postgrex** (no Ecto), and configures itself via a YAML file (`yaml_elixir`), not a web UI.

Two operating modes:
- **Push mode**: monitored apps are issued unique API endpoints and are expected to call in on a schedule (dead-man's-switch style, like samen's fleet heartbeat).
- **Pull mode**: the tool actively probes endpoints via HTTP, DNS, ICMP ping, raw TCP (with optional TLS), and SMTP.

Other surfaces: a live dashboard driven by SSE/**Datastar** (not LiveView) showing response times, downtime, and error messages; a `/metrics` **Prometheus** endpoint; multi-channel alerting (email, IRC, XMPP, Matrix, ntfy, Gotify, Telegram, generic webhooks, and arbitrary subprocess execution); auth via htpasswd/bcrypt or trusted reverse-proxy headers. Deployed as a Docker/Podman container or a Mix release (`health_release`), with Postgres as the only hard dependency.

Key deps (from `mix.exs`): `bandit`, `plug`, `postgrex`, `phoenix_pubsub` (standalone, no Phoenix), `finch`, `mua` (lightweight SMTP client), `dns`, `gen_icmp`/`pkt`/`procket` (raw ICMP sockets), `bcrypt_elixir`, `yaml_elixir`.

## Verification against samen

Checked directly against the samen tree (not just the digest):
- `docs/saas-gap-roadmap.md` G11 confirms: `/readyz` + metrics-egress/alert runbook shipped, but **"public status page still open."** Health is essentially a purpose-built implementation of exactly that missing surface.
- `samen_core/lib/samen/fleet/heartbeat_actor.ex` and `attention.ex` confirm samen's fleet cockpit already has a **push-only** heartbeat model (capability-scoped `{fleet:heartbeat}` actor, append-only, signature-checked, with abuse-attention tracking on bad signatures) — structurally similar to Health's push mode, but samen has **no pull-mode active probing** (no HTTP/DNS/ICMP/TCP/SMTP synthetic checks) anywhere in the fleet or observability modules.

## What samen could adopt

1. **Public status-page surface for G11** — what: a masked, publicly-viewable (or per-tenant) live status page showing uptime/response-time/incident history for registered fleet apps, backed by SSE for live updates. Why it fits: this is literally the one open item under G11; samen already has LiveView + the two-plane masking discipline, so it doesn't need Datastar — it needs the *feature*, not the transport. Effort: **M** (new `samen_web` surface reusing existing fleet report data + a public/unauthenticated masked read path).

2. **Pull-mode active synthetic checks (HTTP/DNS/TCP/SMTP)** — what: samen's fleet only knows an app is unhealthy if that app's own heartbeat process stops calling in; it has no independent, outside-in probing. Why it fits: closes a real blind spot — an app that's up but whose heartbeat job itself is wedged/misconfigured is invisible today. Health's four check types (skip ICMP, see below) are a clean minimal set to emulate as a `samen_core` scope or a small adapter package, following samen's fail-honest-adapter convention (unconfigured check target → `{:error, :not_configured}`, never fake success). Effort: **L** (new subsystem; needs its own Oban-scheduled prober, result storage, and a verifier tier akin to the existing fleet/observability ones).

3. **Prometheus `/metrics` egress pattern** — what: Health exposes a plain, unauthenticated `/metrics` Prometheus endpoint as a first-class feature, cleanly separated from the dashboard. Why it fits: samen already claims "metrics egress/alert runbook shipped" (F5) — Health is a useful reference for what a minimal, correctly-scoped `/metrics` route looks like if samen's current implementation needs hardening or a public/ops-facing variant. Effort: **S** (comparison/audit against samen's existing F5 work, not new build).

4. **Generic webhook + ntfy-style notifier as a first-party-but-separate adapter package** — what: Health treats "send to an arbitrary webhook" and "run an arbitrary subprocess" as first-class alert sinks, in addition to named integrations (Telegram, Matrix, ntfy, Gotify). Why it fits: samen already has the `samen_stripe`/`samen_postmark`/`samen_ses`/`samen_resend`/`samen_anthropic` pattern (vendor deps isolated outside `samen_core`, INV-4). A `samen_webhook` (generic outbound alert/event webhook) adapter is a natural, low-risk extension of that pattern for fleet/automation alerting. Effort: **S** (one adapter package, same shape as existing ones).

## What to ignore, and why

- **The codebase itself is not reusable as code.** Health deliberately skips Phoenix, Ecto, and Ash; samen's ADR-037 has already made a deep, deliberate commitment to the Ash ecosystem (adopt ash_money/ash_archival/ash_oban/ash_paper_trail/Reactor/AshStateMachine, reject ash_ai/ash_admin/ash_authentication rewrites). Porting Health's Postgrex-direct, Ecto-free style would fight that commitment. Treat this project as a **pattern/feature reference only**, never a dependency or vendored source.
- **AGPL-3.0 license.** Samen is MIT. Copying or adapting Health's source directly would create a copyleft obligation incompatible with samen's licensing posture (ADR-033: distribution stays in-monorepo, no Hex packages, but MIT is still the stated license). Only architecture ideas should cross the line, never code.
- **Raw ICMP ping support (`gen_icmp`, `pkt`, `procket`).** These require raw-socket / elevated network capabilities (typically `CAP_NET_RAW` or setuid helpers) in the container. This directly conflicts with samen's minimal-attack-surface, fail-honest-adapter ethos and its container/deploy posture (Fly.io production deploys, no privileged containers documented). Skip ICMP; HTTP/DNS/TCP/SMTP checks cover the practical need without the privilege escalation.
- **IRC/XMPP/Matrix notification channels.** These fit a self-hosted homelab audience, not samen's SaaS-operator/tenant audience. Samen's notification surface (`samen_web/lib/samen/web/notifications`) and ESP-adapter pattern already covers the channels that matter (email via Postmark/SES/Resend, plus the proposed generic webhook above); IRC/XMPP/Matrix add integration surface with no clear samen user demand.
- **YAML-file-based configuration model.** Health configures endpoints/notifiers via a static YAML file edited by an operator with shell access. Samen's fleet/automation config lives in the database behind Ash resources, RBAC, and the audit chain — the YAML-file model is a step backward from samen's governance-by-construction posture and shouldn't be imitated even for the new pull-mode checks (config those as Ash resources instead).
