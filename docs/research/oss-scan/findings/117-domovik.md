---
project: Domovik
url: https://github.com/domovikapp/domovik-server
category: Media and Personal
relevance: low
verdict: A small single-maintainer Elixir/Phoenix consumer E2EE browser-sync app — genuine Elixir signal but no Ash, no multi-tenancy, no vault/reveal architecture; only loosely transferable patterns.
---

## What the project is

Domovik (`domovik-server`, 41 stars, AGPL-3.0, active — pushed 2026-08-08) is a self-hostable "cross-browser, privacy-oriented synchronization service" that syncs open tabs, bookmarks, and transient reading lists across browsers, plus lets a user send an async "command" (e.g. push a page) from one browser to another. A companion browser WebExtension (separate `domovik-webext` repo) does the client side.

Stack: **Elixir 1.14 / Phoenix 1.7**, plain **Ecto + PostgreSQL** (no Ash), **Pow** for auth, **Bamboo** for email, **stripity_stripe** for billing, Phoenix Channels (`user_socket.ex`) for realtime push, Mnesia enabled as an extra OTP app, deployed via Docker/Docker Compose or systemd unit, dev environment via `devenv`/Nix.

Its core claim, textually close to samen's own PII language: *"Domovik uses an end-to-end encryption scheme such that none of your browsing data ever transit in clear through the synchronization server."* Keys are password-derived client-side (in the browser extension, using the WebCrypto API — HTTPS is mandatory for this reason); the README is explicit that losing the password means losing all synced data, since the server never holds anything that can decrypt it. This is **true zero-knowledge E2EE** — a materially different trust model from samen's server-side vault+reveal-grant masking, where an authorized operator/tenant can always request plaintext through an approved, audited path.

Codebase is small and conventional: `lib/domovik/{bookmarks, reading_list, sync, users}` contexts, `lib/domovik_web/{controllers, channels, pow, plugs}` — a straightforward single-purpose Phoenix CRUD+Channels monolith, not a multi-tenant platform. No LiveView dependency; no Ash; no separate billing context despite the Stripe dependency (Stripe wiring appears to live directly in a controller, not as a first-class module).

## What samen could adopt

1. **Zero-knowledge / true client-side E2EE as an opt-in storage class.** What: for specific product verticals where samen's operator-reveal model is unwanted (e.g. a password manager or notes app built on samen), support a `pii_zero_knowledge` field class where the vault never holds a server-recoverable key at all — key material derived and held client-side only, server stores ciphertext it structurally cannot decrypt (not just "masked by default," but "undecryptable by anyone but the client"). Why it fits: samen's whole story is chokepoint-enforced PII discipline; this is a natural, on-brand extreme end of that spectrum for verticals that need it, and it's a small conceptual bolt-on to the existing `Samen.Type` / vault-class system rather than a new subsystem. Effort: **M** (needs a documented client crypto contract + WebCrypto reference implementation + an ADR on trading off "erasure via key-destruction" against "no recovery ever," since this is a much harder support/UX posture than samen's current reveal-gated model).

2. **Phoenix Channels for lightweight cross-device/cross-plane push.** What: Domovik uses a plain `Phoenix.Socket`/Channel to push async commands between browser sessions. Why it fits: samen's chat surface is already described as "cross-plane realtime, catalog-driven"; this is confirmation that a vanilla Channels layer (no extra dependency) is a viable, simple pattern for any future low-latency push needs outside chat (e.g. live fleet heartbeat UI, live agent-run progress) if LiveView's server-rendered model doesn't fit a given surface. Effort: **S** (validates an approach samen substantially already uses, nothing new to build).

## What to ignore and why

- **Ecto/plain-Postgres data layer, Pow auth, no multi-tenancy.** Domovik is single-user-per-account with no org/tenant concept at all — the opposite of samen's two-plane, OrgScope-everywhere design. Nothing here generalizes; samen already made and documented the harder, more general choice (ADR-010, ADR-037 rejecting ash_authentication rewrites in favor of its own identity spine).
- **stripity_stripe wiring.** It's a thin, ad hoc controller integration for a single fixed-price consumer subscription, not a sync-adapter/webhook-reconciliation pattern — offers nothing samen's `SyncAdapter.Stub` gap (G13) needs when it eventually goes live.
- **Mnesia as an extra OTP app.** Appears to be legacy/vestigial (likely just declared, not obviously load-bearing for the sync feature) and in any case is out of step with samen's Postgres-only, KMS-external, WAL-avoidance posture (ADR-001) — not worth investigating further.
- **General app structure / Docker-Compose deploy.** Conventional Phoenix release deploy, nothing samen's own `mix samen.gen.app` / CI gate story doesn't already exceed.

## Process note

No further sub-agent tooling was available in this run context (the `Agent`/Task-launch tool was not present), so this evaluation was done directly via WebFetch (GitHub README) and the GitHub API (repo metadata, `mix.exs`, `lib/` tree) rather than via a sequential subagent chain. Depth was calibrated to "one focused pass" given the project's small size (1.6MB repo, single maintainer, consumer scope) once its real-but-modest Elixir/Phoenix relevance was confirmed.
