---
project: Loopyard
url: https://github.com/loopyard/loopyard
category: Software Factories
relevance: low
verdict: Elixir-built coding-agent workspace orchestrator, not a SaaS substrate — nothing samen's product kernel needs; at most dev-process inspiration, and AGPL bars code reuse.
---

# 022 — Loopyard

## What the project is

Loopyard is an open-source (AGPL-3.0-or-later) "multiplayer software factory": a self-hosted
Elixir 1.19+ / Node.js application that runs Claude Code agents inside isolated Docker
workspaces so they can operate with full autonomy (permission prompts disabled, overnight runs)
without endangering the host. Key features:

- **Docker-everything substrate** — "every workspace, agent, and dev server is a container";
  zero-config onboarding clones a repo, auto-detects the stack, and generates
  Dockerfile/Compose (Postgres, Redis, dev server, env vars). Mutagen syncs files host↔volume.
- **Multiplayer observability** — every chat, terminal, and service log gets its own live URL,
  shareable across devices; SSH into containers on port 2222.
- **Concurrent agents + operator agent** — multiple agents per project run simultaneously,
  with an operator agent that watches every workspace and dispatches work.
- **Durable review decisions** — "durable cards" park decisions that need human input; users
  answer from chat, a "For You" rail, or a `/review` deck, and agent work resumes on answer.
- **Credential posture** — tokens are pushed up from the user's machine via per-user setup
  URLs rather than read from disk inside containers; containers and conversations survive
  server restarts.

Repo status (2026-08): ~1,800 commits, 52 stars, 6 forks, 67 open issues, Linux CI with
Docker E2E tests, contributor CLAUDE.md with `/new-feature`, `/fix-bug`, `/review-pr` skills.
Active but small-community; it is a dev-tool product in the same market as Claude Code CLI /
Cursor / Codex (it ships comparison pages), not a framework.

## Why relevance is low for samen

Samen is a SaaS *product substrate* (vault/masking, two-plane policy, verifiers, generators).
Loopyard addresses a different layer entirely: how coding agents are hosted while they build
software. It offers no Ash patterns, no multi-tenancy/PII/policy machinery, no SaaS product
surfaces. Its only overlap is with samen's *development process* (the `_orch/` autonomous
agent loop), which already has mature, deliberately different conventions (serialized
fan-outs, foreground gate tasks, per-task handoff files as durable state). The published
material also doesn't surface notable OTP/supervision patterns worth studying.

## What samen could adopt

- **Docker-isolated workspace for autonomous runs** (dev-process only). What: run samen's
  `_orch` agent sessions inside a container with the repo volume-mounted and local Postgres
  containerized, so overnight/unattended rounds have a bounded blast radius. Why it fits:
  samen's loop already runs long autonomous batches with full `./ci.sh` gates; isolation is a
  cheap safety upgrade and doesn't touch product code. Effort: M (Compose file + KMS-sim/
  Postgres wiring + doc note; no kernel changes). Build it independently — AGPL forbids
  lifting Loopyard code into MIT samen.
- **"Durable card" framing for operator gates** (idea only). What: a single queue-of-pending-
  operator-decisions view over `_orch` (blocked tasks, human-gated TODOs like T88/T89/T91)
  instead of grepping backlog.yaml. Why it fits: samen's runs strand credential-gated items;
  a resume-digest-style "decision deck" is the same knowledge-as-infra move as
  `resume-digest.sh`. Effort: S (script emitting a markdown deck; no runtime).

## What to ignore and why

- **The product itself / any code reuse** — AGPL-3.0 is incompatible with samen's MIT repo;
  and samen doesn't need a hosted agent-orchestration app.
- **Concurrent multi-agent-per-project model** — directly contradicts samen's proven
  serialize-fan-outs / foreground-gate discipline; concurrency was a source of stranded
  agents, not a gap.
- **Multiplayer terminals / live URLs / SSH-into-container** — solo-operator workflow;
  no second human to share with.
- **Auto-generated Dockerfiles/Compose from stack detection** — samen's toolchain is fixed
  (Elixir 1.20/OTP 29, local Postgres) and its deploy story is deliberately operator-gated
  (Fly TODOs); auto-generated infra conflicts with fail-honest, hand-verified infra proofs.
- **In-product approvals inspiration** — samen already has a stronger version (E3 approvals
  engine, requester≠approver at policy + DB CHECK layers); nothing to learn here.
