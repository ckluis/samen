---
project: HydraSRT
url: https://github.com/streamband/hydra-srt
category: Media and Personal
relevance: low
verdict: Elixir/OTP + MCP broadcast-video gateway — same substrate, wrong domain; a couple of small MCP-token and process-isolation notes are the only transferable bits.
---

# What the project is

HydraSRT is an open-source alternative to Haivision's SRT Gateway: a video-transport routing box for broadcast workflows (SRT/UDP/RTMP/RTP in and out, opt-in NDI, HLS/WebRTC planned). Polyglot three-layer architecture: an Elixir/OTP control plane (route supervision, SQLite config, REST/WebSocket API), a Rust + GStreamer media plane (one isolated OS process per route), and a React + Vite dashboard. Supervision tree: `HydraSrt.Application` (`:one_for_one`) → `PartitionSupervisor` → per-route `RoutesSupervisor` → a `RouteHandler` `gen_statem` that owns a single native GStreamer pipeline via an Erlang Port. On pipeline crash the handler kills and respawns the OS process rather than attempting in-place GStreamer state recovery; VictoriaMetrics/VictoriaLogs are optional and their failure degrades analytics without crashing the app. It also ships a Model Context Protocol server (`hermes_mcp` library, 43 curated tools, bearer tokens stored as SHA-256 hashes shown once at creation) so AI assistants (Cursor, Claude Desktop) can manage routes and inspect logs. Beta maturity: ~139 stars, 10 forks, 223 commits.

# What samen could adopt

- **MCP token display-once + hash-at-rest convention.** HydraSRT's MCP tokens are SHA-256-hashed at rest and the plaintext value is shown exactly once at creation, mirroring API-key best practice. Worth a quick check that samen's own per-operator MCP tokens (ADR-043) follow the same discipline if they don't already — cheap and directly comparable since both projects hand-rolled an MCP server. Effort: S (verify/patch only, likely already covered by samen's vault/token conventions).
- **Curated-tool-subset framing for MCP surfaces.** HydraSRT explicitly documents that MCP only covers a curated tool subset, not full REST parity, and calls out what's unimplemented (resource/prompt primitives, token expiry, usage tracking) rather than implying full coverage. This is a documentation-honesty pattern, not code — consonant with samen's claim-evidence culture, worth applying to samen's own MCP tool-surface docs if not already explicit about what the MCP server does *not* expose. Effort: S.

# What to ignore and why

- **The entire product domain**: broadcast video routing (SRT/RTP/RTMP/NDI transport, GStreamer pipelines, source failover for live feeds) has zero overlap with a multi-tenant B2B SaaS substrate. No PII, no tenancy, no billing, no vault concept applies.
- **`hermes_mcp` library and gen_statem-owns-external-process pattern**: samen already hand-built its own MCP server and has an explicit chokepoint/masking posture (ADR-043) that a generic MCP library doesn't provide; adopting the library would reintroduce exactly the vendor-dependency-in-core problem ADR-037's Ash-ecosystem gate was designed to reject. The `gen_statem`-owns-a-Port pattern is a reasonable BEAM idiom but solves "supervise a risky native process," a problem samen doesn't have (samen has no native/GStreamer-style subprocess workloads).
- **Rust + GStreamer media plane, React+Vite dashboard, SQLite config store**: samen is Postgres-first end to end (including pgvector) and Phoenix/LiveView for UI; none of this stack choice transfers.
- **"Honest degradation when optional analytics store fails" as a novel idea**: samen's fail-honest adapter invariant (ADR-014/024/026/038) already covers this more rigorously (typed `{:error, :not_configured}` results across email/Stripe/files/AI/backup, not just metrics); nothing new to import here, just a confirmation the pattern is industry-sound.
