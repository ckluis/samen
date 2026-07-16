# Samen

**An Elixir · Ash · Phoenix SaaS foundry.** Samen is a kernel (`samen_core`), a web
framework layer (`samen_web`), three maintained vertical apps, and a set of generators
that emit *new* vertical apps — web UI, JSON:API, seeds, observability, tests and a full
verifier gate included — **correct-by-construction**: a freshly generated app passes its
own gate on the first run, with zero hand-edits.

The repo's ethos is **claim-evidence parity**: every claim below is backed by a test,
a verifier or a probe that runs in CI, and every command in this README is verified
against the CI probes' executed set by `samen_core/test/doc_commands_test.exs` — an
aspirational command here fails the build.

## The honest claim set

| Claim | What it means | Where it's proven |
|---|---|---|
| **PII is vaulted + masked by default** | Every 🔒 field writes a `vt_*` token through one vault chokepoint; plaintext is nowhere at rest; every plane renders `••••` unless a scoped, audited reveal grant exists — including operator support/impersonation sessions. | `samen_core/test/{vault,masked_render,reveal_grants,impersonation_masking}_test.exs`; the `no_plaintext_pii`/`pii_reads` verifier tiers in every app's `ci.sh` |
| **Crypto-shred erasure** | Deleting a subject's key material makes their vaulted PII unrecoverable — erasure is key destruction, not row scrubbing. | `samen_core/test/{erasure,shred_key_material,post_shred_oracle}_test.exs`; driftwood's crypto-shred game-day step in its `ci.sh` |
| **Two planes** | Every app runs a tenant plane and an ADR-010 operator plane (accounts, support, billing ops) — mounted from the framework, masked by default on both. | `samen_web`'s two-plane render/masking suite (`samen_web/ci.sh`); the `/operator/*` routes HTTP-probed on every generated app |
| **The proof is generative** | `mix samen.gen.app` emits a running product that passes its full 18-step verifier gate, seeds vault-aware, boots, and serves every mounted route — and two sabotages (API allowlist, observability `db_statement`) each flip the gate and revert byte-exact. | `samen_core/priv/gen_app_flagship_probe.exs` + `priv/gen_post_probe.exs`, permanent steps of the root `ci.sh` (~100s each, need local Postgres) |

## The 5-minute start

Prerequisites: Elixir 1.20 / OTP 29, local PostgreSQL trusting `$USER` on localhost.

```bash
cd samen_core
mix samen.gen.app --module Harbor --prefix hb --abbrev hrb
cd ../harbor
MIX_ENV=test bash ci.sh
```

That is a new vertical app — Billing scope mounted as-is, one authored resource with a
vaulted PII field, a token-blind aggregate, notifications, feature flags, an operator
workspace, a deny-by-default `/api/v1` JSON:API — passing its own 18-step verifier gate
on first run. Boot it:

```bash
MIX_ENV=dev mix ecto.create && MIX_ENV=dev mix ecto.migrate
MIX_ENV=dev mix harbor.seed
mix phx.server
```

Then open `http://localhost:4050` (the landing page links every mounted surface;
`/healthz` is the liveness probe). The full zero-to-first-feature walkthrough — including
adding a second scope + resource with `mix samen.gen.scope` / `mix samen.gen.resource`
and bending the API contract to watch the gate flip — is
[docs/guides/getting-started.md](docs/guides/getting-started.md).

To run the whole foundry gate (spikes + kernel + both generative probes + framework +
all three verticals):

```bash
bash ci.sh
```

## Repo map

| Path | What it is |
|---|---|
| `samen_core/` | The kernel: `Samen.Resource` (self-qualifying storage + the abbrev registry), the PII vault + crypto-shred, the machine catalog, policies/RBAC, Oban jobs, observability, the `samen.verify.*` verifier tiers, and the generators (`mix samen.gen.app` / `gen.scope` / `gen.resource`, `mix samen.abbrev.reserve`) |
| `samen_web/` | The framework web layer: `Samen.Web.Router` mount macros (tenant + operator planes), the UI kit, masked rendering, notifications inbox, the JSON:API plumbing (`KeyAuthPlug` idiom, `PageLimitClamp`) |
| `demo/` | The dogfood host (CRM et al.) — the canonical Identity policy-matrix / red-path test references |
| `driftwood/` | Reference vertical #1: freight — full 19-step gate incl. the crypto-shred game-day |
| `pawchart/` | Reference vertical #2: veterinary — the thin-mount shape the generator emits |
| `spikes/` | The mechanism spikes (s00–s07) that de-risked the kernel; still run by root `ci.sh` |
| `docs/` | ADRs (`docs/adr/`), guides (`docs/guides/`), and the per-workstream adversarial gate reports (`docs/gate-*.md`) |
| `ci.sh` | The root gate: everything above, in sequence, fail-fast |

## Docs

- [Getting started — zero to first feature](docs/guides/getting-started.md)
- [Generators](docs/guides/generators.md) — `mix samen.gen.app` flags, output, red paths
- [Scope authoring](docs/guides/scope-authoring.md) — the fan-out pattern for new scopes
- [Observability](docs/observability-guide.md) — metrics, wide events, tracing (and the
  `db_statement: :disabled` trap the generator now makes un-forgettable)
- [LLM grounding](docs/guides/llm-grounding.md) — the machine-readable schema dict + verifier surface
- [Claim-evidence parity](docs/claim-evidence.md) — how claims map to proofs
- [ADRs](docs/adr/) — every load-bearing decision, including
  [ADR-022 (generator emits a running product)](docs/adr/022-generator-emits-running-product.md),
  [ADR-023 (abbrev allocator)](docs/adr/023-abbrev-reserve-allocator-host-namespace.md) and
  [ADR-024 (deploy artifacts are fail-honest)](docs/adr/024-generated-deploy-fail-honest.md)

## What stays human (operator-TODO)

Honesty over polish: real Neon/AWS/ClickHouse drills, real Fly/Neon deploys, real KMS
keys and a real OTLP exporter are **operator work**, tracked as carries in the gate
reports — not claimed here. Generated deploy artifacts, when they ship, are fail-honest
by design (ADR-024): fail-closed `runtime.exs`, explicit operator-TODO runbooks, never
"just run `fly deploy`".
