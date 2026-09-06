---
project: Hacker News frontend
url: https://codeberg.org/jorams/hacker-news
category: Media and Personal
relevance: low
verdict: A small single-purpose Phoenix hobby app (mobile HN reader over the public HN API) with no multi-tenancy, auth, PII, or Ash usage — nothing structurally relevant to samen's SaaS-foundry concerns.
---

## What the project is

A mobile-focused alternative web frontend for Hacker News, built in Elixir/Phoenix (Elixir 80.3%, HTML 7.7%, JS 5.5%, Dockerfile 3.6%, Shell 2.4%). It server-renders pages by calling the official read-only Hacker News API (no user accounts, no database of its own, no writes), with "very minimal JS," styling/UX inspired by hn.premii.com. Comment-thread pages require an "enormous number" of HTTP fan-out requests per page load against the HN API, mitigated by caching (no rate limits on the HN API make this viable). Ships as a container image (Podman/Docker) via `bin/build-container-image`, configured with just `SECRET_KEY_BASE` and `PORT`; local dev is `mix setup` + `mix phx.server`. Licensed EUPL-1.2.

It is a personal read-only content proxy/reader, not a SaaS product, multi-tenant app, or anything with persisted user data, billing, or PII.

## What samen could adopt

Nothing rises to a concrete adoptable pattern. The only tangentially relevant idea:

- **Aggressive per-request caching in front of a fan-out external API** (what: cache layer absorbing N HTTP calls per page render; why it fits samen: samen's adapter packages — samen_stripe, samen_anthropic, ESP adapters — also wrap external HTTP APIs and could benefit from a similar caching discipline for read-heavy, rate-sensitive endpoints; effort: S) — but this is a generic Elixir pattern samen's `req`-based adapters can already apply on their own; the HN project offers no novel implementation worth studying (no Ash, no Oban, no notable OTP supervision pattern visible from the README).

## What to ignore and why

- **The entire app architecture** — no Ash, no Ecto/Postgres, no multi-tenancy, no auth, no PII, no vault, no billing, no LiveView-driven UI kit of note. It is orthogonal to every one of samen's core concerns (two-plane masking, crypto-shred, chokepoints, catalog, verifier gates).
- **UI/UX inspiration** — a minimal-JS HN reader clone has no bearing on samen's operator/tenant plane UX, which is form- and workflow-heavy (approvals, reveal grants, fleet cockpit) rather than a read-only content feed.
- **Deployment story** — plain Docker/Podman container with two env vars is far below the bar samen already clears (Fly deploys, KMS/secrets discipline, generative CI gate); nothing to borrow.
