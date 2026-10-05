#!/usr/bin/env bash
# scripts/sabotage-lanes.sh — the FULL sabotage replay in two concurrent lanes (issue #30).
#
# WHY. The serial replay (`scripts/sabotage.sh`, no flags) is ~15 min, and most of it
# is fixed per-patch cost that cannot be removed: each patch gets a fresh `mix test`,
# and the per-invocation DB drop is load-bearing (migrations run lib code, so a
# patched tree needs its schema rebuilt — the reason #30's lever 1 was dropped). What
# CAN change is scheduling. The corpus splits cleanly by the `APP:` header:
#
#   lane A — `--app samen_core`       (~58%): tests use samen_core_test only
#   lane B — `--not-app samen_core`   (~42%): samen_web / demo / driftwood / pawchart /
#                                             adapters, each with its OWN test DB
#
# The two lanes' DB sets are disjoint, so they can run at the same time. They cannot
# share one working tree: a lane-A sabotage edits samen_core/lib, and every lane-B app
# compiles samen_core as a path dep, so a shared tree would leak one lane's sabotage
# into the other's tests. So lane B runs in its OWN git worktree, checked out at the
# same commit. Each lane is the unchanged `sabotage.sh` — apply → fresh `mix test` →
# named MUST_FAIL flips → revert → SHA-256 byte-exact — so per-patch semantics and
# attribution are exactly the serial harness's. Only the scheduling changes.
#
# WHAT IT CERTIFIES — a COMMIT. Lane B's tree is a checkout of HEAD, so uncommitted
# edits would be certified in lane A and silently NOT in lane B. A dirty tree is
# therefore refused (exit 2); commit first, or run the serial `scripts/sabotage.sh`,
# which certifies the working tree as-is.
#
# ACCOUNTING — the same rule the serial harness enforces (#17), across lanes:
#   * each lane must exit 0 AND report `PROCESSED n of n SELECTED`;
#   * the two lanes' SELECTED counts must sum to the whole corpus (a partition gap
#     would certify a subset as the full run);
#   * lane B's tree must be at the certified commit, and both trees clean after.
# Any failure names the lane and prints that lane's own failure + NOT EXERCISED list.
#
# THE LANE-B TREE lives under the repository's git dir (`<git-common-dir>/samen-lanes/b`,
# override with SAMEN_LANE_B_DIR) — never tracked, never in the way — and is REUSED
# across runs, so its `_build` stays warm: only the first run pays a full compile. Each
# run resets it to the certified commit (tracked edits and untracked non-ignored files
# discarded; `_build`/`deps` kept). Missing `deps/` dirs are cloned from the main tree
# (`cp -c`, an APFS clone: no copy cost) — fetched deps never change per patch.
#
# Usage: scripts/sabotage-lanes.sh
# Exit:  0 both lanes ALL PASSED and the partition is total · 1 a lane failed or the
#        accounting does not add up · 2 environment (dirty tree, no patches, not a repo)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPLIT_APP="samen_core"
SAB_REL="scripts/sabotage.sh"

env_err() { echo "SABOTAGE LANES: $1" >&2; exit 2; }

git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1 || env_err "$REPO_ROOT is not a git repository"

if [[ -n "$(git -C "$REPO_ROOT" status --porcelain)" ]]; then
  git -C "$REPO_ROOT" status --short | head -10 >&2
  env_err "the working tree is DIRTY. Lanes mode certifies a COMMIT (lane B runs in a checkout of HEAD, so uncommitted edits would be certified in one lane and not the other). Commit first, or run the serial scripts/sabotage.sh, which certifies the working tree as-is."
fi

HEAD_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD)"
TOTAL="$(find "$REPO_ROOT/scripts/sabotages" -maxdepth 1 -name '*.patch' | wc -l | tr -d ' ')"
[[ "$TOTAL" -gt 0 ]] || env_err "no patches in scripts/sabotages"

COMMON_DIR="$(cd "$REPO_ROOT" && cd "$(git rev-parse --git-common-dir)" && pwd)"
LANE_B="${SAMEN_LANE_B_DIR:-$COMMON_DIR/samen-lanes/b}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/samen_lanes.XXXXXX")"
PID_A=""; PID_B=""

cleanup() {
  # An interrupt reaches the lanes through their own traps (each sabotage.sh reverts its
  # in-flight patch on exit); this only makes sure neither is left running.
  [[ -n "$PID_A" ]] && kill "$PID_A" 2>/dev/null
  [[ -n "$PID_B" ]] && kill "$PID_B" 2>/dev/null
  wait 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

# ── lane B's tree: create once, then reset to the certified commit every run ──────────
if [[ -e "$LANE_B/.git" ]]; then
  git -C "$LANE_B" checkout -q --detach --force "$HEAD_SHA" || env_err "could not check out $HEAD_SHA in $LANE_B"
  git -C "$LANE_B" clean -q -fd
else
  mkdir -p "$(dirname "$LANE_B")"
  git -C "$REPO_ROOT" worktree add -q --detach "$LANE_B" "$HEAD_SHA" || env_err "could not create the lane-B worktree at $LANE_B"
fi
[[ "$(git -C "$LANE_B" rev-parse HEAD)" == "$HEAD_SHA" ]] || env_err "lane-B tree is not at $HEAD_SHA"
[[ -z "$(git -C "$LANE_B" status --porcelain)" ]] || env_err "lane-B tree is not clean after reset"

for deps in "$REPO_ROOT"/*/deps; do
  [[ -d "$deps" ]] || continue
  app="$(basename "$(dirname "$deps")")"
  [[ -d "$LANE_B/$app" && ! -e "$LANE_B/$app/deps" ]] || continue
  cp -Rc "$deps" "$LANE_B/$app/deps" 2>/dev/null || cp -R "$deps" "$LANE_B/$app/deps"
done

echo "SABOTAGE LANES: certifying commit $HEAD_SHA — $TOTAL patches in 2 lanes"
echo "  lane A: --app $SPLIT_APP      in $REPO_ROOT"
echo "  lane B: --not-app $SPLIT_APP  in $LANE_B"
START=$(date +%s)

(cd "$REPO_ROOT" && bash "$SAB_REL" --app "$SPLIT_APP") > "$WORK/lane-a.log" 2>&1 &
PID_A=$!
(cd "$LANE_B" && bash "$SAB_REL" --not-app "$SPLIT_APP") > "$WORK/lane-b.log" 2>&1 &
PID_B=$!

wait "$PID_A"; RC_A=$?
wait "$PID_B"; RC_B=$?
PID_A=""; PID_B=""
ELAPSED=$(( $(date +%s) - START ))

# processed_of <log> -> "n m" from the lane's own accounting line, or "" if absent.
processed_of() {
  sed -n 's/^SABOTAGE HARNESS: PROCESSED \([0-9][0-9]*\) of \([0-9][0-9]*\) SELECTED$/\1 \2/p' "$1" | tail -1
}

problems=()
for lane in A B; do
  log="$WORK/lane-$(echo "$lane" | tr 'AB' 'ab').log"
  rc=$([[ $lane == A ]] && echo "$RC_A" || echo "$RC_B")
  read -r n m <<<"$(processed_of "$log")"
  if [[ -z "${n:-}" ]]; then
    problems+=("lane $lane printed no PROCESSED accounting line (exit $rc)")
  elif [[ "$rc" -ne 0 ]]; then
    problems+=("lane $lane FAILED (exit $rc) after PROCESSED $n of $m")
  elif [[ "$n" -ne "$m" ]]; then
    problems+=("lane $lane exited 0 but PROCESSED $n of $m — a short lane is not coverage")
  fi
  eval "N_$lane=\${n:-0}; M_$lane=\${m:-0}"
done

if [[ ${#problems[@]} -eq 0 && $((M_A + M_B)) -ne $TOTAL ]]; then
  problems+=("the lanes SELECTED $M_A + $M_B = $((M_A + M_B)) patches, but the corpus has $TOTAL — the partition is not total")
fi
[[ "$(git -C "$LANE_B" rev-parse HEAD)" == "$HEAD_SHA" ]] || problems+=("lane-B tree moved off $HEAD_SHA during the run")
[[ -z "$(git -C "$REPO_ROOT" status --porcelain)" ]] || problems+=("the main tree is DIRTY after the run — residue")
[[ -z "$(git -C "$LANE_B" status --porcelain)" ]] || problems+=("the lane-B tree is DIRTY after the run — residue")

for lane in a b; do
  echo ""
  echo "──────── lane $(echo "$lane" | tr 'ab' 'AB') log ────────"
  cat "$WORK/lane-$lane.log"
done

echo ""
echo "SABOTAGE LANES: lane A PROCESSED $N_A of $M_A · lane B PROCESSED $N_B of $M_B · ${ELAPSED}s wall"
if [[ ${#problems[@]} -gt 0 ]]; then
  for p in "${problems[@]}"; do echo "  !! $p"; done
  echo "SABOTAGE HARNESS: PROCESSED $((N_A + N_B)) of $TOTAL SELECTED"
  echo "SABOTAGE HARNESS: FAILED — lanes mode (see the lane logs above; each names its failing patch and what it never exercised)"
  exit 1
fi

echo "SABOTAGE HARNESS: PROCESSED $((N_A + N_B)) of $TOTAL SELECTED"
echo "SABOTAGE HARNESS: ALL PASSED ($((N_A + N_B)) sabotages flipped their named tests; byte-exact restores; 2 lanes, commit ${HEAD_SHA:0:7})"
