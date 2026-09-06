---
project: Lanyard
url: https://github.com/Phineas/lanyard
category: Communication and Social
relevance: low
verdict: Elixir Discord-presence bridge; single-purpose consumer service with nothing samen's governed SaaS substrate needs — skip.
---

# 071 — Lanyard

## What the project is

Lanyard is an Elixir service (~1.5k stars, actively maintained, MIT) that connects a Discord bot to Discord's gateway with privileged presence intents and re-exposes user presence (status, activities, Spotify) over a public REST endpoint and a WebSocket (`wss://api.lanyard.rest/socket`) with an opcode-based protocol (heartbeats, zlib_json compression, per-user / multi-user / firehose subscriptions). It also offers a small per-user KV store (max 512 keys, 30KB values, Redis-backed) merged into presence payloads. Self-hosting is Docker + Redis + a Discord bot token behind a reverse proxy. A large third-party wrapper ecosystem (React, Vue, Go, Python, etc.) exists around its hosted instance.

## What samen could adopt

Essentially nothing structural. Two marginal ideas, neither worth active effort:

- **Opcode/heartbeat WebSocket protocol design for a public realtime API** — what: Lanyard's documented op-based subscribe/heartbeat/compression contract for third-party consumers; why it might fit: if samen ever exposes a public realtime API to external (non-LiveView) clients, this is a clean reference for versioned wire contracts; effort M — but samen's realtime surfaces (chat, notifications) are Phoenix Channels/LiveView within its own planes, and no public realtime API is on the roadmap. Not actionable now.
- **Wrapper-ecosystem-as-adoption playbook** — what: Lanyard's traction comes largely from 20+ community client wrappers around one tiny, stable API; why: mildly relevant to the G22 "agent-grounding packaging for builders" theme (small stable contract → community tooling); effort S as a positioning note only, no code.

## What to ignore and why

- **The entire domain**: Discord presence mirroring is a consumer/social use case with zero overlap with multi-tenant SaaS, PII governance, billing, or operator planes.
- **Redis as state store**: samen is deliberately Postgres-centric with a vendor-free core (INV-4); introducing Redis contradicts the architecture for no gain.
- **Public unauthenticated presence API + user KV store**: Lanyard broadcasts user data by design — the inverse of samen's mask-by-default, token-blind posture; its KV store has none of the classification/vaulting discipline samen requires.
- **Discord gateway integration**: no samen roadmap item needs Discord; if one ever did, it would be a fail-honest adapter package, not a pattern borrowed from here.
