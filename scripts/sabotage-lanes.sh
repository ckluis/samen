#!/usr/bin/env bash
# scripts/sabotage-lanes.sh — the sabotage replay in N concurrent lanes (issue #30; ADR-053 §2.6, P3).
#
# WHY. The serial replay (`scripts/sabotage.sh`) is dominated by fixed per-patch cost that cannot be
# removed: each patch gets a fresh `mix test`, and the per-invocation DB drop is load-bearing
# (migrations run lib code, so a patched tree needs its schema rebuilt — the reason #30's lever 1 was
# dropped). What CAN change is scheduling. P3 generalises the original two lanes (samen_core vs the
# rest — capped at the samen_core share, ~60%) to N lanes of EQUAL size:
#
#   * the selection is partitioned with `sabotage.sh --shard <i>/<N>` (position mod N in the
#     listing's order — disjoint, union = the selection, every lane a mix of apps),
#   * each lane is a git worktree of its own (a sabotage edits `samen_core/lib`, which every other app
#     compiles as a path dep, so one shared tree would leak one lane's sabotage into another's tests),
#   * and each lane gets its OWN test databases: lane 1 (this tree) keeps the default names, lane k>1
#     sets SAMEN_TEST_DB_SUFFIX=_lane<k> (every app's config/test.exs appends it to its database name).
#
# Each lane is the unchanged `sabotage.sh` — apply → fresh `mix test` → named MUST_FAIL flips → revert →
# SHA-256 byte-exact — so per-patch semantics and attribution are exactly the serial harness's.
#
# HOW MANY LANES. Default min(cores/2, RAM GB/3, Postgres connections free / 22, 8), at least 1 and
# never more than the selection. Each lane is a BEAM + an app compile (~1-1.5 GB) and holds a 20-connection
# test pool, and the server's max_connections is 100. `--lanes N` / SAMEN_LANES=N overrides (N=1 runs
# the plain harness in this tree).
#
# C7 — ACCOUNTING (the same rule the serial harness enforces, across lanes). The run FAILS unless
#   * every lane exits 0 AND reports `PROCESSED n of n SELECTED` with n > 0,
#   * the lanes' SELECTED counts sum to the selection this script listed itself, and
#   * the lanes' PROCESSED counts sum to that same number.
# A lane that processes 0, crashes, drops patches or prints nothing is a failure that names the lane.
#
# WHAT IT CERTIFIES. Lane trees are checkouts of HEAD, so by default a DIRTY main tree is refused (exit 2):
# uncommitted edits would be certified in lane 1 and silently not in the others. `--working-tree` instead
# SYNCS the main tree's tracked diff vs HEAD and its untracked-not-ignored files into every other lane
# (the driver uses this: a `pr` run is normally on an uncommitted tree), and every lane tree must be
# exactly as clean/dirty after the run as it was after the sync.
#
# THE LANE TREES live under the repository's git dir (`<git-common-dir>/samen-lanes/<b|c|d…>`, lane 2
# honours SAMEN_LANE_B_DIR) — never tracked, never in the way — and are REUSED across runs so `_build`
# stays warm; a lane tree with no `_build` of an app starts from an APFS clone (`cp -c`) of this tree's,
# so a new lane is not a cold compile. Every run re-clones each app's `deps/` from this tree
# (`cp -c`, no copy cost) and runs `mix deps.get` there, so a dependency bump never leaves a lane stale.
#
# Usage: scripts/sabotage-lanes.sh [--lanes N] [--working-tree] [sabotage.sh selection flags…]
#        e.g. scripts/sabotage-lanes.sh                         the whole corpus
#             scripts/sabotage-lanes.sh --working-tree --range 1-120
# Exit:  0 every lane ALL PASSED and the accounting is total · 1 a lane failed or the accounting does
#        not add up · 2 environment (dirty tree, no patches, not a repo, bad flag)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SAB_REL="scripts/sabotage.sh"
LETTERS=(a b c d e f g h)

env_err() { echo "SABOTAGE LANES: $1" >&2; exit 2; }

LANES="${SAMEN_LANES:-}"
MIN_PER_LANE=12
WORKING_TREE=0
PASS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --lanes) shift; [[ $# -gt 0 && "$1" =~ ^[1-8]$ ]] || env_err "--lanes wants a number 1..8"; LANES="$1"; shift ;;
    --working-tree) WORKING_TREE=1; shift ;;
    --min-per-lane) shift; [[ $# -gt 0 && "$1" =~ ^[0-9]+$ && "$1" -ge 1 ]] || env_err "--min-per-lane wants a number >= 1"; MIN_PER_LANE="$1"; shift ;;
    -h|--help) sed -n '2,/^set -uo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    --shard|--list|--dry-run) env_err "$1 is the lanes' own business — do not pass it" ;;
    *) PASS+=("$1"); shift ;;
  esac
done
[[ -z "$LANES" || "$LANES" =~ ^[1-8]$ ]] || env_err "SAMEN_LANES wants a number 1..8, got: $LANES"

git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1 || env_err "$REPO_ROOT is not a git repository"
DIRTY="$(git -C "$REPO_ROOT" status --porcelain)"
if [[ -n "$DIRTY" && $WORKING_TREE -eq 0 ]]; then
  git -C "$REPO_ROOT" status --short | head -10 >&2
  env_err "the working tree is DIRTY. Lanes mode certifies a COMMIT (the other lanes run in checkouts of HEAD, so uncommitted edits would be certified in one lane and not the others). Commit first, pass --working-tree to sync the edits into every lane, or run the serial scripts/sabotage.sh, which certifies the working tree as-is."
fi

HEAD_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD)"
# THE selection, listed by this script itself: the number every lane's accounting is held to.
LIST_OUT="$(cd "$REPO_ROOT" && bash "$SAB_REL" "${PASS[@]+"${PASS[@]}"}" --list 2>&1)" || { echo "$LIST_OUT" >&2; env_err "could not list the selection (see above)"; }
TOTAL="$(printf '%s\n' "$LIST_OUT" | sed -n 's/^SABOTAGE SELECTION: \([0-9][0-9]*\) of [0-9][0-9]* patches selected.*/\1/p' | tail -1)"
[[ "$TOTAL" =~ ^[0-9]+$ && "$TOTAL" -gt 0 ]] || { echo "$LIST_OUT" | tail -5 >&2; env_err "the selection is empty or unreadable (TOTAL='$TOTAL') — nothing to certify"; }

default_lanes() {
  local cores mem_gb n conn max used
  cores="$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 2)"
  n=$((cores / 2))
  mem_gb=$(( $(sysctl -n hw.memsize 2>/dev/null || awk '/MemTotal/ {print $2 * 1024}' /proc/meminfo 2>/dev/null || echo 8589934592) / 1073741824 ))
  (( mem_gb / 3 < n )) && n=$((mem_gb / 3))
  if command -v psql >/dev/null 2>&1; then
    max="$(psql -d postgres -Atc 'show max_connections' 2>/dev/null)"; used="$(psql -d postgres -Atc 'select count(*) from pg_stat_activity' 2>/dev/null)"
    if [[ "$max" =~ ^[0-9]+$ && "$used" =~ ^[0-9]+$ ]]; then
      conn=$(( (max - used - 5) / 22 ))
      (( conn < n )) && n=$conn
    fi
  fi
  (( n > 8 )) && n=8
  (( n < 1 )) && n=1
  echo "$n"
}
# an explicit --lanes/SAMEN_LANES is honoured (capped at the selection); the default also keeps every lane
# worth its setup: at least --min-per-lane patches each (a 20-patch chunk is one lane, i.e. the plain harness)
if [[ -z "$LANES" ]]; then
  LANES="$(default_lanes)"
  (( LANES > TOTAL / MIN_PER_LANE )) && LANES=$(( TOTAL / MIN_PER_LANE ))
  (( LANES < 1 )) && LANES=1
fi
(( LANES > TOTAL )) && LANES=$TOTAL

COMMON_DIR="$(cd "$REPO_ROOT" && cd "$(git rev-parse --git-common-dir)" && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/samen_lanes.XXXXXX")"
PIDS=()

lane_dir() { # lane_dir <k>  (k >= 2)
  if [[ "$1" -eq 2 && -n "${SAMEN_LANE_B_DIR:-}" ]]; then echo "$SAMEN_LANE_B_DIR"; else echo "$COMMON_DIR/samen-lanes/${LETTERS[$(( $1 - 1 ))]}"; fi
}

cleanup() {
  # An interrupt reaches the lanes through their own traps (each sabotage.sh reverts its in-flight patch
  # on exit); this only makes sure none is left running.
  local p
  for p in "${PIDS[@]+"${PIDS[@]}"}"; do kill "$p" 2>/dev/null; done
  wait 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

# ── every other lane's tree: create once, then reset to HEAD (+ the synced working tree) every run ──
sync_lane() { # sync_lane <dir> — make <dir> byte-identical to the main tree's tracked+untracked content
  local d="$1" f
  git -C "$REPO_ROOT" diff --binary HEAD > "$WORK/tree.diff" || return 1
  if [[ -s "$WORK/tree.diff" ]]; then git -C "$d" apply --whitespace=nowarn "$WORK/tree.diff" || return 1; fi
  while IFS= read -r -d '' f; do
    mkdir -p "$d/$(dirname "$f")" && cp -p "$REPO_ROOT/$f" "$d/$f" || return 1
  done < <(git -C "$REPO_ROOT" ls-files -o --exclude-standard -z)
}
for (( k = 2; k <= LANES; k++ )); do
  d="$(lane_dir "$k")"
  if [[ -e "$d/.git" ]]; then
    git -C "$d" checkout -q --detach --force "$HEAD_SHA" || env_err "could not check out $HEAD_SHA in $d"
    git -C "$d" clean -q -fd
  else
    mkdir -p "$(dirname "$d")"
    git -C "$REPO_ROOT" worktree add -q --detach "$d" "$HEAD_SHA" || env_err "could not create the lane-$k worktree at $d"
  fi
  [[ "$(git -C "$d" rev-parse HEAD)" == "$HEAD_SHA" ]] || env_err "lane-$k tree is not at $HEAD_SHA"
  [[ -z "$(git -C "$d" status --porcelain)" ]] || env_err "lane-$k tree is not clean after reset"
  if [[ $WORKING_TREE -eq 1 && -n "$DIRTY" ]]; then
    sync_lane "$d" || env_err "could not sync the working tree into lane $k ($d)"
  fi
  git -C "$d" status --porcelain > "$WORK/status.$k"
done
git -C "$REPO_ROOT" status --porcelain > "$WORK/status.1"

# the slow part, ALL lanes at once (each lane's tree is its own, so nothing is shared): deps/ is gitignored, so
# the reset above never touches it — and a lane deps/ that was only ever copied when MISSING went stale on the
# first dependency bump: every patch then died on `lock mismatch`. So EVERY run re-clones each app's deps/ from
# the main tree (`-p` keeps mtimes, so `_build` stays warm), then `mix deps.get` there, because the main tree's
# own deps/ can lag its lockfiles. A brand-new lane starts from a clone of an existing _build (APFS: free)
# instead of a cold compile. Sequential, this was ~55 s per chunk of a budgeted run; in parallel it is one lane's.
setup_lane_deps() { # setup_lane_deps <k> — prints the problem on stderr and returns 1
  local k="$1" d deps app
  d="$(lane_dir "$k")"
  for deps in "$REPO_ROOT"/*/deps; do
    [[ -d "$deps" ]] || continue
    app="$(basename "$(dirname "$deps")")"
    [[ -d "$d/$app" ]] || continue
    rm -rf "$d/$app/deps"
    cp -Rpc "$deps" "$d/$app/deps" 2>/dev/null || cp -Rp "$deps" "$d/$app/deps" \
      || { echo "could not copy $app/deps into the lane-$k tree" >&2; return 1; }
    if [[ ! -d "$d/$app/_build" && -d "$REPO_ROOT/$app/_build" ]]; then
      cp -Rpc "$REPO_ROOT/$app/_build" "$d/$app/_build" 2>/dev/null || cp -Rp "$REPO_ROOT/$app/_build" "$d/$app/_build" 2>/dev/null || true
    fi
    (cd "$d/$app" && mix deps.get >/dev/null 2>&1) \
      || { echo "mix deps.get failed in the lane-$k tree for $app — rerun it in $d/$app for detail" >&2; return 1; }
  done
}
for (( k = 2; k <= LANES; k++ )); do
  setup_lane_deps "$k" 2> "$WORK/setup.err.$k" &
  PIDS+=("$!")
done
for (( k = 2; k <= LANES; k++ )); do
  wait "${PIDS[$(( k - 2 ))]}" || env_err "$(cat "$WORK/setup.err.$k")"
done
PIDS=()

echo "SABOTAGE LANES: certifying commit $HEAD_SHA — $TOTAL patches in $LANES lane(s)$([[ $WORKING_TREE -eq 1 && -n "$DIRTY" ]] && echo ' (working tree synced into every lane)')"
for (( k = 1; k <= LANES; k++ )); do
  if (( k == 1 )); then echo "  lane 1: --shard 1/$LANES in $REPO_ROOT (default test databases)"
  else echo "  lane $k: --shard $k/$LANES in $(lane_dir "$k") (SAMEN_TEST_DB_SUFFIX=_lane$k)"; fi
done
START=$(date +%s)

for (( k = 1; k <= LANES; k++ )); do
  if (( k == 1 )); then
    (cd "$REPO_ROOT" && bash "$SAB_REL" "${PASS[@]+"${PASS[@]}"}" --shard "1/$LANES") > "$WORK/lane-1.log" 2>&1 &
  else
    # staggered: concurrent CREATE DATABASE from template1 can collide
    (sleep $(( (k - 1) * 2 )); cd "$(lane_dir "$k")" && SAMEN_TEST_DB_SUFFIX="_lane$k" bash "$SAB_REL" "${PASS[@]+"${PASS[@]}"}" --shard "$k/$LANES") > "$WORK/lane-$k.log" 2>&1 &
  fi
  PIDS+=("$!")
done

RCS=()
for (( k = 1; k <= LANES; k++ )); do
  wait "${PIDS[$(( k - 1 ))]}"; RCS[k]=$?
done
PIDS=()
ELAPSED=$(( $(date +%s) - START ))

# processed_of <log> -> "n m" from the lane's own accounting line, or "" if absent.
processed_of() {
  sed -n 's/^SABOTAGE HARNESS: PROCESSED \([0-9][0-9]*\) of \([0-9][0-9]*\) SELECTED$/\1 \2/p' "$1" | tail -1
}

problems=()
SUM_N=0; SUM_M=0; SUMMARY=""
for (( k = 1; k <= LANES; k++ )); do
  log="$WORK/lane-$k.log"; rc="${RCS[$k]}"
  n=""; m=""
  read -r n m <<<"$(processed_of "$log")"
  if [[ -z "${n:-}" ]]; then
    problems+=("lane $k printed no PROCESSED accounting line (exit $rc)")
    n=0; m=0
  elif [[ "$rc" -ne 0 ]]; then
    problems+=("lane $k FAILED (exit $rc) after PROCESSED $n of $m")
  elif [[ "$n" -ne "$m" ]]; then
    problems+=("lane $k exited 0 but PROCESSED $n of $m — a short lane is not coverage")
  elif [[ "$n" -eq 0 ]]; then
    problems+=("lane $k PROCESSED 0 patches — a lane that does nothing certifies nothing")
  fi
  SUM_N=$((SUM_N + n)); SUM_M=$((SUM_M + m))
  SUMMARY+="lane $k PROCESSED $n of $m · "
done

[[ $SUM_M -eq $TOTAL ]] || problems+=("the lanes SELECTED $SUM_M patches in total, but the selection is $TOTAL — the partition is not total")
[[ $SUM_N -eq $TOTAL ]] || problems+=("the lanes PROCESSED $SUM_N patches in total, not the $TOTAL selected")
for (( k = 1; k <= LANES; k++ )); do
  if (( k == 1 )); then d="$REPO_ROOT"; else d="$(lane_dir "$k")"; [[ "$(git -C "$d" rev-parse HEAD)" == "$HEAD_SHA" ]] || problems+=("lane-$k tree moved off $HEAD_SHA during the run"); fi
  [[ "$(git -C "$d" status --porcelain)" == "$(cat "$WORK/status.$k")" ]] || problems+=("the lane-$k tree changed during the run — residue")
done

for (( k = 1; k <= LANES; k++ )); do
  echo ""
  echo "──────── lane $k log ────────"
  cat "$WORK/lane-$k.log"
done

echo ""
echo "SABOTAGE LANES: ${SUMMARY}${ELAPSED}s wall"
if [[ ${#problems[@]} -gt 0 ]]; then
  for p in "${problems[@]}"; do echo "  !! $p"; done
  echo "SABOTAGE HARNESS: PROCESSED $SUM_N of $TOTAL SELECTED"
  echo "SABOTAGE HARNESS: FAILED — lanes mode (see the lane logs above; each names its failing patch and what it never exercised)"
  exit 1
fi

echo "SABOTAGE HARNESS: PROCESSED $SUM_N of $TOTAL SELECTED"
echo "SABOTAGE HARNESS: ALL PASSED ($SUM_N sabotages flipped their named tests; byte-exact restores; $LANES lanes, commit ${HEAD_SHA:0:7})"
