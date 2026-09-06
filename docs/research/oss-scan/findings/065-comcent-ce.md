---
project: Comcent CE
url: https://github.com/comcent-io/comcent-ce
category: Communication and Social
relevance: low
verdict: Go/Node self-hosted voice contact center vertical — wrong stack and wrong layer for samen; only a couple of packaging/positioning ideas worth noting.
---

# 065 — Comcent CE

## What the project is

Comcent CE is an open-source (AGPL-3.0, dual-licensed commercially) voice contact center designed to run on a single Linux server: bring-your-own SIP trunk (Twilio/Telnyx), Kamailio as the SBC, a Go backend, Node.js/Turbo monorepo frontend, Docker Compose deployment. Features: browser-based agent calling, queues, IVR/business-hours routing, call recording to S3-compatible storage, optional Deepgram transcription and OpenAI summaries/sentiment/voice-bot, multi-tenant orgs with API keys and webhooks. Small but active (~45 stars, 57 commits, one-line installer, auto-migrations on startup, Let's Encrypt HTTPS). Positioned to run on a $12/mo droplet.

It is a finished product in a single vertical (telephony/CX), not a substrate, framework, or pattern library.

## What samen could adopt

Little that is directly transplantable — different language (Go/Node vs Elixir/Ash), different layer (product vs foundry). Two ideas carry over as inspiration only:

1. **One-line installer + "runs on a $12 droplet" positioning** — what: a single curl-to-install bootstrap with explicit minimum-hardware framing and first-run time stated honestly (~800MB, 5–10 min). Why it fits samen: samen's generated apps already boot-and-probe in CI (`mix samen.gen.app`), but there is no equivalently blunt "generated app → running on a cheap box in N minutes" operator story; this is cheap credibility for the eventual Fly/deploy-artifact path (fail-honest deploy seam already exists). Effort: S (docs/script polish, not new mechanism).
2. **Bring-your-own-vendor as the default demo posture** — what: Comcent ships fully functional with optional Deepgram/OpenAI keys layered on. Why it fits: samen already does this better (keyless fake AI provider, fail-honest adapters), so this is confirmation of the pattern, not new work. Effort: none — already adopted.

A voice/telephony scope blueprint for samen is **not** worth deriving from this repo: Kamailio/SIP is deep infrastructure with no Elixir carryover here, and no vertical demand exists in the samen roadmap (G-register has no telephony gap).

## What to ignore and why

- **The entire SIP/Kamailio/media stack** — domain-specific C/Go telephony infrastructure; zero overlap with samen's kernel, and samen verticals (driftwood, pawchart) prove leverage in other domains.
- **Its multi-tenancy, API keys, webhooks, recordings-with-transcripts model** — samen's equivalents (OrgScope policies, deny-by-default JSON:API, webhook subsystem, vault/masking, AI chokepoint) are architecturally far stronger; Comcent has no PII vaulting, masking, audit chaining, or verification story to learn from.
- **AGPL-3.0 code** — license-incompatible with reading-for-reuse into MIT samen anyway; treat as concept-level reference only.
- **Turbo/Node frontend monorepo conventions** — samen is LiveView-first with a function-component kit; nothing to import.
