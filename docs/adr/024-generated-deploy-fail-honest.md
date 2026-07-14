# ADR-024 — Generated deploy artifacts are fail-honest, not aspirational

**Status:** Accepted (WS-D design, 2026-07-14)
**Context workstream:** WS-D "Builder Joy" (G16)

## 1. Context

"Samen makes building AND running a SaaS a joy," but the *running* half has **zero** generated
on-ramp: grep for `fly.toml`/`Dockerfile`/`release.exs` returns nothing; the gate reports carry
"real Neon/AWS/ClickHouse drills + Fly/Neon deploy" as standing **operator TODOs**. `config/dev.exs`
is bare localhost/`$USER`/empty-password Postgres; the observability guide's exporter is a documented
"Operator TODO: replace `:none` with a real OTLP exporter." Every vertical author writes their own
Dockerfile/release/Neon wiring by hand.

The repo's ethos is **claim-evidence parity**: no aspirational docs, every claim backed by a passing
test or a run. A deploy generator that emits `fly.toml` + a runbook saying "just run `fly deploy`"
would violate that ethos — it implies a working deploy the generated artifacts cannot honestly claim
(there is no Fly account, no Neon project, no KMS keys in a fresh generation).

## 2. Decision

**`mix samen.gen.deploy` (or `--deploy` on gen.app) emits structurally-correct, fail-honest deploy
artifacts + an explicit operator-TODO runbook — never a claim of a live deploy.** Specifically:

- Emit `fly.toml` (app name, region, `[http_service]` on the endpoint port, health check on
  `/healthz`, release command running migrations), `Dockerfile`, release config (`mix release`
  shape), and a **new `config/runtime.exs` template**.
- `config/runtime.exs` is **fail-closed**: it reads `DATABASE_URL`, `SECRET_KEY_BASE`, `PHX_HOST`,
  and the **KMS env** (`SAMEN_KMS_*` the vault needs in prod), and **raises a clear, named error if a
  required secret is absent** rather than booting insecurely (AC-G16-2).
- Emit a per-app `docs/runbooks/deploy.md` with Neon per-product DB provisioning notes
  (branch-per-env), a secrets checklist (incl. KMS + `SECRET_KEY_BASE` generation), and an
  **explicit operator-TODO block** naming what stays human: real Fly account, real Neon project, real
  KMS keys, real OTLP exporter (AC-G16-3).
- The deploy artifacts must **not break the gate**: the app with `--deploy` still compiles and passes
  `ci.sh` (AC-G16-1), proven by the CI probe running once with `--deploy`.

## 3. Consequences

**Positive.** Builders get a real deploy on-ramp (the "running is half the thesis" gap), and the KMS
env — the single most-forgotten prod requirement for a vaulted app — is made explicit and fail-closed
at boot. The runbook is honest about the human prerequisites, matching the standing operator-TODO
carries rather than pretending they're solved.

**Negative / accepted.** A fresh generated app cannot be `fly deploy`-ed without the operator's real
accounts/credentials — the artifacts are a scaffold, not a turnkey deploy. This is a deliberate
honesty cost: we would rather emit a fail-closed runtime that raises on a missing secret than a
runtime that boots insecurely. The deploy templates are harder to fully test end-to-end (no live
target), so their proof is limited to "compiles, passes gate, runtime raises on missing secret,
runbook names the TODOs" — not a live deploy assertion.

**Neutral.** No live infrastructure is provisioned; all real accounts/credentials remain operator
work, consistent with the existing gate-report carries.

## 4. Alternatives considered

- **Emit a `fly deploy`-ready template that assumes accounts exist.** Rejected — violates
  claim-evidence parity; a fresh generation has no Fly/Neon/KMS, so the claim would be false.
- **Skip deploy entirely; keep it a pure operator-TODO.** Rejected — the "running a SaaS is a joy"
  half of the mission has *no* on-ramp today; a fail-honest scaffold + runbook is a real joy multiplier
  even without turnkey deploy, and it un-forgets the KMS env.
- **Boot with insecure defaults if secrets are missing (like `config/dev.exs`).** Rejected for
  prod runtime — a vaulted SaaS must fail closed on a missing KMS key or secret_key_base, not boot
  with an empty-password/localhost fallback.
