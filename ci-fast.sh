#!/usr/bin/env bash
# ci-fast.sh — WS-F4 QA iteration tier.
#
# The INNER-LOOP gate: spikes → samen_core → samen_web ONLY. This is the framework
# core (the pure kernel + the UI library) — the tier a builder is most often iterating
# on. It deliberately SKIPS the slow tail of the full `./ci.sh`: the three gen_app
# generative probes (each deps.get/compiles a scratch app + runs its ci.sh, ~250s
# combined), the demo dogfood + 5-verifier gate, and the driftwood/pawchart vertical
# verifier gates. Use it for fast feedback while working in samen_core/samen_web; run
# the FULL `./ci.sh` (and `SAMEN_SABOTAGE=1 ./ci.sh` for the sabotage harness) before
# committing a milestone — ci-fast.sh is NOT a substitute for the root gate.
#
# That paragraph is a COMMENT, and nobody executing this script reads it. So the
# skipped set is also computed and PRINTED on every run, and uncommitted work under
# a skipped app raises a warning naming the app — see the coverage guard below.
#
# Like ci.sh: local Postgres required; compiles with --warnings-as-errors; exits
# non-zero on the first failure and ends `CI-FAST: ALL PASSED` on success.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- coverage guard: make the blind spot executable, not just documented -----
#
# ci-fast.sh runs a SUBSET of the tree, and a comment saying so is invisible to
# anyone actually running it. That blind spot has already cost this project a
# phase that closed 6/6 "verified" while the full gate was red: every node in it
# gated on ci-fast.sh, so driftwood was never exercised at all.
#
# The covered set is therefore DERIVED FROM THIS FILE'S OWN SOURCE, never listed
# by hand — a hand-copied scope is precisely what drifts out of sync with what
# the script really runs, which is the failure mode already hit twice. Every app
# this script exercises is entered through exactly one of two idioms, a run_spike
# call or a subshell cd, both spelled against $REPO_ROOT; those two idioms ARE
# the ground truth. Add a gate above using either and the app drops off the
# uncovered list by itself; delete a gate and the app reappears on it. Comment
# lines are stripped first, so prose (including this block) can never widen the
# claim.
#
# The universe is every mix project in the tree — any directory holding a
# mix.exs. A newly added app is thus uncovered BY DEFAULT, which is the
# fail-closed direction: the guard over-reports before it under-reports.
#
# Cheap by construction: one grep over this file, one find, one git status. No
# compiles, no test runs, nothing that slows the fast path down.

SELF="${BASH_SOURCE[0]}"

# Apps this script actually enters, read off its own executable lines.
COVERED_APPS="$(
  grep -vE '^[[:space:]]*#' "$SELF" \
    | grep -oE '(cd|run_spike) "[$]REPO_ROOT/[^"]+"' \
    | sed -E 's/^[a-z_]+ "[$]REPO_ROOT\///; s/"$//' \
    | sort -u || true
)"

# Every mix project in the tree = the universe an app can belong to.
ALL_APPS="$(
  find "$REPO_ROOT" -maxdepth 3 -name mix.exs \
       -not -path '*/deps/*' -not -path '*/_build/*' -print 2>/dev/null \
    | sed -E "s|^$REPO_ROOT/||; s|/mix\.exs$||" \
    | sort -u || true
)"

UNCOVERED_APPS="$(comm -23 <(printf '%s\n' "$ALL_APPS") <(printf '%s\n' "$COVERED_APPS") || true)"

# Uncommitted paths, one per line (rename entries reduced to their destination).
DIRTY_PATHS="$(
  git -C "$REPO_ROOT" status --porcelain 2>/dev/null \
    | sed -E 's/^.{3}//; s/^.* -> //; s/^"(.*)"$/\1/' || true
)"

# Uncovered apps that have uncommitted work sitting under them right now.
DIRTY_UNCOVERED=""
if [ -n "$UNCOVERED_APPS" ] && [ -n "$DIRTY_PATHS" ]; then
  while IFS= read -r app; do
    [ -n "$app" ] || continue
    if printf '%s\n' "$DIRTY_PATHS" | grep -qE "^$app/"; then
      DIRTY_UNCOVERED="$DIRTY_UNCOVERED$app
"
    fi
  done <<< "$UNCOVERED_APPS"
fi

print_coverage_notice() {
  echo ""
  echo "------------------------------------------------------------------------"
  echo " CI-FAST COVERAGE — this gate does NOT run the whole tree"
  echo ""
  if [ -z "$UNCOVERED_APPS" ]; then
    echo "   every mix project in the tree is exercised by this script."
  else
    echo "   NOT exercised by ci-fast.sh:"
    printf '%s\n' "$UNCOVERED_APPS" | sed 's/^/     - /'
    echo ""
    echo "   A change under any of those is UNPROVEN by this run. Gate it on the"
    echo "   full ./ci.sh, or say in your envelope that you did not."
  fi
  echo "------------------------------------------------------------------------"
  echo ""
}

# Deliberately a WARNING and never a hard failure: ci-fast.sh earns its keep by
# being fast, and a gate that refuses to run pushes people back to bypassing it
# entirely — which is worse than a loud notice they can act on.
print_dirty_warning() {
  [ -n "$DIRTY_UNCOVERED" ] || return 0
  echo ""
  echo "########################################################################"
  echo "##  WARNING: uncommitted changes under apps ci-fast.sh does NOT run   ##"
  echo "########################################################################"
  while IFS= read -r app; do
    [ -n "$app" ] || continue
    echo ""
    echo "  $app  -- NOT exercised by this run, but modified in your tree:"
    printf '%s\n' "$DIRTY_PATHS" | grep -E "^$app/" | sed 's/^/      /'
  done <<< "$DIRTY_UNCOVERED"
  echo ""
  echo "  A green CI-FAST below says NOTHING about the changes listed above."
  echo "  Run the full ./ci.sh before calling this verified."
  echo "########################################################################"
  echo ""
}

print_coverage_notice
print_dirty_warning

run_spike() {
  local spike_dir="$1"
  local spike_name
  spike_name="$(basename "$spike_dir")"
  echo "==> Running tests for spike: $spike_name"
  (
    cd "$spike_dir"
    mix deps.get --quiet
    mix test
  )
  echo "==> spike $spike_name: PASSED"
}

# --- spike list (same set as ci.sh) ---
run_spike "$REPO_ROOT/spikes/s00_smoke"
run_spike "$REPO_ROOT/spikes/s02_transformer"
run_spike "$REPO_ROOT/spikes/s03_fragments"
run_spike "$REPO_ROOT/spikes/s04_catalog_tx"
run_spike "$REPO_ROOT/spikes/s05_vault"
run_spike "$REPO_ROOT/spikes/s07_pii_reads"

echo ""
echo "==> All spikes passed."

# --- samen_core kernel tests ---
echo ""
echo "==> Running samen_core tests"
(
  cd "$REPO_ROOT/samen_core"
  mix deps.get --quiet
  mix test --warnings-as-errors
)
echo "==> samen_core: PASSED"

# --- samen_web framework UI library gate (ADR-009) ---
echo ""
echo "==> Running samen_web gate (compile --warnings-as-errors + two-plane render/masking suite)"
(
  cd "$REPO_ROOT/samen_web"
  bash ci.sh
)
echo "==> samen_web gate: PASSED"

# Re-printed here because minutes of suite output have scrolled the pre-run
# banner off screen, and the last thing a reader sees is what they act on. Both
# print BEFORE the ALL PASSED line, which other things grep for and which stays
# the final line of a successful run.
print_coverage_notice
print_dirty_warning

echo ""
echo "==> CI-FAST: ALL PASSED"
