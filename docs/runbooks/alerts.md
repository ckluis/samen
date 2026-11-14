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
| Second instance on the database | `samen.single_node.peers`, `.overlap_seconds`, `.unknown`, `.overlap.count`, `.unknown.count`, `.peer_refused.count`; `/readyz` body line `single_node:` | `peers` > 0 (a rolling deploy does this for up to the 5-minute grace period; do not page on it), OR `peer_refused.count` rising | `single_node: CRITICAL` (overlap past the grace period), OR `single_node: UNKNOWN` sustained > 15m, OR `overlap.count` > 0 outside a deploy | this file, §8 |
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
them under the exclusive lock, so it refuses. Raising only the row cap is not enough: a DEFAULT that large then trips the window budget
(`:partition_move_window_budget_ms`, 15 s; `partition_move_window_exceeded` or `query_canceled`). Off-peak does not change the answer (the cap is a
row count). Drain it with ONE supervised run that raises BOTH, in a remote shell on the node that runs the job:

```elixir
Application.put_env(:samen_core, :partition_move_max_default_rows, 5_000_000)   # above the DEFAULT's row count
Application.put_env(:samen_core, :partition_move_window_budget_ms, 120_000)     # the longest write stall you accept
Samen.AuditEvent.PartitionManager.ensure_partition(YourApp.Repo, ~D[YYYY-MM-01])  # for the month the rows belong to
# then, always (also if it failed):
Application.delete_env(:samen_core, :partition_move_max_default_rows)
Application.delete_env(:samen_core, :partition_move_window_budget_ms)
```

Audited writes STALL, for up to the raised budget, while the move holds its exclusive lock (plus the lock wait, `:partition_move_lock_timeout_ms`,
5 s), so pick a quiet period and a budget you can live with. `Application.put_env` is node-wide: the daily job on that node sees the raised values
until you delete them, so do not leave them set. A move that is refused or rolled back loses nothing; read `DEFAULT too large` /
`partition_move_window_exceeded` again after raising and retry with a larger budget only if you accept the longer stall.

**Permanent WARN (rows older than every partition).** `default_rows` > 0 that never falls: those rows are older than the first
partition (a backdated import, a replayed anchor), so no month the job creates will take them. They are not lost — `aud_event`
reads include them. Remediation: create the missing months (`Samen.AuditEvent.PartitionManager.ensure_partition(Repo, ~D[YYYY-MM-01])`
for each month they belong to; the move puts the rows in), or, if they are accepted as they are, record the decision in the incident
log and silence the `default_rows` alert for this table (the `default_landing` counter must still alert: it tells you a NEW row fell out).
`partitions: UNKNOWN` names the table it could not read (integer or MAXVALUE-bounded tables are not read at all).

## 8. Second instance on the database (ADR-054)

Samen runs as ONE instance per database. Each serving instance holds a session advisory lock on a dedicated connection and counts
the other holders (`Samen.SingleNode.Lease`). `/readyz` adds a `single_node:` line to its **200** body (it is an advisory like §7:
draining a machine would not cure it), or answers **503** on the LATE instance when `config :samen_core, Samen.SingleNode,
strict: true`. Alert on the metrics or the body line.

- `single_node: CRITICAL N other instance(s) share this database for Ns` — another instance has been on this database longer
  than `grace_ms` (default 300 s). A rolling deploy produces `samen.single_node.peers` = 1 for a few minutes and no line; the grace clock starts when the other instance is confirmed alive
  (a holder that never beats starts nothing); the line
  means the old instance was not stopped, or someone scaled the app.
- `single_node: UNKNOWN … (reason)` — the lease cannot say. It never refuses traffic, not even with `strict: true` (ADR-054 §2.2:
  strict does not 503 on UNKNOWN). `connection_down` / `query_failed`: the database or the dedicated connection is failing (§5 will
  usually be failing too). **`connection_pooler`: the lease connection goes through a transaction pooler (PgBouncer, Neon's
  `-pooler` host), where session locks do not work. The lease LATCHES this reading at the first check that proves it and logs
  one error, and only a restart of the lease process clears it (redeploy with `DATABASE_DIRECT_URL` set; if the URL is already direct,
  restart the instance and report it). A pooled lease reads UNKNOWN only from then on (until it does, and after the pooler recycles its server
  connection, an instance sharing the database can read `single` while it serves), so treat any `connection_pooler` as a real
  fault; `lease_url` (generated apps: `DATABASE_DIRECT_URL`) must be a DIRECT, unpooled URL.** Two instances whose statements
  share one server connection (also a pooler) read the same. `lease_lost`: the lock vanished under a live session (`pg_advisory_unlock_all()`, a pooler `DISCARD ALL`);
  the lease re-takes it only on a new session, restart the instance. `stale_holder`: a lock whose owner stopped beating (a crashed
  machine whose session Postgres has not dropped yet, a lock left on a pooler's server connection, or a LIVE instance connected
  through a pooler: it latched `connection_pooler`, no longer beats, and looks exactly like a ghost lock to a direct peer). BEFORE you
  terminate anything, check the holder's `client_addr` / `application_name` in `pg_stat_activity` (step 3 below): if `client_addr` is your
  pooler, find the instance that reports `connection_pooler` first, because terminating the pooler's server connection makes this
  instance read `single` while that one keeps serving. It clears when the session
  ends (15 s after the owner went silent on Postgres 14+, else when TCP keepalive drops it, which behind a proxy or session pooler can take hours; or `SELECT pg_terminate_backend(pid)` for
  the pid in step 3 below). `lease_not_running` / `lease_stale`: this instance's lease process died or hung; its supervisor restarts it,
  a persistent line means it keeps failing (look for `Samen.SingleNode.Lease` in the log). `not confirmed alive`: another holder
  exists and an overlap clock already runs from an earlier confirmed episode (or `grace_ms` is 0), but its beat has not changed yet; a first-seen holder that is not yet confirmed starts no clock and `/readyz` stays clean. It resolves to CRITICAL or `stale_holder` within one to three check intervals.
- The gauge `samen.single_node.unknown` is emitted by a RUNNING lease only: `lease_not_running` and `lease_stale` leave it at its
  last value, so alert on the `/readyz` body line as well as on the metric.
- `samen.single_node.peer_refused.count` rising — something connects a VISIBLE Erlang node (a clustering library, or an operator
  starting `iex`/`:observer` without `--hidden`). It is disconnected each time. Use `bin/app remote` or `iex --hidden --remsh`.

First response to CRITICAL:
1. `fly status` / `fly machines list`: how many machines run this app? Expect one.
2. Stop the extra one (`fly machines stop <id>` then `fly scale count 1`). The line clears on the next check (5 s).
3. If only one machine exists, look for a second deployment pointing at the same `DATABASE_URL` (a staging app, a preview, a laptop with the production URL):
   `SELECT pid, application_name, client_addr, backend_start FROM pg_stat_activity WHERE pid IN (SELECT pid FROM pg_locks WHERE locktype='advisory' AND classid=1396788549 AND objid=1313817669 AND objsubid=2);`
   (`client_addr`, `backend_start` and `application_name` read NULL for another role's session: run it as the database owner, a superuser or a `pg_read_all_stats` member.)
4. Meanwhile treat the node-local state as unreliable (ADR-054 §1.1): re-check the AI kill switch on BOTH instances if it was thrown, and review fleet heartbeat rejections.
