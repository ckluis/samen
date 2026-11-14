# Alerts — what pages a human

Alert catalog for a deployed Samen app. Every metric-based alert here requires **metrics
egress ON** (`SAMEN_METRICS_ENABLED=true`, off by default — see [observability
guide](../observability-guide.md) and `Samen.Observability.child_specs/2`). Without it, use
the event-based fallbacks noted per alert (Oban table queries, log-based tamper/exception
matches) until egress is enabled.

| Alert | Signal | Warn | Page | Runbook |
|---|---|---|---|---|
| Oban backlog | `samen.oban.job.queue_time` (event `[:samen,:oban,:job,:stop]`) + `oban_jobs` backlog count | p95 queue_time > 30s, OR backlog > 500 in a queue | p95 queue_time > 2m sustained 5m, OR `erasure`/`reveal` backlog > 50 | this file, §1 |
| Discarded jobs | `oban_jobs` state=`discarded`, or `[:samen,:oban,:job,:stop]` result=`:error` rate | >5/hr outside `erasure`/`reveal` | ANY discarded job in `erasure` or `reveal` | this file, §2 |
| Seal-lag | `[:samen,:audit_chain,:verify]` recency; `[:samen,:break_glass,:unanchored]` age | no verify success in 30m; unanchored entry > 20m | no verify success in 60m; ANY `[:samen,:audit_chain,:tamper]` | this file, §3; [breach-notification.md](breach-notification.md) |
| KMS error rate | wrap/unwrap failure rate on `Samen.Kms.AwsKmsDynamo`; `/readyz` `:kms` check | any failures, non-sustained | ANY sustained KMS failure > 1m | this file, §4 |
| `/readyz` failing | `GET /readyz` 503 (`Samen.Web.Readiness.check/1`) | single flaky 503 | 503 sustained > 2m OR any machine failing Fly's health check | this file, §5 |
| Audit partition runway | `samen.audit.partition.runway_days`, `.default_rows`, `.default_landing.count`, `.runway_unknown.count`; `/readyz` body line `partitions:` | runway < 31 days, OR any `default_rows` > 0, OR no DEFAULT partition, OR any `runway_unknown` | runway <= 0 (`partitions: CRITICAL`), OR `runway_unknown` for > 1h, OR `default_landing` still rising after the roll-forward ran | this file, §7 |
| Pool saturation | `samen.pool.saturation.events` (event `[:samen,:pool,:saturation]`, default threshold 50ms checkout wait) | events present, low rate | sustained rate increase over baseline | this file, §6 |

---

## 1. Oban backlog / queue depth growing

Queues and their sensitivity (`Samen.Jobs` app config): `default:10`, `rollups:2`,
`webhooks_out:5`, `erasure:1`, `maintenance:1`, `reveal:5`. `erasure` and `reveal` are
**governance-critical and latency-sensitive** — erasure backlog means retention/crypto-shred
deadlines slip; reveal backlog means live support/DSAR requests stall. A pruner keeps job rows
7 days, so `oban_jobs` is always queryable for recent backlog.

- **Warn:** `samen.oban.job.queue_time` p95 > 30s for any queue, OR backlog (state=`available`
  + `scheduled`) > 500 rows in a queue.
- **Page:** p95 queue_time > 2m sustained 5m in ANY queue, OR backlog > 50 rows specifically in
  `erasure` or `reveal` (their concurrency is 1 and 5 respectively — backlog there means real
  wait, not noise).

First response:
1. Identify the queue: `SELECT queue, count(*) FROM oban_jobs WHERE state IN ('available','scheduled') GROUP BY queue ORDER BY 2 DESC;`
2. Check if it's a volume spike (legit traffic) vs a stuck worker (same job retried repeatedly — check `attempt` on the oldest rows).
3. Confirm the app has DB pool headroom and BEAM scheduler isn't saturated (see [beam-introspection.md](beam-introspection.md)).
4. If `erasure` or `reveal` is backed up, consider a temporary queue-limit bump (`Oban.scale_queue/2`) rather than waiting out the cron.
5. If a single job is stuck retrying, inspect it with beam-introspection.md before killing/discarding — cancelling an `erasure` job can leave a scope half-swept.
6. Once cleared, confirm queue_time returns under warn threshold for 2 consecutive scrape intervals before closing.

## 2. Discarded jobs

A job that exhausts `max_attempts` becomes Oban state `discarded`. This is a job the system
gave up on — for `erasure` (retention deletes) or `reveal` (governed PII access) a discard means
a governance obligation silently didn't happen.

- **Warn:** >5 discarded/hr in any queue OTHER than `erasure`/`reveal`.
- **Page:** ANY discarded job in `erasure` or `reveal` — no threshold, page on the first one.

First response:
1. Query: `SELECT id, queue, worker, errors FROM oban_jobs WHERE state='discarded' ORDER BY discarded_at DESC LIMIT 20;` — read the `errors` array for the terminal exception.
2. For `erasure`/`reveal`: identify the affected org/subject from job args, determine if the obligation (retention deadline, DSAR SLA) is still coverable manually or needs escalation.
3. Fix the root cause (bad args, downstream dependency down, code bug) before requeuing — a blind retry of a job that will fail the same way just re-discards.
4. Requeue via `Oban.retry_job/1` (or `retry_all_jobs` scoped to the affected ids) once the fix is confirmed.
5. For non-critical queues, triage in batch during business hours; log the pattern if it recurs (possible upstream instability).
6. If discards correlate with a recent deploy, treat as a bad-release signal — see [rollback.md](rollback.md).

## 3. Seal-lag (audit chain falling behind)

The audit chain is hash-chained per org and periodically re-verified/anchored:
`Samen.AuditChain.VerifyWorker` runs `*/15 * * * *` and emits `[:samen,:audit_chain,:verify]`
(success) or per-tamper `[:samen,:audit_chain,:tamper]`. `Samen.BreakGlass.ReconcileWorker`
runs `*/10 * * * *` and anchors node-local deferred break-glass entries; an entry still in
`[:samen,:break_glass,:unanchored]` beyond one cycle is lagging. Growing seal-lag means
integrity attestation is falling behind reality.

- **Warn:** no successful `[:samen,:audit_chain,:verify]` in 30m (2 missed 15m cycles); a
  break-glass entry stays `[:samen,:break_glass,:unanchored]` > 20m (2 missed 10m cycles).
- **Page:** no successful verify in 60m (4 missed cycles); ANY `[:samen,:audit_chain,:tamper]`
  event, immediately, regardless of frequency.

First response:
1. Confirm `Samen.AuditChain.VerifyWorker` / `Samen.BreakGlass.ReconcileWorker` are actually scheduled — check the Oban cron plugin config and `oban_jobs` for recent `maintenance`-queue runs.
2. If the worker is running but slow/erroring, check Repo health (`SELECT 1`) and Oban `maintenance` queue backlog (see §1).
3. **On ANY `[:samen,:audit_chain,:tamper]` event** — stop routine triage, treat as a suspected integrity incident and open [breach-notification.md](breach-notification.md) §1 (contain) immediately.
4. For a stuck break-glass unanchored entry, confirm the control-plane DB is reachable — see [break-glass.md](break-glass.md) for the deferred-anchoring contract (control-plane-down defers anchoring by design; this is only a page if it exceeds one missed reconcile cycle).
5. Once the worker resumes, confirm a clean `[:samen,:audit_chain,:verify]` for the affected org(s) before closing.
6. Document the gap window (start of lag → resolution) — it matters if a breach investigation later needs to know when integrity attestation was degraded.

## 4. KMS error rate

Prod KMS adapter is `Samen.Kms.AwsKmsDynamo` (AWS KMS wrap/unwrap of per-subject DEKs +
DynamoDB wrapped-DEK store). Config: `SAMEN_KMS_KEY_ID`, `SAMEN_KMS_REGION`. The vault is
**fail-closed** — a KMS failure means reads/writes of vaulted PII fields error rather than
leak plaintext, so any sustained KMS failure is directly user-facing.

- **Warn:** any wrap/unwrap failures observed, not yet sustained.
- **Page:** sustained KMS failure > 1m. Cross-check `/readyz`'s `:kms` component — a `/readyz`
  503 with `kms: {:error, _}` corroborates this at the probe level (§5).

First response:
1. Check AWS KMS and DynamoDB service health (AWS Health Dashboard) for the configured `SAMEN_KMS_REGION`.
2. Verify `SAMEN_KMS_KEY_ID` / `SAMEN_KMS_REGION` are still correct and the key isn't disabled/scheduled for deletion (AWS Console → KMS → key state).
3. Check IAM: the deploying role/credential still has `kms:Encrypt`/`kms:Decrypt`/`kms:GenerateDataKey` on the key, and DynamoDB table access for the wrapped-DEK store.
4. Confirm `/readyz` is failing closed as expected (503, not a false 200) — this is correct behavior, not a bug to work around.
5. If AWS-side and healthy, check network egress from the Fly app to AWS (VPC peering / firewall changes).
6. Do not attempt a workaround that bypasses the vault chokepoint — there is no degraded path that manufactures plaintext by design; wait for KMS to recover or engage AWS support.

## 5. `/readyz` failing

`Samen.Web.Readiness.check/1` probes Repo `SELECT 1`, KMS store attest, and Oban liveness →
200/503. `/healthz` is a separate static-200 liveness check (proves the BEAM is up, nothing
more). Fly's `[[http_service.checks]]` gates traffic on the readiness check.

- **Warn:** a single flaky 503 (one probe cycle).
- **Page:** 503 sustained > 2m, or any machine failing Fly's health check and being pulled from rotation.

First response:
1. Hit `/readyz` directly and read which component failed (`repo`, `kms`, or `oban`).
2. Route to the matching section: Repo → check Postgres/Neon status; KMS → §4; Oban → confirm the Oban instance/supervisor is up (not just queue backlog — see §1 if it's just deep, not down).
3. If this follows a deploy, treat as a bad-release signal first — see [rollback.md](rollback.md) decision table.
4. Confirm `/healthz` is still 200 to distinguish "app process is up but dependency down" from "app process itself is down."

## 6. Pool saturation

`samen.pool.saturation.events` (event `[:samen,:pool,:saturation]`) counts DB pool checkout
waits exceeding the configured threshold (default 50ms) — an early contention signal before
requests start timing out outright.

- **Warn:** events present at a low, steady rate.
- **Page:** sustained rate increase over baseline (treat as a leading indicator for `/readyz`
  repo-check failures — escalate per §5 if it progresses).

First response:
1. Correlate with traffic volume — is this proportional load or a leak (connections not being returned)?
2. Check for a recent deploy introducing a long-held transaction or N+1 pattern.
3. Confirm Postgres/Neon isn't itself under load (see pitr/observability tooling); pool saturation upstream of a healthy DB usually means app-side pool sizing or a stuck query.
4. If sustained, consider whether a query is worth killing at the Postgres level — verify via [beam-introspection.md](beam-introspection.md) before doing so.

## 7. Audit partition runway

`aud_event` is partitioned by month. `Samen.AuditEvent.PartitionManager` (daily 01:00 and once at boot) keeps two
months ahead; `aud_event_default` catches any row outside every month so an audited write never fails for want of
a partition. `/readyz` adds a `partitions:` line (WARN, CRITICAL or UNKNOWN) to its **200** body: this is an advisory, not a
readiness failure, because every node shares the database and a 503 would drain the fleet without curing anything.
Alert on the metrics (or poll the `/readyz` body), not on the status code.

- **Warn:** `runway_days` < 31; any `default_rows` > 0 or a `default_landing` event (a row fell outside the window: a
  backdated or future import, or a lapsed roll-forward); the DEFAULT partition is missing (migration `20261114120000`
  not run); any `runway_unknown` event (the catalog could not be read: unknown is never healthy).
- **Page:** `runway_days` <= 0 (`partitions: CRITICAL`); `runway_unknown` sustained > 1h; `default_landing` still
  rising after the roll-forward has run.

First response:
1. `SELECT relname, pg_get_expr(relpartbound, oid) FROM pg_class WHERE relname LIKE 'aud_event%' ORDER BY 1;` — what exists.
2. Check the `PartitionManager` job in `oban_jobs` (`maintenance` queue): a discarded or failing job is the usual cause; its error names the month.
3. Run it now: `Oban.insert(Samen.AuditEvent.PartitionManager.new(%{}))`. If DEFAULT holds rows for a month, the job moves them into the new partition.
4. Rows in DEFAULT for a month that already has a partition cannot occur; rows for months not yet created are moved when the job creates them. Rows older than the first partition stay in DEFAULT by design: they are still read through `aud_event`.
5. Confirm `runway_days` > 31 and `default_rows` is falling to the rows you accept before closing.

**A move that fails** (job error `partition_roll_forward_failed`, `audit_partition_move` in the log, Postgres `lock_not_available`):
something held a lock on `aud_event` for longer than `:partition_move_lock_timeout_ms` (5 s). The move rolled back whole and Oban
retries (5 attempts); nothing is lost. Find the holder (`SELECT pid, state, xact_start, query FROM pg_stat_activity WHERE state <> 'idle' ORDER BY xact_start`)
— usually a long transaction that wrote audit rows — and end it, or raise the timeout for the retry.

**DEFAULT too large to move** (`audit_partition_move` in the log with `default_too_large_to_move`): the roll-forward job lapsed for long
enough that `aud_event_default` holds more than `:partition_move_max_default_rows` (500 000) rows. An automated move would pass over all of
them under the exclusive lock, so it refuses. Raise the cap for ONE run you supervise (`Application.put_env(:samen_core,
:partition_move_max_default_rows, n)` in a remote shell, then `ensure_partition/2` for the month, in a quiet period), or run the move off-peak
with the same cap; do not leave it raised. A move that stops with `partition_move_window_exceeded` or `query_canceled` is the same condition
one step later: the DEFAULT is too big for the window budget (`:partition_move_window_budget_ms`, 15 s); drain it in a quiet period.

**Permanent WARN (rows older than every partition).** `default_rows` > 0 that never falls: those rows are older than the first
partition (a backdated import, a replayed anchor), so no month the job creates will take them. They are not lost — `aud_event`
reads include them. Remediation: create the missing months (`Samen.AuditEvent.PartitionManager.ensure_partition(Repo, ~D[YYYY-MM-01])`
for each month they belong to; the move puts the rows in), or, if they are accepted as they are, record the decision in the incident
log and silence the `default_rows` alert for this table (the `default_landing` counter must still alert: it tells you a NEW row fell out).
`partitions: UNKNOWN` names the table it could not read (integer or MAXVALUE-bounded tables are not read at all).

