---
project: BBoard
url: https://codeberg.org/fungal/bboard
category: Communication and Social
relevance: low
verdict: Tiny personal Phoenix forum with stock deps; nothing samen doesn't already do far deeper — only its hardened systemd unit is even mildly interesting.
---

# 063 — BBoard

## What the project is

A minimal bulletin-board/forum in Elixir + Phoenix 1.7 (LiveView 1.0, Bandit, Ecto/Postgres with citext, argon2_elixir, esbuild). Self-described by the author as "not really meant to be something run by anyone." ~102 commits, 1 star, v0.2.0 on the `develop` default branch, last touched 2026-08-02, EUPL-1.2, Woodpecker CI. Features: invite-code-gated registration (`MAX_INVITES` per user), env-var-assigned admin/mod roles (`ADMINS`/`MODS` as comma-separated user IDs), configurable allowed link schemes, OTP release deployment with a documented systemd unit. First-user bootstrap is manual: raw SQL insert with a hand-generated argon2 hash, or `bin/bboard remote` REPL calling `Bboard.Accounts.register_password/1`.

## What samen could adopt

- **Systemd sandboxing directives for self-host ops docs** — the unit uses `DynamicUser`, `PrivateDevices/IPC/Tmp`, `ProtectHome/Hostname/Clock/ControlGroups/KernelLogs/KernelModules/KernelTunables`, `RestrictRealtime`, `StateDirectory`, root-owned `400` EnvironmentFile, plus an SELinux `chcon` note. Why it fits: samen's WS-L ops story is Fly-centric; if a "self-host a generated app on bare metal" guide ever ships, this is a decent hardened-unit checklist to crib. Effort: S (docs-only). Marginal priority.
- Nothing else. Invite-gated registration, roles, releases, env-var config — samen's identity spine (team invites with role selection and lifecycle, generator-emitted auth, seeds) already covers each with vaulting, auditing, and verifier proof this project has no concept of.

## What to ignore and why

- **The auth/accounts code** — vanilla phx.gen.auth-shape with plaintext PII columns; samen vaults credential PII and gates everything through chokepoints.
- **Env-var role assignment (`ADMINS="1,42"`)** — anti-pattern versus samen's RBAC/policy layer; roles as deploy-time env vars can't be audited or org-scoped.
- **Manual SQL/REPL user bootstrap** — samen solves first-user creation with atomic Org+User+Membership registration and seeds; documenting raw-insert password hashes is the opposite of samen's discipline.
- **Forum domain itself** — if samen ever wanted community/forum features, its own Scopes (mailbox, chat, support) are the substrate; nothing here to lift.
- **Stack choices** — Phoenix 1.7/LiveView 1.0/Bandit are stock and older than samen's pins; no Ash, no OTP patterns beyond a default supervision tree, no tests worth studying.
