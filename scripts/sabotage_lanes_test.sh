#!/usr/bin/env bash
# scripts/sabotage_lanes_test.sh — regression harness for scripts/sabotage-lanes.sh (#30).
#
# A scheduler that can report green over a lane that never ran is worse than the slow
# serial run it replaces. This builds a throwaway git repo in a temp dir whose
# scripts/sabotage.sh is a STUB (no mix, no DB): it selects patches by the same
# `--app` / `--not-app` rule, records WHICH TREE it ran in, and prints the serial
# harness's accounting line — honestly, or dishonestly on command. The REAL
# sabotage-lanes.sh is run against that repo, and must:
#
#   1. GREEN — both lanes pass: exit 0, "PROCESSED 5 of 5", "ALL PASSED".
#   2. ISOLATION — lane A ran in the main tree and lane B in a DIFFERENT tree (the
#      lane-B worktree), at the SAME commit. One shared tree would leak lane A's
#      sabotage into lane B's compile.
#   3. A FAILING LANE — lane B exits 1: the run fails and names lane B.
#   4. A LYING LANE — lane B exits 0 but reports PROCESSED 1 of 2: the run fails.
#   5. A PARTITION GAP — lane A silently selects one patch fewer than it should:
#      both lanes are internally "complete", but 2 + 2 != 5, so the run fails.
#   6. A DIRTY TREE — refused with exit 2, and NO lane runs.
#   7. REUSE — the lane-B tree is reused and reset: a stray edit planted in it is gone,
#      and after a new commit lane B certifies the NEW commit.
#
# Usage: scripts/sabotage_lanes_test.sh     Residue: none outside the temp dir.
set -uo pipefail

REAL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sabotage-lanes.sh"

pass_count=0; fail_count=0
ok()  { echo "PASS: $*"; pass_count=$((pass_count + 1)); }
bad() { echo "FAIL: $*"; fail_count=$((fail_count + 1)); }

T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/samen_lanes_test.XXXXXX")" && pwd -P)"
cleanup() { rm -rf "$T"; }
trap cleanup EXIT INT TERM

FIX="$T/repo"; MARK="$T/marks"; LANE_B="$T/lane-b"
mkdir -p "$FIX/scripts/sabotages" "$MARK"
cp "$REAL" "$FIX/scripts/sabotage-lanes.sh"

for i in 1 2 3; do printf '# APP: samen_core\n# TEST_FILES: t\n# MUST_FAIL: x\n' > "$FIX/scripts/sabotages/$i-core.patch"; done
for i in 4 5; do printf '# APP: samen_web\n# TEST_FILES: t\n# MUST_FAIL: x\n' > "$FIX/scripts/sabotages/$i-web.patch"; done

# The stub harness. STUB_<LANE>=fail|lie|short changes one lane's behaviour.
cat > "$FIX/scripts/sabotage.sh" <<'STUB'
#!/usr/bin/env bash
mode_flag="$1"; app="$2"
lane=$([[ "$mode_flag" == "--app" ]] && echo A || echo B)
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
echo "$root $(git -C "$root" rev-parse HEAD)" > "$STUB_MARKS/lane-$lane"
n=0
for p in "$root"/scripts/sabotages/*.patch; do
  a="$(sed -n 's/^# APP: //p' "$p")"
  if [[ "$mode_flag" == "--app" && "$a" == "$app" ]] || [[ "$mode_flag" == "--not-app" && "$a" != "$app" ]]; then
    n=$((n + 1))
  fi
done
behaviour="$(eval echo "\${STUB_$lane:-}")"
case "$behaviour" in
  fail)  echo "SABOTAGE HARNESS: PROCESSED 1 of $n SELECTED"; echo "SABOTAGE HARNESS: FAILED — stub"; exit 1 ;;
  lie)   echo "SABOTAGE HARNESS: PROCESSED $((n - 1)) of $n SELECTED"; exit 0 ;;
  short) n=$((n - 1)); echo "SABOTAGE HARNESS: PROCESSED $n of $n SELECTED"; exit 0 ;;
  *)     echo "SABOTAGE HARNESS: PROCESSED $n of $n SELECTED"; echo "SABOTAGE HARNESS: ALL PASSED"; exit 0 ;;
esac
STUB

git -C "$FIX" init -q
git -C "$FIX" -c user.email=t@t -c user.name=t add -A
git -C "$FIX" -c user.email=t@t -c user.name=t commit -q -m base

LOG=""; RC=0
run() { # run <logname> [ENV=val ...]
  LOG="$T/$1"; shift
  rm -f "$MARK"/lane-*
  env STUB_MARKS="$MARK" SAMEN_LANE_B_DIR="$LANE_B" "$@" bash "$FIX/scripts/sabotage-lanes.sh" > "$LOG" 2>&1
  RC=$?
}
expect_rc()     { if [[ $RC -eq $1 ]]; then ok "$2 (exit $RC)"; else cat "$LOG"; bad "$2 — expected exit $1, got $RC"; fi; }
expect_says()   { if grep -qF -- "$1" "$LOG"; then ok "$2"; else cat "$LOG"; bad "$2 — never said: $1"; fi; }
expect_silent() { if grep -qF -- "$1" "$LOG"; then cat "$LOG"; bad "$2 — wrongly said: $1"; else ok "$2"; fi; }

echo "== 1/2. green, and the lanes are isolated =="
run green.log
expect_rc 0 "1a. both lanes passing is a pass"
expect_says "SABOTAGE HARNESS: PROCESSED 5 of 5 SELECTED" "1b. the merged accounting covers the whole corpus"
expect_says "SABOTAGE HARNESS: ALL PASSED (5 sabotages" "1c. the merged verdict"
head_sha="$(git -C "$FIX" rev-parse HEAD)"
read -r tree_a sha_a < "$MARK/lane-A"; read -r tree_b sha_b < "$MARK/lane-B"
[[ "$tree_a" == "$FIX" ]] && ok "2a. lane A ran in the main tree" || bad "2a. lane A ran in $tree_a"
[[ "$tree_b" == "$LANE_B" && "$tree_b" != "$tree_a" ]] && ok "2b. lane B ran in its OWN tree" || bad "2b. lane B ran in $tree_b"
[[ "$sha_a" == "$head_sha" && "$sha_b" == "$head_sha" ]] && ok "2c. both lanes certified the same commit" || bad "2c. commits differ: $sha_a / $sha_b"

echo "== 3. a failing lane =="
run failb.log STUB_B=fail
expect_rc 1 "3a. a lane that fails fails the run"
expect_says "lane B FAILED" "3b. the failing lane is named"
expect_silent "ALL PASSED (" "3c. and no pass is claimed"

echo "== 4. a lying lane =="
run lieb.log STUB_B=lie
expect_rc 1 "4a. a lane that exits 0 with PROCESSED < SELECTED fails the run"
expect_says "a short lane is not coverage" "4b. and says why"

echo "== 5. a partition gap =="
run shorta.log STUB_A=short
expect_rc 1 "5a. two internally-complete lanes that do not sum to the corpus fail the run"
expect_says "the partition is not total" "5b. and says why"

echo "== 6. a dirty tree =="
echo dirt >> "$FIX/scripts/sabotages/1-core.patch"
run dirty.log
expect_rc 2 "6a. a dirty tree is refused"
[[ ! -e "$MARK/lane-A" && ! -e "$MARK/lane-B" ]] && ok "6b. and no lane ran" || bad "6b. a lane ran on a dirty tree"
git -C "$FIX" checkout -q -- scripts/sabotages/1-core.patch

echo "== 7. the lane-B tree is reused, reset, and follows HEAD =="
echo stray >> "$LANE_B/scripts/sabotages/4-web.patch"
printf '# APP: samen_web\n# TEST_FILES: t\n# MUST_FAIL: x\n' > "$FIX/scripts/sabotages/6-web.patch"
git -C "$FIX" -c user.email=t@t -c user.name=t add -A
git -C "$FIX" -c user.email=t@t -c user.name=t commit -q -m next
run reuse.log
expect_rc 0 "7a. a second run passes"
expect_says "PROCESSED 6 of 6 SELECTED" "7b. the new patch is counted"
read -r _ sha_b < "$MARK/lane-B"
[[ "$sha_b" == "$(git -C "$FIX" rev-parse HEAD)" ]] && ok "7c. lane B certified the NEW commit" || bad "7c. lane B certified $sha_b"
[[ -z "$(git -C "$LANE_B" status --porcelain)" ]] && ok "7d. the stray edit in the lane-B tree was reset" || bad "7d. lane-B tree still dirty"

echo ""
echo "SABOTAGE LANES SELF-TEST: $pass_count passed, $fail_count failed"
[[ $fail_count -eq 0 ]] || { echo "SABOTAGE LANES SELF-TEST: FAILED"; exit 1; }
echo "SABOTAGE LANES SELF-TEST: ALL PASSED"
