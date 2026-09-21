#!/usr/bin/env bash
# scripts/mutate.sh — the MUTATION GATE (ADR-049).
#
# ── WHAT THIS ADDS THAT THE SABOTAGE HARNESS CANNOT ──────────────────────────
# `scripts/sabotage.sh` replays 328 HAND-AUTHORED patches and proves each still
# flips its NAMED tests. That answers: "are the guarantees this repo claims still
# guarded?" It cannot answer the converse — "is there some OTHER way to break
# this same file that these same tests do NOT catch?" — because every sabotage is
# a claim someone already thought to make. The blind spot is structural: a
# sabotage corpus can only ever cover the failure modes its authors imagined.
#
# This harness closes that. For every file on the watch-list it ENUMERATES every
# mutation site mechanically (scripts/mutation/mutate.exs — AST-derived, four
# operator families), applies each one, and requires the file's OWNING tests to
# kill it. A mutant that SURVIVES is a hole immediately adjacent to a guarantee
# the repo already claims to hold, named down to file:line:operator. That is the
# one thing the sabotage corpus structurally cannot produce: evidence about the
# failure modes nobody thought of.
#
# ── SPECIFICITY IS PRESERVED (the house objection, answered) ─────────────────
# The repo's standing objection to mutation testing is that it "counts breakage"
# instead of proving the guarantee is where you claim it is. That objection
# applies to whole-suite mutation testing, and this harness does not do that:
# each mutant runs ONLY the OWNING test files declared for that target, so a
# kill is ATTRIBUTED by construction — killed by the suite that claims to guard
# the file, not by some unrelated test three apps away. Where the owning-test
# mapping comes from the sabotage corpus (most of it does), the attribution is
# already gate-proven.
#
# ── THE FIVE CONTRACTS (do not weaken any of them) ───────────────────────────
#  1. BASELINE GREEN FIRST. Before a target's first mutant, its owning tests run
#     UNMUTATED and MUST pass. Skipping this is the vacuity that makes mutation
#     testing lie: against an already-red suite EVERY mutant scores as killed and
#     the gate reports a confident 100%.
#  2. A KILL IS A NAMED TEST FAILURE. The run must fail AND emit at least one
#     `N) test ...` header. A non-zero exit with no test headers means the mutant
#     never reached a test: the COMPILER refused it. That is scored
#     BUILD-REFUSED, never a kill. The distinction is the whole point — a
#     build-refused mutant cannot exist in a tree that compiles (it is
#     correct-by-construction, no test owes anything), whereas scoring it as a
#     kill would credit the test suite for work the compiler did, which is this
#     family's other false green. The gate deliberately does NOT pass
#     `--warnings-as-errors` to the owning suites, so a mere warning can never
#     masquerade as either a kill or a refusal.
#  3. BYTE-EXACT RESTORE. Every target is snapshotted before its first mutant and
#     restored + SHA-256 verified after every single one, on every exit path
#     including SIGINT/SIGTERM. Residue fails the run.
#  4. A SURVIVOR FAILS THE GATE unless it carries a ledger entry
#     (scripts/mutation/ledger.tsv) that is CONTENT-PINNED: the exemption names
#     the SHA-256 of the source line it excuses, so editing that line EXPIRES the
#     exemption and forces a re-justification. Exemptions cannot rot.
#  5. THE FULL REPORT COMES FIRST. Unlike sabotage.sh (fail-fast), this runs the
#     whole selection and fails at the END, because the value of a mutation run
#     is the complete survivor list, not the first one.
#
# ── SELECTION ────────────────────────────────────────────────────────────────
# Default (no flags) = the TIER-1 watch-list in scripts/mutation/targets.tsv:
# the structural chokepoints and guards, ~60 mutants, a few minutes. That is the
# set wired into ci.sh.
#   --corpus            DERIVE the target set from the sabotage corpus instead:
#                       every lib/ file any scripts/sabotages/*.patch touches,
#                       its owning tests being the UNION of those patches'
#                       TEST_FILES headers. 163 rows / 2,852 mutants — a soak,
#                       not a gate step. Run backgrounded or in --shard chunks.
#   --all               tier-1 targets UNION the derived corpus.
#   --app <name>        only targets in that app.
#   --file <relpath>    only that one target file.
#   --family <NAME>     only mutants of one operator family (EQ|REL|BOOLOP|BOOLLIT).
#   --changed [<ref>]   only targets whose file is in the UNION of
#                       `git diff --name-only <ref>` and `git ls-files --others
#                       --exclude-standard`. The untracked half is load-bearing
#                       for the same reason it is in sabotage.sh: `git diff`
#                       never lists new files, so without it a batch that ADDS a
#                       guard module selects NONE of its own mutants.
#   --shard <i>/<n>     a DETERMINISTIC 1-based partition of the selected mutant
#                       list (index mod n == i-1). The n shards are disjoint and
#                       their union is the whole selection, so a 2,852-mutant soak
#                       can be swept across runs without overlap or gaps.
#   --list, --dry-run   print the selected mutants (and per-file counts) and EXIT.
#                       Applies nothing, runs nothing, needs no DB.
#   --emit-patches <d>  write each SURVIVOR as a sabotage-format .patch into <d>,
#                       headers pre-filled, MUST_FAIL left as a TODO — the
#                       promotion path: write the test, fill MUST_FAIL, move it
#                       into scripts/sabotages/ and the hole becomes a permanent
#                       committed guarantee.
#   --targets <file>    override the watch-list (the self-test uses this).
#   --ledger <file>     override the exemption ledger (ditto).
#
# Repeating the SAME flag is an error (house rule, matching sabotage.sh); different
# flags compose as an INTERSECTION. A FILTERED run's success line is deliberately
# distinct from a full run's so a partial sweep can never read as full coverage.
#
# ── ENV ──────────────────────────────────────────────────────────────────────
#   SAMEN_MUTATION_RUNNER  the test command, run with cwd = the target's app dir
#                          and $MUT_TEST_FILES / $MUT_PHASE (baseline|mutant) /
#                          $MUT_TARGET exported. Default: `mix test $MUT_TEST_FILES`.
#                          Exists so scripts/mutation_selection_test.sh can drive
#                          the harness's own scoring logic with a stub runner and
#                          no database.
#
# Needs: elixir (the engine) and, for a real run, local Postgres (the owning
# suites are DB-backed). Exits non-zero on a surviving unexempted mutant, a red
# baseline, residue, an unknown flag, or an empty selection.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE="$REPO_ROOT/scripts/mutation/mutate.exs"
TARGETS_FILE="$REPO_ROOT/scripts/mutation/targets.tsv"
LEDGER_FILE="$REPO_ROOT/scripts/mutation/ledger.tsv"
SABOTAGE_DIR="$REPO_ROOT/scripts/sabotages"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/samen_mutation.XXXXXX")"

RUNNER="${SAMEN_MUTATION_RUNNER:-mix test \$MUT_TEST_FILES}"

# In-flight restore state: the file currently mutated + its pristine snapshot.
INFLIGHT_TARGET=""
INFLIGHT_SNAPSHOT=""

cleanup() {
  # Contract 3: never leave a mutated tree behind, on ANY exit path.
  if [[ -n "$INFLIGHT_TARGET" && -n "$INFLIGHT_SNAPSHOT" && -f "$INFLIGHT_SNAPSHOT" ]]; then
    echo "!! cleanup: restoring in-flight mutant target $INFLIGHT_TARGET"
    cp "$INFLIGHT_SNAPSHOT" "$REPO_ROOT/$INFLIGHT_TARGET" || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

fail() {
  echo ""
  echo "MUTATION GATE: FAILED — $1"
  exit 1
}

arg_err() {
  echo "mutate.sh: $1" >&2
  echo "" >&2
  echo "Run 'mutate.sh --list' to preview a selection, or see this script's header" >&2
  echo "for the full flag reference." >&2
  exit 2
}

usage() {
  sed -n '/^# ── SELECTION/,/^# ── ENV/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# ── argument parsing ─────────────────────────────────────────────────────────
MODE="tier1"            # tier1 | corpus | all
FILTER_APP=""
FILTER_FILE=""
FILTER_FAMILY=""
TOUCH_MODE=0
TOUCH_DESC=""
TOUCH_SET="$WORK/touch_set"; : > "$TOUCH_SET"
SHARD_I=""; SHARD_N=""
LIST_ONLY=0
EMIT_DIR=""
SEEN_MODE=0; MODE_FIRST=""
SEEN_APP=0; APP_FIRST=""
SEEN_FILE=0; FILE_FIRST=""
SEEN_FAMILY=0; FAMILY_FIRST=""
SEEN_CHANGED=0; CHANGED_FIRST=""
SEEN_SHARD=0; SHARD_FIRST=""
SEEN_EMIT=0; EMIT_FIRST=""
SEEN_TARGETS=0; SEEN_LEDGER=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --corpus|--all)
      if [[ $SEEN_MODE -eq 1 ]]; then
        arg_err "target-set mode given twice ('$MODE_FIRST' and '$1') — repeating the same flag is an error"
      fi
      [[ "$1" == "--corpus" ]] && MODE="corpus" || MODE="all"
      MODE_FIRST="$1"; SEEN_MODE=1; shift ;;
    --app)
      shift; [[ $# -gt 0 ]] || arg_err "--app requires a name"
      [[ $SEEN_APP -eq 0 ]] || arg_err "--app given twice: '$APP_FIRST' and '$1' — run separate invocations"
      FILTER_APP="$1"; APP_FIRST="$1"; SEEN_APP=1; shift ;;
    --file)
      shift; [[ $# -gt 0 ]] || arg_err "--file requires a repo-relative path"
      [[ $SEEN_FILE -eq 0 ]] || arg_err "--file given twice: '$FILE_FIRST' and '$1' — run separate invocations"
      FILTER_FILE="$1"; FILE_FIRST="$1"; SEEN_FILE=1; shift ;;
    --family)
      shift; [[ $# -gt 0 ]] || arg_err "--family requires EQ|REL|BOOLOP|BOOLLIT"
      [[ $SEEN_FAMILY -eq 0 ]] || arg_err "--family given twice: '$FAMILY_FIRST' and '$1' — run separate invocations"
      case "$1" in
        EQ|REL|BOOLOP|BOOLLIT) ;;
        *) arg_err "--family wants EQ|REL|BOOLOP|BOOLLIT, got: $1" ;;
      esac
      FILTER_FAMILY="$1"; FAMILY_FIRST="$1"; SEEN_FAMILY=1; shift ;;
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
      [[ $SEEN_CHANGED -eq 0 ]] || arg_err "--changed given twice: '$CHANGED_FIRST' and '$changed_ref' — run separate invocations"
      # The union with untracked files is load-bearing, not belt-and-braces: see
      # scripts/sabotage_selection_test.sh for the miss this closes.
      git -C "$REPO_ROOT" diff --name-only "$changed_ref" >> "$TOUCH_SET"
      git -C "$REPO_ROOT" ls-files --others --exclude-standard >> "$TOUCH_SET"
      TOUCH_MODE=1
      TOUCH_DESC="changed=${changed_ref}+untracked"
      CHANGED_FIRST="$changed_ref"; SEEN_CHANGED=1 ;;
    --shard)
      shift; [[ $# -gt 0 ]] || arg_err "--shard requires <i>/<n>"
      [[ $SEEN_SHARD -eq 0 ]] || arg_err "--shard given twice: '$SHARD_FIRST' and '$1' — run separate invocations"
      if [[ "$1" =~ ^([0-9]+)/([0-9]+)$ ]]; then
        SHARD_I="${BASH_REMATCH[1]}"; SHARD_N="${BASH_REMATCH[2]}"
        (( SHARD_N >= 1 )) || arg_err "--shard: n must be >= 1, got: $1"
        (( SHARD_I >= 1 && SHARD_I <= SHARD_N )) || arg_err "--shard: i must be in 1..n, got: $1"
      else
        arg_err "--shard wants <i>/<n> (1-based, e.g. --shard 3/16), got: $1"
      fi
      SHARD_FIRST="$1"; SEEN_SHARD=1; shift ;;
    --emit-patches)
      shift; [[ $# -gt 0 ]] || arg_err "--emit-patches requires a directory"
      [[ $SEEN_EMIT -eq 0 ]] || arg_err "--emit-patches given twice: '$EMIT_FIRST' and '$1' — run separate invocations"
      EMIT_DIR="$1"; EMIT_FIRST="$1"; SEEN_EMIT=1; shift ;;
    --targets)
      shift; [[ $# -gt 0 ]] || arg_err "--targets requires a file"
      [[ $SEEN_TARGETS -eq 0 ]] || arg_err "--targets given twice — run separate invocations"
      [[ -f "$1" ]] || arg_err "--targets: no such file: $1"
      TARGETS_FILE="$1"; SEEN_TARGETS=1; shift ;;
    --ledger)
      shift; [[ $# -gt 0 ]] || arg_err "--ledger requires a file"
      [[ $SEEN_LEDGER -eq 0 ]] || arg_err "--ledger given twice — run separate invocations"
      [[ -f "$1" ]] || arg_err "--ledger: no such file: $1"
      LEDGER_FILE="$1"; SEEN_LEDGER=1; shift ;;
    --list|--dry-run)
      LIST_ONLY=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      arg_err "unknown flag: $1" ;;
  esac
done

FILTER_ACTIVE=0
[[ "$MODE" != "tier1" || -n "$FILTER_APP" || -n "$FILTER_FILE" || -n "$FILTER_FAMILY" \
   || $TOUCH_MODE -eq 1 || -n "$SHARD_I" ]] && FILTER_ACTIVE=1

filter_label() {
  local parts=()
  [[ "$MODE" != "tier1" ]] && parts+=("set=$MODE")
  [[ -n "$FILTER_APP" ]] && parts+=("app=$FILTER_APP")
  [[ -n "$FILTER_FILE" ]] && parts+=("file=$FILTER_FILE")
  [[ -n "$FILTER_FAMILY" ]] && parts+=("family=$FILTER_FAMILY")
  [[ $TOUCH_MODE -eq 1 ]] && parts+=("$TOUCH_DESC")
  [[ -n "$SHARD_I" ]] && parts+=("shard=${SHARD_I}/${SHARD_N}")
  local IFS=', '
  echo "${parts[*]}"
}

# ── header preflight (ALWAYS, even under a filter) ───────────────────────────
# Same discipline as scripts/sabotage.sh calling sabotage_lint.sh first: a
# malformed watch-list or ledger row is a latent bug wherever it sits, and the
# check costs milliseconds, so narrowing the run never lowers this protection.
"$REPO_ROOT/scripts/mutation_lint.sh" --targets "$TARGETS_FILE" --ledger "$LEDGER_FILE" \
  || fail "preflight failed (see above) — no mutant was applied"

# ── the target set ───────────────────────────────────────────────────────────
# Rows are `relpath \t app \t test_files`. Tier-1 rows come from the committed
# watch-list; corpus rows are DERIVED from the sabotage headers, so the
# owning-test mapping is the one the sabotage corpus already proves.
TARGET_ROWS="$WORK/targets"
: > "$TARGET_ROWS"

read_tier1_targets() {
  grep -v '^[[:space:]]*#' "$TARGETS_FILE" | grep -v '^[[:space:]]*$' | cut -f1-3
}

derive_corpus_targets() {
  local p app tf
  local raw="$WORK/corpus_raw"; : > "$raw"
  for p in "$SABOTAGE_DIR"/*.patch; do
    [[ -e "$p" ]] || continue
    app="$(sed -n 's/^# APP: //p' "$p" | head -1)"
    tf="$(sed -n 's/^# TEST_FILES: //p' "$p" | head -1)"
    [[ -n "$app" && -n "$tf" ]] || continue
    # A PIPELINE, deliberately not `while read … < <(process substitution)`. The
    # process-substitution form ABORTED this loop with SIGABRT (exit 134) partway
    # through the 328 patches, silently and with no diagnosable error — bash holds a
    # process substitution's descriptor until the enclosing FUNCTION returns, so the
    # per-iteration substitutions accumulate for the whole loop. A pipeline's
    # descriptors are reaped each iteration. Measured, not theorised: --corpus --list
    # went from exit 134 with 1 line of output to exit 0 with 2852 mutants listed.
    sed -n 's|^+++ b/||p' "$p" | sed 's/\t.*//' \
      | awk -v app="$app" -v tf="$tf" \
          'index($0, "/lib/") > 0 && /\.ex$/ { print $0 "\t" app "\t" tf }' >> "$raw"
  done
  # One row per (file, app), owning tests = the UNION of every patch's TEST_FILES.
  sort -u "$raw" | awk -F'\t' '
    { key = $1 "\t" $2
      n = split($3, parts, " ")
      for (i = 1; i <= n; i++) if (!((key SUBSEP parts[i]) in seen)) {
        seen[key SUBSEP parts[i]] = 1
        union[key] = (key in union) ? union[key] " " parts[i] : parts[i]
      }
      if (!(key in order)) { order[key] = ++c; keys[c] = key }
    }
    END { for (i = 1; i <= c; i++) print keys[i] "\t" union[keys[i]] }'
}

case "$MODE" in
  tier1)  read_tier1_targets >> "$TARGET_ROWS" ;;
  corpus) derive_corpus_targets >> "$TARGET_ROWS" ;;
  all)    { read_tier1_targets; derive_corpus_targets; } | awk -F'\t' '
             { key = $1 "\t" $2
               n = split($3, parts, " ")
               for (i = 1; i <= n; i++) if (!((key SUBSEP parts[i]) in seen)) {
                 seen[key SUBSEP parts[i]] = 1
                 union[key] = (key in union) ? union[key] " " parts[i] : parts[i]
               }
               if (!(key in order)) { order[key] = ++c; keys[c] = key }
             }
             END { for (i = 1; i <= c; i++) print keys[i] "\t" union[keys[i]] }' >> "$TARGET_ROWS" ;;
esac

# Apply the target-level filters (app / file / --changed).
FILTERED_ROWS="$WORK/targets_filtered"
: > "$FILTERED_ROWS"
while IFS=$'\t' read -r relpath app tests; do
  [[ -n "$relpath" ]] || continue
  [[ -z "$FILTER_APP" || "$app" == "$FILTER_APP" ]] || continue
  [[ -z "$FILTER_FILE" || "$relpath" == "$FILTER_FILE" ]] || continue
  if [[ $TOUCH_MODE -eq 1 ]]; then
    grep -qxF "$relpath" "$TOUCH_SET" || continue
  fi
  printf '%s\t%s\t%s\n' "$relpath" "$app" "$tests" >> "$FILTERED_ROWS"
done < "$TARGET_ROWS"

target_count=$(grep -c '' "$FILTERED_ROWS" || true)
grand_targets=$(grep -c '' "$TARGET_ROWS" || true)
[[ "$grand_targets" -gt 0 ]] || fail "no targets in the selected set ($MODE) — nothing to certify"

# ── enumerate mutants for the selected targets ───────────────────────────────
# Mutant rows: relpath \t line \t col \t family \t from \t to \t line_sha12 \t app \t tests
MUTANTS="$WORK/mutants"
: > "$MUTANTS"

while IFS=$'\t' read -r relpath app tests; do
  [[ -n "$relpath" ]] || continue
  [[ -f "$REPO_ROOT/$relpath" ]] || fail "target file does not exist: $relpath"
  sites="$WORK/sites.tmp"
  (cd "$REPO_ROOT" && elixir "$ENGINE" list "$relpath") > "$sites" 2>"$WORK/sites.err" \
    || { cat "$WORK/sites.err"; fail "engine could not enumerate $relpath"; }
  while IFS=$'\t' read -r f line col family from to lsha; do
    [[ -n "$f" ]] || continue
    [[ -z "$FILTER_FAMILY" || "$family" == "$FILTER_FAMILY" ]] || continue
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$f" "$line" "$col" "$family" "$from" "$to" "$lsha" "$app" "$tests" >> "$MUTANTS"
  done < "$sites"
done < "$FILTERED_ROWS"

total_mutants=$(grep -c '' "$MUTANTS" || true)

# Deterministic shard partition over the stable mutant order.
if [[ -n "$SHARD_I" ]]; then
  awk -F'\t' -v i="$SHARD_I" -v n="$SHARD_N" \
    '{ if ((NR - 1) % n == i - 1) print }' "$MUTANTS" > "$WORK/mutants.shard"
  mv "$WORK/mutants.shard" "$MUTANTS"
fi

sel_mutants=$(grep -c '' "$MUTANTS" || true)

# ── --list / --dry-run ───────────────────────────────────────────────────────
if [[ $LIST_ONLY -eq 1 ]]; then
  if [[ $FILTER_ACTIVE -eq 1 ]]; then
    echo "MUTATION SELECTION (FILTERED: $(filter_label)) — $sel_mutants mutants over $target_count target(s):"
  else
    echo "MUTATION SELECTION (default: tier-1 watch-list) — $sel_mutants mutants over $target_count target(s):"
  fi
  awk -F'\t' '{ printf "  %-60s %s:%s %-7s %s -> %s\n", $1, $2, $3, $4, $5, $6 }' "$MUTANTS"
  echo ""
  awk -F'\t' '{ n[$1]++ } END { for (f in n) printf "  %-60s %d mutants\n", f, n[f] }' "$MUTANTS" | sort
  echo ""
  echo "MUTATION SELECTION: $sel_mutants of $total_mutants mutants selected (dry-run — nothing applied)"
  exit 0
fi

# An empty selection certifies nothing — never a silent green.
if [[ "$sel_mutants" -eq 0 ]]; then
  fail "selection is empty ($sel_mutants mutants over $target_count target(s)) for filter [$(filter_label)] — nothing to certify"
fi

# ── ledger (exemptions) ──────────────────────────────────────────────────────
# Key: relpath | line_sha12 | col | family | from>to — pinned on the LINE'S
# CONTENT, never its number, so lines may move but not change.
LEDGER_KEYS="$WORK/ledger_keys"
: > "$LEDGER_KEYS"
LEDGER_REASONS="$WORK/ledger_reasons"
: > "$LEDGER_REASONS"
if [[ -f "$LEDGER_FILE" ]]; then
  while IFS=$'\t' read -r relpath lsha col family mutation class reason; do
    [[ -n "${relpath:-}" ]] || continue
    [[ "$relpath" == \#* ]] && continue
    printf '%s|%s|%s|%s|%s\n' "$relpath" "$lsha" "$col" "$family" "$mutation" >> "$LEDGER_KEYS"
    printf '%s|%s|%s|%s|%s\t%s\t%s\n' "$relpath" "$lsha" "$col" "$family" "$mutation" "$class" "$reason" \
      >> "$LEDGER_REASONS"
  done < <(grep -v '^[[:space:]]*#' "$LEDGER_FILE" | grep -v '^[[:space:]]*$')
fi

ledger_lookup() { # ledger_lookup <key> -> "class<TAB>reason" or empty
  grep -F "$1"$'\t' "$LEDGER_REASONS" 2>/dev/null | head -1 | cut -f2-
}

# ── run ──────────────────────────────────────────────────────────────────────
if [[ $FILTER_ACTIVE -eq 1 ]]; then
  echo "MUTATION GATE: FILTERED run — $sel_mutants of $total_mutants mutants over $target_count target(s) [$(filter_label)]"
  echo "  (a filtered run certifies ONLY this subset; full coverage needs an unfiltered/background run)"
else
  echo "MUTATION GATE: tier-1 run — $sel_mutants mutants over $target_count target(s)"
fi

run_tests() { # run_tests <app> <tests> <phase> <target> <outfile>
  local app="$1" tests="$2" phase="$3" target="$4" out="$5"
  (
    cd "$REPO_ROOT/$app" || exit 97
    export MUT_TEST_FILES="$tests" MUT_PHASE="$phase" MUT_TARGET="$target"
    eval "$RUNNER"
  ) > "$out" 2>&1
  return $?
}

# A KILL requires a NAMED test failure header (contract 2).
has_test_failures() { grep -qE '^[[:space:]]*[0-9]+\) test' "$1"; }
first_failure_name() {
  grep -E '^[[:space:]]*[0-9]+\) test' "$1" | head -1 | sed 's/^[[:space:]]*[0-9]*) //'
}

killed=0; survived=0; exempted=0; build_refused=0
SURVIVOR_LOG="$WORK/survivors"; : > "$SURVIVOR_LOG"
REFUSED_LOG="$WORK/build_refused"; : > "$REFUSED_LOG"
EVIDENCE="$WORK/evidence"; : > "$EVIDENCE"
# Ledger keys whose mutant was KILLED this run — i.e. exemptions that are no
# longer needed. On an UNFILTERED run these are refused: an exemption kept past
# the test that closed it is exactly the rot the content-pinning exists to stop.
OBSOLETE="$WORK/obsolete"; : > "$OBSOLETE"

current_target=""
snapshot=""
baseline_sha=""

while IFS=$'\t' read -r relpath line col family from to lsha app tests; do
  [[ -n "$relpath" ]] || continue

  # New target → snapshot it and prove its owning suite is GREEN unmutated.
  if [[ "$relpath" != "$current_target" ]]; then
    current_target="$relpath"
    snapshot="$WORK/snapshot.$(echo "$relpath" | tr '/' '_')"
    cp "$REPO_ROOT/$relpath" "$snapshot"
    baseline_sha="$(shasum -a 256 "$REPO_ROOT/$relpath" | cut -d' ' -f1)"

    echo ""
    echo "==> target $relpath (app: $app)"
    echo "    owning tests: $tests"

    base_out="$WORK/baseline.$(echo "$relpath" | tr '/' '_').out"
    if ! run_tests "$app" "$tests" baseline "$relpath" "$base_out"; then
      tail -30 "$base_out"
      fail "$relpath: the owning suite is RED before any mutation — every mutant would score as KILLED against it (contract 1). Fix the suite; do not run the gate over a red baseline."
    fi
    echo "    baseline: GREEN (contract 1 — mutants are scored against a passing suite)"
  fi

  mut_id="$relpath@${line}:${col} $family $from->$to"
  key="$relpath|$lsha|$col|$family|$from>$to"

  INFLIGHT_TARGET="$relpath"
  INFLIGHT_SNAPSHOT="$snapshot"

  if ! (cd "$REPO_ROOT" && elixir "$ENGINE" apply "$relpath" "$line" "$col" "$from" "$to") >"$WORK/apply.out" 2>&1; then
    cat "$WORK/apply.out"
    cp "$snapshot" "$REPO_ROOT/$relpath"
    INFLIGHT_TARGET=""; INFLIGHT_SNAPSHOT=""
    fail "$mut_id: engine refused to apply the mutant (stale site?)"
  fi

  out="$WORK/mutant.$(echo "$relpath" | tr '/' '_').${line}_${col}_${family}.out"
  run_tests "$app" "$tests" mutant "$relpath" "$out"
  status=$?

  # Restore BEFORE judging, so a failed assertion never strands a mutated tree.
  cp "$snapshot" "$REPO_ROOT/$relpath"
  INFLIGHT_TARGET=""; INFLIGHT_SNAPSHOT=""

  after_sha="$(shasum -a 256 "$REPO_ROOT/$relpath" | cut -d' ' -f1)"
  [[ "$after_sha" == "$baseline_sha" ]] \
    || fail "$mut_id: SHA-256 mismatch after restore — residue left behind (contract 3)"

  if [[ $status -eq 0 ]]; then
    # SURVIVED — the owning suite cannot tell this mutant from the real code.
    reason="$(ledger_lookup "$key")"
    if [[ -n "$reason" ]]; then
      exempted=$((exempted + 1))
      echo "    SURVIVED (ledger-exempt: $(cut -f1 <<<"$reason")) $family $from->$to at ${line}:${col}"
    else
      survived=$((survived + 1))
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$relpath" "$line" "$col" "$family" "$from" "$to" "$lsha" "$app" "$tests" >> "$SURVIVOR_LOG"
      echo "    *** SURVIVED (UNEXEMPT) $family $from->$to at ${line}:${col}"
    fi
  elif has_test_failures "$out"; then
    killed=$((killed + 1))
    if grep -qxF "$key" "$LEDGER_KEYS"; then
      printf '%s\n' "$key" >> "$OBSOLETE"
    fi
    kname="$(first_failure_name "$out")"
    echo "    killed by: $kname"
    printf '%s\t%s:%s\t%s\t%s>%s\t%s\n' "$relpath" "$line" "$col" "$family" "$from" "$to" "$kname" >> "$EVIDENCE"
  else
    # Non-zero exit with NO named test failure: the mutant never reached a test,
    # the COMPILER rejected it (contract 2). Correct-by-construction, so no test
    # owes anything — but it is NOT a kill, because crediting the suite for the
    # compiler's work is this gate's false-green mode.
    build_refused=$((build_refused + 1))
    printf '%s\t%s:%s\t%s\t%s>%s\n' "$relpath" "$line" "$col" "$family" "$from" "$to" >> "$REFUSED_LOG"
    echo "    BUILD-REFUSED (the compiler rejects this mutant — correct-by-construction, not scored as a kill) $family $from->$to at ${line}:${col}"
  fi
done < "$MUTANTS"

# ── survivor patches (the promotion path into the sabotage corpus) ───────────
if [[ -n "$EMIT_DIR" && -s "$SURVIVOR_LOG" ]]; then
  mkdir -p "$EMIT_DIR"
  n=0
  while IFS=$'\t' read -r relpath line col family from to lsha app tests; do
    n=$((n + 1))
    slug="$(basename "${relpath%.ex}" | tr '._' '-')-l${line}c${col}-$(echo "$family" | tr 'A-Z' 'a-z')"
    patch="$EMIT_DIR/$(printf '%03d' "$n")-survivor-$slug.patch"
    snap="$WORK/emit.$(echo "$relpath" | tr '/' '_')"
    cp "$REPO_ROOT/$relpath" "$snap"
    (cd "$REPO_ROOT" && elixir "$ENGINE" apply "$relpath" "$line" "$col" "$from" "$to") >/dev/null 2>&1
    {
      echo "# SABOTAGE: mutation-gate SURVIVOR — $relpath:$line ($family $from -> $to)."
      echo "# The owning suite ($tests) does NOT kill this mutation. This patch is NOT"
      echo "# a shipped sabotage yet: write the test that kills it, put that test's name in"
      echo "# MUST_FAIL, re-run scripts/mutate.sh --file $relpath to confirm the mutant now"
      echo "# dies, and only then move this file into scripts/sabotages/."
      echo "# APP: $app"
      echo "# TEST_FILES: $tests"
      echo "# MUST_FAIL: TODO — name the test that kills this mutant (the gate refuses a TODO)"
      (cd "$REPO_ROOT" && git diff -- "$relpath")
    } > "$patch"
    cp "$snap" "$REPO_ROOT/$relpath"
  done < "$SURVIVOR_LOG"
  echo ""
  echo "MUTATION GATE: wrote $n survivor patch(es) to $EMIT_DIR (promotion path: write the test, fill MUST_FAIL, move into scripts/sabotages/)"
fi

# ── report ───────────────────────────────────────────────────────────────────
scored=$((killed + survived + exempted))
echo ""
echo "── mutation report ──────────────────────────────────────────────────────"
echo "  targets           : $target_count"
echo "  mutants run       : $sel_mutants"
echo "  killed            : $killed"
echo "  survived (unexempt): $survived"
echo "  survived (ledger) : $exempted"
echo "  build-refused     : $build_refused   [compiler rejects the mutant — not scored as kills, contract 2]"
if [[ $scored -gt 0 ]]; then
  echo "  mutation score    : $((killed * 100 / scored))% of scored mutants killed by their OWNING tests"
fi

if [[ -s "$EVIDENCE" ]]; then
  echo ""
  echo "── which test actually guards which line ────────────────────────────────"
  awk -F'\t' '{ printf "  %s %s %s %s\n     killed by: %s\n", $1, $2, $3, $4, $5 }' "$EVIDENCE"
fi

if [[ -s "$REFUSED_LOG" ]]; then
  echo ""
  echo "── BUILD-REFUSED mutants — the compiler rejects them, so no test owes a kill ──"
  awk -F'\t' '{ printf "  %s %s %s %s\n", $1, $2, $3, $4 }' "$REFUSED_LOG"
fi

if [[ -s "$SURVIVOR_LOG" ]]; then
  echo ""
  echo "── SURVIVORS (unexempt) — each is a hole next to a guarantee this repo claims ──"
  while IFS=$'\t' read -r relpath line col family from to lsha app tests; do
    echo "  $relpath:$line:$col  $family  $from -> $to"
    echo "     owning tests that FAILED to notice: $tests"
    echo "     source: $(sed -n "${line}p" "$REPO_ROOT/$relpath")"
    echo "     ledger key (if genuinely equivalent): $relpath	$lsha	$col	$family	$from>$to"
  done < "$SURVIVOR_LOG"
  echo ""
  echo "Close a survivor ONE of two honest ways:"
  echo "  (a) write the test that kills it (then --emit-patches promotes it to a committed sabotage), or"
  echo "  (b) if the mutation is genuinely EQUIVALENT (no behaviour change), add the printed"
  echo "      ledger key to scripts/mutation/ledger.tsv with class EQUIVALENT and a reason."
  echo "Never widen the owning-test set to make a survivor disappear — that hides the hole."
  fail "$survived mutant(s) survived their owning tests with no ledger entry (contract 4)"
fi

if [[ -s "$OBSOLETE" && $FILTER_ACTIVE -eq 0 ]]; then
  echo ""
  echo "── OBSOLETE ledger entries — the mutant is now KILLED, the exemption is dead weight ──"
  while IFS= read -r k; do
    echo "  $k"
    echo "     $(ledger_lookup "$k" | cut -f1): $(ledger_lookup "$k" | cut -f2 | cut -c1-100)"
  done < "$OBSOLETE"
  echo ""
  echo "Delete these rows from $LEDGER_FILE. An exemption that outlives the gap it excused"
  echo "is how a ledger stops being a debt list and becomes a blindfold."
  fail "$(grep -c '' "$OBSOLETE") ledger entry(ies) are obsolete — their mutants are now killed"
fi

echo ""
if [[ $FILTER_ACTIVE -eq 1 ]]; then
  echo "MUTATION GATE: ALL PASSED ($killed killed, $exempted ledger-exempt — FILTERED: $(filter_label))"
else
  echo "MUTATION GATE: ALL PASSED ($killed of $scored scored mutants killed by their owning tests; $exempted ledger-exempt; byte-exact restores)"
fi
