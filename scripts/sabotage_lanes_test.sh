#!/usr/bin/env bash
# scripts/sabotage_lanes_test.sh — regression harness for scripts/sabotage-lanes.sh (#30, ADR-053 P3 / C7).
#
# A scheduler that can report green over a lane that never ran is worse than the slow
# serial run it replaces. This builds a throwaway git repo in a temp dir whose
# scripts/sabotage.sh is a STUB (no mix, no DB): it lists/partitions patches by the same
# `--shard i/n` rule, records WHICH TREE and which DB suffix it ran with, and prints the serial
# harness's accounting line — honestly, or dishonestly on command (STUB_LANE<k>=fail|lie|short|zero|silent).
# The REAL sabotage-lanes.sh is run against that repo with 3 lanes over 8 patches, and must:
#
#   1. GREEN — all lanes pass: exit 0, "PROCESSED 8 of 8", "ALL PASSED ... 3 lanes".
#   2. ISOLATION — lane 1 ran in the main tree and each other lane in its OWN tree, all at the SAME
#      commit; lane 1 on the default DB names, lane k>1 with SAMEN_TEST_DB_SUFFIX=_lane<k>.
#   3. A FAILING LANE — lane 3 exits 1: the run fails and names lane 3.
#   4. A LYING LANE — lane 2 exits 0 but reports PROCESSED 2 of 3: the run fails.
#   5. C7 — A PARTITION GAP — lane 1 silently selects one patch fewer: each lane is internally
#      "complete" but the SELECTED sum is not the selection, so the run fails.
#   6. C7 — A LANE THAT PROCESSES 0 (and selects 0), and a lane that prints NOTHING: both fail.
#   7. A DIRTY TREE — refused with exit 2 and NO lane runs; `--working-tree` SYNCS the edit (and an
#      untracked file) into every lane and passes; a lane tree dirtied during the run is residue.
#   8. REUSE — lane trees are reused and reset: a stray edit planted in one is gone, and after a new
#      commit every lane certifies the NEW commit.
#   9. STALE DEPS — a lane `deps/` planted stale is re-cloned from the main tree and `mix deps.get`
#      runs on it BEFORE the lanes run.
#  10. DEPS.GET FAILS — exit 2, and NO lane runs.
#  11. --lanes 1 runs the plain harness in the main tree only; selection flags pass through; the default
#      lane count scales with the selection (--min-per-lane) while an explicit count is honoured.
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

FIX="$T/repo"; MARK="$T/marks"; BIN="$T/bin"
LANE_DIRS=("$T/lane-b" "$T/lane-c")   # lane 2 honours SAMEN_LANE_B_DIR; lane 3 lives under the git dir
mkdir -p "$FIX/scripts/sabotages" "$MARK" "$BIN" "$FIX/samen_web/deps/pkg"
cp "$REAL" "$FIX/scripts/sabotage-lanes.sh"

for i in 1 2 3 4 5; do printf '# APP: samen_core\n# TEST_FILES: t\n# MUST_FAIL: x\n' > "$FIX/scripts/sabotages/$i-core.patch"; done
for i in 6 7 8; do printf '# APP: samen_web\n# TEST_FILES: t\n# MUST_FAIL: x\n' > "$FIX/scripts/sabotages/$i-web.patch"; done

# One app with fetched (ignored) deps, and a stub `mix` on PATH that records where it ran and which
# deps/ it saw. STUB_MIX=fail makes `mix deps.get` fail.
echo 'deps/' > "$FIX/.gitignore"
echo 'defmodule Web.MixProject, do: nil' > "$FIX/samen_web/mix.exs"
echo fresh-1 > "$FIX/samen_web/deps/pkg/VERSION"
cat > "$BIN/mix" <<'STUB'
#!/usr/bin/env bash
echo "$(pwd -P) $* $(cat deps/pkg/VERSION 2>/dev/null)" >> "$STUB_MARKS/mix-calls"
[[ "${STUB_MIX:-}" != fail ]]
STUB
chmod +x "$BIN/mix"

# The stub harness: understands the selection flags the lanes pass (`--list`, `--shard i/n`, `--range`,
# `--app`), records where it ran. STUB_LANE<k>=fail|lie|short|zero|silent changes one lane's behaviour.
cat > "$FIX/scripts/sabotage.sh" <<'STUB'
#!/usr/bin/env bash
shard=""; list=0; range=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --shard) shard="$2"; shift 2 ;;
    --range) range="$2"; shift 2 ;;
    --list) list=1; shift ;;
    *) shift ;;
  esac
done
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
all=(); for p in "$root"/scripts/sabotages/*.patch; do all+=("$p"); done
sel=()
for p in "${all[@]}"; do
  num="$(basename "$p")"; num="${num%%-*}"
  if [[ -n "$range" ]]; then lo="${range%-*}"; hi="${range#*-}"; (( num >= lo && num <= hi )) || continue; fi
  sel+=("$p")
done
total=${#sel[@]}
if [[ $list -eq 1 ]]; then
  echo "SABOTAGE SELECTION: $total of ${#all[@]} patches selected (dry-run — nothing applied)"; exit 0
fi
i="${shard%/*}"; n="${shard#*/}"
m=0; pos=0
for p in "${sel[@]}"; do pos=$((pos + 1)); (( (pos - 1) % n == i - 1 )) && m=$((m + 1)); done
echo "$root $(git -C "$root" rev-parse HEAD) suffix=[${SAMEN_TEST_DB_SUFFIX:-}] args=[$range]" > "$STUB_MARKS/lane-$i"
cat "$root/samen_web/deps/pkg/VERSION" > "$STUB_MARKS/lane-$i-deps" 2>/dev/null
[[ -n "${STUB_DIRTY:-}" && "$i" == "$STUB_DIRTY" ]] && echo residue > "$root/RESIDUE"
behaviour="$(eval echo "\${STUB_LANE$i:-}")"
case "$behaviour" in
  fail)   echo "SABOTAGE HARNESS: PROCESSED 1 of $m SELECTED"; echo "SABOTAGE HARNESS: FAILED — stub"; exit 1 ;;
  lie)    echo "SABOTAGE HARNESS: PROCESSED $((m - 1)) of $m SELECTED"; exit 0 ;;
  short)  m=$((m - 1)); echo "SABOTAGE HARNESS: PROCESSED $m of $m SELECTED"; exit 0 ;;
  zero)   echo "SABOTAGE HARNESS: PROCESSED 0 of 0 SELECTED"; exit 0 ;;
  silent) exit 0 ;;
  *)      echo "SABOTAGE HARNESS: PROCESSED $m of $m SELECTED"; echo "SABOTAGE HARNESS: ALL PASSED"; exit 0 ;;
esac
STUB

git -C "$FIX" init -q
git -C "$FIX" -c user.email=t@t -c user.name=t add -A
git -C "$FIX" -c user.email=t@t -c user.name=t commit -q -m base

LOG=""; RC=0
run() { # run <logname> [ENV=val ...] -- [lanes args…]
  LOG="$T/$1"; shift
  local envs=()
  while [[ $# -gt 0 && "$1" != -- ]]; do envs+=("$1"); shift; done
  [[ "${1:-}" == -- ]] && shift
  rm -f "$MARK"/lane-* "$MARK/mix-calls"
  env PATH="$BIN:$PATH" STUB_MARKS="$MARK" SAMEN_LANE_B_DIR="${LANE_DIRS[0]}" SAMEN_LANES=3 "${envs[@]}" bash "$FIX/scripts/sabotage-lanes.sh" "$@" > "$LOG" 2>&1
  RC=$?
}
expect_rc()     { if [[ $RC -eq $1 ]]; then ok "$2 (exit $RC)"; else cat "$LOG"; bad "$2 — expected exit $1, got $RC"; fi; }
expect_says()   { if grep -qF -- "$1" "$LOG"; then ok "$2"; else cat "$LOG"; bad "$2 — never said: $1"; fi; }
expect_silent() { if grep -qF -- "$1" "$LOG"; then cat "$LOG"; bad "$2 — wrongly said: $1"; else ok "$2"; fi; }
no_lane_ran()   { [[ -z "$(ls "$MARK"/lane-? 2>/dev/null)" ]]; }

echo "== 1/2. green, and the lanes are isolated =="
run green.log
expect_rc 0 "1a. all lanes passing is a pass"
expect_says "SABOTAGE HARNESS: PROCESSED 8 of 8 SELECTED" "1b. the merged accounting covers the whole selection"
expect_says "SABOTAGE HARNESS: ALL PASSED (8 sabotages" "1c. the merged verdict"
expect_says "3 lanes" "1d. and names the lane count"
head_sha="$(git -C "$FIX" rev-parse HEAD)"
read -r tree1 sha1 suf1 _ < "$MARK/lane-1"; read -r tree2 sha2 suf2 _ < "$MARK/lane-2"; read -r tree3 sha3 suf3 _ < "$MARK/lane-3"
[[ "$tree1" == "$FIX" ]] && ok "2a. lane 1 ran in the main tree" || bad "2a. lane 1 ran in $tree1"
[[ "$tree2" == "${LANE_DIRS[0]}" && "$tree3" == */.git/samen-lanes/c && "$tree2" != "$tree3" ]] \
  && ok "2b. lanes 2 and 3 each ran in their OWN tree" || bad "2b. lane trees: $tree2 / $tree3"
[[ "$sha1" == "$head_sha" && "$sha2" == "$head_sha" && "$sha3" == "$head_sha" ]] && ok "2c. all lanes certified the same commit" || bad "2c. commits differ: $sha1 / $sha2 / $sha3"
[[ "$suf1" == "suffix=[]" && "$suf2" == "suffix=[_lane2]" && "$suf3" == "suffix=[_lane3]" ]] \
  && ok "2d. lane 1 on the default test DBs, lanes 2-3 on their own (SAMEN_TEST_DB_SUFFIX)" || bad "2d. suffixes: $suf1 $suf2 $suf3"

echo "== 3. a failing lane =="
run failc.log STUB_LANE3=fail
expect_rc 1 "3a. a lane that fails fails the run"
expect_says "lane 3 FAILED" "3b. the failing lane is named"
expect_silent "ALL PASSED (" "3c. and no pass is claimed"

echo "== 4. a lying lane =="
run lie2.log STUB_LANE2=lie
expect_rc 1 "4a. a lane that exits 0 with PROCESSED < SELECTED fails the run"
expect_says "a short lane is not coverage" "4b. and says why"

echo "== 5. C7: a partition gap =="
run short1.log STUB_LANE1=short
expect_rc 1 "5a. lanes that are internally complete but do not sum to the selection fail the run"
expect_says "the partition is not total" "5b. and says why"
expect_says "PROCESSED 7 of 8 SELECTED" "5c. and the merged line shows the shortfall"
expect_silent "ALL PASSED (" "5d. never a pass"

echo "== 6. C7: a lane that processes 0, and a silent lane =="
run zero2.log STUB_LANE2=zero
expect_rc 1 "6a. a lane that selects and processes 0 patches fails the run"
expect_says "the partition is not total" "6b. (its patches went unexercised)"
run silent3.log STUB_LANE3=silent
expect_rc 1 "6c. a lane that prints no accounting fails the run"
expect_says "lane 3 printed no PROCESSED accounting line" "6d. and names it"

echo "== 7. a dirty tree =="
echo dirt >> "$FIX/scripts/sabotages/1-core.patch"
echo new > "$FIX/scripts/sabotages/9-new.patch"
run dirty.log
expect_rc 2 "7a. a dirty tree is refused"
no_lane_ran && ok "7b. and no lane ran" || bad "7b. a lane ran on a dirty tree"
run wt.log -- --working-tree
expect_rc 0 "7c. --working-tree certifies the working tree"
expect_says "PROCESSED 9 of 9 SELECTED" "7d. the untracked patch is part of the selection"
expect_says "working tree synced into every lane" "7e. and says it synced"
[[ "$(tail -1 "${LANE_DIRS[0]}/scripts/sabotages/1-core.patch")" == dirt && -f "${LANE_DIRS[0]}/scripts/sabotages/9-new.patch" ]] \
  && ok "7f. the edit and the untracked file reached lane 2" || bad "7f. lane 2 does not hold the working tree"
run wtres.log STUB_DIRTY=3 -- --working-tree
expect_rc 1 "7g. a lane that leaves its tree changed is residue and fails the run"
expect_says "lane-3 tree changed during the run" "7h. naming the lane"
git -C "$FIX" checkout -q -- scripts/sabotages/1-core.patch; rm -f "$FIX/scripts/sabotages/9-new.patch"

echo "== 8. the lane trees are reused, reset, and follow HEAD =="
echo stray >> "${LANE_DIRS[0]}/scripts/sabotages/4-core.patch"
printf '# APP: samen_web\n# TEST_FILES: t\n# MUST_FAIL: x\n' > "$FIX/scripts/sabotages/9-web.patch"
git -C "$FIX" -c user.email=t@t -c user.name=t add -A
git -C "$FIX" -c user.email=t@t -c user.name=t commit -q -m next
run reuse.log
expect_rc 0 "8a. a second run passes"
expect_says "PROCESSED 9 of 9 SELECTED" "8b. the new patch is counted"
head_sha="$(git -C "$FIX" rev-parse HEAD)"
read -r _ sha2 _ < "$MARK/lane-2"; read -r _ sha3 _ < "$MARK/lane-3"
[[ "$sha2" == "$head_sha" && "$sha3" == "$head_sha" ]] && ok "8c. the lanes certified the NEW commit" || bad "8c. lanes certified $sha2 / $sha3"
[[ -z "$(git -C "${LANE_DIRS[0]}" status --porcelain)" ]] && ok "8d. the stray edit in a lane tree was reset" || bad "8d. lane tree still dirty"

echo "== 9. a stale lane deps/ is refreshed before the lanes run =="
echo stale > "${LANE_DIRS[0]}/samen_web/deps/pkg/VERSION"
echo fresh-2 > "$FIX/samen_web/deps/pkg/VERSION"
run staledeps.log
expect_rc 0 "9a. the run passes"
[[ "$(cat "$MARK/lane-2-deps" 2>/dev/null)" == fresh-2 ]] \
  && ok "9b. lane 2 ran against the main tree's CURRENT deps/" \
  || bad "9b. lane 2 ran against deps '$(cat "$MARK/lane-2-deps" 2>/dev/null)', not fresh-2"
grep -qxF "${LANE_DIRS[0]}/samen_web deps.get fresh-2" "$MARK/mix-calls" 2>/dev/null \
  && ok "9c. mix deps.get ran in the lane app, on the refreshed deps/" \
  || { cat "$MARK/mix-calls" 2>/dev/null; bad "9c. no mix deps.get on the refreshed lane deps/"; }

echo "== 10. a failing mix deps.get in a lane =="
run depsfail.log STUB_MIX=fail
expect_rc 2 "10a. a failing deps.get is an environment error"
expect_says "mix deps.get failed in the lane-2 tree for samen_web" "10b. and names the lane and app"
no_lane_ran && ok "10c. and no lane ran" || bad "10c. a lane ran after deps.get failed"

echo "== 11. --lanes 1, and selection flags pass through =="
run one.log -- --lanes 1 --range 2-4
expect_rc 0 "11a. one lane passes"
expect_says "PROCESSED 3 of 3 SELECTED" "11b. over the range-selected 3 patches"
[[ -e "$MARK/lane-1" && ! -e "$MARK/lane-2" ]] && ok "11c. only the main tree ran" || bad "11c. unexpected lanes: $(ls "$MARK")"
grep -qF 'args=[2-4]' "$MARK/lane-1" && ok "11d. --range reached the lane" || bad "11d. --range was dropped: $(cat "$MARK/lane-1")"
# the default lane count scales with the selection: --min-per-lane 8 over 8 patches is ONE lane (the plain
# harness in this tree, no worktrees); an explicit SAMEN_LANES is honoured regardless
run scaled.log SAMEN_LANES= -- --min-per-lane 8
expect_rc 0 "11f. a selection too small for two lanes runs one"
expect_says "in 1 lane(s)" "11g. and says 1 lane"
[[ -e "$MARK/lane-1" && ! -e "$MARK/lane-2" ]] && ok "11h. only the main tree ran" || bad "11h. unexpected lanes: $(ls "$MARK")"
run explicit.log -- --min-per-lane 8
expect_says "in 3 lane(s)" "11i. an explicit SAMEN_LANES=3 is honoured despite --min-per-lane"
run guard.log -- --shard 1/2
expect_rc 2 "11e. --shard is the lanes' own business and is refused"

echo ""
echo "SABOTAGE LANES SELF-TEST: $pass_count passed, $fail_count failed"
[[ $fail_count -eq 0 ]] || { echo "SABOTAGE LANES SELF-TEST: FAILED"; exit 1; }
echo "SABOTAGE LANES SELF-TEST: ALL PASSED"
