---
project: Charsh
url: https://gitlab.com/owni.dev/charsh
category: Media and Personal
relevance: none
verdict: Small hobby Phoenix/LiveView app for fictional-character reference sheets; single-purpose CRUD tool with no multi-tenancy, PII, or governance concerns — nothing samen needs.
---

# What the project is

Charsh is a small, personal-scale Elixir/Phoenix web app ("detailed reference-sheet manager for fictional characters", Apache-2.0) — creators build in-depth reference sheets for their original characters (visual traits, notes, links) so designs stay consistent across artwork. It is a `mix phoenix.new`-shaped app: Phoenix ~1.7.10 + Phoenix LiveView, Ecto + PostgreSQL, bcrypt-based password auth, `plug_attack` for basic rate limiting, Waffle + `ex_aws`/S3 for image/file storage, Swoosh for email, Sentry for error tracking, esbuild/Tailwind for assets. ~606 commits, 18 tags — actively maintained as a side project, not a framework or platform. Deployment is Nix-flake-built Docker images (`nix build .#docker`, `mix2nix` for a `deps.nix` lockfile) run via plain `docker run`. The README also documents a one-time migration off MongoDB (users/characters/links collections exported via `mongoexport` and replayed through a migration script), implying the app started on Mongo and moved to Postgres/Ecto. No Ash framework, no multi-tenancy, no admin/operator plane, no audit trail, no billing, no AI features visible from the README/mix.exs.

# What samen could adopt

Nothing rises to a concrete adoption item. Everything in Charsh's stack is either already present in samen in a strictly more capable form, or is a generic Phoenix pattern samen doesn't need reminding of:
- File uploads (Waffle + S3) — samen's `samen_web` already has a LiveView upload chokepoint with quarantine-by-default, which is a stronger pattern than Waffle's direct-to-storage flow.
- Auth (bcrypt + plug_attack) — samen's identity spine (assent OIDC, nimble_totp 2FA, ash_rate_limiter/Hammer) is materially more advanced.
- Nix-flake + Docker deploy (`nix build .#docker`, `mix2nix`) is a mildly interesting reproducible-build technique for a solo-maintainer app, but samen's roadmap deploy target is Fly.io with credential-gated infra drills already planned (WS-L); introducing a second, unrelated deploy toolchain (Nix) would add build-system surface without solving any open samen gap. Not worth the effort even at S.

# What to ignore and why

- **The entire product domain** (fictional-character reference sheets, art/creative-writing tooling): unrelated to a multi-tenant SaaS foundry; no transferable UX or domain modeling.
- **Single-tenant, single-user data model**: no org/tenant scoping, no operator plane, no RBAC — the opposite of samen's two-plane, org-scoped architecture; nothing to compare against.
- **No PII handling, no vaulting, no audit, no erasure**: the app stores user accounts and character data in the clear with no visible masking or compliance story — strictly behind samen's baseline, not a source of ideas.
- **MongoDB-to-Postgres migration notes**: a one-off personal-project data migration, not a reusable pattern.
- **Basic bcrypt/plug_attack auth and Waffle/S3 uploads**: functionally simpler versions of things samen already ships at a higher bar (chokepoint uploads, OIDC+TOTP identity spine, ash_rate_limiter).
