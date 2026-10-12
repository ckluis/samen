#!/usr/bin/env bash
# scripts/sabotage new — turn a sabotage EDIT in the working tree into a headered, proven patch (ADR-053 §2.7, P3).
#
# Building a patch by hand went wrong in ADR-052: the author edited a file that already held UNCOMMITTED
# fixes, took `git diff`, then `git checkout`-ed the file — so the patch carried the fix as well as the
# sabotage, and the checkout wiped the fix. This command does it in the only safe order, mechanically:
#
#   1. STAGE your fix           git add <the files holding your real change>
#   2. SABOTAGE the lib file(s) edit them in the working tree — ONLY the sabotage, unstaged
#   3. scripts/sabotage new <slug> --app <app> --test-file <path under app> --must-fail "<literal test name>" <file>…
#
# The patch is `git diff` of the named files AGAINST THE INDEX, so staged (and committed) work is never
# captured; the files are then restored FROM THE INDEX, byte-exact, and nothing else is touched.
#
# USAGE
#   scripts/sabotage new <slug> --app <app> --test-file <file> [--test-file <file>…]
#                        --must-fail "<test name>" [--must-fail "<test name>"…]
#                        [--number <n>] [--description "<why this sabotage matters>"] [--base <ref>]
#                        [--] <lib file>…
#     <slug>        lowercase words joined by dashes — the patch becomes NNN-<slug>.patch
#     --app         the app dir the tests run in (samen_core, samen_web, …)
#     --test-file   a test file RELATIVE TO THE APP that holds the named test (repeatable)
#     --must-fail   a LITERAL substring of the test's name (repeatable). The harness matches it with
#                   `grep -F` against the failed-test headers and the double sweep against the app's
#                   test SOURCE, so a name built by interpolation ("... #{var} ...") can never match.
#     --number      default: one more than the highest existing patch number
#     --description one sentence for the `# SABOTAGE:` header (default: the slug as words)
#     --base        the previous HEAD the new patch must anchor against (default origin/main)
#     <lib file>…   repo-relative, tracked, each carrying a working-tree edit against the index
#
# A PATCH IS KEPT ONLY IF ALL OF THESE HOLD (otherwise it is deleted and the working tree is left exactly
# as it was, your sabotage edit included, so you can fix and re-run):
#   * every MUST_FAIL is found literally (grep -F) in the named test files — not interpolated;
#   * the patch passes the header lint and `git apply --check` against the restored tree;
#   * it ANCHORS per the double sweep against --base (scripts/double-sweep.sh; this command asks the
#     script itself, it does not re-implement the rule): it must not apply at the base, or name a test
#     that does not exist there — a patch that would fire in BOTH baselines tests nothing this branch added;
#   * `scripts/sabotage.sh --range N-N` flips the NAMED tests and restores byte-exact — and the failure is a
#     NAMED test failure: a sabotage that breaks the compile or a migration ("suite failed but no
#     test-failure headers found") cannot show a named flip and is refused;
#   * the BASELINE is green: the same test files PASS with the sabotage removed (this is what catches an
#     unstaged fix that was captured into the patch — without the fix the tests fail).
# On success it runs `scripts/counts --write` for the sabotage counts in CLAUDE.md. The new patch is left
# untracked (git add it with the rest of your change).
#
# Exit: 0 created · 1 refused (reason printed) · 2 usage
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SAB_DIR="$REPO_ROOT/scripts/sabotages"
cd "$REPO_ROOT" || exit 2

usage() { sed -n '2,/^# Exit:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
usage_err() { echo "sabotage new: $1" >&2; echo "" >&2; echo "(scripts/sabotage new --help for the workflow)" >&2; exit 2; }

SLUG=""; APP=""; NUMBER=""; DESC=""; BASE="origin/main"
TEST_FILES=(); MUST=(); FILES=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --app) [[ $# -ge 2 ]] || usage_err "--app needs a value"; APP="$2"; shift 2 ;;
    --test-file) [[ $# -ge 2 ]] || usage_err "--test-file needs a value"; TEST_FILES+=("$2"); shift 2 ;;
    --must-fail) [[ $# -ge 2 ]] || usage_err "--must-fail needs a value"; MUST+=("$2"); shift 2 ;;
    --number) [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || usage_err "--number wants an integer"; NUMBER=$((10#$2)); shift 2 ;;
    --description) [[ $# -ge 2 ]] || usage_err "--description needs a value"; DESC="$2"; shift 2 ;;
    --base) [[ $# -ge 2 ]] || usage_err "--base needs a ref"; BASE="$2"; shift 2 ;;
    --) shift; while [[ $# -gt 0 ]]; do FILES+=("$1"); shift; done ;;
    -*) usage_err "unknown flag: $1" ;;
    *) if [[ -z "$SLUG" ]]; then SLUG="$1"; else FILES+=("$1"); fi; shift ;;
  esac
done
[[ -n "$SLUG" ]] || usage_err "a slug is required (the patch becomes NNN-<slug>.patch)"
[[ "$SLUG" =~ ^[a-z0-9][a-z0-9-]*$ ]] || usage_err "slug must be lowercase words joined by dashes, got: $SLUG"
[[ -n "$APP" ]] || usage_err "--app is required"
[[ ${#TEST_FILES[@]} -gt 0 ]] || usage_err "at least one --test-file is required"
[[ ${#MUST[@]} -gt 0 ]] || usage_err "at least one --must-fail is required"
[[ ${#FILES[@]} -gt 0 ]] || usage_err "name at least one lib file carrying the sabotage edit"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/samen_sabotage_new.XXXXXX")"
PATCH=""            # set once written
SNAP="$WORK/snap"   # the working-tree bytes of the named files, restored on ANY refusal
SNAPPED=0
DONE=0

restore_snapshot() {
  [[ -f "$WORK/CLAUDE.md.snap" ]] && cp -p "$WORK/CLAUDE.md.snap" "$REPO_ROOT/CLAUDE.md"
  [[ $SNAPPED -eq 1 ]] || return 0
  local f
  for f in "${FILES[@]}"; do
    mkdir -p "$(dirname "$REPO_ROOT/$f")"
    cp -p "$SNAP/$f" "$REPO_ROOT/$f"
  done
}
cleanup() {
  local rc=$?
  if [[ $DONE -eq 0 ]]; then
    [[ -n "$PATCH" ]] && rm -f "$PATCH"
    restore_snapshot
  fi
  rm -rf "$WORK"
  return $rc
}
trap cleanup EXIT
trap 'echo "sabotage new: interrupted — restoring your tree" >&2; exit 130' INT TERM

refuse() {
  echo "" >&2
  echo "SABOTAGE NEW: REFUSED — $1" >&2
  shift
  local l; for l in "$@"; do echo "  $l" >&2; done
  if [[ $DONE -eq 0 && $SNAPPED -eq 1 ]]; then
    echo "  (no patch was kept; your working tree is exactly as you left it, sabotage edit included)" >&2
  fi
  exit 1
}

# ── 1. cheap, read-only validation ───────────────────────────────────────────
[[ "$APP" != */* && -d "$APP" ]] || refuse "--app $APP: no such app directory ($REPO_ROOT/$APP)"
for tf in "${TEST_FILES[@]}"; do
  [[ -f "$APP/$tf" ]] || refuse "--test-file $tf: no such file in $APP/ (the path is relative to the app, e.g. test/foo_test.exs)"
done
for mf in "${MUST[@]}"; do
  if [[ -z "$mf" || "$mf" == *$'\n'* ]]; then refuse "--must-fail must be one non-empty line"; fi
  if [[ "$mf" == *'#{'* ]]; then
    refuse "--must-fail \"$mf\" contains an interpolation (#{…})." \
      "MUST_FAIL is matched with grep -F against the app's test SOURCE (the double sweep's positive control)" \
      "and against the failed-test header the harness prints. A test named \"... #{var} ...\" can never match" \
      "either, so the harness would report a missing positive control. Name a literal PREFIX or SUFFIX of the" \
      "test name instead (any substring that appears verbatim in the source), or give the test a literal name."
  fi
  found=0
  for tf in "${TEST_FILES[@]}"; do grep -qF -- "$mf" "$APP/$tf" && found=1; done
  [[ $found -eq 1 ]] || refuse "--must-fail \"$mf\" is not found literally (grep -F) in ${TEST_FILES[*]}." \
      "It must be a substring of a test name exactly as written in the source of the named test file(s)." \
      "(A name built by interpolation, a typo, or a test in another file all look like this.)"
done
for f in "${FILES[@]}"; do
  [[ "$f" != /* && "$f" != *..* ]] || refuse "$f: pass repo-relative paths"
  [[ "$f" != scripts/sabotages/* ]] || refuse "$f: a sabotage cannot sabotage the sabotage corpus"
  [[ -f "$f" ]] || refuse "$f: no such file"
  git ls-files --error-unmatch -- "$f" >/dev/null 2>&1 \
    || refuse "$f is not tracked. \`git add -N $f\` (or add it) first so there is an index version to diff against."
  if git diff --quiet -- "$f"; then
    refuse "$f has no working-tree edit against the index — nothing to turn into a sabotage." \
      "Workflow: 1) git add your real fix  2) edit the lib file to SABOTAGE it (unstaged)  3) run this command."
  fi
done

# the next number
HIGHEST="$(ls "$SAB_DIR" | sed -n 's/^\([0-9][0-9]*\)-.*\.patch$/\1/p' | sort -n | tail -1)"
[[ -n "$HIGHEST" ]] || HIGHEST=0
if [[ -z "$NUMBER" ]]; then NUMBER=$((10#$HIGHEST + 1)); fi
if ls "$SAB_DIR" | grep -qE "^0*${NUMBER}-.*\.patch$"; then
  refuse "patch number $NUMBER is already taken ($(ls "$SAB_DIR" | grep -E "^0*${NUMBER}-" | head -1)); omit --number to take $((10#$HIGHEST + 1))"
fi
NAME="${NUMBER}-${SLUG}.patch"
PATCH="$SAB_DIR/$NAME"
[[ ! -e "$PATCH" ]] || refuse "$NAME already exists"

# ── 2. capture: working tree vs INDEX, then restore FROM THE INDEX ───────────
mkdir -p "$SNAP"
for f in "${FILES[@]}"; do
  mkdir -p "$SNAP/$(dirname "$f")"
  cp -p "$f" "$SNAP/$f"
done
SNAPPED=1
git diff --no-color --no-ext-diff --binary -- "${FILES[@]}" > "$WORK/body.diff" || refuse "git diff failed"
grep -q '^diff --git' "$WORK/body.diff" || refuse "git produced no diff for ${FILES[*]}"
grep -q '^GIT binary patch' "$WORK/body.diff" && refuse "the edit is binary — a sabotage must be a text edit"

git checkout-index -f -- "${FILES[@]}" || refuse "could not restore ${FILES[*]} from the index"
git diff --quiet -- "${FILES[@]}" || refuse "restore from the index left a diff behind"

# ── 3. the header, in the exact existing format ──────────────────────────────
[[ -n "$DESC" ]] || DESC="${SLUG//-/ }"
{
  printf '%s\n' "$DESC" | fold -s -w 96 | sed '1s/^/# SABOTAGE: /; 2,$s/^/#   /'
  echo "#"
  echo "# Flips the named test(s)."
  echo "# APP: $APP"
  echo "# TEST_FILES: ${TEST_FILES[*]}"
  for mf in "${MUST[@]}"; do echo "# MUST_FAIL: $mf"; done
  cat "$WORK/body.diff"
} > "$PATCH"

bash scripts/sabotage_lint.sh >"$WORK/lint.out" 2>&1 || refuse "the header lint failed on the new patch" "$(tail -3 "$WORK/lint.out")"
git apply --check "$PATCH" 2>"$WORK/apply.err" || refuse "the new patch does not apply to the restored tree" "$(head -3 "$WORK/apply.err")"

# ── 3b. the counts: the guard tests check CLAUDE.md against the patch directory, so the new patch must be
#        counted BEFORE the replay and the baseline run (restored with everything else on a refusal)
FIXERS="sabotages"
grep -q 'ci_driver_guard_test.exs' <<<"${TEST_FILES[*]}" && FIXERS="sabotages,driver_sabotages"
COUNTS_NOTE="(scripts/counts not present)"
if [[ -x scripts/counts ]]; then
  [[ -f CLAUDE.md ]] && cp -p CLAUDE.md "$WORK/CLAUDE.md.snap"
  COUNTS_NOTE="$(bash scripts/counts --write --only "$FIXERS" 2>&1 | tail -3 | tr '\n' ' ')"
fi

# ── 4. anchor — ask the double sweep itself ───────────────────────────────────
git rev-parse --verify -q "${BASE}^{commit}" >/dev/null \
  || refuse "--base $BASE does not exist here, so the patch cannot be anchored (git fetch origin, or pass --base <ref>)"
bash scripts/double-sweep.sh --base "$BASE" --work "$WORK/ds" --quiet > "$WORK/ds.out" 2>&1
ds_rc=$?
SECTION="$(awk -v n="=== $NAME " 'index($0, n) == 1 {on=1; print; next} /^=== / {on=0} on {print}' "$WORK/ds/anchor.txt" 2>/dev/null)"
if ! printf '%s\n' "$SECTION" | grep -q '^  ANCHORED:'; then
  refuse "the double sweep does not anchor $NAME against $BASE (double-sweep exit $ds_rc)." \
    "A new patch must anchor on code or tests THIS BRANCH adds: it must fail to apply at $BASE, or name a" \
    "test that does not exist there. Otherwise it would fire in both baselines and prove nothing new." \
    "$(grep -E "$NAME|POSITIVE CONTROL|MUST_FAIL not found" "$WORK/ds.out" | head -6)" \
    "$(printf '%s\n' "$SECTION" | tail -5)"
fi
ANCHOR_WHY="$(printf '%s\n' "$SECTION" | sed -n 's/^  ANCHORED: //p')"

# ── 5. flip + byte-exact restore, via the real harness ───────────────────────
bash scripts/sabotage.sh --range "$NUMBER-$NUMBER" > "$WORK/flip.out" 2>&1
flip_rc=$?
if [[ $flip_rc -ne 0 ]]; then
  if grep -q 'no test-failure headers found' "$WORK/flip.out"; then
    refuse "the suite failed under the sabotage but printed NO named test failure — it breaks the compile or a migration." \
      "The harness cannot see a named flip, so this patch is useless even though it \"fails\" (and the failure would" \
      "read as a broken tree, not a broken guard). Make the sabotage compile and migrate: change behaviour, not syntax." \
      "$(grep -E '(CompileError|error:|\*\* \()' "$WORK/flip.out" | head -4)"
  elif grep -q 'suite PASSED under sabotage' "$WORK/flip.out"; then
    refuse "the tests PASSED under the sabotage — it flips nothing (a vacuous gate)." \
      "$(grep -E 'FAILED' "$WORK/flip.out" | head -2)"
  elif grep -q 'named test did not flip' "$WORK/flip.out"; then
    refuse "the sabotage fails the suite but NOT the test you named." \
      "$(grep -E 'did not flip|^ *[0-9]+\) (test|property)' "$WORK/flip.out" | head -8)"
  else
    refuse "scripts/sabotage.sh --range $NUMBER-$NUMBER failed (exit $flip_rc)." "$(tail -12 "$WORK/flip.out")"
  fi
fi
grep -q 'restore: byte-exact' "$WORK/flip.out" || refuse "the harness did not confirm a byte-exact restore" "$(tail -5 "$WORK/flip.out")"
git diff --quiet -- "${FILES[@]}" || refuse "the files differ from the index after the replay"

# ── 6. baseline: the same tests PASS without the sabotage ────────────────────
# A captured unstaged fix shows up HERE: the restored tree lacks it, so the tests that need it fail.
( cd "$APP" && mix test "${TEST_FILES[@]}" ) > "$WORK/base.out" 2>&1
base_rc=$?
if [[ $base_rc -ne 0 ]]; then
  refuse "the test files FAIL on the restored tree even WITHOUT the sabotage (mix test exit $base_rc)." \
    "Either the tree is red, or your real fix was UNSTAGED when you made the sabotage and was captured into the" \
    "patch (and just restored away). Stage the fix first: git add <fix files>, redo the sabotage edit, re-run." \
    "$(grep -E '^ *[0-9]+\) (test|property)' "$WORK/base.out" | head -5)"
fi

# ── 7. keep it ───────────────────────────────────────────────────────────────
DONE=1
echo ""
echo "SABOTAGE NEW: CREATED scripts/sabotages/$NAME"
echo "  anchored  : $ANCHOR_WHY"
echo "  flip      : $(grep -m1 'flip confirmed' "$WORK/flip.out" | sed 's/^ *//')"
echo "  restore   : byte-exact (sha-256), ${FILES[*]} back to the index"
echo "  baseline  : ${TEST_FILES[*]} pass without it"
echo "  counts    : $COUNTS_NOTE"
echo "  next      : git add scripts/sabotages/$NAME CLAUDE.md   (the patch is untracked until you do)"
exit 0
