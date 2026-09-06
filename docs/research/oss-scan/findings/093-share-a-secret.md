---
project: Share a Secret
url: https://github.com/Flo0807/share-a-secret
category: Developer Tools
relevance: low
verdict: Small, well-built Elixir/Phoenix one-time-secret-sharing point tool; useful UX pattern for reveal-link ergonomics, but no framework, no Ash, no multi-tenant substrate to learn from.
---

# What the project is

Share a Secret is a self-hosted, single-purpose web app (Apache-2.0, ~17 stars, active) for sharing sensitive text/passwords via one-time links: the secret is encrypted with 128-bit AES symmetric encryption and stored in Postgres, but the decryption key lives only in the URL fragment and the URL itself is never persisted server-side — so a database breach alone cannot decrypt anything, and only whoever holds the link can. Links can be configured with an access-count limit and an availability duration, and become invalid after being viewed. It's built on Elixir + Phoenix 1.8.11 + Phoenix LiveView 1.2.9 (versions nearly identical to samen's pinned `phoenix ~>1.8.9` / `phoenix_live_view ~>1.2.9`) with TailwindCSS/daisyUI, Ecto/Postgrex, Bandit, Gettext, and standard Phoenix tooling (Credo, Floki, Mox, Phoenix LiveDashboard). No Ash, no OTP-supervision-tree novelty, no multi-tenancy — it is a single-tenant, single-feature consumer utility with a straightforward LiveView CRUD architecture. Deployment is Docker-image-based (`latest`/versioned/`main` tags), with a `compose.example.yml`, manual `SECRET_KEY_BASE` generation via `mix phx.gen.secret`, `/app/bin/create` + `/app/bin/migrate` for DB setup, and a stated recommendation to terminate TLS at a reverse proxy (nginx) in front of it.

# What samen could adopt

- **Client-held decryption key, never-persisted URL pattern for one-off reveal deliverables.** The core idea — encrypt server-side, but keep the key (or the full URL) out of any persisted store, so a DB compromise alone yields nothing — is a clean, minimal pattern worth borrowing for narrow, ephemeral disclosure surfaces samen already has stubs for: DSAR self-serve export (G19, open) and one-time credential/invite delivery in the identity spine. Samen's vault chokepoint already goes further (KMS-managed per-subject keys, chokepoint-minted access), but for a literal single-use export link (e.g., a DSAR bundle download URL, or a break-glass credential handoff), a "key lives only in the URL, URL is never stored" convention is a cheap, auditable hardening on top of the existing reveal-grant/expiry machinery. Effort: S.
- **One-time-view invalidation as explicit UX, not just a policy field.** The app treats "viewed once → dead link" as a first-class state machine outcome surfaced to the user (a clear "this secret is gone" screen), rather than a silent expiry. Samen's reveal grants already have `expires_at` and no in-place renewal (ADR level), but the operator/tenant-facing UX for "this reveal window is now closed" could take the same explicit-terminal-state treatment for clarity in the identity spine and reveal UI. Effort: S.

# What to ignore and why

- **The entire product/architecture**: this is a single-tenant, single-feature app with no scopes, no policy layer, no RBAC, no org-scoping, no catalog, no audit chain, and no verification/sabotage discipline — none of samen's load-bearing architecture (vault chokepoint, two-plane model, hash-chained audit, fail-honest adapters, generative CI proof) has an analog here to compare against or borrow from.
- **AES-128 symmetric encryption choice**: samen's vault already uses AES-256-GCM via OTP `:crypto` behind a KMS behaviour (ADR-001/003); this project's simpler cipher and lack of per-subject key material is a strictly weaker scheme, not an upgrade path.
- **Docker/Compose self-hosting story**: samen's deploy target is Fly/Neon-style managed cloud infra per its roadmap (WS-L), not single-container self-hosting; nothing operationally transferable.
- **No Ash, no multi-tenancy, no generator/verifier tooling**: the tech-stack version overlap (Phoenix/LiveView pinning) is coincidental currency, not evidence of shared architectural thinking — there is no generative-proof, catalog, or scope-blueprint equivalent to compare.
