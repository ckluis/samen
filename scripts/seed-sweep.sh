#!/usr/bin/env bash
# scripts/seed-sweep.sh — the seed-sweep tier (issue #42).
#
# WHY THIS EXISTS. Four pre-existing, seed- or order- or timing-dependent test reds
# (#31, #36, #40, #41) all surfaced BY ACCIDENT in a single day — each found while
# doing something else (perf profiling, an unrelated PR's first ci-fast, chasing a
# different bug). None was caught by CI, because CI runs exactly one ExUnit seed per
# invocation and every one of these reds needs a SPECIFIC seed (or order, or wall-clock
# alignment) to fire. Re-running past a red like that trains exactly the habit T129
# named as the real failure: "re-run past the known flake" masks real reds too.
#
# WHAT THIS IS. A runner that executes a chosen suite (or one file, for a fast check)
# under N distinct ExUnit seeds, one `mix test` invocation per seed, and reports every
# seed that failed BY NAME at the end. A red on any seed is a real red — this tier
# never retries past one. Cost is linear in N; the existing `--seed` plumbing needs no
# new machinery.
#
# WHAT THIS IS NOT. It is NOT wired into ci.sh. It is opt-in, like the sabotage replay,
# because a real samen_core/samen_web sweep at N>1 multiplies the real suite's cost and
# memory footprint by N — that is a decision for the operator to make with headroom,
# not something this task should force into every gate run. Wiring an opt-in nightly
# ci.sh step is a deliberate follow-up (see the PR body), not done here.
#
# ── ACCOUNTING DISCIPLINE (mirrors scripts/sabotage.sh's PROCESSED/SELECTED) ─────────
# This runner is NOT fail-fast: it runs every selected seed even after a failure, so
# that one bad seed can never hide whether the rest were exercised. Every exit path —
# clean, some-seeds-failed, or interrupted — prints
#   SEED-SWEEP: PROCESSED <n> of <N>
# so a partial or aborted run can never be misread as a clean sweep: n < N says so in
# words. A failing seed is always named as
#   SEED-SWEEP: seed <seed> FAILED
# Exit code is non-zero iff any seed failed (or the run never reached a full selection).
#
# ── FLAGS ─────────────────────────────────────────────────────────────────────────
#   --app <name>          samen_core (default) or samen_web resolve to that directory
#                         under the repo root; any other value is treated as a path
#                         (absolute, or relative to the CWD) to a directory containing
#                         a mix.exs — this is how the self-test points the sweep at a
#                         throwaway, DB-free fixture app without touching either real app.
#   --seeds <N>           sweep N seeds, generated from the current time so repeated
#                         invocations explore different seeds (default 20). Ignored if
#                         --seed-list is given.
#   --file <path>         sweep one file only (relative to the app dir) instead of the
#                         whole suite — for a fast check on a suspect module.
#   --seed-list <list>    an explicit, comma- or space-separated list of seeds to run
#                         instead of generating N — for reproducing a KNOWN bad seed
#                         (e.g. --seed-list 636821) or re-running an exact prior sweep.
#
# Needs: whatever the target app's own `mix test` needs (real samen_core/samen_web
# suites are DB-backed; the self-test's fixture apps are deliberately not). Exits
# non-zero on an unknown flag, a bad --app (no mix.exs found), an empty seed
# selection, or any swept seed failing.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  echo "Usage: seed-sweep.sh [--app <samen_core|samen_web|path>] [--seeds <N>]"
  echo "                     [--file <path-relative-to-app>] [--seed-list <s1,s2,...>]"
  echo ""
  echo "See the header of this script for the full flag reference and accounting"
  echo "discipline (SEED-SWEEP: PROCESSED n of N / SEED-SWEEP: seed <s> FAILED)."
}

arg_err() {
  echo "seed-sweep.sh: $1" >&2
  echo "" >&2
  usage >&2
  exit 2
}

FILTER_APP="samen_core"
SEEDS_N=20
FILE_ARG=""
SEED_LIST=""
SEEN_APP=0; APP_FIRST=""
SEEN_SEEDS=0; SEEDS_FIRST=""
SEEN_FILE=0; FILE_FIRST=""
SEEN_SEED_LIST=0; SEED_LIST_FIRST=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      shift; [[ $# -gt 0 ]] || arg_err "--app requires a name or path"
      if [[ $SEEN_APP -eq 1 ]]; then
        arg_err "--app given twice: '$APP_FIRST' and '$1' — repeating the same flag is an error; run separate invocations for separate apps"
      fi
      FILTER_APP="$1"; APP_FIRST="$1"; SEEN_APP=1; shift ;;
    --seeds)
      shift; [[ $# -gt 0 ]] || arg_err "--seeds requires a positive integer"
      if [[ $SEEN_SEEDS -eq 1 ]]; then
        arg_err "--seeds given twice: '$SEEDS_FIRST' and '$1' — repeating the same flag is an error"
      fi
      [[ "$1" =~ ^[0-9]+$ && "$1" -gt 0 ]] || arg_err "--seeds wants a positive integer, got: $1"
      SEEDS_N="$1"; SEEDS_FIRST="$1"; SEEN_SEEDS=1; shift ;;
    --file)
      shift; [[ $# -gt 0 ]] || arg_err "--file requires a path"
      if [[ $SEEN_FILE -eq 1 ]]; then
        arg_err "--file given twice: '$FILE_FIRST' and '$1' — repeating the same flag is an error"
      fi
      FILE_ARG="$1"; FILE_FIRST="$1"; SEEN_FILE=1; shift ;;
    --seed-list)
      shift; [[ $# -gt 0 ]] || arg_err "--seed-list requires a comma- or space-separated list of seeds"
      if [[ $SEEN_SEED_LIST -eq 1 ]]; then
        arg_err "--seed-list given twice: '$SEED_LIST_FIRST' and '$1' — repeating the same flag is an error"
      fi
      SEED_LIST="$1"; SEED_LIST_FIRST="$1"; SEEN_SEED_LIST=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      arg_err "unknown flag: $1" ;;
  esac
done

# ── resolve the app directory ────────────────────────────────────────────────
case "$FILTER_APP" in
  samen_core|samen_web)
    APP_DIR="$REPO_ROOT/$FILTER_APP" ;;
  /*)
    APP_DIR="$FILTER_APP" ;;
  *)
    APP_DIR="$PWD/$FILTER_APP" ;;
esac

if [[ ! -f "$APP_DIR/mix.exs" ]]; then
  echo "seed-sweep.sh: no mix.exs at $APP_DIR (resolved from --app $FILTER_APP)" >&2
  exit 2
fi

# ── build the seed selection ─────────────────────────────────────────────────
SEEDS=()
if [[ -n "$SEED_LIST" ]]; then
  for s in $(echo "$SEED_LIST" | tr ',' ' '); do
    [[ "$s" =~ ^[0-9]+$ ]] || arg_err "--seed-list wants numeric seeds, got: '$s'"
    SEEDS+=("$s")
  done
else
  # Time-derived base so back-to-back sweeps explore different seeds by default;
  # --seed-list is the reproducibility escape hatch for a KNOWN bad seed.
  base=$(( $(date +%s) % 100000 ))
  for ((i = 0; i < SEEDS_N; i++)); do
    SEEDS+=( $(( (base + i * 104729) % 1000000 )) )
  done
fi

SEL_COUNT=${#SEEDS[@]}
if [[ $SEL_COUNT -eq 0 ]]; then
  echo "seed-sweep.sh: empty seed selection" >&2
  exit 2
fi

# ── run accounting (see ACCOUNTING DISCIPLINE above) ─────────────────────────
PROCESSED=0
FAILED_SEEDS=()
LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/samen_seedsweep.XXXXXX")"

report_and_exit() {
  local rc=$1
  echo ""
  echo "SEED-SWEEP: PROCESSED $PROCESSED of $SEL_COUNT"
  if [[ $PROCESSED -lt $SEL_COUNT ]]; then
    echo "  !! NOT A FULL SWEEP: only $PROCESSED of $SEL_COUNT selected seeds were exercised"
    echo "     (interrupted or aborted before finishing) — this run certifies nothing"
    echo "     about the $((SEL_COUNT - PROCESSED)) seed(s) never reached."
  fi
  if [[ ${#FAILED_SEEDS[@]} -gt 0 ]]; then
    echo "SEED-SWEEP: ${#FAILED_SEEDS[@]} of $SEL_COUNT seeds FAILED:"
    for s in "${FAILED_SEEDS[@]}"; do
      echo "SEED-SWEEP: seed $s FAILED"
    done
    echo "  logs kept at: $LOG_DIR"
  elif [[ $PROCESSED -eq $SEL_COUNT ]]; then
    echo "SEED-SWEEP: ALL PASSED ($SEL_COUNT seeds)"
    rm -rf "$LOG_DIR"
  fi
  exit "$rc"
}
trap 'report_and_exit 130' INT TERM

echo "SEED-SWEEP: app=$FILTER_APP dir=$APP_DIR file=${FILE_ARG:-<full suite>}"
echo "SEED-SWEEP: SELECTED $SEL_COUNT seed(s): ${SEEDS[*]}"

for seed in "${SEEDS[@]}"; do
  logfile="$LOG_DIR/seed-$seed.log"
  echo "==> seed $seed ($((PROCESSED + 1)) of $SEL_COUNT)"
  if [[ -n "$FILE_ARG" ]]; then
    (cd "$APP_DIR" && mix test "$FILE_ARG" --seed "$seed") > "$logfile" 2>&1
  else
    (cd "$APP_DIR" && mix test --seed "$seed") > "$logfile" 2>&1
  fi
  rc=$?
  PROCESSED=$((PROCESSED + 1))
  if [[ $rc -ne 0 ]]; then
    echo "SEED-SWEEP: seed $seed FAILED (exit $rc)"
    echo "  log: $logfile"
    tail -n 40 "$logfile" | sed 's/^/    | /'
    FAILED_SEEDS+=("$seed")
  else
    echo "SEED-SWEEP: seed $seed passed"
  fi
done

if [[ ${#FAILED_SEEDS[@]} -gt 0 ]]; then
  report_and_exit 1
fi
report_and_exit 0
