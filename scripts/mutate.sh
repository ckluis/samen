#!/usr/bin/env bash
# scripts/mutate.sh -- a source-level MUTATION-TESTING harness for the samen repo.
#
# The sabotage harness (scripts/sabotage.sh) proves the guards someone remembered to
# sabotage. This tool finds the guards with NO proof at all. For each target guard it
# parses out the mutable sites, and for each site it writes a mutated copy of the source,
# runs a SCOPED test command, and classifies the outcome:
#
#   test command FAILS    -> mutant KILLED    (a test caught the change -- the guard is proven)
#   test command PASSES   -> mutant SURVIVED   (NOTHING asserts this guard -- reported loudly)
#   mutant does not COMPILE-> mutant STILLBORN (reported separately: not a kill, not a survivor)
#
# ---- THE OPERATORS (declared in scripts/mutate_ops.py; add a fifth without touching core) --
#   drop-conjunct    `A and B` -> `A` (and -> `B`).  flip-comparison   > <-> <= , < <-> >= , == <-> !=
#   force-guard      condition -> true, then false.  tuple-arm         arm body -> passthrough
# The operator set lives in mutate_ops.py's OPERATORS registry + OPERATOR_ORDER list; the
# per-target operator SELECTION lives in the TARGETS config (below / --targets file).
#
# ---- TARGETS & THE TEST MAPPING (a config LIST, so more can be added with no code change) --
# Each target is one `|`-delimited record: LABEL | FILE | ANCHOR | OPS | TESTDIR | COMPILE | TEST
#   LABEL    human name (e.g. context_gate/6)
#   FILE     repo-relative source file to mutate
#   ANCHOR   a Python-regex that uniquely matches the target clause's OPENING line; the
#            clause spans from it to the matching `end` at the same indentation.
#   OPS      comma-separated operator names to apply to this target
#   TESTDIR  repo-relative dir the COMPILE/TEST commands run in (`.` = repo root)
#   COMPILE  command that must exit 0 for the mutant to be considered compilable
#   TEST     the SCOPED test command; its EXIT STATUS alone decides KILLED vs SURVIVED.
# The v1 built-in list is in builtin_targets(). Add the chokepoint/pii/egress guards later
# by appending records -- no engine change. Override the whole list with `--targets <file>`.
#
# How the mapping was chosen: each target's TEST names only the test files that exercise it.
# context_gate/6 is called from the agent run loop; test/ai/agent_loop_test.exs drives that
# loop (fast, no DB) -- and NO test on main asserts context exhaustion, which is precisely
# why every context_gate mutant SURVIVES. That survivor is the finding, not a mapping bug.
#
# ---- NON-NEGOTIABLES enforced here (each earned the hard way in this project) --------------
#  1. BYTE-EXACT RESTORE, sha-256 verified, on EVERY exit path incl. SIGINT/SIGTERM. Each
#     target is snapshotted before mutation and restored+re-verified after every mutant and
#     in a trap covering INT/TERM/EXIT. The run ends with `git status --porcelain` (scoped to
#     the target files) empty -- asserted.
#  2. The KILLED/SURVIVED decision reads the test command's status DIRECTLY: `cmd; rc=$?` on
#     the very next line. `out=$(cmd); rc=$?` (pipeline status) is BANNED and never used for a
#     verdict. Command output goes to log FILES via redirection, which keeps rc the command's.
#  3. PROCESSED-vs-GENERATED accounting: every run ends with a MUTANTS: line and reconciles
#     generated == run + skipped. An abort names what it did not run.
#  4. `while IFS= read -r`, never `for f in $LIST` (zsh/bash word-split safety).
#
# ---- USAGE --------------------------------------------------------------------------------
#   scripts/mutate.sh                 run all built-in v1 targets
#   scripts/mutate.sh --only <substr> run only built-in targets whose LABEL/FILE matches
#   scripts/mutate.sh --targets <f>   load targets from <f> instead of the built-in list
#   scripts/mutate.sh --list          print the resolved target set and exit
# Exit: 0 = ran cleanly (tree restored), even if survivors were found (they are informational);
#       non-zero = operational failure (restore mismatch / dirty tree / accounting mismatch)
#       or aborted by signal (130).
# Opt-in only: this tool is standalone and additive. It is NOT wired into ci.sh.
#
# Testability hook: MUTATE_PAUSE_BEFORE_RESTORE=<secs> sleeps while a mutant is live on disk,
# before restoring -- used only by scripts/mutate_test.sh's SIGINT proof to widen the window.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$REPO_ROOT/scripts/mutate_ops.py"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mutate.XXXXXX")"

TARGETS_FILE=""
LIST_ONLY=0
declare -a ONLY_FILTERS=()

# ---- accounting counters (non-negotiable #3) ----------------------------------------------
g_generated=0
n_killed=0
n_survived=0
n_stillborn=0
n_skipped=0
declare -a SURVIVOR_LINES=()
declare -a STILLBORN_LINES=()
declare -a SKIPPED_TARGETS=()

# ---- snapshot registry for byte-exact restore (non-negotiable #1) -------------------------
declare -a SNAP_TARGET=()   # repo-relative target file paths
declare -a SNAP_FILE=()     # snapshot absolute paths
declare -a SNAP_SHA=()      # baseline sha-256

sha_of() { shasum -a 256 "$1" | awk '{print $1}'; }

register_snapshot() { # register_snapshot <repo-rel-file>
  local rel="$1" snap
  snap="$WORK/snap_${#SNAP_TARGET[@]}.orig"
  cp "$REPO_ROOT/$rel" "$snap"
  SNAP_TARGET+=("$rel")
  SNAP_FILE+=("$snap")
  SNAP_SHA+=("$(sha_of "$snap")")
}

restore_all() { # cp every snapshot back over its target (idempotent, byte-exact)
  local i
  for i in "${!SNAP_TARGET[@]}"; do
    [[ -f "${SNAP_FILE[$i]}" ]] && cp "${SNAP_FILE[$i]}" "$REPO_ROOT/${SNAP_TARGET[$i]}"
  done
}

verify_all_restored() { # 0 iff every target's sha == its baseline snapshot sha
  local i now rc=0
  for i in "${!SNAP_TARGET[@]}"; do
    now="$(sha_of "$REPO_ROOT/${SNAP_TARGET[$i]}")"
    if [[ "$now" != "${SNAP_SHA[$i]}" ]]; then
      echo "!! RESTORE MISMATCH: ${SNAP_TARGET[$i]} (sha ${now} != baseline ${SNAP_SHA[$i]})"
      rc=1
    fi
  done
  return $rc
}

print_accounting() { # print_accounting <status-word>
  local status="$1"
  local run=$((n_killed + n_survived + n_stillborn))
  local line="MUTANTS: generated ${g_generated}, run ${run}, killed ${n_killed}, survived ${n_survived}, stillborn ${n_stillborn}"
  [[ $n_skipped -gt 0 ]] && line="${line}, skipped ${n_skipped}"
  echo "$line"
  local accounted=$((run + n_skipped))
  local not_run=$((g_generated - accounted))
  if [[ "$status" == COMPLETE ]]; then
    # On a clean run the books MUST balance: generated == run + skipped.
    if [[ $accounted -ne $g_generated ]]; then
      echo "!! ACCOUNTING MISMATCH: generated(${g_generated}) != run(${run}) + skipped(${n_skipped})"
      ACCOUNTING_OK=0
    fi
  elif [[ $not_run -gt 0 ]]; then
    # On an abort the gap is expected -- but it must be NAMED, never read as clean.
    echo "   NOT RUN (aborted before completion): ${not_run} mutant(s)"
  fi
  if [[ ${#SKIPPED_TARGETS[@]} -gt 0 ]]; then
    local t
    for t in "${SKIPPED_TARGETS[@]}"; do echo "   NOT RUN (baseline red): $t"; done
  fi
  echo "RUN STATUS: $status"
}

ACCOUNTING_OK=1

on_signal() {
  trap - INT TERM EXIT
  echo
  echo "!! SIGNAL received mid-run -- restoring tree from snapshots before exit"
  restore_all
  verify_all_restored && echo "   restore: byte-exact (sha-256 verified)"
  echo
  print_accounting "ABORTED (signal)"
  exit 130
}

cleanup() { # EXIT trap: restore (idempotent) + scrub scratch
  restore_all
  rm -rf "$WORK"
}
trap on_signal INT TERM
trap cleanup EXIT

# ---- the v1 built-in target list (a config LIST; append records to extend) -----------------
builtin_targets() {
  cat <<'TARGETS'
context_gate/6|samen_core/lib/samen/ai/agent.ex|^  defp context_gate\(|drop-conjunct,flip-comparison,force-guard|samen_core|mix compile|mix test test/ai/agent_loop_test.exs
dispatch/4:complete|samen_core/lib/samen/ai/chokepoint.ex|^  defp dispatch\(provider, :complete,|tuple-arm,force-guard|samen_core|mix compile|mix test test/chokepoint_test.exs
TARGETS
}

# ---- arg parsing --------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --targets) TARGETS_FILE="$2"; shift 2 ;;
    --only)    ONLY_FILTERS+=("$2"); shift 2 ;;
    --list)    LIST_ONLY=1; shift ;;
    -h|--help) sed -n '2,60p' "$0"; exit 0 ;;
    *) echo "mutate.sh: unknown arg '$1'" >&2; exit 64 ;;
  esac
done

target_source() {
  if [[ -n "$TARGETS_FILE" ]]; then cat "$TARGETS_FILE"; else builtin_targets; fi
}

matches_filter() { # matches_filter <label> <file>
  [[ ${#ONLY_FILTERS[@]} -eq 0 ]] && return 0
  local f
  for f in "${ONLY_FILTERS[@]}"; do
    [[ "$1" == *"$f"* || "$2" == *"$f"* ]] && return 0
  done
  return 1
}

# ---- --list mode: resolve and print the selected targets, run nothing ----------------------
if [[ $LIST_ONLY -eq 1 ]]; then
  echo "== mutate.sh selected targets =="
  while IFS='|' read -r label file anchor ops tdir ccmd tcmd; do
    [[ -z "${label// }" || "${label:0:1}" == "#" ]] && continue
    matches_filter "$label" "$file" || continue
    echo "  $label -> $file   [ops: $ops]   test: ($tdir) $tcmd"
  done < <(target_source)
  exit 0
fi

echo "== samen mutation-testing harness =="
echo "   repo:    $REPO_ROOT"
echo "   scratch: $WORK"
echo

# ---- main loop ----------------------------------------------------------------------------
while IFS='|' read -r label file anchor ops tdir ccmd tcmd; do
  [[ -z "${label// }" || "${label:0:1}" == "#" ]] && continue
  # trim surrounding whitespace on each field
  label="${label#"${label%%[![:space:]]*}"}"; label="${label%"${label##*[![:space:]]}"}"
  file="${file#"${file%%[![:space:]]*}"}";    file="${file%"${file##*[![:space:]]}"}"
  anchor="${anchor#"${anchor%%[![:space:]]*}"}"; anchor="${anchor%"${anchor##*[![:space:]]}"}"
  ops="${ops#"${ops%%[![:space:]]*}"}";       ops="${ops%"${ops##*[![:space:]]}"}"
  tdir="${tdir#"${tdir%%[![:space:]]*}"}";     tdir="${tdir%"${tdir##*[![:space:]]}"}"
  ccmd="${ccmd#"${ccmd%%[![:space:]]*}"}";     ccmd="${ccmd%"${ccmd##*[![:space:]]}"}"
  tcmd="${tcmd#"${tcmd%%[![:space:]]*}"}";     tcmd="${tcmd%"${tcmd##*[![:space:]]}"}"

  matches_filter "$label" "$file" || continue

  echo "── TARGET: $label  ($file)"
  if [[ ! -f "$REPO_ROOT/$file" ]]; then
    echo "   !! source not found -- skipping"; SKIPPED_TARGETS+=("$label (no source)"); continue
  fi

  register_snapshot "$file"

  # Enumerate mutants FIRST (so a skipped target still contributes to `generated`).
  mutdir="$WORK/mut_$(echo "$label" | tr -c 'A-Za-z0-9' '_')"
  index="$WORK/index_$(echo "$label" | tr -c 'A-Za-z0-9' '_').tsv"
  python3 "$HELPER" generate "$REPO_ROOT/$file" "$anchor" "$ops" "$mutdir" >"$index"
  gen_rc=$?
  if [[ $gen_rc -ne 0 ]]; then
    echo "   !! enumeration failed (rc=$gen_rc) -- skipping"; SKIPPED_TARGETS+=("$label (enum rc=$gen_rc)"); continue
  fi
  anchor_line="$(awk -F'\t' '$1=="ANCHOR"{print $2}' "$index")"; anchor_line="${anchor_line#"$REPO_ROOT"/}"
  n_mut=$(awk -F'\t' '$1!="ANCHOR"{c++} END{print c+0}' "$index")
  echo "   clause: $anchor_line   mutants: $n_mut   ops: $ops"
  g_generated=$((g_generated + n_mut))

  # BASELINE GATE: the scoped test MUST be green on the pristine file, else every verdict
  # under it is noise. Capture rc DIRECTLY (non-negotiable #2). A red baseline SKIPS the
  # target -- its mutants are counted as skipped, never inferred as kills.
  ( cd "$REPO_ROOT/$tdir" && eval "$ccmd" ) >"$WORK/baseline_compile.log" 2>&1
  base_crc=$?
  if [[ $base_crc -ne 0 ]]; then
    echo "   !! baseline COMPILE failed (rc=$base_crc) -- target SKIPPED; $n_mut mutant(s) not run"
    tail -3 "$WORK/baseline_compile.log" | sed 's/^/      /'
    n_skipped=$((n_skipped + n_mut)); SKIPPED_TARGETS+=("$label (baseline compile red)"); continue
  fi
  ( cd "$REPO_ROOT/$tdir" && eval "$tcmd" ) >"$WORK/baseline_test.log" 2>&1
  base_trc=$?
  if [[ $base_trc -ne 0 ]]; then
    echo "   !! baseline TEST failed (rc=$base_trc) -- target SKIPPED; $n_mut mutant(s) not run"
    tail -3 "$WORK/baseline_test.log" | sed 's/^/      /'
    n_skipped=$((n_skipped + n_mut)); SKIPPED_TARGETS+=("$label (baseline test red)"); continue
  fi
  echo "   baseline: compile + scoped test GREEN"

  # snapshot index for THIS target's baseline sha (already in registry)
  snap_idx=$((${#SNAP_TARGET[@]} - 1))
  base_sha="${SNAP_SHA[$snap_idx]}"

  # ---- run each mutant --------------------------------------------------------------------
  while IFS=$'\t' read -r seq op loc desc; do
    [[ "$seq" == "ANCHOR" ]] && continue
    loc="${loc#"$REPO_ROOT"/}"   # report repo-relative file:line, not the scratch abs path
    cp "$mutdir/${seq}.mut" "$REPO_ROOT/$file"

    # compile step -> STILLBORN if it does not compile (rc captured directly)
    ( cd "$REPO_ROOT/$tdir" && eval "$ccmd" ) >"$WORK/compile.log" 2>&1
    crc=$?
    if [[ $crc -ne 0 ]]; then
      n_stillborn=$((n_stillborn + 1))
      echo "   STILLBORN $loc  [$op]  $desc  (did not compile)"
      STILLBORN_LINES+=("$loc  [$op]  $desc")
    else
      # scoped test -> its EXIT STATUS alone is the verdict (non-negotiable #2)
      ( cd "$REPO_ROOT/$tdir" && eval "$tcmd" ) >"$WORK/test.log" 2>&1
      trc=$?
      if [[ $trc -ne 0 ]]; then
        n_killed=$((n_killed + 1))
        echo "   KILLED    $loc  [$op]  $desc"
      else
        n_survived=$((n_survived + 1))
        echo "   >>> SURVIVED  $loc  [$op]  $desc"
        SURVIVOR_LINES+=("$loc  [$op]  $desc")
      fi
    fi

    # testability window: mutant is still live on disk here (SIGINT proof).
    [[ -n "${MUTATE_PAUSE_BEFORE_RESTORE:-}" ]] && sleep "$MUTATE_PAUSE_BEFORE_RESTORE"

    # BYTE-EXACT restore + per-mutant verify (non-negotiable #1)
    cp "${SNAP_FILE[$snap_idx]}" "$REPO_ROOT/$file"
    now_sha="$(sha_of "$REPO_ROOT/$file")"
    if [[ "$now_sha" != "$base_sha" ]]; then
      echo "   !! per-mutant restore FAILED for $file -- aborting"
      exit 3
    fi
  done < "$index"
  echo "   restore: $file byte-exact after every mutant (sha-256 $base_sha)"
  echo
done < <(target_source)

# ---- final restore + verification ---------------------------------------------------------
restore_all
if ! verify_all_restored; then
  echo "!! FINAL RESTORE VERIFICATION FAILED"; print_accounting "FAILED (restore)"; exit 4
fi

# git status scoped to the target files must show no MODIFICATION residue (the tool left the
# tracked tree byte-exact). Untracked entries (`??`) are ignored: a target that was untracked
# to begin with -- e.g. a self-test scratch fixture -- is not residue. The sha-256 re-verify
# above is the primary, tracked-or-not, byte-exact proof.
dirty=""
if [[ ${#SNAP_TARGET[@]} -gt 0 ]]; then
  dirty="$(cd "$REPO_ROOT" && git status --porcelain -- "${SNAP_TARGET[@]}" 2>/dev/null | /usr/bin/grep -v '^??' || true)"
fi
if [[ -n "$dirty" ]]; then
  echo "!! TARGET FILES DIRTY after run:"; echo "$dirty"; print_accounting "FAILED (dirty tree)"; exit 5
fi
echo "restore: all targets byte-exact; git status (targets) clean"
echo

# ---- loud survivor report -----------------------------------------------------------------
if [[ ${#SURVIVOR_LINES[@]} -gt 0 ]]; then
  echo "════════ SURVIVORS (${#SURVIVOR_LINES[@]}) -- guards NO test proves ════════"
  printf '   >>> %s\n' "${SURVIVOR_LINES[@]}"
  echo
fi
if [[ ${#STILLBORN_LINES[@]} -gt 0 ]]; then
  echo "──────── STILLBORN (${#STILLBORN_LINES[@]}) -- did not compile, not a verdict ────────"
  printf '   %s\n' "${STILLBORN_LINES[@]}"
  echo
fi

print_accounting "COMPLETE"
[[ $ACCOUNTING_OK -eq 1 ]] || exit 6
exit 0
