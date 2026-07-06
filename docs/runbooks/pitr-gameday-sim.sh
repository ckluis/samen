#!/usr/bin/env bash
# pitr-gameday-sim.sh — the T2.5 LOCAL SIMULATION of the PITR / reverse-migration
# game-day drill (plan §7 T2.5; vision doc §runs 2b).
#
# NO Neon account exists in this environment. This script SIMULATES Neon's
# branch-and-restore faithfully with local Postgres primitives:
#
#   Neon "branch at pre-contract point"  ->  a pg_dump taken BEFORE the contract
#                                            migration ran (the base backup).
#   Neon "restore/promote"               ->  psql-restore that dump into a FRESH DB.
#
# The simulation seam (documented as an operator TODO in pitr-gameday.md): a real
# Neon branch is a copy-on-write WAL branch off a continuous archive; here we use a
# logical pg_dump snapshot taken at the pre-contract instant. The RESTORE-ARM
# mechanics (fresh DB, app validation, KEY-STORE exclusion) are identical; only the
# snapshot substrate differs.
#
# It runs BOTH recovery arms of the runbook and MEASURES each:
#   ARM (i)  — reverse the EXPAND via its tested down/0 (forward-fix path).
#   ARM (ii) — full RESTORE of the pre-contract backup into a fresh DB + validate
#              the app suite + prove the KEY STORE is excluded from the restore.
#
# RED PATH (plan hard-rule 2): the script EXITS NON-ZERO if post-restore validation
# fails. Pass --probe-corrupt to corrupt the restore target once and prove the red
# path fails closed (the script then expects the validation to fail and exits 0 if
# it does, non-zero if the "corrupted" DB still validated — a tautology guard).
#
# Usage:
#   bash docs/runbooks/pitr-gameday-sim.sh            # full drill, writes evidence
#   bash docs/runbooks/pitr-gameday-sim.sh --probe-corrupt   # red-path probe
#
# Requires: pg_dump, psql, createdb/dropdb (or psql CREATE/DROP DATABASE), a local
# Postgres reachable as $USER with no password (this environment's setup).

set -uo pipefail

# --------------------------------------------------------------------------
# Config
# --------------------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEMO_DIR="$REPO_ROOT/demo"
RUNBOOK="$REPO_ROOT/docs/runbooks/pitr-gameday.md"

PGHOST="${DRILL_PGHOST:-localhost}"
PGPORT="${DRILL_PGPORT:-5432}"
PGUSER="${USER}"

BASE_DB="samen_pitr_drill_base"       # the "production" DB the incident happens on
RESTORE_DB="samen_pitr_drill_restore" # the fresh DB we promote the branch into
DRILL_SUBJECT_ID="drill-subject-fixed"

# Working dir OUTSIDE /tmp root (plan hard-rule 2): a self-created subdir we clean.
WORK_DIR="$REPO_ROOT/.pitr_drill_work"
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

# millis -> human
fmt_ms() { python3 -c "import sys; ms=int(sys.argv[1]); print(f'{ms} ms ({ms/1000:.2f} s)')" "$1"; }

# Run a drill phase in the demo app context against $2 (the DB name), with $3 as
# the key dir. The app is started (MIX_ENV=drill start_repo? defaults true) so
# Demo.Repo is available for the Vault/reveal phases; the migrate/expand/reverse
# phases use Ecto.Migrator (which reuses the already-started repo). Returns exit.
run_phase_started() {
  local phase="$1" db="$2" keydir="$3"
  ( cd "$DEMO_DIR" && \
    MIX_ENV=drill \
    DRILL_DB="$db" \
    DRILL_PGHOST="$PGHOST" \
    DRILL_PGPORT="$PGPORT" \
    DRILL_SUBJECT_ID="$DRILL_SUBJECT_ID" \
    SAMEN_KMS_KEY_DIR="$keydir" \
    mix run priv/drills/pitr_drill.exs "$phase" )
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

echo "==> T2.5 PITR game-day LOCAL SIMULATION (probe_corrupt=$PROBE_CORRUPT)"
echo "    base DB=$BASE_DB  restore DB=$RESTORE_DB  key dir=$KEY_DIR"

# Fresh DBs.
drop_db "$BASE_DB"; drop_db "$RESTORE_DB"
create_db "$BASE_DB"

# --------------------------------------------------------------------------
# STEP 1 — migrate the base DB to the PRE-CONTRACT baseline + seed vault PII.
# --------------------------------------------------------------------------
echo "--- step 1: migrate base to pre-contract baseline + seed vault PII"
run_phase_started migrate "$BASE_DB" "$KEY_DIR" || fail "migrate phase failed"

# --------------------------------------------------------------------------
# STEP 2 — take the BASE BACKUP (Neon branch-at-pre-contract simulation).
#          The dump captures ciphertext + tokens but NEVER the key dir.
# --------------------------------------------------------------------------
echo "--- step 2: pg_dump base (branch @ pre-contract)"
pg_dump -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$BASE_DB" \
  --no-owner --no-privileges -f "$DUMP_FILE" || fail "pg_dump failed"
# Assert the key material is NOT in the dump (the whole PITR claim).
if grep -q "master.key\|\.dek" "$DUMP_FILE"; then
  fail "SECURITY: key material appears in the pg_dump!"
fi
DUMP_BYTES=$(wc -c < "$DUMP_FILE" | tr -d ' ')
echo "    dump captured ($DUMP_BYTES bytes); key store NOT in dump (verified)"

# --------------------------------------------------------------------------
# STEP 3 — apply EXPAND then the BAD CONTRACT on the base DB (the incident).
# --------------------------------------------------------------------------
echo "--- step 3: apply expand"
run_phase_started expand "$BASE_DB" "$KEY_DIR" || fail "expand phase failed"
echo "--- step 3: apply BAD contract (drops load-bearing column)"
run_phase_started bad_contract "$BASE_DB" "$KEY_DIR" || fail "bad_contract phase failed"

# --------------------------------------------------------------------------
# STEP 4 — DETECT. The app validation harness must now FAIL on the base DB.
# --------------------------------------------------------------------------
echo "--- step 4: detect (app validation must fail => bad contract detected)"
DETECT_T0=$(now_ms)
run_phase_started detect "$BASE_DB" "$KEY_DIR"
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
run_phase_started reverse "$BASE_DB" "$KEY_DIR"
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
  echo "    [PROBE] corrupting restore target: DROP COLUMN cnt_display_name"
  psql_db "$RESTORE_DB" "ALTER TABLE cnt_contact DROP COLUMN cnt_display_name" >/dev/null \
    || fail "probe corruption DDL failed"
fi

echo "--- ARM (ii): validate app suite against restored DB"
VAL_T0=$(now_ms)
run_phase_started validate "$RESTORE_DB" "$KEY_DIR"
VAL_CODE=$?
VAL_MS=$(( $(now_ms) - VAL_T0 ))
ARM2_MS=$(( $(now_ms) - ARM2_T0 ))

if [[ "$PROBE_CORRUPT" -eq 1 ]]; then
  # Red-path probe: validation MUST fail on the corrupted DB.
  if [[ "$VAL_CODE" -eq 0 ]]; then
    fail "RED-PATH PROBE FAILED — validation passed on a CORRUPTED restore (fail-open!)"
  fi
  echo "    [PROBE] validation correctly FAILED closed on corrupted restore (exit $VAL_CODE)"
  echo "==> RED-PATH PROBE OK: post-restore validation fails closed."
  cleanup
  exit 0
fi

# Normal run: validation MUST pass on a clean restore.
if [[ "$VAL_CODE" -ne 0 ]]; then
  fail "post-restore validation FAILED on a clean restore (exit $VAL_CODE)"
fi
echo "    ARM (ii) validate OK in $(fmt_ms $VAL_MS); arm total $(fmt_ms $ARM2_MS)"

# --------------------------------------------------------------------------
# STEP 5 — KEY-STORE EXCLUSION (T2.5 (c)): the restored DB decrypts NOTHING
#          without the external key dir. Point the harness at an EMPTY key dir.
# --------------------------------------------------------------------------
echo "--- step 5: key-store exclusion — restore + EMPTY key dir must deny decrypt"
run_phase_started keystore "$RESTORE_DB" "$EMPTY_KEY_DIR"
KEYSTORE_CODE=$?
if [[ "$KEYSTORE_CODE" -ne 0 ]]; then
  fail "key-store exclusion FAILED — restore resurrected a key (exit $KEYSTORE_CODE)"
fi
echo "    key-store exclusion PROVEN (restore does not resurrect shredded/absent keys)"

# --------------------------------------------------------------------------
# EVIDENCE — emit measured wall-clock as JSON for the runbook appendix.
# --------------------------------------------------------------------------
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
PG_VER="$(psql_db "$BASE_DB" 'SHOW server_version' 2>/dev/null | sed -n '3p' | tr -d ' ' || echo unknown)"

cat > "$EVIDENCE_JSON" <<EOF
{
  "drill": "T2.5 PITR game-day LOCAL SIMULATION",
  "timestamp_utc": "$TS",
  "postgres_version": "$PG_VER",
  "simulation_seam": "Neon branch-and-restore simulated with pg_dump (pre-contract snapshot) + psql restore into a fresh DB; real Neon drill registered as operator TODO in pitr-gameday.md",
  "base_db": "$BASE_DB",
  "restore_db": "$RESTORE_DB",
  "dump_bytes": $DUMP_BYTES,
  "detection_ms": $DETECT_MS,
  "arm_i_reverse_expand_forwardfix_ms": $ARM1_MS,
  "arm_ii_restore_ms": $RESTORE_MS,
  "arm_ii_validate_ms": $VAL_MS,
  "arm_ii_total_ms": $ARM2_MS,
  "key_store_exclusion_proven": true,
  "rto_target_forward_fix_ms": 1800000,
  "rto_target_full_pitr_ms": 7200000,
  "arm_i_within_forward_fix_target": $( [[ $ARM1_MS -le 1800000 ]] && echo true || echo false ),
  "arm_ii_within_pitr_target": $( [[ $ARM2_MS -le 7200000 ]] && echo true || echo false )
}
EOF

echo ""
echo "==> DRILL COMPLETE. Evidence:"
cat "$EVIDENCE_JSON"

# Persist a copy of the evidence next to the runbook for the appendix generator.
cp "$EVIDENCE_JSON" "$REPO_ROOT/docs/runbooks/pitr-gameday-evidence.json"

cleanup
echo ""
echo "==> T2.5 LOCAL SIMULATION: ALL ARMS GREEN. Evidence saved to docs/runbooks/pitr-gameday-evidence.json"
exit 0
