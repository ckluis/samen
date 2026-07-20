# Bad-release rollback

Scope: reverting a bad **release** (code/config) via Fly, not recovering data. If the problem
is a bad migration that already mutated data, or any other data-loss/corruption scenario, this
runbook hands off to [pitr-gameday.md](pitr-gameday.md) — do not attempt a data fix here.

---

## 1. Decide: bad release or data problem?

| Symptom | Likely cause | Action | Runbook |
|---|---|---|---|
| `/readyz` starts failing right after a deploy, `/healthz` still 200 | Bad code/config in the new release (dependency, misconfigured secret, boot-time crash) | Code rollback | this file, §2 |
| Error-rate spike (5xx) correlated with deploy timestamp, no destructive migration in the release | Bad code path (logic bug, unhandled case) | Code rollback | this file, §2 |
| Canary/smoke check fails post-deploy before traffic cutover | Bad release caught pre-traffic | Redeploy prior image; do not investigate live | this file, §2 |
| Release included an irreversible/destructive migration (dropped column, hard delete, backfill that overwrote data) and it already ran | Data problem — code rollback cannot undo it | Escalate to PITR | [pitr-gameday.md](pitr-gameday.md) |
| Discarded jobs or audit-chain tamper events start right after deploy | Could be either — check whether a migration ran | Triage via [alerts.md](alerts.md) §2/§3 first, then decide | this file / pitr-gameday.md |
| Data looks wrong but no recent deploy | Not a release problem | Do not use this runbook | [pitr-gameday.md](pitr-gameday.md) |

The deciding question: **did the bad release's `release_command` run a migration that
destructively changed data, and has that migration already executed?** If yes, a code rollback
alone is not safe — go to §3.

## 2. Fly rollback

1. List releases to find the last known-good version: `fly releases`.
2. Confirm which image/version was healthy (cross-check against the last clean `/readyz` and alert history).
3. Roll back:
   - `fly releases rollback` (if available for the app's Fly config), or
   - explicitly redeploy the prior image: `fly deploy --image <prior-image-ref>`.
4. Watch the rollout — Fly's health checks gate traffic on `/readyz`, so a still-bad prior image won't silently take traffic, but confirm manually anyway (§4).
5. If the rollback itself fails health checks, the "last known good" assumption was wrong — go back one more release and repeat, or escalate to data recovery if a migration is now implicated.

## 3. The migration hazard

Samen deploys run migrations in the `release_command`, **before traffic** (`fly.toml`). This
means:

- Rolling back the **code** does NOT roll back a migration that already ran. The prior code
  image will boot against a database schema shaped by the migration from the bad release.
- **Rule:** ship migrations **expand-contract** (additive/backward-compatible first, destructive
  cleanup only after the expand has been running safely for a full release cycle) so that a
  code rollback is always safe against the current schema — the prior code simply ignores the
  new column/table it doesn't know about yet.
- If the bad release's migration was destructive or irreversible (dropped a column still read
  by the prior code, hard-deleted rows, ran a lossy backfill) and it already executed, a pure
  code rollback is **not safe** — the prior code may crash on the missing shape, or worse,
  silently misbehave. **Escalate to [pitr-gameday.md](pitr-gameday.md)** for point-in-time
  restore. Read that runbook's RPO framing first: restore cost is bounded by detection
  latency, not the WAL interval — the faster this is caught, the less it costs.

If in doubt about whether a migration in the bad release was destructive, treat it as
destructive and go to pitr-gameday.md rather than guessing with a code rollback.

## 4. Post-rollback verification

1. `/readyz` returns 200 (`Samen.Web.Readiness.check/1` — repo, KMS attest, Oban all healthy).
2. `/healthz` returns 200.
3. Walk the key flows for the vertical (login, the primary governed action, a reveal if
   applicable) — don't rely on health checks alone to declare the rollback clean.
4. Confirm the audit chain verify sweep is still green: no new `[:samen,:audit_chain,:tamper]`
   events, and a recent successful `[:samen,:audit_chain,:verify]` (see
   [alerts.md](alerts.md) §3 for the seal-lag thresholds).
5. Check the alert catalog broadly for anything still elevated (Oban backlog, discarded jobs,
   KMS errors) — a bad release can leave secondary damage (e.g. a backlog of jobs queued
   against the bad code) that outlives the rollback itself.

## 5. Pre-deploy checklist (make rollback cheap before you need it)

- [ ] Migrations are expand-contract: additive/backward-compatible now, destructive cleanup
      deferred to a later release once the expand has proven safe.
- [ ] Risky new behavior sits behind a feature flag (Samen ships a flag engine) rather than
      being unconditionally live on deploy — a flag flip is cheaper than a rollback.
- [ ] The prior release's image is still available/warm (don't let Fly's image retention lapse
      right before a risky deploy) so `fly deploy --image <prior>` is fast.
- [ ] A canary/smoke pass runs before full traffic cutover (Fly health checks gate on
      `/readyz`, so wire any additional smoke check ahead of that gate too) so a bad release is
      caught pre-traffic per the §1 table.
- [ ] Know in advance which recent releases included a migration and whether it was
      expand-only or destructive — write it in the release notes so a 2am rollback decision
      doesn't require digging through migration files first.

See also: the generated per-app [`deploy.md`](deploy.md) for this app's specific deploy
mechanics, and [observability-guide.md](../observability-guide.md) for the tracing/metrics
used to detect a bad release in the first place.
