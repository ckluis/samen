---
project: PodSync
url: https://codeberg.org/jorams/pod-sync
category: Media and Personal
relevance: low
verdict: A tiny single-user, no-auth Elixir/Phoenix podcast sync toy with no multi-tenancy, PII handling, or Ash usage — almost nothing transfers to samen's SaaS-foundry concerns.
---

## What the project is

PodSync is a "very simplistic" single-user podcast synchronization server that implements the Nextcloud GPodder Sync API, letting podcast apps (tested with AntennaPod and Kasts) sync subscriptions/episode state without a Nextcloud instance. It is built in Elixir/Phoenix (90.6% Elixir) with SQLite for storage, packaged as a Podman/Docker container, and configured via plain env vars (`DATABASE_PATH`, `SECRET_KEY_BASE`, `PORT`, `PHX_HOST`). It deliberately has **no authentication and no multi-user support** — it's a personal, single-tenant self-hosted utility. Repo history is tiny (6 commits), most recently doc comments in January 2026; there is no Ash usage, no test/verification harness of note, no notable architectural patterns beyond a minimal Phoenix API server over SQLite.

## What samen could adopt

Nothing substantive. Scanning against samen's core concerns (multi-tenant vaulting/masking, two-plane architecture, verification/sabotage discipline, Ash ecosystem patterns, agent/AI plane, fleet cockpit) turns up no overlap:

- The env-var-driven container config (`DATABASE_PATH`/`SECRET_KEY_BASE`/`PORT`/`PHX_HOST`) is standard Phoenix release convention samen already follows — nothing new to learn here. Effort: N/A.
- The GPodder-Sync-API-compatibility idea (cloning a third-party sync protocol against a simpler storage backend) is a pattern samen could theoretically reuse for adapter design, but it's too generic and low-signal to count as a concrete adoptable pattern.

## What to ignore and why

Ignore essentially the whole project. It is single-user by design (no org/tenant model, no auth), has no PII vaulting/masking, no Ash resources, no verification/CI discipline, and a near-zero commit history — it sits far outside samen's domain (multi-tenant SaaS trust-kernel framework) and offers no libraries, UX flows, or ops practices worth importing.
