# Samen

**An Elixir · Ash · Phoenix SaaS foundry.** Samen is a substrate for one builder — or a
small studio — to launch *many* SaaS products fast without re-solving the hard parts each
time: PII vaulting and masking, a two-plane architecture (a tenant product plane plus an
operator control plane with masked impersonation), a machine-readable catalog for grounding
LLMs and tooling, and generators that emit a *running* product.

It is a kernel (`samen_core`), a web framework layer (`samen_web`), a set of generators, and
several vertical apps that exist to prove the substrate rather than to be shipped.

> **Authorship.** Samen is an AI-authored codebase: every commit was written by Claude
> (Anthropic's AI) under human direction and is marked `Co-Authored-By: Claude`. It is
> reviewed and adversarially gated by a human operator, but the code is Claude's.

## The honest hero claim

> **PII is masked by default. Reveal is grant-gated, second-party-approved, logged in a
> hash-chained log the tenant can read, and time-boxed. Cross-tenant views are
> aggregate-only and token-blind.**

Unpacked:

- **Masked by default, on both planes.** Every 🔒 field writes a `vt_*` token through one
  vault chokepoint; plaintext is nowhere at rest. Every surface renders `••••` unless a
  scoped reveal grant is present — *including* operator support and impersonation sessions.
- **Reveal is second-party.** An operator can request a reveal, but a *distinct* party must
  approve it — enforced both in policy and by a DB `CHECK (granted_by <> requestor_id)`.
  Self-approval is refused. Grants carry `expires_at` and cannot be renewed in place; an
  Oban auto-revoke job is enqueued in the same transaction as the approval.
- **Every reveal is logged where the tenant can see it.** The audit record lands in a
  hash-chained, append-only, tenant-readable log the operator cannot edit (a DB trigger
  refuses `UPDATE`/`DELETE` on the chain).
- **Cross-tenant views never touch PII.** Aggregates (MRR, queues, cohorts) run on a
  separate token-blind actor over resources that have no `pii_*` columns at all. The reveal
  path structurally refuses that actor before any grant or vault check — the two paths are
  mutually exclusive by construction.

This is deliberately *not* the stronger-sounding "run support without ever seeing PII" — that
claim was retired as false-by-construction. Support **can** see PII, but only through a
grant that a second party approved and the tenant can audit.

## The claim set (each backed by a test, verifier, or probe in CI)

| Claim | Where it is proven |
|---|---|
| **PII vaulted + masked by default** on every plane | `samen_core/test/{vault,masked_render,reveal_grants,impersonation_masking}_test.exs`; the `no_plaintext_pii` / `pii_reads` verifier tiers in every app's `ci.sh` |
| **Crypto-shred erasure** — deleting a subject's key material makes their vaulted PII unrecoverable across every tier (erasure = key destruction, not row scrubbing) | `samen_core/test/{erasure,shred_key_material,post_shred_oracle}_test.exs`; driftwood's crypto-shred game-day + the destruction oracle in its `ci.sh` |
| **Two planes** — every app runs a tenant plane and an operator plane, both masked by default, mounted from the framework | `samen_web`'s two-plane render/masking suite; the `/operator/*` routes HTTP-probed on every generated app |
| **The proof is generative** — `mix samen.gen.app` emits a running product that passes its full 18-step verifier gate, seeds vault-aware, boots, and serves every mounted route, with zero hand-edits | `samen_core/priv/gen_app_flagship_probe.exs` + `priv/gen_post_probe.exs`, permanent steps of the root `ci.sh` (need local Postgres) |
| **Self-serve identity spine** — registration (Org+User+Membership atomic, credential PII vaulted), email verification, password reset, sessions (remember-me / listing / revocation / deterministic org-cap eviction), team invites, OIDC that **honors TOTP step-up**, TOTP 2FA + vaulted recovery codes, an onboarding wizard, and login-family auth events → notifications/audit — **emitted by the generator with zero hand-edits** | `samen_web/test/samen/web/auth/*_test.exs` (`confirm`/`session`/`invitation`/`oidc`/`oidc_totp_stepup`/`totp`/`onboarding`/`auth_events`/`login_events`); `samen_core/test/auth/*`; the flagship probe's HTTP-probed `/signup /login /onboarding /settings/security/2fa` |
| **Rich declared types** — Money, Percent, Score, Duration, Priority, URL, Email, Phone, Address (+ `pii_address`/`pii_dob` vault classes); the vault write path re-runs each type's `cast_input` so vaulted values are validated + normalized on input | `samen_core/test/type/*_test.exs`; `samen_core/test/vault/vault_cast_validation_test.exs` |
| **Stripe billing as a fail-honest, vendor-free adapter** — hosted checkout, subscription lifecycle sync (fetch-on-event, idempotent, out-of-order-safe), invoice + tax mirroring, hosted-only payment methods (no PAN column can even compile), dunning, metered usage, a signature-fail-closed webhook ingress with DLQ, and a billing settings page with an honest `:not_configured` empty state. The `samen_core` kernel names **zero** Stripe strings; the adapter lives in a sibling `samen_stripe/` package | `samen_core/test/billing_*_test.exs`; `samen_stripe/test/*` (standalone); `scripts/sabotages/{25-b9,29-b3}-*.patch`; **kernel stays vendor-free** — with the four adapter packages deleted, `samen_core` + `samen_web` still pass |
| **ESP email delivery behind one behaviour, three vendors** — a shared, non-vacuous conformance harness satisfied by **Postmark, SES, and Resend** (Basic-Auth / SNS-RSA / Svix-HMAC); a single send chokepoint; PII-safe rendering that resolves through the vault plane with a fail-closed, non-skippable no-leak gate; deliverability (bounce/complaint → suppression) and masked notification digests | `samen_core/lib/samen/delivery/provider_conformance_case.ex`; `samen_core/test/delivery_*` + `test/delivery/*`; `samen_{postmark,ses,resend}/test/conformance_test.exs`; `scripts/sabotages/30-c3-*.patch` |
| **Auth-surface rate-limiting + bounded `login_failed`** — sign-in / 2FA / registration / reset limited via one shared seam; keys are HMAC-bidx / credential / IP, **never plaintext email**; the brute-force audit signal is a bounded edge row, not O(N) | `samen_web/test/samen/web/auth/rate_limit_test.exs` |

Full mapping: [docs/claim-evidence.md](docs/claim-evidence.md) (Phase-1 identity spine + rich
types are section J; Phase-2 billing + ESP + rate-limiting are **section K**). **Honest scope:**
the identity spine, its auth-surface rate-limiting, and the Stripe/ESP adapters are complete and
verified — **but everything runs on the keyless lane.** Billing/ESP dispatch is proven against
hermetic fakes + injected-transport cassettes; **no host wires a live provider** (every generated
app boots with billing/ESP unconfigured and honestly says so), production persistence is
fake-backed with the Ash-backed mirrors' host-wiring **deferred to T108**, and the live lanes
(`STRIPE_TEST_KEY`, `SAMEN_POSTMARK_SMOKE`, `SAMEN_ESP_LIVE`) are documented-but-not-CI. AI is a
later phase.

## Architecture

Two apps are the substrate; three are proof; one command spins up new ones.

- **`samen_core` — the kernel (web-dependency-free).** The PII vault and crypto-shred
  erasure, field masking and per-plane PII resolution, policies/RBAC and org-scoping, the
  machine-readable catalog (schema dictionary for LLM/tooling grounding), the hash-chained
  audit log, the `samen.verify.*` verifier tiers, and the generators
  (`mix samen.gen.app` / `gen.scope` / `gen.resource`).
- **`samen_web` — the UI kit and product surfaces.** Router mount macros for the tenant and
  operator planes, masked rendering, the **self-serve identity spine** (signup / login /
  email verification / password reset / sessions / team invites / OIDC with TOTP step-up /
  TOTP 2FA enrollment / onboarding wizard), and the mountable product surfaces: CRM, Billing,
  Support desk, Marketing, Files, CSV import/export, Search (⌘K command palette), Settings,
  notifications inbox, and cross-plane chat. Verticals inherit these by mounting them; they
  do not re-implement them.
- **Verticals as proof, not product.**
  - `driftwood` — a freight vertical; the deepest reference, with the crypto-shred game-day.
  - `pawchart` — a veterinary vertical; the thin-mount shape the generator emits (~191
    authored lines mounting framework surfaces on top of the shared substrate).
  - `demo` — the API-only dogfood host; the canonical Identity policy-matrix and red-path
    reference.
- **`mix samen.gen.app`** — emits a new vertical (web UI, JSON:API, seeds, observability,
  tests, and a full verifier gate) that passes its own gate on the first run. Framework
  capability lands in `samen_core` / `samen_web`; a vertical adopts it with a router/macro
  call at roughly zero authored LOC.

The full design story lives in [index.html](index.html) (open it in
a browser) and in the 33 ADRs under [docs/adr/](docs/adr/) (indexed in
[docs/adr/README.md](docs/adr/README.md)).

## The verification story

This is the point of the repo, not a footnote: **every guarantee ships with a green proof, a
red-path proof, and a sabotage that proves the test can actually fail.** A test that cannot
fail is treated as a bug.

- **Committed sabotage harness.** `scripts/sabotage.sh` replays **28 committed sabotage
  patches** (`scripts/sabotages/*.patch`). For each: SHA-256 the touched files → apply the
  patch → the *named* tests **must** fail (not "something broke") → revert → verify a
  byte-exact restore. Run it with:

  ```
  SAMEN_SABOTAGE=1 ./ci.sh
  ```

  It is opt-in because it deliberately breaks the tree 28 times and re-runs DB-backed
  suites; the default CI path stays green-only. Later gates add a new `.patch` rather than
  re-deriving sabotages by hand.
- **Destruction oracle for crypto-shred.** `mix samen.verify.no_plaintext_pii` runs as a
  separate OS process across every tier (domain rows, vault, audit events, rollups, Oban
  args, the KMS store) and attests that a shredded subject is unrecoverable — the erasure
  game-day regenerates and re-verifies this on every driftwood `ci.sh` run.
- **Generative proof in the root gate.** `./ci.sh` doesn't just test the substrate — it
  *generates* a fresh app, runs the app's entire gate, seeds it, boots it, HTTP-probes its
  routes, and drives sabotages against the generated gate to prove it is non-vacuous.
- **AC-mapped gate reports.** Every workstream's adversarial gate is written up in `docs/`
  (`gate-ws-*.md`, `gate-*.md`): each acceptance criterion mapped to a named covering test,
  suite counts reproduced, sabotages re-flipped. The newest is the full F1–F7 burn-down gate
  [docs/gate-burndown.md](docs/gate-burndown.md) (see also [docs/gate-ws-e.md](docs/gate-ws-e.md)).

Suite totals (reproduced in the F1–F7 burn-down gate with `SAMEN_SABOTAGE=1 ./ci.sh`, all
`--warnings-as-errors` clean):

| Suite | Passing |
|---|---|
| `samen_core` | 1285 |
| `samen_web` | 647 |
| `demo` | 465 |
| `driftwood` | 123 |
| `pawchart` | 49 |
| sabotage harness | 28/28 sabotages flipped their named tests; byte-exact restores |

## Getting started

Prerequisites: Elixir 1.20 / OTP 29, and a local PostgreSQL that trusts `$USER` on
localhost. All commands start from the repo root.

Generate a new vertical app and run its gate:

```bash
cd samen_core
mix samen.gen.app --module Harbor --prefix hb --abbrev hrb
cd ../harbor
MIX_ENV=test bash ci.sh
```

That is a running product — a Billing scope mounted as-is, one authored resource with a
vaulted PII field, a token-blind aggregate, notifications, feature flags, an operator
workspace, and a deny-by-default `/api/v1` JSON:API — passing its own 18-step verifier gate
on the first run, with zero hand-edits. Boot it:

```bash
MIX_ENV=dev mix ecto.create && MIX_ENV=dev mix ecto.migrate
MIX_ENV=dev mix harbor.seed
mix phx.server
```

Then open `http://localhost:4050` (the landing page links every mounted surface; `/healthz`
is the liveness probe).

To run the whole foundry gate (spikes + kernel + both generative probes + framework + all
three verticals — takes minutes, must end `ROOT CI: ALL PASSED`):

```bash
bash ci.sh
```

The full zero-to-first-feature walkthrough — adding a second scope and resource with
`mix samen.gen.scope` / `mix samen.gen.resource`, then bending the API contract to watch the
gate flip — is [docs/guides/getting-started.md](docs/guides/getting-started.md). Every fenced
command in this README and that tutorial is verified against the CI probes' executed set by
`samen_core/test/doc_commands_test.exs`: an aspirational command fails the build.

## Repo map

| Path | What it is |
|---|---|
| `samen_core/` | The kernel: vault + crypto-shred, masking, policies/RBAC, catalog, audit, `samen.verify.*` verifier tiers, and the generators |
| `samen_web/` | The framework web layer: tenant + operator plane mount macros, the UI kit, masked rendering, and the mountable product surfaces (CRM/Billing/Support/Marketing/Files/CSV/Search/Settings/chat) |
| `demo/` | The API-only dogfood host — canonical Identity policy-matrix / red-path references |
| `driftwood/` | Reference vertical: freight — the deepest gate, including the crypto-shred game-day |
| `pawchart/` | Reference vertical: veterinary — the thin-mount shape the generator emits |
| `spikes/` | The mechanism spikes (s00–s07) that de-risked the kernel; still run by root `ci.sh` |
| `docs/` | ADRs (`docs/adr/`), guides (`docs/guides/`), the gate reports (`docs/gate-*.md`), the roadmap (`docs/saas-gap-roadmap.md`), and an archived long-form design variant (`docs/archive/samen-foundry.html`) |
| `scripts/` | `sabotage.sh` + the 28 committed sabotage patches |
| `ci.sh` | The root gate: everything above, in sequence, fail-fast |

## Docs

- [Docs index](docs/README.md) — the front door to everything under `docs/`, grouped
- [Getting started — zero to first feature](docs/guides/getting-started.md)
- [Cookbook](docs/guides/cookbook.md) — task recipes
- [Gate-failure index](docs/guides/gate-failures.md) — what each gate step means when it goes red
- [Generators](docs/guides/generators.md) · [Scope authoring](docs/guides/scope-authoring.md)
- [LLM grounding](docs/guides/llm-grounding.md) — the machine-readable schema dictionary
- [Claim-evidence parity](docs/claim-evidence.md) — every claim mapped to its proof
- [ADRs](docs/adr/) — every load-bearing decision
- [The full design story](index.html) — open in a browser

## Status & caveats

Read this before assuming anything about production-readiness.

- **This is an internal foundry, built by one builder working with AI agents.** It is not a
  hosted product, not a package on Hex, and carries **no stability or support promises**. It
  is published so the architecture and the verification discipline are legible.
- **Some infrastructure is locally simulated.** Real Neon PITR drills, real AWS KMS /
  DynamoDB / S3 Object-Lock, ClickHouse ClickPipes, live Stripe keys, and Fly deploys are
  **operator TODOs**, tracked honestly as carries in the gate reports — not claimed as done.
  The local sims (a file-backed KMS, a local PITR harness) exercise the same load-bearing
  invariants, and the numbers they produce (RTO/RPO targets, detection latency) are labeled
  as sims/proxies where they appear.
- **Fail-honest by design.** An unconfigured or unimplemented adapter never returns success
  for work it did not do — it returns `{:error, :not_configured | :not_implemented}`.
  Generated deploy artifacts (ADR-024) are fail-closed: a missing secret raises and names
  itself; there is no turnkey "just run `fly deploy`".
- **The product surfaces vary in depth.** The security/governance kernel is as deep as the
  gates claim; some product surfaces are honestly-labeled first cuts. The
  [gap roadmap](docs/saas-gap-roadmap.md) ranks what is shipped versus what remains.

## License

See [LICENSE](LICENSE).
