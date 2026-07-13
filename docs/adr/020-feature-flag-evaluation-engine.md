# ADR-020 — Feature-flag evaluation engine: kernel placement, deterministic bucketing, non-PII keys, fail-safe kill switch

- **Status:** Accepted (design; WS-B phase B5/B6 implements).
- **Date:** 2026-07-13
- **Task:** WS-B / G6 — the `FeatureFlag` resource (abbrev `pff`) is config rows nothing evaluates; build the evaluation engine (`evaluate/2`) with targeting, deterministic % rollout, gradual ramp, kill switch, cached evaluation, and two-plane admin.
- **Deciders:** opus (WS-B design), grounded in `docs/gap-discovery/operator.md` G3 (LaunchDarkly benchmark) and the live `FeatureFlag` blueprint (config-only, no engine).

---

## 1 · Context

`FeatureFlag` (`pff`: name, enabled, rollout_pct, stage, metadata) stores flag config that NOTHING reads. There is no `evaluate/2`, no bucketing, no targeting, no variant assignment. The engine is a small pure function; the question is WHERE it lives and HOW it stays deterministic, non-PII, and fail-safe.

## 2 · Decision

**Four load-bearing decisions:**

1. **Placement: the engine is KERNEL (`samen_core`), the admin UI is `samen_web`.** `evaluate/2` is a pure deterministic function over governed config + a non-PII subject key, needed by every plane and by API/worker paths — not a web concern. It belongs in the kernel alongside the notifications record/dispatch core; the `pff` resource already lives in the kernel primitives scope. Verticals inherit evaluation at 0 LOC.

2. **Deterministic bucketing via `phash2`, org-stable and flag-independent.** `bucket = :erlang.phash2({flag_name, subject_key}, 10_000) / 100.0`; `on = bucket < rollout_pct`. Keying on `{flag, subject}` makes the same `(flag, org)` bucket identically forever (a rollout ramp only ADDS orgs — the monotonic-stability invariant, never a reshuffle) and makes different flags bucket independently (no correlated exposure). `phash2` (not `:rand`, not `:crypto` hashing per-call) is deterministic, fast, and dependency-free.

3. **Targeting keys are NON-PII by construction.** Target rules key ONLY off governed non-PII attributes (org_id, plan, tier, stage — never name/email). This is enforced at flag-WRITE time: a rule keyed on a PII-classified attribute is REFUSED via the shared `Samen.Pii.Classification` oracle (the same default-deny mechanism A1 shipped). The `subject_key` passed to `evaluate/2` is a bounded non-PII id by construction.

4. **The kill switch is fail-SAFE.** `enabled == false` short-circuits everything (`reason: :kill_switch`) — the incident lever. Evaluation is cached in ETS (invalidated on write via the id-only PubSub broadcast pattern); on any cache/lookup error `evaluate` returns `{off}` for a flag it cannot confirm ON — it NEVER fails open.

The experiment SEAM (variant assignment emits a `flag.assignment` `pae` event) ships; full A/B statistical analysis does NOT (design §7).

## 3 · Rationale

- **Kernel placement** matches the notifications-engine precedent and serves all callers; the UI split keeps the kernel web-dep-free.
- **`{flag, subject}` bucketing** gives the two properties that matter for a rollout lever: stable ramp (raising % only turns orgs on) and independent flags (uncorrelated exposure) — both directly red-pathed.
- **Write-time non-PII enforcement** means the targeting key can NEVER be a PII field, satisfying the "flag targeting keys must be non-PII by construction" non-negotiable at the earliest possible boundary (write, not read).
- **Fail-safe kill switch** matches the framework's fail-closed posture: a flag you can't confirm ON is OFF.

## 4 · Consequences

**Positive** — a real rollout/kill-switch/targeting engine every incident and release uses; deterministic and auditable; the experiment seam feeds G12 for later analysis; verticals inherit at 0 LOC.

**Negative / accepted** — cache invalidation is one broadcast hop of staleness (acceptable for a rollout lever; the kill switch is fail-safe so staleness can only leave a flag OFF-confirmed, never wrongly ON). Full A/B analysis is deferred.

**Neutral** — new `pff` fields (`target_rules`, `variants`, bounded jsonb, structurally validated) + an ETS cache GenServer.

## 5 · Red paths

- **RP-F1 (AC-G6-2) determinism + stability:** property test — deterministic output + monotonic org-stable ramp (raising rollout_pct only flips off→on); replacing `phash2` with `:rand` FAILS the stability property.
- **RP-F2 (AC-G6-3) distribution:** at rollout_pct=30 over 10k org keys the on-fraction is 30%±tol; biasing the hash FAILS.
- **RP-F3 (AC-G6-4) non-PII targeting key:** flag-write refuses a rule keyed on a PII-classified attribute; sabotaging the allowlist FAILS the refusal test.
- **RP-F4 (AC-G6-5) kill-switch fail-safe:** with the cache unavailable, `evaluate` returns `{off}`; defaulting-ON-on-error FAILS the fail-safe test.
