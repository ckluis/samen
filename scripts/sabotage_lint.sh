#!/usr/bin/env bash
# scripts/sabotage_lint.sh — fast header preflight for scripts/sabotages/*.patch.
#
# T75 closing round: patch 67 shipped missing its `# MUST_FAIL:` header (the
# ONLY one of 75), which made `scripts/sabotage.sh`'s per-patch check abort
# mid-loop on patch 67 and never reach patches 68-75 at all. This script
# checks EVERY patch's APP/TEST_FILES/MUST_FAIL headers up front — milliseconds,
# no `git apply`, no `mix test` — so a missing header is caught by name before
# any patch is applied, and a single bad patch can never silently swallow the
# rest of the harness run.
#
# It also validates the BUILD_REFUSED.tsv ledger (scripts/sabotages/BUILD_REFUSED.tsv): an entry naming a patch that
# does not exist, an empty required substring or reason, a malformed row or a patch listed twice fails here, at the
# start of every replay.
#
# `scripts/sabotage.sh` calls this FIRST and aborts if it fails; run it
# directly for a standalone, instant header check.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SABOTAGE_DIR="$REPO_ROOT/scripts/sabotages"

meta() { # meta <patch> <key> -> values, one per line
  sed -n "s/^# $2: //p" "$1"
}

bad=0
total=0

for patch in "$SABOTAGE_DIR"/*.patch; do
  total=$((total + 1))
  name="$(basename "$patch")"

  app="$(meta "$patch" APP)"
  test_files="$(meta "$patch" TEST_FILES)"
  must_fail="$(meta "$patch" MUST_FAIL)"

  missing=""
  [[ -n "$app" ]] || missing="$missing APP"
  [[ -n "$test_files" ]] || missing="$missing TEST_FILES"
  [[ -n "$must_fail" ]] || missing="$missing MUST_FAIL"

  if [[ -n "$missing" ]]; then
    echo "SABOTAGE LINT: $name — missing header(s):$missing"
    bad=$((bad + 1))
  fi
done

# The ledger: `patch<TAB>required substring<TAB>reason`; `#` comments and blank lines are skipped.
LEDGER="$SABOTAGE_DIR/BUILD_REFUSED.tsv"
ledger_bad=0
if [[ -f "$LEDGER" ]]; then
  ledger_errs="$(awk -F'\t' -v dir="$SABOTAGE_DIR" '
    /^[[:space:]]*$/ || /^#/ { next }
    NF != 3 { printf "SABOTAGE LINT: BUILD_REFUSED.tsv:%d — want exactly 3 tab-separated columns (patch, required substring, reason)\n", NR; next }
    { if ($1 !~ /^[A-Za-z0-9._-]+$/ || system("test -f \"" dir "/" $1 "\"") != 0) printf "SABOTAGE LINT: BUILD_REFUSED.tsv:%d — names a patch that does not exist: \047%s\047\n", NR, $1 }
    $2 ~ /^[[:space:]]*$/ { printf "SABOTAGE LINT: BUILD_REFUSED.tsv:%d — %s has an empty required substring\n", NR, $1 }
    $3 ~ /^[[:space:]]*$/ { printf "SABOTAGE LINT: BUILD_REFUSED.tsv:%d — %s has an empty reason\n", NR, $1 }
    ($1 in seen) { printf "SABOTAGE LINT: BUILD_REFUSED.tsv:%d — %s is listed twice\n", NR, $1 }
    { seen[$1] = 1 }
  ' "$LEDGER")"
  if [[ -n "$ledger_errs" ]]; then
    printf '%s\n' "$ledger_errs"
    ledger_bad=$(printf '%s\n' "$ledger_errs" | wc -l | tr -d ' ')
  fi
fi

if [[ $total -eq 0 ]]; then
  echo "SABOTAGE LINT: FAILED — no patches found in $SABOTAGE_DIR"
  exit 1
fi

if [[ $bad -gt 0 ]]; then
  echo ""
  echo "SABOTAGE LINT: FAILED — $bad of $total patch(es) missing required headers"
  exit 1
fi

if [[ $ledger_bad -gt 0 ]]; then
  echo ""
  echo "SABOTAGE LINT: FAILED — $ledger_bad invalid BUILD_REFUSED.tsv problem(s) above"
  exit 1
fi

echo "SABOTAGE LINT: ALL PASSED ($total patches, headers present)"
