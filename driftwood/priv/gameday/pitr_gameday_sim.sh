#!/usr/bin/env bash
# pitr_gameday_sim.sh — T5.5 PITR / reverse-migration GAME-DAY #2 LOCAL SIMULATION
# against a PRODUCTION-SIZED Driftwood dataset (plan §7 T5.5; vision doc §runs 2b).
#
# This is the Driftwood adaptation of the T2.5 machinery
# (docs/runbooks/pitr-gameday-sim.sh). NO Neon account exists here; this script
# SIMULATES Neon's branch-and-restore faithfully with local Postgres primitives:
#
#   Neon "branch at pre-contract point"  ->  a pg_dump taken BEFORE the contract
#                                            migration ran (the base backup).
#   Neon "restore/promote"               ->  psql-restore that dump into a FRESH DB.
#
# The simulation seam (registered as an operator TODO in docs/runbooks/pitr-gameday.md):
# a real Neon branch is a copy-on-write WAL branch off a continuous archive; here we
# use a logical pg_dump snapshot at the pre-contract instant. The RESTORE-ARM mechanics
# (fresh DB, app validation, KEY-STORE exclusion) are identical; only the snapshot
# substrate differs.
#
# It runs BOTH recovery arms of the runbook and MEASURES each:
#   ARM (i)  — reverse the EXPAND via its tested down/0 (forward-fix path).
#   ARM (ii) — full RESTORE of the pre-contract backup into a fresh DB + validate the
#              SETTLEMENT-INTEGRITY suite + prove the KEY STORE is excluded (the driver
#              CDL ciphertext survives but does not decrypt without the external key).
#
# The load-bearing validation is a SETTLEMENT-INTEGRITY check (design §3 netting math):
# it re-derives net_payable = max((linehaul+fuel+accessorial) − advances −
# factoring_fee − claims, 0) in SQL from the stored cents columns over the whole
# dataset. The BAD contract drops stl_advances_cents — silently zeroing advances and
# OVER-PAYING every carrier — which the integrity check catches (fail closed).
#
# RED PATH (plan hard-rule 2): the script EXITS NON-ZERO if post-restore
# settlement-integrity validation fails. Pass --probe-corrupt to corrupt the restore
# target once (drop stl_advances_cents post-restore) and prove the red path fails
# closed (the script then expects validation to fail and exits 0 if it does, non-zero
# if the corrupted DB still validated — a tautology guard).
#
# Usage:
#   bash priv/gameday/pitr_gameday_sim.sh                  # full drill, writes evidence + report
#   bash priv/gameday/pitr_gameday_sim.sh --probe-corrupt  # red-path probe
#
# Requires: pg_dump, psql, python3, a local Postgres reachable as $USER, no password.

set -uo pipefail

# --------------------------------------------------------------------------
# Config
# --------------------------------------------------------------------------
DW_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPO_ROOT="$(cd "$DW_DIR/.." && pwd)"
RUNBOOK="$REPO_ROOT/docs/runbooks/pitr-gameday.md"
REPORT="$DW_DIR/reports/T5.5.md"

PGHOST="${DRILL_PGHOST:-localhost}"
PGPORT="${DRILL_PGPORT:-5432}"
PGUSER="${USER}"

BASE_DB="driftwood_pitr_drill_base"       # the "production" DB the incident happens on
RESTORE_DB="driftwood_pitr_drill_restore" # the fresh DB we promote the branch into
DRILL_SUBJECT_ID="5c5f4d3e-0000-4000-8000-000000000d11"

# Dataset scale (production-sized: thousands of loads/settlements across several tenants).
# Overridable so CI can pick a scale that is multi-thousand but fast.
export DRILL_TENANTS="${DRILL_TENANTS:-4}"
export DRILL_CARRIERS="${DRILL_CARRIERS:-40}"
export DRILL_LOADS="${DRILL_LOADS:-600}"

# Working dir OUTSIDE /tmp root (plan hard-rule 2): a self-created subdir we clean.
WORK_DIR="$DW_DIR/.pitr_drill_work"
KEY_DIR="$WORK_DIR/kms_keys"          # the EXTERNAL key store (never in a dump)
EMPTY_KEY_DIR="$WORK_DIR/kms_keys_empty"
DUMP_FILE="$WORK_DIR/base_precontract.sql"
EVIDENCE_JSON="$WORK_DIR/evidence.json"

PROBE_CORRUPT=0
[[ "${1:-}" == "--probe-corrupt" ]] && PROBE_CORRUPT=1

mkdir -p "$WORK_DIR" "$KEY_DIR" "$EMPTY_KEY_DIR"

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------
psql_admin() { psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d postgres -v ON_ERROR_STOP=1 -c "$1"; }
psql_db()    { psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$1" -v ON_ERROR_STOP=1 -c "$2"; }

drop_db()   { psql_admin "DROP DATABASE IF EXISTS $1" >/dev/null 2>&1 || true; }
create_db() { psql_admin "CREATE DATABASE $1" >/dev/null; }

now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }
fmt_ms() { python3 -c "import sys; ms=int(sys.argv[1]); print(f'{ms} ms ({ms/1000:.2f} s)')" "$1"; }

# Run a drill phase in the Driftwood app context against $2 (the DB name), with $3 as
# the KMS key dir. Uses `mix run` (NOT --no-start): the drill env sets start_repo?=false
# so the OTP app boots WITHOUT the repo/web tree (no Endpoint/port), but the deps
# (:db_connection/:ecto_sql) DO start; the drill script then starts Driftwood.Repo itself.
run_phase() {
  local phase="$1" db="$2" keydir="$3"
  ( cd "$DW_DIR" && \
    MIX_ENV=drill \
    DRILL_DB="$db" \
    DRILL_PGHOST="$PGHOST" \
    DRILL_PGPORT="$PGPORT" \
    DRILL_SUBJECT_ID="$DRILL_SUBJECT_ID" \
    DRIFTWOOD_KMS_KEY_DIR="$keydir" \
    mix run priv/drills/pitr_drill.exs "$phase" 2>&1 | grep -E "DRILL|error|Error|\*\*" )
  return "${PIPESTATUS[0]}"
}

cleanup() {
  drop_db "$BASE_DB"
  drop_db "$RESTORE_DB"
  rm -rf "$WORK_DIR"
}

fail() { echo "DRILL FAILED: $*" >&2; cleanup; exit 1; }

# --------------------------------------------------------------------------
# Preflight
# --------------------------------------------------------------------------
for bin in pg_dump psql python3; do
  command -v "$bin" >/dev/null 2>&1 || fail "required binary '$bin' not found on PATH"
done

echo "==> T5.5 PITR game-day #2 LOCAL SIMULATION (probe_corrupt=$PROBE_CORRUPT)"
echo "    base DB=$BASE_DB  restore DB=$RESTORE_DB  key dir=$KEY_DIR"
echo "    dataset scale: ${DRILL_TENANTS} tenants x ${DRILL_CARRIERS} carriers x ${DRILL_LOADS} loads"

drop_db "$BASE_DB"; drop_db "$RESTORE_DB"
create_db "$BASE_DB"

# --------------------------------------------------------------------------
# STEP 1 — migrate base to the current schema + GENERATE the production-sized
#          dataset + seed a real CDL-bearing driver into the vault.
# --------------------------------------------------------------------------
echo "--- step 1: migrate base + generate production-sized dataset + seed vault CDL"
GEN_T0=$(now_ms)
run_phase migrate "$BASE_DB" "$KEY_DIR" || fail "migrate phase failed"
GEN_MS=$(( $(now_ms) - GEN_T0 ))

# Row counts — evidence the dataset is production-sized.
N_SETTLE=$(psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$BASE_DB" -tA -c "SELECT count(*) FROM stl_settlement")
N_LOADS=$(psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$BASE_DB" -tA -c "SELECT count(*) FROM fop_opportunity")
N_CARRIERS=$(psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$BASE_DB" -tA -c "SELECT count(*) FROM fcm_company")
N_TENANTS=$(psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$BASE_DB" -tA -c "SELECT count(DISTINCT stl_org_id) FROM stl_settlement")
echo "    dataset: $N_TENANTS tenants, $N_CARRIERS carriers, $N_LOADS loads, $N_SETTLE settlements (built in $(fmt_ms $GEN_MS))"

# --------------------------------------------------------------------------
# STEP 2 — take the BASE BACKUP (Neon branch-at-pre-contract simulation).
#          The dump captures ciphertext + tokens but NEVER the key dir.
# --------------------------------------------------------------------------
echo "--- step 2: pg_dump base (branch @ pre-contract)"
DUMP_T0=$(now_ms)
pg_dump -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$BASE_DB" \
  --no-owner --no-privileges -f "$DUMP_FILE" || fail "pg_dump failed"
DUMP_MS=$(( $(now_ms) - DUMP_T0 ))
# Assert the key material is NOT in the dump (the whole PITR claim, T5.5 (c)).
if grep -q "master.key\|\.dek" "$DUMP_FILE"; then
  fail "SECURITY: key material appears in the pg_dump!"
fi
DUMP_BYTES=$(wc -c < "$DUMP_FILE" | tr -d ' ')
echo "    dump captured ($DUMP_BYTES bytes) in $(fmt_ms $DUMP_MS); key store NOT in dump (verified)"

# --------------------------------------------------------------------------
# STEP 3 — apply EXPAND then the BAD CONTRACT on the base DB (the incident).
# --------------------------------------------------------------------------
echo "--- step 3: apply reversible EXPAND (adds stl_settlement_note)"
run_phase expand "$BASE_DB" "$KEY_DIR" || fail "expand phase failed"
echo "--- step 3: apply BAD contract (drops load-bearing stl_advances_cents)"
CONTRACT_T=$(now_ms)   # t_contract_committed — the RPO clock start
run_phase bad_contract "$BASE_DB" "$KEY_DIR" || fail "bad_contract phase failed"

# --------------------------------------------------------------------------
# STEP 4 — DETECT. The settlement-integrity harness must now FAIL on the base DB.
#          detection_latency (proxy) = the harness runtime here (see runbook §G
#          honest caveat: the REAL RPO is monitoring-driven detection latency).
# --------------------------------------------------------------------------
echo "--- step 4: detect (settlement integrity must fail => bad contract detected)"
DETECT_T0=$(now_ms)
run_phase detect "$BASE_DB" "$KEY_DIR"
DETECT_CODE=$?
DETECT_MS=$(( $(now_ms) - DETECT_T0 ))
if [[ "$DETECT_CODE" -eq 0 ]]; then
  fail "detect returned 0 — the bad contract was NOT detected (drill is vacuous)"
fi
echo "    DETECTED (harness exit $DETECT_CODE) in $(fmt_ms $DETECT_MS)"

# ==========================================================================
# ARM (i) — reverse the EXPAND via its tested down/0 (+ forward-fix). MEASURED.
# ==========================================================================
echo "--- ARM (i): reverse expand via down/0 + forward-fix"
ARM1_T0=$(now_ms)
run_phase reverse "$BASE_DB" "$KEY_DIR"
ARM1_CODE=$?
ARM1_MS=$(( $(now_ms) - ARM1_T0 ))
if [[ "$ARM1_CODE" -ne 0 ]]; then
  fail "ARM (i) reverse failed (exit $ARM1_CODE)"
fi
echo "    ARM (i) complete in $(fmt_ms $ARM1_MS)"

# ==========================================================================
# ARM (ii) — full RESTORE of the pre-contract backup into a FRESH DB + validate.
#            MEASURED. This is the red-path-bearing arm.
# ==========================================================================
echo "--- ARM (ii): restore pre-contract backup into fresh DB"
ARM2_T0=$(now_ms)
drop_db "$RESTORE_DB"; create_db "$RESTORE_DB"
psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$RESTORE_DB" \
  -v ON_ERROR_STOP=1 -f "$DUMP_FILE" >/dev/null || fail "restore (psql) failed"
RESTORE_MS=$(( $(now_ms) - ARM2_T0 ))
echo "    restore complete in $(fmt_ms $RESTORE_MS)"

# Optional red-path probe: corrupt the restore target ONCE, expect validation to fail.
if [[ "$PROBE_CORRUPT" -eq 1 ]]; then
  echo "    [PROBE] corrupting restore target: DROP COLUMN stl_advances_cents"
  psql_db "$RESTORE_DB" "ALTER TABLE stl_settlement DROP COLUMN stl_advances_cents" >/dev/null \
    || fail "probe corruption DDL failed"
fi

echo "--- ARM (ii): validate settlement-integrity suite against restored DB"
VAL_T0=$(now_ms)
run_phase validate "$RESTORE_DB" "$KEY_DIR"
VAL_CODE=$?
VAL_MS=$(( $(now_ms) - VAL_T0 ))
ARM2_MS=$(( $(now_ms) - ARM2_T0 ))

if [[ "$PROBE_CORRUPT" -eq 1 ]]; then
  if [[ "$VAL_CODE" -eq 0 ]]; then
    fail "RED-PATH PROBE FAILED — validation passed on a CORRUPTED restore (fail-open!)"
  fi
  echo "    [PROBE] validation correctly FAILED closed on corrupted restore (exit $VAL_CODE)"
  echo "==> RED-PATH PROBE OK: post-restore settlement-integrity validation fails closed."
  cleanup
  exit 0
fi

if [[ "$VAL_CODE" -ne 0 ]]; then
  fail "post-restore settlement-integrity validation FAILED on a clean restore (exit $VAL_CODE)"
fi
echo "    ARM (ii) validate OK in $(fmt_ms $VAL_MS); arm total $(fmt_ms $ARM2_MS)"

# --------------------------------------------------------------------------
# STEP 5 — KEY-STORE EXCLUSION (T5.5 (c)): the restored DB decrypts NOTHING (the
#          driver CDL) without the external key dir. Point the harness at an EMPTY dir.
# --------------------------------------------------------------------------
echo "--- step 5: key-store exclusion — restore + EMPTY key dir must deny CDL decrypt"
run_phase keystore "$RESTORE_DB" "$EMPTY_KEY_DIR"
KEYSTORE_CODE=$?
if [[ "$KEYSTORE_CODE" -ne 0 ]]; then
  fail "key-store exclusion FAILED — restore resurrected a key (exit $KEYSTORE_CODE)"
fi
echo "    key-store exclusion PROVEN (restore does not resurrect shredded/absent keys)"

# --------------------------------------------------------------------------
# EVIDENCE — emit measured wall-clock as JSON.
# --------------------------------------------------------------------------
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
PG_VER="$(psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$BASE_DB" -tA -c 'SHOW server_version' 2>/dev/null | tr -d ' ' || echo unknown)"

ARM1_OK=$( [[ $ARM1_MS -le 1800000 ]] && echo true || echo false )
ARM2_OK=$( [[ $ARM2_MS -le 7200000 ]] && echo true || echo false )

cat > "$EVIDENCE_JSON" <<EOF
{
  "drill": "T5.5 Driftwood PITR game-day #2 LOCAL SIMULATION",
  "timestamp_utc": "$TS",
  "postgres_version": "$PG_VER",
  "simulation_seam": "Neon branch-and-restore simulated with pg_dump (pre-contract snapshot) + psql restore into a fresh DB; real Neon drill registered as operator TODO in pitr-gameday.md",
  "base_db": "$BASE_DB",
  "restore_db": "$RESTORE_DB",
  "dataset": {"tenants": $N_TENANTS, "carriers": $N_CARRIERS, "loads": $N_LOADS, "settlements": $N_SETTLE},
  "dataset_gen_ms": $GEN_MS,
  "dump_bytes": $DUMP_BYTES,
  "dump_ms": $DUMP_MS,
  "detection_ms": $DETECT_MS,
  "arm_i_reverse_expand_forwardfix_ms": $ARM1_MS,
  "arm_ii_restore_ms": $RESTORE_MS,
  "arm_ii_validate_ms": $VAL_MS,
  "arm_ii_total_ms": $ARM2_MS,
  "key_store_exclusion_proven": true,
  "rto_target_forward_fix_ms": 1800000,
  "rto_target_full_pitr_ms": 7200000,
  "arm_i_within_forward_fix_target": $ARM1_OK,
  "arm_ii_within_pitr_target": $ARM2_OK
}
EOF

echo ""
echo "==> DRILL COMPLETE. Evidence:"
cat "$EVIDENCE_JSON"

# UXD-02 Seam B: "timestamp_utc" is the one run-varying mint in this evidence file
# (E-03; minted above at $TS, from `date -u +%Y-%m-%dT%H:%M:%SZ`). It moves to a
# gitignored sidecar so the tracked evidence file stops changing byte-for-byte on
# every regeneration. render_t55_report.py still reads it (for T5.5.md's own
# "Generated:" line, out of this node's scope) from $EVIDENCE_JSON, which is
# untouched — only the copy that becomes the TRACKED artifact is stripped.
SIDECAR_JSON="$DW_DIR/reports/pitr-gameday2-evidence.sidecar.json"
python3 -c "
import json
with open('$EVIDENCE_JSON') as f:
    e = json.load(f)
with open('$SIDECAR_JSON', 'w') as f:
    json.dump({'timestamp_utc': e['timestamp_utc']}, f, indent=2)
    f.write('\n')
with open('$DW_DIR/reports/pitr-gameday2-evidence.json', 'w') as f:
    e.pop('timestamp_utc', None)
    json.dump(e, f, indent=2)
    f.write('\n')
"

# --------------------------------------------------------------------------
# REPORT — generate reports/T5.5.md from the measured evidence.
# --------------------------------------------------------------------------
python3 "$DW_DIR/priv/gameday/render_t55_report.py" "$EVIDENCE_JSON" "$REPORT" \
  || fail "report generation failed"
echo "==> wrote $REPORT"

cleanup
echo ""
echo "==> T5.5 LOCAL SIMULATION: ALL ARMS GREEN. Evidence + report written."
exit 0
