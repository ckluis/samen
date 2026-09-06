---
project: Codebattle
url: https://github.com/hexlet-codebattle/codebattle
category: Games
relevance: low
verdict: Active Elixir/Phoenix multiplayer coding-game platform (real-time matches, sandboxed multi-language code execution) — wrong domain for a multi-tenant SaaS foundry and carries no Ash/PII/vault architecture, so adoption surface is limited to minor ops/sandboxing inspiration.
---

## What the project is

Codebattle (hexlet-codebattle/codebattle, AGPL-3.0) is a real-time competitive-programming game: players solve algorithm challenges head-to-head, similar in spirit to Codewars/LeetCode duels. It is built on **Elixir + Phoenix** (umbrella-app layout under `/apps`) with a **React/JavaScript** frontend, and is actively maintained (5,235+ commits, live at codebattle.hexlet.io, GitHub Actions CI, Codecov, Credo/ESLint linting). Ops tooling includes Docker, Kubernetes manifests (`/k8s`), and Terraform/Ansible for infra provisioning. Player-submitted code appears to run through containerized, per-language runner images (`mix images.build`/`images.push`), i.e., Docker-based sandboxed execution for untrusted code across multiple languages.

It is a consumer game product for one community, not a multi-tenant framework — no tenancy model, no PII vaulting, no Ash resources, no billing/CRM/automation substrate. Its problem space (real-time matchmaking, isolated code execution, leaderboard/rating systems) doesn't overlap with samen's core mission (PII-safe multi-tenant SaaS generation with vault chokepoints, crypto-shred, two-plane masking).

## What samen could adopt

- **What**: Docker-based per-language sandboxed execution model for untrusted code (isolated runner images per language, pushed/managed via Mix tasks).
  **Why it fits samen**: Samen's agent loop (ADR-047) and future `mix samen.gen.agent` tooling may eventually need to run untrusted or semi-trusted code/tool invocations safely; Codebattle's pattern of one container image per language/runtime with a thin Mix-task management layer is a concrete, working reference for that kind of isolation boundary if samen ever adds code-execution tools to its AI/automation plane.
  **Effort**: M — would require adapting the sandboxing/container-orchestration approach, not a drop-in dependency.

- **What**: Elixir umbrella-app repo layout at scale (multiple `/apps` packages) with Terraform/Ansible/K8s ops tooling committed alongside the app.
  **Why it fits samen**: samen already uses a multi-package layout (`samen_core`, `samen_web`, vendor adapters) but currently keeps real cloud infra (Fly, AWS KMS, S3) as operator-TODO/simulated; Codebattle is a live example of an Elixir/Phoenix app with real K8s+Terraform deploy manifests checked in, which could be skimmed for concrete manifest/pipeline shape when samen's WS-L infra drills (Fly production deploys) get unblocked.
  **Effort**: S — reference only, skim manifests for structure, not reusable code.

## What to ignore and why

- The entire product surface (game matchmaking, ratings, tournaments, chat) — irrelevant to a B2B SaaS foundry.
- Any React/frontend patterns — samen_web uses Phoenix LiveView, not a separate React SPA; different UI paradigm entirely.
- No Ash usage, no PII/vault/masking concepts, no multi-tenancy — nothing here informs samen's core moat (chokepoint architecture, crypto-shred, two-plane masking, catalog-as-data). Do not mine this repo for Ash ecosystem patterns.
- AGPL-3.0 licensing makes any direct code reuse legally incompatible with samen's MIT posture in any case — treat as read-only inspiration, never a dependency or code source.
