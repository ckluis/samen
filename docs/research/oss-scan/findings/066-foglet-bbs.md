---
project: Foglet BBS
url: https://github.com/bmanturner/foglet-bbs
category: Communication and Social
relevance: low
verdict: Well-built hobbyist Elixir/Phoenix SSH BBS in an unrelated domain; only a couple of small operator-tooling ideas transfer to samen.
---

# 066 — Foglet BBS

## What the project is

Foglet is an SSH-first bulletin board system: forums (boards, threaded posts with edit/soft-delete), board-scoped chat rooms (ephemeral or persistent), user-to-user BBS mail, RSS/Atom feed ingestion, oneliners, and door games (native Elixir, external PTY, and classic dropfile manifests). It is built on Elixir/OTP 28 + Phoenix + PostgreSQL, with the primary interface being a terminal UI (a vendored copy of the Raxol TUI library under `vendor/raxol/`); the web surface is deliberately minimal ("a lobby, docs shelf, and operational shell — not a browser forum"). Auth supports passwords and SSH public-key login, with in-TUI SSH key management. It ships Docker Compose + fly.toml, GitHub Actions CI, `mix precommit` lint gates, and a family of operator mix tasks (user creation, invites, verification codes, reset tokens, board subscriptions, a `foglet.doctor` diagnostic, TUI QA mode). Actively maintained (2,646 commits) but small (7 stars), self-labeled "public beta". Apache-2.0.

## What samen could adopt

- **`foglet.doctor`-style single diagnostic mix task.** What: one `mix samen.doctor` that checks env/config/DB/KMS-sim/Oban wiring and prints a pass/fail triage for a host app. Why it fits: samen has ~20 `samen.verify.*` tiers aimed at CI correctness proofs, but no single operator-facing "is my host environment sane" triage command — useful for the `mix samen.gen.app` first-run experience and for G22 (packaging for external builders). Effort: S.
- **SSH public-key credential as an identity-spine extension seam.** What: pubkey-on-file login plus self-serve key add/remove, as Foglet does in-TUI. Why it fits (marginally): samen's identity spine already covers password/OIDC/TOTP; SSH keys are only relevant if samen ever grows a CLI/SSH operator channel. Note as a seam, do not build. Effort: M (and not currently justified).
- **Per-source IP access rules on an ingress.** What: Foglet's sysop-managed SSH IP allow/deny rules. Why it fits: samen's rate limiting (Hammer) covers auth+webhook ingress but has no operator-editable IP policy; could be a small operator-plane hardening feature under WS-L/ops. Effort: S–M.

## What to ignore and why

- **The entire BBS domain** (boards, chat rooms, door games, dropfiles, oneliners, RSS surfaces): samen already has richer scope blueprints (mailbox, cms, support, chat) with masking/tenancy guarantees Foglet has no concept of; nothing here advances multi-tenant SaaS.
- **Raxol terminal UI / SSH-first UX**: samen is LiveView-first with a two-plane web architecture; a TUI channel contradicts its mount/plane model and would bypass the masked-rendering chokepoints.
- **Auth/moderation flows**: single-tenant, no org model, no PII vaulting, no audit chain — strictly weaker than samen's generator-emitted identity spine.
- **Ops posture**: Docker Compose + fly.toml + LiveDashboard is standard Phoenix practice samen already exceeds (readyz, metrics egress, gate reports).
