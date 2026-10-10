#!/usr/bin/env bash
# ci-fast.sh — WS-F4 QA iteration tier. Since ADR-053 a thin wrapper over the CI driver:
#
#     scripts/ci fast --budget 0 --markers [args…]
#
# The INNER-LOOP gate: toolchain → apply-check → spikes → samen_core → samen_web ONLY (the `fast`
# steps of ci/steps.conf; `scripts/ci list fast`). It deliberately SKIPS the slow tail of the full
# `./ci.sh`: the gen_app generative probes, the demo dogfood + verifier gate, the
# driftwood/pawchart vertical gates, dialyzer, the adapters. Use it for fast feedback while
# working in samen_core/samen_web; run the FULL `./ci.sh` (or `scripts/ci pr`) before a
# milestone — ci-fast.sh is NOT a substitute for the root gate, and its final driver line says
# so (`NOT PR-READY`). For "near what I touched" across the whole tree, `scripts/ci quick` is
# usually the better inner loop: it is diff-aware and dependency-aware.
#
# That paragraph is a COMMENT, and nobody executing this script reads it. So the skipped set is
# also computed and PRINTED on every run, and uncommitted work under a skipped app raises a
# warning naming the app — see the coverage guard below.
#
# Like ci.sh: local Postgres required; compiles with --warnings-as-errors; exits non-zero on a
# failure and ends `CI-FAST: ALL PASSED` on success — printed only when the driver exited 0 AND
# its _ci/last.json verdict is PASS. One { … } block, parsed whole before it runs.
{
  set -uo pipefail
  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  CI_DRIVER="${SAMEN_CI_DRIVER:-$REPO_ROOT/scripts/ci}"   # SAMEN_CI_DRIVER: test seam (ci_test.sh C6)
  CI_HOME="${SAMEN_CI_HOME:-$REPO_ROOT/_ci}"

  # --- coverage guard: make the blind spot executable, not just documented -----
  #
  # ci-fast.sh runs a SUBSET of the tree, and a comment saying so is invisible to
  # anyone actually running it. That blind spot has already cost this project a
  # phase that closed 6/6 "verified" while the full gate was red: every node in it
  # gated on ci-fast.sh, so driftwood was never exercised at all.
  #
  # The covered set is therefore DERIVED, never listed by hand — a hand-copied scope
  # is precisely what drifts out of sync with what the script really runs, which is
  # the failure mode already hit twice. Since ADR-053 the ground truth is the step
  # manifest: every project directory a `fast`-mode step runs in
  # (`scripts/ci list fast --apps`, read from ci/steps.conf — the same file the
  # driver executes). Add a fast step and its app drops off the uncovered list by
  # itself; remove one and the app reappears on it.
  #
  # The universe is every mix project in the tree — any directory holding a
  # mix.exs. A newly added app is thus uncovered BY DEFAULT, which is the
  # fail-closed direction: the guard over-reports before it under-reports.
  #
  # Cheap by construction: one manifest read, one find, one git status. No
  # compiles, no test runs, nothing that slows the fast path down.

  # Apps the fast mode actually enters, read off the manifest the driver runs.
  COVERED_APPS="$("$CI_DRIVER" list fast --apps 2>/dev/null | sort -u || true)"

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
        DIRTY_UNCOVERED="$DIRTY_UNCOVERED$app"$'\n'
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

  rm -f "$CI_HOME/last.json"   # a stale PASS verdict can never vouch for this run
  "$CI_DRIVER" fast --budget 0 --markers "$@"
  rc=$?
  verdict="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("verdict", ""))' "$CI_HOME/last.json" 2>/dev/null || true)"

  if [[ $rc -ne 0 || "$verdict" != "PASS" ]]; then
    echo ""
    echo "==> CI-FAST: FAILED — scripts/ci exit $rc, verdict ${verdict:-none} (see _ci/last.json; logs in _ci/logs/). NOT all passed."
    exit 1
  fi

  # Re-printed here because minutes of suite output have scrolled the pre-run
  # banner off screen, and the last thing a reader sees is what they act on. Both
  # print BEFORE the ALL PASSED line, which other things grep for and which stays
  # the final line of a successful run.
  print_coverage_notice
  print_dirty_warning

  echo ""
  echo "==> CI-FAST: ALL PASSED"
  exit 0
}
