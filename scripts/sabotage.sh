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
# ── SELECTION / FILTER MODES (additive; DEFAULT no-arg run is UNCHANGED) ──────
# With no flags this replays ALL patches, in filename order, exactly as before.
# Flags narrow the set — a FILTERED run certifies ONLY its subset; total
# coverage still requires a full (unfiltered) run, which at 212 patches exceeds
# the 600s single tool-call ceiling and so must be run BACKGROUNDED or in
# `--app`/`--range` CHUNKS (see docs/adr/ADR-045 §4.2). Different FLAGS compose
# as an intersection (e.g. --app + --range); repeating the SAME flag is an
# error — use two separate runs for two ranges.
#   --app <name>            only patches whose APP: header == <name>
#   --range <lo>-<hi>       only patches whose FILENAME number (the NNN in
#   --from <lo> --to <hi>     NNN-slug.patch — stable, matches how we say
#                             "sabotage 205") is in [lo,hi] INCLUSIVE. --from/
#                             --to are an alternate spelling; a lone --from is
#                             lo..∞, a lone --to is 0..hi.
#   --touching <path>...    only patches whose touched-file set (the +++ b/…
#   --touching-file <file>    paths) INTERSECTS the given repo-relative paths
#                             (or the newline-separated paths in <file>).
#   --changed [<ref>]       derive the touched set from the UNION of `git diff
#                             --name-only <ref>` and `git ls-files --others
#                             --exclude-standard` (default ref: origin/main if it
#                             exists, else HEAD~1) — "certify the sabotages
#                             relevant to my diff". Selects patches touching any
#                             changed file. The untracked half is LOAD-BEARING:
#                             `git diff` never lists new files, so without it a
#                             batch that ADDS a module + its sabotages selects
#                             NONE of them (the A3 247/248/249 miss). The banner
#                             says `changed=<ref>+untracked` so the union is
#                             visible in the run's own output.
#   --list, --dry-run       print the SELECTED patch set (name + resolved APP,
#                             and the count) and EXIT — no patch is applied and
#                             no test runs. Fast proof of what a filter will run.
#
# The header preflight (scripts/sabotage_lint.sh) ALWAYS runs over ALL patches,
# even on a filtered run: a missing APP/TEST_FILES/MUST_FAIL header anywhere is
# a latent bug (the "patch 67 missing header aborts silently" class), so it is
# checked regardless of which subset was selected.
#
# A filtered run's success line is deliberately DISTINCT from the full-harness
# line so a partial run can never be mistaken for full certification, e.g.
#   SABOTAGE HARNESS: ALL PASSED (97 of 212 sabotages — FILTERED: app=samen_web)
# vs the full-run line:
#   SABOTAGE HARNESS: ALL PASSED (212 sabotages flipped their named tests; byte-exact restores)
#
# Wiring: a permanent OPT-IN root ci.sh step, gated by SAMEN_SABOTAGE=1 (the
# WS-D generative probes run unconditionally; this one deliberately breaks the
# tree and re-runs targeted suites, so it is opt-in — gates run it explicitly).
# ci.sh invokes it with NO flags → the full run, unchanged. Direct invocation
# runs regardless of the env var.
#
# Later gates: add the new sabotage as a .patch here (headers + git diff),
# re-run this harness, and spend gate judgment ONLY on new vacuity hunting.
#
# Needs: local Postgres (the targeted suites are DB-backed). Exits non-zero on
# the first sabotage that fails to flip, fails to name its tests, or leaves
# residue — and on an unknown flag or an empty selection.
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

usage() {
  echo "Usage: sabotage.sh [--app <name>] [--range <lo>-<hi> | --from <lo> --to <hi>]"
  echo "                   [--touching <path>... | --touching-file <file> | --changed [<ref>]]"
  echo "                   [--list | --dry-run]"
  echo ""
  sed -n '22,44p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

arg_err() {
  echo "sabotage.sh: $1" >&2
  echo "" >&2
  echo "Run 'sabotage.sh --list' to preview a selection, or see the header of this" >&2
  echo "script for the full flag reference." >&2
  exit 2
}

meta() { # meta <patch> <key> -> values, one per line
  sed -n "s/^# $2: //p" "$1"
}

# touched_paths <patch> -> repo-relative paths the patch writes, one per line.
# Normalizes the plain-diff `+++ b/path<TAB>timestamp` form (6 patches ship this
# way) down to the bare path — so the SHA baseline actually hashes a real file
# (not a tab-suffixed non-path that silently skips the check) AND so --touching
# matching compares clean repo-relative paths.
touched_paths() { # touched_paths <patch>
  sed -n 's|^+++ b/||p' "$1" | sed 's/\t.*//'
}

sha_files() { # sha_files <listfile> <outfile>
  : > "$2"
  while IFS= read -r f; do
    shasum -a 256 "$REPO_ROOT/$f" >> "$2"
  done < "$1"
}

# ── argument parsing ─────────────────────────────────────────────────────────
FILTER_APP=""
RANGE_LO=""
RANGE_HI=""
RANGE_ACTIVE=0
TOUCH_MODE=0
TOUCH_DESC=""
TOUCH_SET="$WORK/touch_set"
: > "$TOUCH_SET"
LIST_ONLY=0
SEEN_APP=0; APP_FIRST=""
SEEN_RANGE=0; RANGE_FIRST=""
SEEN_FROM=0; FROM_FIRST=""
SEEN_TO=0; TO_FIRST=""
SEEN_TOUCHING_FILE=0; TOUCHING_FILE_FIRST=""
SEEN_CHANGED=0; CHANGED_FIRST=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      shift; [[ $# -gt 0 ]] || arg_err "--app requires a name"
      if [[ $SEEN_APP -eq 1 ]]; then
        arg_err "--app given twice: '$APP_FIRST' and '$1' — repeating the same flag is an error; run separate invocations for separate apps"
      fi
      FILTER_APP="$1"; APP_FIRST="$1"; SEEN_APP=1; shift ;;
    --range)
      shift; [[ $# -gt 0 ]] || arg_err "--range requires <lo>-<hi>"
      if [[ "$1" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        if [[ $SEEN_RANGE -eq 1 ]]; then
          arg_err "--range given twice: '$RANGE_FIRST' and '$1' — repeating the same flag is an error; use two separate runs for two ranges"
        fi
        RANGE_LO="${BASH_REMATCH[1]}"; RANGE_HI="${BASH_REMATCH[2]}"; RANGE_ACTIVE=1
        RANGE_FIRST="$1"; SEEN_RANGE=1
      else
        arg_err "--range wants <lo>-<hi> (e.g. --range 200-212), got: $1"
      fi
      shift ;;
    --from)
      shift; [[ $# -gt 0 ]] || arg_err "--from requires a number"
      [[ "$1" =~ ^[0-9]+$ ]] || arg_err "--from wants a number, got: $1"
      if [[ $SEEN_FROM -eq 1 ]]; then
        arg_err "--from given twice: '$FROM_FIRST' and '$1' — repeating the same flag is an error; use two separate runs for two ranges"
      fi
      RANGE_LO="$1"; RANGE_ACTIVE=1; FROM_FIRST="$1"; SEEN_FROM=1; shift ;;
    --to)
      shift; [[ $# -gt 0 ]] || arg_err "--to requires a number"
      [[ "$1" =~ ^[0-9]+$ ]] || arg_err "--to wants a number, got: $1"
      if [[ $SEEN_TO -eq 1 ]]; then
        arg_err "--to given twice: '$TO_FIRST' and '$1' — repeating the same flag is an error; use two separate runs for two ranges"
      fi
      RANGE_HI="$1"; RANGE_ACTIVE=1; TO_FIRST="$1"; SEEN_TO=1; shift ;;
    --touching)
      shift
      [[ $# -gt 0 && "$1" != --* ]] || arg_err "--touching requires one or more repo-relative paths"
      local_paths=0
      while [[ $# -gt 0 && "$1" != --* ]]; do
        printf '%s\n' "$1" >> "$TOUCH_SET"; local_paths=$((local_paths + 1)); shift
      done
      TOUCH_MODE=1
      TOUCH_DESC="touching=${local_paths} path(s)" ;;
    --touching-file)
      shift; [[ $# -gt 0 ]] || arg_err "--touching-file requires a file"
      [[ -f "$1" ]] || arg_err "--touching-file: no such file: $1"
      if [[ $SEEN_TOUCHING_FILE -eq 1 ]]; then
        arg_err "--touching-file given twice: '$TOUCHING_FILE_FIRST' and '$1' — repeating the same flag is an error; run separate invocations for separate files"
      fi
      grep -v '^[[:space:]]*$' "$1" >> "$TOUCH_SET" || true
      TOUCH_MODE=1
      TOUCH_DESC="touching-file=$(basename "$1")"
      TOUCHING_FILE_FIRST="$1"; SEEN_TOUCHING_FILE=1; shift ;;
    --changed)
      shift
      changed_ref=""
      if [[ $# -gt 0 && "$1" != --* ]]; then changed_ref="$1"; shift; fi
      if [[ -z "$changed_ref" ]]; then
        if git -C "$REPO_ROOT" rev-parse --verify -q origin/main >/dev/null; then
          changed_ref="origin/main"
        else
          changed_ref="HEAD~1"
        fi
      fi
      git -C "$REPO_ROOT" rev-parse --verify -q "$changed_ref" >/dev/null \
        || arg_err "--changed: not a valid git ref: $changed_ref"
      if [[ $SEEN_CHANGED -eq 1 ]]; then
        arg_err "--changed given twice: '$CHANGED_FIRST' and '$changed_ref' — repeating the same flag is an error; run separate invocations for separate refs"
      fi
      # The changed set is the UNION of tracked modifications AND untracked-but-not-
      # ignored files. `git diff --name-only` lists ONLY tracked paths, so a batch that
      # ADDS files (a new lib module + the sabotages that target it) silently
      # under-selected: A3's own new patches 247/248/249 were missed by `--changed`
      # because their only touched files were brand-new, and a verifier trusting
      # `--changed` alone would have certified the batch without ever replaying them.
      # An under-selecting verifier primitive is worse than no primitive, so the union
      # is taken here (and reflected in --list and in the FILTERED banner below).
      git -C "$REPO_ROOT" diff --name-only "$changed_ref" >> "$TOUCH_SET"
      git -C "$REPO_ROOT" ls-files --others --exclude-standard >> "$TOUCH_SET"
      TOUCH_MODE=1
      TOUCH_DESC="changed=${changed_ref}+untracked"
      CHANGED_FIRST="$changed_ref"; SEEN_CHANGED=1 ;;
    --list|--dry-run)
      LIST_ONLY=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      arg_err "unknown flag: $1" ;;
  esac
done

# Normalize a one-sided --from/--to into a full inclusive range.
if [[ $RANGE_ACTIVE -eq 1 ]]; then
  [[ -n "$RANGE_LO" ]] || RANGE_LO=0
  [[ -n "$RANGE_HI" ]] || RANGE_HI=999999
  if (( RANGE_LO > RANGE_HI )); then
    arg_err "--range/--from/--to: lo ($RANGE_LO) is greater than hi ($RANGE_HI)"
  fi
fi

FILTER_ACTIVE=0
[[ -n "$FILTER_APP" || $RANGE_ACTIVE -eq 1 || $TOUCH_MODE -eq 1 ]] && FILTER_ACTIVE=1

# Human-readable selection label (for the effective-selection line + success line).
filter_label() {
  local parts=()
  [[ -n "$FILTER_APP" ]] && parts+=("app=$FILTER_APP")
  [[ $RANGE_ACTIVE -eq 1 ]] && parts+=("range=${RANGE_LO}-${RANGE_HI}")
  [[ $TOUCH_MODE -eq 1 ]] && parts+=("$TOUCH_DESC")
  local IFS=', '
  echo "${parts[*]}"
}

# patch_touches <patch> — 0 if the patch's touched set intersects $TOUCH_SET.
patch_touches() {
  local pf
  while IFS= read -r pf; do
    [[ -n "$pf" ]] || continue
    grep -qxF "$pf" "$TOUCH_SET" && return 0
  done < <(touched_paths "$1")
  return 1
}

# select_patch <patch> — 0 if the patch passes EVERY active filter (intersection).
select_patch() {
  local patch="$1" name num n app
  name="$(basename "$patch")"

  if [[ -n "$FILTER_APP" ]]; then
    app="$(meta "$patch" APP)"
    [[ "$app" == "$FILTER_APP" ]] || return 1
  fi

  if [[ $RANGE_ACTIVE -eq 1 ]]; then
    num="${name%%-*}"
    [[ "$num" =~ ^[0-9]+$ ]] || return 1
    n=$((10#$num))
    (( n >= RANGE_LO && n <= RANGE_HI )) || return 1
  fi

  if [[ $TOUCH_MODE -eq 1 ]]; then
    patch_touches "$patch" || return 1
  fi

  return 0
}

# ── header preflight ─────────────────────────────────────────────────────────
# ALWAYS lint ALL patches, even under a filter: a missing header anywhere is a
# latent bug (patch 67 shipped this way once and silently swallowed patches
# 68-75). Cheap (milliseconds, no git apply / mix test), so filtering never
# lowers this protection.
"$REPO_ROOT/scripts/sabotage_lint.sh" || fail "header preflight failed (see above) — no patch was applied"

# ── build the selection ──────────────────────────────────────────────────────
grand_total=0
selected=()
for patch in "$SABOTAGE_DIR"/*.patch; do
  [[ -e "$patch" ]] || continue
  grand_total=$((grand_total + 1))
  if select_patch "$patch"; then
    selected+=("$patch")
  fi
done
[[ $grand_total -gt 0 ]] || fail "no patches found in $SABOTAGE_DIR"
sel_count=${#selected[@]}

# ── --list / --dry-run: prove the selection, apply/run nothing ───────────────
if [[ $LIST_ONLY -eq 1 ]]; then
  if [[ $FILTER_ACTIVE -eq 1 ]]; then
    echo "SABOTAGE SELECTION (FILTERED: $(filter_label)) — $sel_count of $grand_total patches:"
  else
    echo "SABOTAGE SELECTION (default: full harness) — $sel_count of $grand_total patches:"
  fi
  if [[ $sel_count -gt 0 ]]; then
    for patch in "${selected[@]}"; do
      printf '  %-64s app=%s\n' "$(basename "$patch")" "$(meta "$patch" APP)"
    done
  fi
  echo ""
  echo "SABOTAGE SELECTION: $sel_count of $grand_total patches selected (dry-run — nothing applied)"
  exit 0
fi

# An empty selection certifies nothing — fail loudly (never a silent green).
if [[ $sel_count -eq 0 ]]; then
  fail "selection is empty ($sel_count of $grand_total) for filter [$(filter_label)] — nothing to certify"
fi

# Announce the effective selection at the start of any FILTERED run (the default
# full run stays byte-identical: it prints no such preamble).
if [[ $FILTER_ACTIVE -eq 1 ]]; then
  echo "SABOTAGE HARNESS: FILTERED run — $sel_count of $grand_total patches selected [$(filter_label)]"
  echo "  (a filtered run certifies ONLY this subset; full coverage needs an unfiltered/background run)"
fi

# ── replay the selected patches ──────────────────────────────────────────────
total=0

for patch in "${selected[@]}"; do
  name="$(basename "$patch")"
  app="$(meta "$patch" APP)"
  test_files="$(meta "$patch" TEST_FILES)"
  [[ -n "$app" && -n "$test_files" ]] || fail "$name: missing APP/TEST_FILES header"
  meta "$patch" MUST_FAIL > "$WORK/must_fail"
  [[ -s "$WORK/must_fail" ]] || fail "$name: no MUST_FAIL headers"

  echo ""
  echo "==> sabotage $name (app: $app)"

  # 1. Byte-exact baseline of every file the patch touches.
  touched_paths "$patch" > "$WORK/touched"
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

[[ $total -gt 0 ]] || fail "no patches replayed"

echo ""
if [[ $FILTER_ACTIVE -eq 1 ]]; then
  echo "SABOTAGE HARNESS: ALL PASSED ($total of $grand_total sabotages — FILTERED: $(filter_label))"
else
  echo "SABOTAGE HARNESS: ALL PASSED ($total sabotages flipped their named tests; byte-exact restores)"
fi
