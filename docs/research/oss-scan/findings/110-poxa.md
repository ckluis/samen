---
project: Poxa
url: https://github.com/edgurgel/poxa
category: Infrastructure and Operations
relevance: low
verdict: Stale, single-tenant Pusher-protocol clone; Phoenix Channels/PubSub already gives samen everything it offers, minus masking and multi-tenancy.
---

# What the project is

Poxa is a standalone Elixir server that re-implements the Pusher WebSocket protocol so apps written against Pusher client libraries (`pusher-js`, `pusher-gem`, etc.) can point at a self-hosted server instead of Pusher's SaaS. It runs as one Elixir/Cowboy process boots with a single hardcoded app id/key/secret (not multi-tenant — one Poxa instance = one Pusher "app"), and supports public/private/presence channels, client events, webhooks, an SSL websocket + REST API (`/channels`, `/channels/:name`, `/users`), and a small built-in debug console. Internally it uses `gproc` as a process registry: a subscribed websocket connection tags itself `{pusher, channel_name}`, and a triggered event fans out to every process matching that tag — essentially a hand-rolled pub/sub broker built directly on OTP process registration rather than a framework abstraction. It ships as a Docker image and has historically been deployed to Heroku/Render for demos. Project stats: MIT, ~1,087 GitHub stars, not archived, but last code push was 2024-06-30 (over two years stale) and the README's own TODO list (SockJS support, distributed multi-node operation) has sat unaddressed for years — it is a maintained-in-name-only, feature-frozen implementation of an older Pusher protocol version.

# What samen could adopt

- **Nothing load-bearing.** Samen already has a native realtime layer (`samen_web/lib/samen/web/chat`, described in the digest as "cross-plane realtime, catalog-driven masking-aware object unfurl") that is almost certainly built on Phoenix Channels/Phoenix.PubSub — the framework-native equivalent of what Poxa hand-rolls with `gproc`. Phoenix Channels supersedes everything Poxa does (topic-based pub/sub, presence tracking via `Phoenix.Presence`, client events) while integrating with samen's existing auth, masking, and two-plane conventions; Poxa's tag-and-broadcast pattern over `gproc` is not a technique samen needs to import.
- **Possible narrow idea, not urgent (effort: S, speculative):** if samen ever wants to let *generated tenant apps* (`mix samen.gen.app` output) expose a Pusher-protocol-compatible endpoint for customers who already have Pusher client SDKs wired into their own frontends, Poxa's REST surface (`/channels`, `/channels/:name`, `/users`) is a small, readable reference for what that compatibility shim would need to expose. This is not implied as a need anywhere in the samen digest or roadmap (G-register has no Pusher-compat gap), so treat this as opportunistic only if such a requirement surfaces later — do not build toward it speculatively.

# What to ignore and why

- **The entire pub/sub architecture.** `gproc`-tag-based fanout is a pre-Phoenix-Channels pattern; samen's kernel is Ash/Phoenix-native and already has a superior, masking-aware realtime primitive. Adopting Poxa's approach would be a regression, not an upgrade.
- **Single-tenant-by-design app model.** Poxa boots with exactly one app id/key/secret compiled into config — the opposite of samen's multi-tenant, org-scoped, catalog-driven architecture (ADR-010 two-plane/three-identity model). Nothing about Poxa's tenancy model transfers.
- **No PII/masking awareness whatsoever.** Poxa broadcasts raw event payloads with no concept of vaulting, `%Masked{}` rendering, or chokepoint egress; wiring it into samen unmodified would be a direct violation of samen's mask-by-default invariant (INV-1).
- **Staleness and TODO debt.** Last pushed 2024-06-30 with known-unaddressed TODOs (SockJS, distributed/multi-node operation) — this is not an actively evolving reference to track, and its Cowboy/gproc-era implementation predates samen's Elixir 1.20/OTP 29, Phoenix 1.8/LiveView 1.2 toolchain by several major versions.
- **Docker/Heroku/Render deploy story.** Samen's ops target is Fly + Neon per the roadmap; Poxa's packaging and deploy docs have no bearing on that.
