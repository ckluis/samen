---
project: Pleroma
url: https://git.pleroma.social/pleroma/pleroma
category: Communication and Social
relevance: none
verdict: Elixir/Phoenix/Ecto federated social-media server (ActivityPub, single-instance-per-deployment) with no multi-tenant SaaS, Ash, PII-vaulting, or governance-by-construction concerns — domain mismatch outweighs shared language, nothing worth lifting into samen.
---

# Pleroma — evaluation vs samen

## What the project is

Pleroma is a lightweight, actively-maintained (18k+ commits, ~350 open issues, commits as recent as August 2026) federated microblogging server implementing ActivityPub, compatible with the Mastodon client API and federating with Mastodon/Misskey/PeerTube/Pixelfed. Stack: Elixir + Phoenix + Ecto/PostgreSQL (~80% Elixir, ~18% JS for the bundled frontend). It targets efficiency on low-power single-node hardware (down to a Raspberry Pi) and ships install paths for OTP releases, source builds across a dozen distros, OS packages (NixOS, Arch AUR, YunoHost), and Docker.

Architecturally each Pleroma deployment is a single self-contained instance (one admin, one community, one Postgres DB) that federates peer-to-peer with other instances over ActivityPub — there is no per-tenant isolation, org model, PII vaulting, masking, or approval/audit machinery of the kind samen is built around. It does not use Ash; its resource layer is conventional Ecto schemas/changesets. The product surface (posts, follows, timelines, moderation, federation delivery/inbox processing) has no analog in samen's SaaS-foundry surface area (billing, CRM, support, fleet cockpit, identity spine).

## What samen could adopt

Nothing rises to a concrete adoptable pattern. The two areas that are superficially adjacent — federation/delivery queuing (Oban-like inbox/outbox job processing) and OTP-release packaging across many targets — are both already well-covered inside samen by existing choices (Oban for jobs, standard Elixir releases) and Pleroma's implementations are shaped by ActivityPub's specific delivery-retry semantics, not by anything samen needs. No Ash usage, no multi-tenancy, no PII/masking, no verification/sabotage discipline to compare against.

## What to ignore and why

- **ActivityPub protocol implementation, inbox/outbox delivery, federation retry logic** — solves a distributed social-protocol problem samen doesn't have (samen is a single-tenant-per-vertical, operator-hosted SaaS substrate, not a federated network).
- **Mastodon client API compatibility layer** — irrelevant surface, no analog in samen's product model.
- **Moderation tooling (reports, instance blocks/mutes, MRF policy chain)** — social-network-specific; samen's closest concept (RBAC/policy, approvals) is already purpose-built for tenant/org SaaS governance, not inter-instance content moderation.
- **Multi-distro/OS-package install matrix** — a distribution-breadth concern for a widely self-hosted community project; samen is explicitly monorepo-only (ADR-033, no Hex packages, no broad self-host distribution story), so this doesn't map to samen's roadmap.
- **Frontend (Pleroma-FE / bundled JS client)** — unrelated to samen_web's LiveView-based UI kit and masked-rendering approach.
