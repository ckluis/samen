# Runbook — PITR / Reverse-Migration Game-Day

> **OPERATOR TODO — the REAL Neon drill is not yet run in this environment.**
> This runbook's §A–§E is the production quarterly drill script; §F is a LOCAL
> SIMULATION that has been executed (evidence in §G). To run the real drill you
> need: **(1)** a Neon project with continuous PITR enabled on the target branch,
> **(2)** a Neon API key (`NEON_API_KEY`) with branch create/delete scope, **(3)**
> the app's external KMS reachable from the drill runner (per ADR-001). Cadence:
> **quarterly**, against a production-sized branch. Owner: on-call platform lead.
> File the drill evidence back into §G each quarter. Until the real drill runs, the
> RTO/RPO numbers below are TARGETS with a simulation basis only (see §G caveats).

- **Task:** T2.5 (plan §7 Phase 2). **Vision doc:** §runs 2b ("Migration safety
  posture & the reverse path").
- **Scenario in scope:** a **bad contract migration that ran** — the highest-
  consequence incident on a single Postgres substrate. This is the one incident the
  doc attaches a drilled number to.
- **Two recovery arms, and when to pick each:**
  - **Forward-fix / expand-reversal** (RTO target ≤ 30 min) — the DEFAULT. Catch it
    fast, ship a corrective release, and/or reverse the additive expand via its
    tested `down/0`. Costs no business writes.
  - **Full PITR restore** (RTO drilled ≤ 2 h) — the LAST RESORT. Branch at a point
    before the contract and promote. **Costs every business write since the contract
    committed.**

---

## The honest RPO framing (read this before deciding to restore)

Two RPO scenarios, told apart:

| Scenario | Effective RPO | Why |
|---|---|---|
| Hardware / infra failure (steady state) | **≤ 1 min** | continuous WAL/PITR archive |
| **A bad contract that ran** (this runbook) | **= detection latency** | a PITR restore to a point *before* the contract throws away **every business write since the contract committed**. If you detect the bad contract 90 minutes after it deployed, restore loses 90 minutes of real writes — not 1 minute. |

**Consequence for the decision:** restore is not the default. The preferred control
for a bad contract is to **detect fast and forward-fix or reverse the expand**.
Restore is the last resort that costs real writes. This is why detection latency —
not the WAL archive interval — is the number that actually bounds data loss for the
headline incident, and why the "detect" step below is measured as its own line.

---

## A. Preconditions & preflight (production Neon drill)

1. Target a **production-sized Neon branch** (not `main`). Clone `main` → `drill-YYYY-QN`.
2. Confirm continuous PITR is enabled and the restore window covers the intended
   pre-contract instant.
3. Confirm the external KMS is reachable **and** that the drill will NOT destroy any
   real subject key (the drill exercises restore, not erasure — key-shred drills are
   the crypto-shred game-day, T5.4, a separate runbook).
4. Announce the drill window; freeze non-drill deploys to the branch.
5. Have the corrective (forward-fix) release built and ready to deploy — you decide
   arm at §C, but both arms must be *ready* before you inject the fault.

## B. Inject the fault (bad contract)

1. Apply an **expand** migration (additive, reversible — has a tested `down/0`).
2. Apply a **bad contract** migration: an irreversible, destructive change (e.g.
   `DROP COLUMN` of a still-read column, a narrowing `ALTER TYPE`, a `NOT NULL` add
   that a live code path violates). The contract is irreversible *by construction* —
   its `down/0` cannot resurrect dropped data (§runs 2b: contract is covered by PITR,
   not `down/0`).
3. Record `t_contract_committed` (the wall-clock the contract COMMITs). This is the
   RPO clock start.

## C. Detect → decide

1. **Detect.** The application health signal fails: a load-bearing column read raises,
   an API 500s, a smoke test goes red. Record `t_detected`. **`detection_latency =
   t_detected − t_contract_committed`** — this IS the effective RPO if you restore.
2. **Decide the arm** (write the decision + reasoning in the drill log):
   - **Forward-fix / expand-reversal** if: the damage is bounded and correctable by a
     new release and/or by reversing the additive expand; and the dropped/narrowed
     data is either not yet depended on or is recoverable from application logic.
     **This is the default.**
   - **Full PITR restore** if: the contract corrupted or destroyed data that no
     forward-fix can reconstruct, AND the business cost of losing writes since
     `t_contract_committed` is acceptable versus the cost of the corruption.
   - Escalate the restore decision to the platform lead — restore is a
     writes-destroying operation.

## D. Arm (i) — Forward-fix / expand-reversal (RTO target ≤ 30 min)

1. Reverse the expand via its tested `down/0` (`mix ecto.rollback` / the release's
   down step) — additive, so this is clean and non-destructive.
2. Deploy the corrective release (forward-fix): re-add the erroneously-dropped
   column, widen the narrowed type, or ship the code that tolerates the new schema.
3. Validate: run the app smoke/validation suite. Record `t_recovered_arm_i`.
   **`RTO_arm_i = t_recovered_arm_i − t_detected`** — target ≤ 30 min.
4. This arm costs **no** business writes (it never rewinds time).

## E. Arm (ii) — Full PITR restore (RTO drilled ≤ 2 h)

1. **Branch at the pre-contract point.** In Neon: create a branch from the restore
   point `t_contract_committed − ε` (just before the contract COMMITted).
   ```
   # Neon CLI / API (operator step — needs NEON_API_KEY):
   neonctl branches create --project-id "$NEON_PROJECT" \
     --name "restore-$(date +%s)" \
     --parent main --parent-timestamp "$PRE_CONTRACT_ISO8601"
   ```
2. **Validate** the branch: point a throwaway app instance at the branch's connection
   string and run the app validation suite. Confirm the schema is pre-contract and
   the app reads it cleanly.
3. **Prove key-store exclusion** (load-bearing PII claim, §runs data / §limits):
   the branch brings back **ciphertext**, never the per-subject vault key. The vault
   key lives in the external KMS **outside** the WAL/PITR surface. A restore of any
   pre-shred WAL therefore resurrects ciphertext (already useless for a shredded
   subject) but **cannot** resurrect a destroyed key. Verify: for any subject shredded
   before the restore point, `reveal` against the restored ciphertext MUST deny
   (`:shredded`/`:unavailable`). The restore does not un-erase anyone.
4. **Promote** the validated branch to be the new primary (Neon branch promote), OR
   cut the app's connection string over to it. Record `t_recovered_arm_ii`.
   **`RTO_arm_ii = t_recovered_arm_ii − t_detected`** — target ≤ 2 h.
5. **Accept the RPO cost:** every business write in `(t_contract_committed,
   t_detected]` is gone. This is why arm (i) is preferred.

## Post-drill

- Reconcile: file `detection_latency`, `RTO_arm_i`, `RTO_arm_ii` into §G.
- Any gap (target missed, step ambiguous, tool broke) becomes a fix task in the
  current phase.
- Delete the drill branch(es); un-freeze deploys.

---

## F. LOCAL SIMULATION (no Neon in this environment)

There is **no Neon account and no physical replica** in this build environment. The
local simulation substitutes local Postgres primitives for Neon branch-and-restore,
faithfully preserving the mechanics that matter (fresh-DB restore, app validation,
key-store exclusion) and documenting the one seam that differs.

**The simulation seam (register the real thing as the operator TODO above):**

| Runbook step | Production (Neon) | LOCAL SIMULATION |
|---|---|---|
| "branch at pre-contract point" | Neon copy-on-write branch off the continuous WAL archive at `t_contract_committed − ε` | `pg_dump` of the base DB taken **before** the contract migration ran (a logical snapshot at the pre-contract instant) |
| "validate the branch" | throwaway app instance on the branch conn string | `psql`-restore the dump into a **fresh** local DB; run the app validation harness against it |
| "promote" | Neon branch promote / conn-string cutover | (not simulated — cutover is infra-level; the validated fresh DB is the promotable artifact) |
| key store | external KMS outside WAL/PITR | file-backed KMS dir OUTSIDE Postgres (`Samen.Kms.FileBacked`), never in any `pg_dump` |

The seam is the **snapshot substrate** (logical dump vs CoW WAL branch). Everything
downstream — fresh-DB restore, app validation, and the load-bearing key-store
exclusion — is identical between the two.

**Run it:**
```
bash docs/runbooks/pitr-gameday-sim.sh                 # full drill, both arms, evidence -> §G
bash docs/runbooks/pitr-gameday-sim.sh --probe-corrupt # red-path probe (see below)
```

**What the simulation does (both arms, measured):**
1. Migrate a demo-shaped DB to the **pre-contract baseline**; seed a real
   PII-bearing subject into the vault (ciphertext in Postgres; wrapped DEK in the
   external key dir).
2. `pg_dump` the base (branch @ pre-contract); assert the **key store is NOT in the
   dump**.
3. Apply the **expand**, then the **BAD contract** (drops the load-bearing
   `cnt_display_name` column).
4. **Detect**: the app validation harness fails because the load-bearing column is
   gone. Measured as its own line (detection latency proxy).
5. **Arm (i)**: reverse the expand via its tested `down/0` + forward-fix; re-validate.
   Measured.
6. **Arm (ii)**: restore the pre-contract dump into a **fresh** DB; validate the app
   suite against it. Measured (restore + validate broken out).
7. **Key-store exclusion**: point the harness at an **empty** key dir (a DB-only
   restore) — the restored ciphertext survives but `reveal` **denies**
   (`:unavailable`). Proves restore does not resurrect shredded/absent keys.

**Red path (plan hard-rule 2):** the simulation script **exits non-zero** if
post-restore validation fails on a clean restore. The `--probe-corrupt` flag corrupts
the restore target once (drops the load-bearing column post-restore) and asserts the
validation **fails closed** — if a corrupted restore ever validated, the probe exits
non-zero (fail-open would be caught). Result: PROBE OK — validation fails closed on a
corrupted restore.

**Anti-tautology probe:** in a scratch copy of the harness (outside `/tmp`, since
removed), `DrillValidate.run/3` was sabotaged to always return `0`. The `validate`
phase then returned **exit 0 even against a DROP-COLUMN-corrupted DB** — proving the
red path's pass/fail is genuinely driven by the schema-reading validation logic, not a
constant. Reverted; the shipped harness returns `1` on any failed check.

---

## G. Evidence appendix (measured wall-clock)

Each quarterly drill (real or simulated) appends a row. Wall-clock is measured by the
orchestrator and written to `docs/runbooks/pitr-gameday-evidence.json`.

### Drill #1 — LOCAL SIMULATION (2026-07-05)

- **Substrate:** local Postgres 16.13 (Homebrew), `pg_dump`/`psql` snapshot (Neon
  simulated — see §F seam).
- **Base DB:** `samen_pitr_drill_base` → **restore DB:** `samen_pitr_drill_restore`.
- **Dump size:** ~32 KB (demo-shaped schema + seeded vault rows).

| Measurement | Value | Target | Within target |
|---|---|---|---|
| Detection (app validation fails on bad contract) | **~0.79 s** | — (proxy for detection latency) | n/a |
| **Arm (i)** — reverse expand via `down/0` + forward-fix | **~0.75 s** | ≤ 30 min forward-fix | **YES** |
| **Arm (ii)** — restore (pg_dump → fresh DB) | **~0.21 s** | — | — |
| **Arm (ii)** — validate app suite against restored DB | **~0.72 s** | — | — |
| **Arm (ii)** — restore + validate total | **~0.98 s** | ≤ 2 h full PITR | **YES** |
| Key-store exclusion proven (empty key dir denies decrypt) | **YES** (`:unavailable`) | must be YES | **YES** |

**Honest caveats on these numbers (why the simulation numbers are floors, not the
real RTO):**
- The simulation runs on a **demo-shaped ~32 KB DB on localhost**. Real Neon numbers
  scale with branch size, WAL replay depth, promote latency, and network — a
  production-sized branch restore is minutes-to-hours, not sub-second. The simulation
  proves the **runbook mechanics and the key-store invariant**, not the production RTO
  magnitude. The ≤ 30 min / ≤ 2 h targets remain **targets pending the real Neon
  drill** (operator TODO).
- Detection latency here is the harness's own validation runtime (~0.8 s), NOT a real
  incident's detection latency (which is monitoring/alerting-driven and is the true
  RPO for a bad-contract restore). The real drill must measure detection from
  monitoring, not from a scripted probe.
- "Promote" is not simulated (it is infra-level cutover). The validated fresh DB is
  the promotable artifact; the real drill measures promote/cutover as part of
  `RTO_arm_ii`.

### Drill #2 — REAL Neon (PENDING — operator TODO)

_Not yet run. Requires Neon project + API key + KMS reachability. Append measured
`detection_latency`, `RTO_arm_i`, `RTO_arm_ii`, and the key-store-exclusion result
here after the first production-sized quarterly drill._
