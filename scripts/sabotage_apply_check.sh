#!/usr/bin/env bash
# scripts/sabotage_apply_check.sh — every shipped sabotage must still APPLY to this tree.
#
# WHY THIS EXISTS (issue #53). A sabotage patch that no longer applies is a guard with
# no red: `scripts/sabotage.sh` cannot replay it, so nothing proves the guard it attacks
# still bites. The G-06 double sweep does NOT catch this on its own, by design: a patch
# that fails to apply in BOTH baselines is "pre-existing", not a regression of the
# increment being swept (`double_sweep_test.sh` case 2c pins that). So when #22 moved
# the code under patches 294, 295 and 331, the very next run's baseline already
# contained the breakage, and every `ci.sh` for four days printed "failing at SHIP (3)"
# and passed. The only thing that would have noticed was the full replay, which is
# opt-in (~17 min). Fixed for those three by #52; this step makes the next one a red.
#
# WHAT. `git apply --check` of every scripts/sabotages/*.patch against the WORKING TREE
# (uncommitted edits included — that is what ships). No compile, no DB, no `mix test`,
# nothing written: ~2s for the whole corpus. It asks "can every sabotage still be
# applied", NOT "does it still flip its named tests" — that is the replay's question
# (`scripts/sabotage.sh`), and neither substitutes for the other.
#
# USAGE
#   scripts/sabotage_apply_check.sh [--repo <path>]
#
# EXIT CODES
#   0  every patch applies (and PROCESSED == SELECTED)
#   1  one or more patches do not apply — each is named, with git's first error line
#   2  usage / environment error (not a repo, no patches)
#   5  ACCOUNTING failure — the loop did not process every patch it selected, so the
#      verdict is VOID (the same rule double-sweep.sh and sabotage.sh enforce)
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      [[ $# -ge 2 ]] || { echo "sabotage_apply_check.sh: --repo needs a path" >&2; exit 2; }
      REPO="$2"
      shift 2
      ;;
    *)
      echo "sabotage_apply_check.sh: unknown argument: $1" >&2
      echo "usage: scripts/sabotage_apply_check.sh [--repo <path>]" >&2
      exit 2
      ;;
  esac
done

git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || {
  echo "SABOTAGE APPLY CHECK: $REPO is not a git repository" >&2
  exit 2
}

SAB_DIR="$REPO/scripts/sabotages"
patches=()
while IFS= read -r p; do
  [[ -n "$p" ]] && patches+=("$p")
done < <(ls "$SAB_DIR"/*.patch 2>/dev/null | sort -V)

selected=${#patches[@]}
if [[ $selected -eq 0 ]]; then
  echo "SABOTAGE APPLY CHECK: FAILED — no patches found in $SAB_DIR" >&2
  exit 2
fi

processed=0
bad=0
for patch in "${patches[@]}"; do
  err="$(cd "$REPO" && git apply --check "$patch" 2>&1)"
  if [[ $? -ne 0 ]]; then
    echo "  DOES NOT APPLY  $(basename "$patch")"
    echo "                  $(printf '%s\n' "$err" | head -1)"
    bad=$((bad + 1))
  fi
  processed=$((processed + 1))
done

echo "SABOTAGE APPLY CHECK: PROCESSED $processed of $selected SELECTED"
if [[ $processed -ne $selected ]]; then
  echo "SABOTAGE APPLY CHECK: FAILED — ACCOUNTING: processed $processed of $selected; every number above is VOID"
  exit 5
fi

if [[ $bad -gt 0 ]]; then
  echo "SABOTAGE APPLY CHECK: FAILED — $bad of $selected patch(es) no longer apply to this tree."
  echo "  A patch that cannot apply is a guard with no red. Re-anchor it onto the current code"
  echo "  (same semantics, regenerated from a real edit; see PR #52), then replay it:"
  echo "  scripts/sabotage.sh --range <n>-<n>. Never delete a patch to make this pass."
  exit 1
fi

echo "SABOTAGE APPLY CHECK: ALL PASSED ($selected of $selected patches apply to this tree)"
