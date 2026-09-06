---
project: Pinchflat
url: https://github.com/kieraneglin/pinchflat
category: Media and Personal
relevance: low
verdict: "Actively maintained Elixir/Phoenix LiveView self-hosted YouTube downloader (yt-dlp wrapper, 5.3k stars) — single-tenant, SQLite-backed, no Ash, no PII story; at most one small ops-config idea, nothing core to mine."
---

# 122 — Pinchflat

## What the project is

Pinchflat is a **self-hosted YouTube media manager and downloader** (AGPL-3.0, Elixir/Phoenix + LiveView, actively developed — 390+ commits, 5.3k stars, 202 open issues) built as a wrapper/scheduler around `yt-dlp`. It periodically checks configured YouTube channels/playlists, applies user-defined download rules (quality, format, SponsorBlock integration, Shorts/livestream handling, redownload-on-interval for better quality/tags), and organizes output on disk with a flexible naming/folder scheme for consumption by Plex/Jellyfin/Kodi — it is explicitly not an in-app player, just an archiver/organizer.

Stack: Phoenix + LiveView for a real-time dashboard (download queue/status), **SQLite** as the persistence layer (WAL by default, switchable to `delete` mode for network-share deployments), and a worker-pool style concurrency model for yt-dlp invocations (`YT_DLP_WORKER_CONCURRENCY`, default 2 per queue) — this reads as a hand-rolled OTP worker pool rather than Oban, though the underlying library wasn't independently confirmed. Deployment is Docker-only (GHCR + Docker Hub images, Podman documented), with env-var config for timezone, basic HTTP auth, RSS exposure for podcast apps, Prometheus metrics, IPv6, and reverse-proxy WebSocket routing (including a `BASE_ROUTE_PATH` for subpath hosting). Extensibility comes via custom yt-dlp CLI args and alpha "lifecycle scripts" that fire on post-download/post-delete events. Auth is single basic-HTTP-credential, no multi-user model, no multi-tenancy.

This is the same product category and posture as prior "Media and Personal" entries scanned (e.g. Mydia, #121): single operator, single household, no org/tenant boundary, no PII-handling story, no Ash. It shares essentially nothing with samen's target domain (multi-tenant B2B SaaS with PII vaulting, org-scoped policy/RBAC, crypto-shred erasure, two-plane operator/tenant governance, hash-chained audit, generative CI proof, sabotage harness).

## What samen could adopt

1. **Explicit `BASE_ROUTE_PATH`-style subpath-hosting support with documented reverse-proxy WebSocket caveats** — Pinchflat calls out, in its ops docs, exactly which reverse-proxy directives are required for LiveView WebSockets to survive path-based (non-subdomain) routing, plus an env var for mounting under a subpath. Why it fits samen: samen_web's tenant/operator plane routing (ADR-009 mountable modules) and the fleet cockpit's multi-app posture will eventually hit exactly this class of "customer wants to reverse-proxy our LiveView app under `/tools/samen-app`" support request; a documented, tested subpath-mount + WS-proxy-config pattern is cheap to pre-empt now. Effort: **S** (one ops doc page + a manual verification pass with nginx/Caddy config snippets; no code change to core).

2. **SQLite journal-mode toggle for network-share/degraded-storage deployments** — a narrow, single config knob (`delete` vs `WAL` journal mode) aimed at a specific operational failure mode (SQLite over NFS/SMB corrupts under WAL). Why it fits samen: low direct relevance since samen is deliberately Postgres-only (crypto-shred, pgvector, audit CHECK constraints all assume it — ADR against SQLite is implicit throughout), but the *pattern* — one env var that trades a performance default for durability under a named deployment constraint, documented as such — is a good template for samen's own Local/S3 storage adapter maturation (WS-E follow-on: real `Storage.S3` impl) where a similar durability-vs-throughput knob will likely be needed. Effort: **S**, and only worth doing when the S3 storage adapter work is picked up — not a standalone task.

## What to ignore and why

- **Everything domain-specific** (yt-dlp wrapping, channel/playlist polling, SponsorBlock, Shorts/livestream rules, media-server folder naming) — no overlap with a SaaS foundry's surface area.
- **No Ash usage** — plain Phoenix/Ecto/SQLite; none of Ash.Resource, policies, ash_archival, ash_paper_trail, or the rich-type system have an analog to compare against here.
- **No multi-tenancy, no PII model, no auth spine** — single basic-HTTP-credential auth is not comparable to samen's ADR-035 identity spine (OIDC, TOTP, session management, audited resets); there's nothing to adopt on the identity/PII front because the domain doesn't need one.
- **The "novel faster-than-polling new-content detection" claim** — undocumented in the fetched README detail beyond a marketing line; not independently verified, and even if real it targets YouTube-RSS-specific mechanics with no analog to samen's automation/webhook/CDC surfaces.
- **AGPL-3.0 licensing** — a copyleft license unsuitable for pulling code into samen's MIT monorepo even where a pattern looked interesting; the two items above are documentation/config patterns to imitate, not code to vendor.
- **SQLite as a datastore choice generally** — directly contrary to samen's deliberate Postgres-only purity invariant.
