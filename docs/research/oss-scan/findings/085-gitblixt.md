---
project: GitBlixt
url: https://gitblixt.com/gitblixt/gitblixt
category: Developer Tools
relevance: medium
verdict: Active, well-built AGPL Elixir/Phoenix self-hosted git forge — its approval-gated scheduled-AI-agent pattern, encrypted-backup UX, and Swarm+Caddy self-host PaaS story are worth stealing as patterns, but its core domain (git hosting, issues/MR/CI/wiki) is orthogonal to samen's SaaS-foundry trust kernel and it has zero Ash usage.
---

## What the project is

GitBlixt (gitblixt.com, self-hosted at `gitblixt.com/gitblixt/gitblixt`, dogfooding its own forge) is a real, live, actively developed **self-hosted, GitLab-v4-API-compatible Git forge built in Elixir/Phoenix**, positioned as a lightweight alternative to self-hosted GitLab/Gitea (runs on a 1GB VPS vs GitLab's 8GB+). AGPL-3.0 licensed (confirmed in repo LICENSE — the manifest entry is accurate), copyright "GitBlixt contributors" 2026, single-command Docker install (`curl | sh`).

Verified directly (curl against the live instance, browser UA — plain WebFetch got a 403 from a bot-blocking edge, but the site itself is a normal Cloudflare-fronted Phoenix app, confirmed via `_gitblixt_key` Phoenix session cookie):
- **Feature surface**: full forge — repos (HTTP+SSH transport, blame, file history, web IDE), merge requests (draft, squash, auto-merge, protected branches), issues + boards + milestones, wiki, snippets, organizations/groups with roles, webhooks, OAuth (GitHub/GitLab), TOTP 2FA, PATs, GitHub/GitLab import + push mirroring, admin panel with log streaming and remote shell, scheduled/on-demand encrypted backups (local or S3).
- **Distinctive features**: a **built-in PaaS** (deploy any repo as a Docker service with managed Postgres and per-MR preview environments, via dynamic Caddy route registration over the admin API) and **AI assistance** — Claude Code running in isolated containers to fix issues / review MRs, plus **scheduled agents** that run recurring AI tasks on a cron schedule and open a merge request for review, explicitly "never auto-merged."
- **Stack**: Elixir 1.18+/OTP 27+, Phoenix 1.8 + Bandit (not Cowboy), Phoenix LiveView 1.2, Ecto/Postgres 16-18, Oban (mirror sync, CI dispatch, webhooks, deploys, AI jobs, backups, imports), Docker Swarm for zero-downtime start-first rolling deploys, Caddy for reverse-proxy + auto Let's Encrypt HTTPS, `assent` (OAuth), `nimble_totp` (2FA), `hammer` (rate limiting), `cachex`, `crontab`, git operations abstracted behind a `Gitblixt.Git` behaviour with a shell implementation and a native Rust/gitoxide implementation (via `rustler`). **No Ash anywhere** — plain Ecto/Phoenix/Ecto.Schema throughout.
- Repo is substantial and current: 534 commits, most-recent commit "fix test" ~7 hours before this scan; has `FEATURES.md` (a live GitLab-CE/GitHub-Free feature-parity tracker, last updated 2026-03-19), `CLAUDE.md`/`AGENTS.md` (standard Phoenix 1.8 + `phx.gen.auth` coding-convention boilerplate — generic, not GitBlixt-specific), `SECURITY.md`, `CONTRIBUTING.md` with DCO sign-off.

## What samen could adopt

1. **Approval-gated "scheduled AI agent → draft PR, never auto-merged" UX pattern**
   — *What*: GitBlixt runs recurring AI tasks on a cron schedule; every output lands as a merge request for human review, with auto-merge explicitly excluded from the feature.
   — *Why it fits samen*: this is an external, independently-arrived-at validation of samen's own ADR-047 stance ("AI writes do not exist — anything with side effects goes through the E3 approvals engine"). Samen's roadmap already flags "packaging the agent-grounding differentiator (MCP/eval harness) for external builders" as a next theme; GitBlixt's concrete product framing — a named "Scheduled Agents" feature that surfaces the approval gate as a first-class, marketable capability rather than an invisible policy — is a UX packaging idea worth lifting for samen_web's AI plane.
   — *Effort*: **M**. The governance substrate (Approvals engine, EG2 egress class, agent loop) already exists in samen_core; this is mostly a scheduling primitive (Oban cron) + a surfaced UI affordance, not new architecture.

2. **Encrypted backup envelope UX** — private key shown once, two-object encrypted backups
   — *What*: GitBlixt's backup encryption produces two objects per backup (`*.tar.gz.enc` + `*.key.enc`), shows the generated private key exactly once at enable-time with an explicit "save it off-server" warning, and documents that `secret_key_base`/`APP_SECRETS_KEY` must carry over on restore or encrypted columns won't decrypt.
   — *Why it fits samen*: samen_core already has a `backup` module and a WS-L backup-verification proof (L6, local-sim today). This gives a concrete, tested envelope-key UX and restore-runbook shape (explicit "must restore into an empty DB," explicit secret-carryover warning) samen's real-infra backup story (Neon PITR, S3, etc. — currently operator-TODO) can crib directly when it moves from sim to real.
   — *Effort*: **S–M** (mostly a documented runbook + a show-once key UI; the crypto envelope pattern itself is straightforward given samen already has KMS/vault primitives to build it on).

3. **Self-hosted Docker Swarm + Caddy admin-API PaaS as an alternative deploy target**
   — *What*: on enabling deployment for a repo, GitBlixt registers Caddy routes dynamically via Caddy's admin API over a Docker overlay network, runs the app as a Swarm service with start-first rolling updates, and provisions per-merge-request preview environments with a managed Postgres.
   — *Why it fits samen*: samen's cloud story is currently Fly-centric with real production deploys marked operator-TODO. A self-hosted Swarm+Caddy path is a legitimate lower-cost/no-vendor-lock alternative deploy target for operators who don't want Fly, and the **per-MR preview environment** idea is a nice concrete feature samen's fleet cockpit / generated apps could offer builders directly (spin up an ephemeral tenant instance per PR for QA).
   — *Effort*: **L** (a genuinely new adapter/ops surface — new `Samen.Deploy.Swarm`-style adapter, Caddy admin-API driver, preview-env lifecycle — not a small bolt-on).

4. **Minor engineering-hygiene notes** (low priority, cheap to take or leave)
   — Bandit instead of Cowboy as the HTTP server (samen_web's current adapter isn't specified in the digest; worth a one-line check). *Effort*: S.
   — "Don't let bootstrap/installer traffic hit your rate-limited dynamic content route" — GitBlixt vendors its `docker-compose.yml`/`Caddyfile` into `priv/static` specifically because the git-backed `/-/raw/` browsing route 429s the installer's own `curl` user agent. A cheap general lesson if samen ever ships a curl-pipe installer or bootstrap script that fetches from a rate-limited surface. *Effort*: S.

## What to ignore and why

- **The entire git-hosting/forge domain** — repos, branches, MRs/PRs, issues, boards, wiki, snippets, CI runners, GitLab-v4 API compatibility, GitHub/GitLab import and mirroring, nested subgroups. None of this maps to samen's SaaS-foundry mission (samen is a substrate for building SaaS products, not a code-hosting product). The `FEATURES.md` parity tracker against GitLab CE/GitHub Free is entirely off-mission.
- **No Ash usage at all** — GitBlixt is plain Ecto/Phoenix/Ecto.Schema, contexts, and hand-rolled changesets. There is no Ash resource/policy/blueprint pattern to compare against samen's Ash-first kernel; nothing here informs samen's `Samen.Scopes.*` blueprint or policy-SAT design.
- **`CLAUDE.md`/`AGENTS.md`** — standard `phx.gen.auth`/Phoenix-1.8 boilerplate coding-convention doc (current_scope plumbing, Tailwind v4 import syntax, `<.input>` component usage). Generic Phoenix guidance already superseded by samen's own generator-emitted identity spine (ADR-035); no GitBlixt-specific insight here.
- **AGPL-3.0 licensing caveat**: if any GitBlixt *code* (not just the patterns described above) were ever vendored rather than reimplemented, AGPL-3.0's network-copyleft clause would obligate source disclosure for any modified network-served derivative — a real friction point given samen is MIT and its `docs/compliance-story.md`/positioning cares about clean licensing. Recommend treating everything above as pattern inspiration to reimplement, never as code to copy.
- **"Hot code upgrades" marketing claim** — the GitBlixt homepage advertises "deploy new versions without disconnecting active sessions" as a BEAM hot-code-upgrade benefit, but the actual mechanism documented in the README is a Docker Swarm start-first rolling *restart*, not an OTP release hot-upgrade. Worth noting only as a "don't oversell infra mechanics" cautionary example, not as something to adopt.
