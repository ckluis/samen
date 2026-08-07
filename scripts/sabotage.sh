#!/usr/bin/env bash
# scripts/sabotage.sh — WS-E E2i.1 sabotage harness (gate automation).
#
# Replays every SHIPPED gate sabotage as a committed patch and proves each still
# FLIPS its named tests — the standing anti-tautology ritual of the E1.4/E2.3
# (and every earlier) adversarial gate, converted from by-hand judgment into
# permanent infrastructure. For each scripts/sabotages/*.patch:
#
#   1. SHA-256 every file the patch touches (the byte-exact baseline),
#   2. apply the patch (git apply),
#   3. run `mix test <TEST_FILES>` in the patch's APP — the run MUST fail,
#   4. every MUST_FAIL substring MUST appear among the failed-test headers
#      (the named tests flipped — not just "something broke"),
#   5. revert (git apply -R) and re-SHA — byte-exact restore, zero residue.
#
# Patch metadata lives in `# KEY: value` header lines inside each .patch
# (git apply ignores everything before the first `diff --git`):
#   APP:        the app dir to run tests in (samen_core | samen_web | ...)
#   TEST_FILES: space-separated test files (relative to APP) that hold the named tests
#   MUST_FAIL:  a substring of a test name that MUST be among the failures (repeatable)
#
# Wiring: a permanent OPT-IN root ci.sh step, gated by SAMEN_SABOTAGE=1 (the
# WS-D generative probes run unconditionally; this one deliberately breaks the
# tree 5x and re-runs targeted suites, so it is opt-in — gates run it
# explicitly). Direct invocation runs regardless of the env var.
#
# Later gates: add the new sabotage as a .patch here (headers + git diff),
# re-run this harness, and spend gate judgment ONLY on new vacuity hunting.
#
# Needs: local Postgres (the targeted suites are DB-backed). Exits non-zero on
# the first sabotage that fails to flip, fails to name its tests, or leaves
# residue.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SABOTAGE_DIR="$REPO_ROOT/scripts/sabotages"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/samen_sabotage.XXXXXX")"

APPLIED_PATCH=""

cleanup() {
  # Never leave a sabotaged tree behind — revert the in-flight patch on ANY exit.
  if [[ -n "$APPLIED_PATCH" ]]; then
    echo "!! cleanup: reverting in-flight patch $APPLIED_PATCH"
    (cd "$REPO_ROOT" && git apply -R "$APPLIED_PATCH") || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

fail() {
  echo ""
  echo "SABOTAGE HARNESS: FAILED — $1"
  exit 1
}

# T75 closing round: a fast header preflight (milliseconds, no git apply, no
# mix test) — checks EVERY patch's APP/TEST_FILES/MUST_FAIL headers up front,
# by name, before any patch is applied. Without this, a single patch missing
# a header (patch 67 shipped this way once) aborts the main loop mid-way and
# every patch after it silently never runs at all.
"$REPO_ROOT/scripts/sabotage_lint.sh" || fail "header preflight failed (see above) — no patch was applied"

meta() { # meta <patch> <key> -> values, one per line
  sed -n "s/^# $2: //p" "$1"
}

sha_files() { # sha_files <listfile> <outfile>
  : > "$2"
  while IFS= read -r f; do
    shasum -a 256 "$REPO_ROOT/$f" >> "$2"
  done < "$1"
}

total=0

for patch in "$SABOTAGE_DIR"/*.patch; do
  name="$(basename "$patch")"
  app="$(meta "$patch" APP)"
  test_files="$(meta "$patch" TEST_FILES)"
  [[ -n "$app" && -n "$test_files" ]] || fail "$name: missing APP/TEST_FILES header"
  meta "$patch" MUST_FAIL > "$WORK/must_fail"
  [[ -s "$WORK/must_fail" ]] || fail "$name: no MUST_FAIL headers"

  echo ""
  echo "==> sabotage $name (app: $app)"

  # 1. Byte-exact baseline of every file the patch touches.
  sed -n 's|^+++ b/||p' "$patch" > "$WORK/touched"
  [[ -s "$WORK/touched" ]] || fail "$name: could not parse touched files"
  sha_files "$WORK/touched" "$WORK/sha_before"

  # 2. Apply.
  (cd "$REPO_ROOT" && git apply "$patch") || fail "$name: patch did not apply"
  APPLIED_PATCH="$patch"

  # 3. The targeted suite MUST fail under sabotage.
  out="$WORK/${name%.patch}.out"
  # shellcheck disable=SC2086
  (cd "$REPO_ROOT/$app" && mix test $test_files) > "$out" 2>&1
  status=$?

  # 5a. Revert before judging, so a failed assertion never strands a dirty tree.
  (cd "$REPO_ROOT" && git apply -R "$patch") || fail "$name: revert failed — TREE MAY BE DIRTY"
  APPLIED_PATCH=""

  if [[ $status -eq 0 ]]; then
    tail -20 "$out"
    fail "$name: suite PASSED under sabotage — the guarantee did not flip (vacuous gate)"
  fi

  # 4. The NAMED tests are among the failures (not just any breakage).
  grep -E '^[[:space:]]*[0-9]+\) test' "$out" > "$WORK/failed_tests" || {
    tail -30 "$out"
    fail "$name: suite failed but no test-failure headers found (compile error?)"
  }

  while IFS= read -r must; do
    if grep -qF "$must" "$WORK/failed_tests"; then
      echo "    flip confirmed: $must"
    else
      cat "$WORK/failed_tests"
      fail "$name: named test did not flip: $must"
    fi
  done < "$WORK/must_fail"

  # 5b. Byte-exact restore — zero residue.
  sha_files "$WORK/touched" "$WORK/sha_after"
  diff -q "$WORK/sha_before" "$WORK/sha_after" > /dev/null ||
    fail "$name: SHA mismatch after revert — residue left behind"
  echo "    restore: byte-exact (sha-256 verified)"

  total=$((total + 1))
done

[[ $total -gt 0 ]] || fail "no patches found in $SABOTAGE_DIR"

echo ""
echo "SABOTAGE HARNESS: ALL PASSED ($total sabotages flipped their named tests; byte-exact restores)"
