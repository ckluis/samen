# Runbook — Backup Verification Cadence (L6 / T92)

> **What this covers:** proving a backup is **restorable**, not merely **taken**.
> A dump file on disk / in object storage is not a backup until it has restored
> into a scratch database and matched the primary. `Samen.Backup.Verification`
> (the code) + `Samen.Backup.VerificationWorker` (the Oban job) automate that
> check; this runbook is the operator cadence + game-day drill around them.

- **Task:** T92 (roadmap Phase 7, spec §L6). **Depends on:** the L1 backup/PITR
  posture — see [`pitr-gameday.md`](./pitr-gameday.md) for how the backup artifact
  itself is produced/branched. This runbook consumes that artifact and verifies it.

## The mechanism (built, locally provable)

`Samen.Backup.Verification.verify/1` runs four honest outcomes and NEVER a fake
green:

| Situation | Result |
|---|---|
| no restore target wired | `{:error, :not_configured}` (fail-honest — **never** `{:ok}`) |
| artifact corrupt / truncated / missing (`pg_restore` fails) | `{:error, {:restore_failed, _}}` |
| restore comes back but **does not match** the primary manifest | `{:error, {:verification_failed, diffs}}` |
| full matching restore round-trip | `{:ok, report}` |

Each failure emits the operator-plane alert
`[:samen, :backup, :verification, :failed]` (token-blind — table names, counts,
and md5 **content checksums** only; never a `vt_*` token or a plaintext value).
The success path emits `[:samen, :backup, :verification, :ok]`.

The "manifest" is a per-table `{row_count, content_checksum}` captured from the
**primary** at backup time; the verifier recomputes it against the **restored**
scratch DB and compares. A partial/corrupt/silently-wrong restore cannot match.

### Restore-target adapters (fail-honest seam)

- `Samen.Backup.Restore.NotConfigured` — **default**. Returns
  `{:error, :not_configured}`. This is the honest state until a real target is
  wired.
- `Samen.Backup.Restore.LocalPgDump` — **locally provable**. Really runs
  `pg_restore` of a real `pg_dump` artifact into a real scratch DB. This is what
  the L6 test proves end-to-end (clean dump ⇒ `:ok`; corrupt dump ⇒ fail; missing
  dump ⇒ fail).
- **OPERATOR TODO (credential-gated, L1/L3):** wire a real cloud restore target —
  a Neon PITR branch or an S3-hosted `pg_dump` artifact — behind this same
  behaviour. That step needs cloud credentials and is deliberately **not** built
  here (it lives in the credential-gated half with T88/T91). Until then the
  scheduled job is fail-honest by default.

## Cadence (operator TODO checklist)

- [ ] **Wire the config.** Set `config :samen_core, :backup_verification, [...]`
      with `:adapter`, `:config`, `:scratch`, and the `:expected_manifest` captured
      from the primary at backup time. Absent this, the job is fail-honest
      (`:not_configured`) — visible, never a false green.
- [ ] **Schedule the job.** Add
      `{"0 6 * * *", Samen.Backup.VerificationWorker}` to your host cron block
      (restate `Samen.Jobs.default_crontab() ++ [...]` per the `Samen.Jobs`
      moduledoc so you do not drop the canonical entries). Runs on the
      `:maintenance` queue (concurrency 1) — already in the canonical taxonomy, no
      queue change needed. **Daily** verification of the most recent backup.
- [ ] **Alert on failure.** Attach a handler to
      `[:samen, :backup, :verification, :failed]` that pages the on-call platform
      lead. A backup that stops restoring must be a **paging** event, not a
      dashboard tile.
- [ ] **Watch the DLQ.** A `VerificationWorker` job in `discarded` state (after
      `max_attempts`) means verification kept failing — treat as an active incident.
- [ ] **Quarterly game-day** (below), owner: on-call platform lead. File evidence.

## Game-day drill

Run the local drill any time to exercise the full verify loop against real bytes:

```
./scripts/backup-verify-gameday.sh
```

It seeds a throwaway source DB, `pg_dump`s it, and runs
`Samen.Backup.Verification.verify/1` through `Samen.Backup.Restore.LocalPgDump`
for THREE cases — clean (must pass), corrupted (must fail), missing (must fail) —
printing each outcome. This is the local stand-in for the real quarterly drill.

**Real quarterly drill (OPERATOR TODO):** once a cloud restore target is wired,
run the same `verify/1` against a **production-sized** artifact restored into an
isolated scratch instance, on the cadence in [`pitr-gameday.md`](./pitr-gameday.md)
§A–§E, and file the pass/fail + wall-clock into that runbook's evidence section.
Until the real target exists, the numbers here are a **local basis only**.

## Why this is not theater

The verifier is proven refutable: the L6 test
(`samen_core/test/backup_verification_test.exs`) includes a **corrupted-dump**
control and a **missing-dump** control that MUST fail, alongside the clean control
that MUST pass. The committed sabotage
(`scripts/sabotages/285-l6-backup-verifier-claims-ok-on-bad-restore.patch`) neuters
the gate into claiming `:ok` on a bad restore and proves the named tests flip red —
so "the check can catch a bad backup" is itself gated in CI.
