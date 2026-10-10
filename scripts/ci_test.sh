#!/usr/bin/env bash
# scripts/ci_test.sh — red-path harness for the ADR-053 CI driver (scripts/ci) and its wrappers.
#
# Every case runs the REAL driver (and, for C6, the REAL ./ci.sh and ./ci-fast.sh) against a
# throwaway git repo + a FAKE manifest of fake steps (`sleep`, `echo`, `exit 1`) — no mix, no DB,
# no network; seconds, not minutes. Each case pairs its red assertions with a positive control so
# it can fail (a harness that cannot go red is the bug it exists to catch).
#
#   C1     budget/resume: a deferred, interrupted or unrun step never yields PASS; resume runs each
#          step exactly once; the first step of an invocation always runs; shard accounting.
#   C2     cache: invalidated by a tracked edit, an UNTRACKED file, a reads-only file, a step-
#          definition change and a toolchain change; never for an ignored file; a step with no
#          inputs is never cached; a step whose inputs moved while it ran is not cached.
#   C3     a FAIL is never cached; the run stops at the first failure; --keep-going still FAILs.
#   C4     quick / fast / --only never print a PR-ready verdict (pr does — the positive control).
#   C5     an ExUnit failure is re-run once in isolation; FLAKY (passed on rerun) still FAILS the
#          run and is not cached; a real failure stays FAIL.
#   C6     ./ci.sh and ./ci-fast.sh never print ALL PASSED after a failed step — including a step
#          failing CONCURRENTLY with a passing one, in either completion order — nor when the
#          driver's exit code and its last.json disagree.
#   C9     quick selection: a core change selects every dependant; a vertical change selects only
#          it (+ always-steps); an untracked file is seen; a framework test/ edit does not select
#          dependants; no base → refusal.
#   LOCKS  steps sharing a lock never overlap; a serial step runs alone (positive control:
#          lock-disjoint steps DO overlap).
#   EQUIV  the wrappers keep the pre-ADR-053 step list and every `==> … PASSED` marker
#          (ci/legacy_markers.txt, re-derived from `git show 208dfc5:ci.sh` when that commit exists).
#
# Usage: scripts/ci_test.sh [CASE…]      (default: every case)
# Exit:  0 all assertions pass · 1 otherwise. Residue: none (temp dirs, trap on EXIT/INT/TERM).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CI="$ROOT/scripts/ci"
T="$(mktemp -d "${TMPDIR:-/tmp}/samen_ci_test.XXXXXX")"
trap 'rm -rf "$T"' EXIT INT TERM

pass=0
fail=0
case_fail=0
ok()  { pass=$((pass + 1)); }
bad() { echo "  FAIL: $*"; fail=$((fail + 1)); case_fail=1; }
has()   { grep -qE -- "$2" "$1" || { bad "$3 — expected /$2/ in output:"; sed 's/^/      | /' "$1" | tail -25; return 1; }; ok; }
hasnt() { if grep -qE -- "$2" "$1"; then bad "$3 — unexpected /$2/:"; grep -E -- "$2" "$1" | sed 's/^/      | /'; return 1; fi; ok; }
eq()    { if [[ "$1" == "$2" ]]; then ok; else bad "$3 — got [$1], want [$2]"; fi; }
count() { grep -cxF -- "$2" "$1" 2>/dev/null || true; }
jsonget() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2], {"d": d}))' "$@"; }

# mkrepo <name> — a git repo with an explicit app graph: core ← web ← vert_a / vert_b (the verticals
# name ONLY web, so reaching core proves the expansion is transitive); docs/.
mkrepo() {
  R="$T/$1"
  rm -rf "$R" "$T/$1.home"
  mkdir -p "$R"/{core/lib,core/test,web/lib,vert_a,vert_b,docs}
  (
    cd "$R" && git init -q -b main . && git config user.email t@t && git config user.name t
    echo core > core/lib/a.txt; echo coretest > core/test/a_test.txt; echo web > web/lib/w.txt
    echo va > vert_a/a.txt; echo vb > vert_b/b.txt; echo doc > docs/d.md
    printf '*.log\n' > .gitignore
    git add -A && git commit -qm init && git update-ref refs/remotes/origin/main HEAD
  )
  export SAMEN_CI_REPO="$R" SAMEN_CI_HOME="$T/$1.home" SAMEN_CI_MANIFEST="$T/$1.conf"
  export SAMEN_CI_TOOLCHAIN="fake-toolchain-1" CI_TEST_RUNS="$T/$1.runs"
  : > "$CI_TEST_RUNS"
}

APPS='[app core]
path = core/
[app web]
path = web/
deps = core
[app vert_a]
path = vert_a/
deps = web
[app vert_b]
path = vert_b/
deps = web
'
# step <id> <inputs> [extra key=value lines…] — a fake step that logs its run.
step() {
  local id="$1" inputs="$2"; shift 2
  printf '[step %s]\ncmd = echo "$CI_STEP" >> "$CI_TEST_RUNS"\nmodes = quick fast pr full\ninputs = %s\nest_s = 1\n' "$id" "$inputs"
  local kv; for kv in "$@"; do printf '%s\n' "$kv"; done
}
runs_of() { grep -cxF -- "$1" "$CI_TEST_RUNS" || true; }
drive() { # drive <outfile> <args…> → rc in $RC
  local o="$1"; shift
  "$CI" "$@" > "$o" 2>&1; RC=$?
}

# ════════════════════════════════════════════════════════════════════════════════════════════════
case_C1() {
  mkrepo c1
  { echo "$APPS"
    for s in a b c; do
      printf '[step %s]\ncmd = sleep 0.3; echo "$CI_STEP" >> "$CI_TEST_RUNS"\nmodes = pr\ninputs = core/\nest_s = 5\n' $s
    done; } > "$SAMEN_CI_MANIFEST"
  drive "$T/o1" pr --budget 4 -j 1 --no-cache
  eq "$RC" 3 "C1: a budget-stopped run exits 3 (INCOMPLETE)"
  has "$T/o1" '^CI\(pr\): INCOMPLETE 1/3 — continue: scripts/ci resume$' "C1: INCOMPLETE 1/3 line"
  hasnt "$T/o1" '^CI\(pr\): PASS' "C1: never PASS over deferred steps"
  has "$T/o1" 'budget — next step b' "C1: names the deferred step"
  eq "$(jsonget "$SAMEN_CI_HOME/last.json" 'd["verdict"]')" INCOMPLETE "C1: last.json verdict"
  eq "$(jsonget "$SAMEN_CI_HOME/last.json" '",".join(d["not_run"])')" "b,c" "C1: last.json names what never ran"
  drive "$T/o2" resume
  eq "$RC" 3 "C1: resume #1 still INCOMPLETE"
  has "$T/o2" '^PASS a .*\(earlier in this run\)$' "C1: resume keeps the earlier PASS (despite --no-cache)"
  has "$T/o2" '^CI\(pr\): INCOMPLETE 2/3' "C1: 2/3 after resume #1"
  drive "$T/o3" resume
  eq "$RC" 0 "C1: resume #2 completes"
  has "$T/o3" '^CI\(pr\): PASS 3/3 in .* — PR-READY$' "C1: PASS 3/3 only once all three ran"
  eq "$(runs_of a),$(runs_of b),$(runs_of c)" "1,1,1" "C1: each step ran exactly once across resumes"

  # the first step of an invocation always runs, even when its est exceeds the whole budget
  drive "$T/o4" pr --budget 1 -j 1 --no-cache
  has "$T/o4" 'exceeds the whole budget — running it anyway' "C1: first step runs over budget"
  has "$T/o4" '^CI\(pr\): INCOMPLETE 1/3' "C1: and only that one"

  # an interrupted step is not PASS; resume re-runs it
  mkrepo c1i
  { echo "$APPS"
    printf '[step slow]\ncmd = echo start >> "$CI_TEST_RUNS"; sleep 4; echo end >> "$CI_TEST_RUNS"\nmodes = pr\ninputs = core/\nest_s = 1\n'
    printf '[step after]\ncmd = true\nmodes = pr\ninputs = core/\nest_s = 1\n'; } > "$SAMEN_CI_MANIFEST"
  "$CI" pr -j 1 > "$T/o5" 2>&1 &
  local pid=$!
  for _ in $(seq 1 150); do grep -q start "$CI_TEST_RUNS" && break; sleep 0.1; done
  kill -TERM "$pid"; wait "$pid"; RC=$?
  eq "$RC" 130 "C1: an interrupted run exits 130"
  has "$T/o5" '^INTERRUPTED slow ' "C1: the in-flight step is INTERRUPTED"
  has "$T/o5" '^CI\(pr\): INCOMPLETE 0/2' "C1: interrupted run is INCOMPLETE, never PASS"
  hasnt "$CI_TEST_RUNS" '^end$' "C1: the interrupted step's process group was terminated"
  drive "$T/o6" resume
  has "$T/o6" '^PASS slow ' "C1: resume re-runs the interrupted step"
  has "$T/o6" '^CI\(pr\): PASS 2/2' "C1: and then passes"

  # shard accounting: sub-steps must each process exactly their chunk
  mkrepo c1s
  { echo "$APPS"
    printf '[step sh]\ncmd = case "$CI_SHARD_ARGS" in "--range 1-2") echo "PROCESSED 2";; *) echo "PROCESSED ${CI_TEST_LIE:-1}";; esac\n'
    printf 'shard_list = printf "1-a.patch\\n2-b.patch\\n3-c.patch\\n"\nshard_kind = ranges\nshard_each_s = 1\nshard_target_s = 2\n'
    printf 'shard_check = ^PROCESSED ([0-9]+)$\nmodes = pr\ninputs = core/\nest_s = 3\n'; } > "$SAMEN_CI_MANIFEST"
  drive "$T/o7" pr -j 1
  has "$T/o7" '^PASS sh\[1/2\] ' "C1: shard 1 (--range 1-2)"
  has "$T/o7" '^CI\(pr\): PASS 2/2' "C1: two shards cover three items"
  CI_TEST_LIE=0 drive "$T/o8" pr -j 1 --no-cache
  has "$T/o8" 'shard accounting: processed 0, expected 1' "C1: a shard that under-processes FAILS"
  hasnt "$T/o8" '^CI\(pr\): PASS' "C1: never PASS over a short shard"
}

# ════════════════════════════════════════════════════════════════════════════════════════════════
case_C2() {
  mkrepo c2
  { echo "$APPS"
    step s_core "core/"
    step s_none ""
    step s_reads "vert_a/" "reads = docs/"
    step s_web "app:web"; } > "$SAMEN_CI_MANIFEST"
  drive "$T/o1" pr
  has "$T/o1" '^CI\(pr\): PASS 4/4' "C2: first run passes"
  drive "$T/o2" pr
  has "$T/o2" '^CACHED s_core$' "C2: unchanged → CACHED (positive control)"
  has "$T/o2" '^CACHED s_web$' "C2: unchanged → CACHED"
  has "$T/o2" '^PASS s_none ' "C2: a step with no inputs is NEVER cached"
  echo edit >> "$R/core/lib/a.txt"
  drive "$T/o3" pr
  has "$T/o3" '^PASS s_core ' "C2: a tracked edit re-runs its step"
  has "$T/o3" '^PASS s_web ' "C2: ... and every step whose app depends on it"
  has "$T/o3" '^CACHED s_reads$' "C2: ... but not an unrelated step"
  echo new > "$R/core/lib/brand_new.txt"
  drive "$T/o4" pr
  has "$T/o4" '^PASS s_core ' "C2: an UNTRACKED file re-runs its step"
  echo junk > "$R/core/lib/ignored.log"
  drive "$T/o5" pr
  has "$T/o5" '^CACHED s_core$' "C2: an IGNORED file does not (positive control)"
  echo t2 > "$R/core/test/new_test.txt"
  drive "$T/o6" pr
  has "$T/o6" '^PASS s_core ' "C2: a test edit re-runs the app's own step"
  has "$T/o6" '^CACHED s_web$' "C2: ... but not dependants (deps compile lib only)"
  echo d2 >> "$R/docs/d.md"
  drive "$T/o7" pr
  has "$T/o7" '^PASS s_reads ' "C2: a reads-only input re-keys the step"
  sed -i.bak 's|^\[step s_core\]$|[step s_core]\n# definition change|' "$SAMEN_CI_MANIFEST" && rm -f "$SAMEN_CI_MANIFEST.bak"
  drive "$T/o8" pr
  has "$T/o8" '^CACHED s_core$' "C2: a comment is not a definition change"
  python3 - "$SAMEN_CI_MANIFEST" <<'PY'
import sys; p=sys.argv[1]; s=open(p).read()
s=s.replace('[step s_core]\n# definition change\ncmd = echo "$CI_STEP" >> "$CI_TEST_RUNS"', '[step s_core]\ncmd = echo "$CI_STEP" >> "$CI_TEST_RUNS"; true')
open(p,'w').write(s)
PY
  drive "$T/o9" pr
  has "$T/o9" '^PASS s_core ' "C2: a step-definition (cmd) change re-runs it"
  SAMEN_CI_TOOLCHAIN=fake-toolchain-2 drive "$T/o10" pr
  has "$T/o10" '^PASS s_web ' "C2: a toolchain change re-runs every cached step"
  # inputs moving while the step runs: never cached
  mkrepo c2m
  { echo "$APPS"
    printf '[step mut]\ncmd = date >> core/lib/moving.txt\nmodes = pr\ninputs = core/\nest_s = 1\n'; } > "$SAMEN_CI_MANIFEST"
  drive "$T/o11" pr
  has "$T/o11" 'not cached: its inputs changed while it ran' "C2: a step whose inputs moved mid-run is not cached"
  drive "$T/o12" pr
  has "$T/o12" '^PASS mut ' "C2: ... so it runs again"
}

# ════════════════════════════════════════════════════════════════════════════════════════════════
case_C3() {
  mkrepo c3
  { echo "$APPS"
    step first "core/"
    printf '[step bad]\ncmd = echo "$CI_STEP" >> "$CI_TEST_RUNS"; [ -f "%s/c3.ok" ]\nmodes = pr\ninputs = core/\nest_s = 1\n' "$T"
    step later "core/"; } > "$SAMEN_CI_MANIFEST"
  drive "$T/o1" pr -j 1
  eq "$RC" 1 "C3: a failing step exits 1"
  has "$T/o1" '^FAIL bad ' "C3: FAIL line"
  has "$T/o1" '^CI\(pr\): FAIL step=bad \(1/3\) — see ' "C3: final FAIL line names the step"
  has "$T/o1" 'stopped at the first failure' "C3: fail-fast says what it did not run"
  eq "$(runs_of later)" 0 "C3: nothing starts after a failure"
  drive "$T/o2" pr -j 1
  eq "$(runs_of bad)" 2 "C3: a FAIL is never cached — it runs again"
  has "$T/o2" '^CACHED first$' "C3: (positive control: the PASS before it is cached)"
  drive "$T/o3" pr -j 1 --keep-going
  has "$T/o3" '^PASS later ' "C3: --keep-going runs the rest"
  has "$T/o3" '^CI\(pr\): FAIL step=bad' "C3: ... and still FAILs"
  touch "$T/c3.ok"
  drive "$T/o4" pr -j 1
  has "$T/o4" '^CI\(pr\): PASS 3/3' "C3: green once fixed"
}

# ════════════════════════════════════════════════════════════════════════════════════════════════
case_C4() {
  mkrepo c4
  { echo "$APPS"
    step s_core "core/" "always = 1"
    printf '[step s_bad]\ncmd = [ -f "%s/c4.ok" ]\nmodes = quick fast pr\ninputs = vert_a/\nest_s = 1\n' "$T"; } > "$SAMEN_CI_MANIFEST"
  touch "$T/c4.ok"
  drive "$T/o1" quick
  has "$T/o1" '^CI\(quick\): PASS 1/1 in .* — NOT PR-READY — run: scripts/ci pr$' "C4: quick PASS is NOT PR-READY"
  drive "$T/o2" fast
  has "$T/o2" '^CI\(fast\): PASS 2/2 in .* — NOT PR-READY — run: scripts/ci pr$' "C4: fast PASS is NOT PR-READY"
  drive "$T/o3" pr --only s_core
  has "$T/o3" '^CI\(pr --only s_core\): PASS 1/1 .* — NOT PR-READY' "C4: a filtered pr is NOT PR-READY"
  drive "$T/o4" pr
  has "$T/o4" '^CI\(pr\): PASS 2/2 in .* — PR-READY$' "C4: an unfiltered pr IS PR-READY (positive control)"
  rm -f "$T/c4.ok"; echo x >> "$R/vert_a/a.txt"
  drive "$T/o5" quick
  has "$T/o5" '^CI\(quick\): FAIL .* — NOT PR-READY — run: scripts/ci pr$' "C4: a quick FAIL says it too"
  drive "$T/o6" quick --budget 1 -j 1 --no-cache
  has "$T/o6" '^CI\(quick\): INCOMPLETE .* — NOT PR-READY' "C4: a quick INCOMPLETE says it too"
  cat "$T"/o[12356] > "$T/all"
  hasnt "$T/all" '(^|[^T] )PR-READY' "C4: no quick/fast/--only line ever claims PR-READY"
}

# ════════════════════════════════════════════════════════════════════════════════════════════════
case_C5() {
  mkrepo c5
  mkdir -p "$T/bin"
  cat > "$T/bin/mix" <<'MIX'
#!/usr/bin/env bash
# fake `mix`: records the isolated rerun; passes iff the flake marker exists
[[ "${1:-}" == test ]] || exit 2
shift; echo "rerun $*" >> "$CI_TEST_RUNS"
[[ -f "$CI_TEST_FLAKE_OK" ]]
MIX
  chmod +x "$T/bin/mix"
  { echo "$APPS"
    cat <<'STEP'
[step flaky]
cmd = echo "$CI_STEP" >> "$CI_TEST_RUNS"
    printf '\n  1) test the thing works (Fake.Test)\n     test/fake_test.exs:7\n     Assertion with == failed\n     code:  assert 1 == 2\n     left:  1\n     right: 2\n     stacktrace:\n       test/fake_test.exs:8: (test)\n\n'
    exit 1
cwd = core
exunit_dir = core
modes = pr
inputs = core/
est_s = 1
STEP
  } > "$SAMEN_CI_MANIFEST"
  export CI_TEST_FLAKE_OK="$T/flake.ok"
  touch "$CI_TEST_FLAKE_OK"
  PATH="$T/bin:$PATH" drive "$T/o1" pr
  eq "$RC" 1 "C5: a FLAKY step fails the run (exit 1)"
  has "$T/o1" '^FLAKY flaky [0-9.]+s \(passed on rerun\)$' "C5: labelled FLAKY (passed on rerun)"
  has "$T/o1" '^CI\(pr\): FAIL step=flaky' "C5: the run is FAIL, never PASS"
  has "$CI_TEST_RUNS" '^rerun test/fake_test.exs:7$' "C5: the failing test re-ran ONCE, alone, by file:line"
  has "$T/o1" 'test the thing works' "C5: digest names the failing test"
  has "$T/o1" 'test/fake_test.exs:7' "C5: digest gives file:line"
  has "$T/o1" 'Assertion with == failed' "C5: digest carries the assertion"
  eq "$(jsonget "$SAMEN_CI_HOME/last.json" 'd["steps"][0]["status"]')" FLAKY "C5: last.json says FLAKY"
  PATH="$T/bin:$PATH" drive "$T/o2" pr
  eq "$(runs_of flaky)" 2 "C5: a FLAKY step is not cached"
  rm -f "$CI_TEST_FLAKE_OK"
  PATH="$T/bin:$PATH" drive "$T/o3" pr
  has "$T/o3" '^FAIL flaky ' "C5: a failure that repeats on rerun is FAIL"
  has "$T/o3" 'failed again on an isolated rerun' "C5: ... and says so"
}

# ════════════════════════════════════════════════════════════════════════════════════════════════
case_C6() {
  mkrepo c6
  local W="$T/wrap"
  rm -rf "$W"; mkdir -p "$W/scripts"
  cp "$ROOT/ci.sh" "$ROOT/ci-fast.sh" "$W/"
  cp "$ROOT/scripts/ci" "$ROOT/scripts/ci_driver.py" "$W/scripts/"
  local P='[step pass_slow]
cmd = sleep 1.0
modes = fast pr
inputs = core/
est_s = 1
marker = ==> slow: PASSED
'
  { echo "$APPS"; echo "$P"
    printf '[step fail_fast]\ncmd = sleep 0.2; exit 1\nmodes = fast pr\ninputs = vert_a/\nest_s = 1\n'; } > "$SAMEN_CI_MANIFEST"
  bash "$W/ci.sh" -j 4 > "$T/o1" 2>&1; RC=$?
  eq "$RC" 1 "C6: ci.sh exits 1 when a concurrent step fails first"
  hasnt "$T/o1" 'ALL PASSED' "C6: ci.sh never prints ALL PASSED over a failed concurrent step"
  has "$T/o1" '^==> ROOT CI: FAILED' "C6: ... and says FAILED"
  has "$T/o1" '^==> slow: PASSED$' "C6: (the passing step still earns its marker)"
  { echo "$APPS"; echo "$P"
    printf '[step fail_late]\ncmd = sleep 1.6; exit 1\nmodes = fast pr\ninputs = vert_a/\nest_s = 1\n'; } > "$SAMEN_CI_MANIFEST"
  bash "$W/ci.sh" -j 4 --no-cache > "$T/o2" 2>&1; RC=$?
  eq "$RC" 1 "C6: ci.sh exits 1 when the concurrent step fails LAST"
  hasnt "$T/o2" 'ALL PASSED' "C6: never ALL PASSED (failure after a pass)"
  bash "$W/ci-fast.sh" -j 4 --no-cache > "$T/o3" 2>&1; RC=$?
  eq "$RC" 1 "C6: ci-fast.sh exits 1"
  hasnt "$T/o3" 'ALL PASSED' "C6: ci-fast.sh never prints ALL PASSED over a failure"
  # positive control: all green → the exact legacy final lines
  { echo "$APPS"; echo "$P"; step also_ok "vert_a/"; } > "$SAMEN_CI_MANIFEST"
  bash "$W/ci.sh" -j 4 > "$T/o4" 2>&1; RC=$?
  eq "$RC" 0 "C6: ci.sh exits 0 when green (positive control)"
  eq "$(tail -1 "$T/o4")" "==> ROOT CI: ALL PASSED" "C6: green ci.sh ends ROOT CI: ALL PASSED"
  bash "$W/ci-fast.sh" -j 4 > "$T/o5" 2>&1; RC=$?
  eq "$(tail -1 "$T/o5")" "==> CI-FAST: ALL PASSED" "C6: green ci-fast.sh ends CI-FAST: ALL PASSED"
  # a driver whose exit code and verdict disagree is not believed
  cat > "$T/liar" <<'LIAR'
#!/usr/bin/env bash
mkdir -p "$SAMEN_CI_HOME"; echo '{"verdict": "FAIL"}' > "$SAMEN_CI_HOME/last.json"; echo "CI(pr): PASS 1/1 in 0.1s"; exit 0
LIAR
  chmod +x "$T/liar"
  SAMEN_CI_DRIVER="$T/liar" bash "$W/ci.sh" > "$T/o6" 2>&1; RC=$?
  eq "$RC" 1 "C6: exit 0 with a FAIL verdict is a failure"
  hasnt "$T/o6" 'ALL PASSED' "C6: ... and never ALL PASSED"
  SAMEN_CI_DRIVER="$T/liar" bash "$W/ci-fast.sh" > "$T/o7" 2>&1; RC=$?
  hasnt "$T/o7" 'CI-FAST: ALL PASSED' "C6: ci-fast.sh does not believe it either"
}

# ════════════════════════════════════════════════════════════════════════════════════════════════
case_C9() {
  mkrepo c9
  { echo "$APPS"
    step s_core "app:core"; step s_web "app:web"; step s_va "app:vert_a"; step s_vb "app:vert_b"
    step s_glob "scripts/" "always = 1"; step s_docs "docs/"; } > "$SAMEN_CI_MANIFEST"
  sel() { grep -E '^(PASS|CACHED) ' "$1" | awk '{print $2}' | sort | tr '\n' ' ' | sed 's/ $//'; }
  drive "$T/o0" quick
  eq "$(sel "$T/o0")" "s_glob" "C9: no change → only the always-steps"
  has "$T/o0" '^SKIP s_core \(not affected\)$' "C9: unaffected steps print SKIP with the reason"
  echo x >> "$R/core/lib/a.txt"
  drive "$T/o1" quick
  eq "$(sel "$T/o1")" "s_core s_glob s_va s_vb s_web" "C9: a core change selects EVERY dependant"
  (cd "$R" && git checkout -q -- core/lib/a.txt)
  (cd "$R" && echo y >> vert_a/a.txt && git commit -qam "branch commit")
  drive "$T/o2" quick
  eq "$(sel "$T/o2")" "s_glob s_va" "C9: a committed vertical change selects only it (+ global)"
  echo n > "$R/vert_b/untracked_new.txt"
  drive "$T/o3" quick
  eq "$(sel "$T/o3")" "s_glob s_va s_vb" "C9: an UNTRACKED new file is seen"
  rm -f "$R/vert_b/untracked_new.txt"
  echo t > "$R/core/test/z_test.txt"
  drive "$T/o4" quick
  eq "$(sel "$T/o4")" "s_core s_glob s_va" "C9: a framework test/ edit selects the framework, not dependants"
  rm -f "$R/core/test/z_test.txt"
  (cd "$R" && git rm -q web/lib/w.txt)
  drive "$T/o5" quick
  eq "$(sel "$T/o5")" "s_glob s_va s_vb s_web" "C9: a DELETED file selects its app + dependants"
  (cd "$R" && git reset -q HEAD web/lib/w.txt && git checkout -q -- web/lib/w.txt)
  echo d >> "$R/docs/d.md"
  drive "$T/o6" quick
  eq "$(sel "$T/o6")" "s_docs s_glob s_va" "C9: docs/ selects the docs step"
  drive "$T/o7" quick --base no-such-ref
  eq "$RC" 2 "C9: quick refuses an unresolvable base"
  has "$T/o7" 'does not resolve' "C9: ... and says why"
  drive "$T/o8" explain s_vb
  has "$T/o8" 'inc:core/\|-core/test/' "C9: explain shows the expanded dependency inputs"
}

# ════════════════════════════════════════════════════════════════════════════════════════════════
case_LOCKS() {
  mkrepo locks
  printf '#!/usr/bin/env python3\nimport os, sys, time\nopen(os.environ["CI_TEST_RUNS"], "a").write("%%s %%s %%.3f\\n" %% (sys.argv[1], sys.argv[2], time.time()))\n' > "$T/stamp"
  chmod +x "$T/stamp"
  local stamp="$T/stamp %s %s"
  { echo "$APPS"
    for s in p1:db:x p2:db:y p3:db:x; do
      id="${s%%:*}"; lk="${s#*:}"
      printf '[step %s]\ncmd = %s; sleep 1.0; %s\nmodes = pr\ninputs = core/\nlocks = %s\nest_s = 1\n' \
        "$id" "$(printf "$stamp" "$id" start)" "$(printf "$stamp" "$id" end)" "$lk"
    done
    printf '[step ser]\ncmd = %s; sleep 0.4; %s\nmodes = pr\nserial = 1\ninputs = core/\nest_s = 1\n' \
      "$(printf "$stamp" ser start)" "$(printf "$stamp" ser end)"
    printf '[step p4]\ncmd = %s; sleep 0.4; %s\nmodes = pr\ninputs = core/\nest_s = 1\n' \
      "$(printf "$stamp" p4 start)" "$(printf "$stamp" p4 end)"; } > "$SAMEN_CI_MANIFEST"
  drive "$T/o1" pr -j 4
  has "$T/o1" '^CI\(pr\): PASS 5/5' "LOCKS: run passes"
  python3 - "$CI_TEST_RUNS" > "$T/ov" <<'PY'
import sys
iv = {}
for l in open(sys.argv[1]):
    i, w, t = l.split(); iv.setdefault(i, {})[w] = float(t)
ov = lambda a, b: iv[a]["start"] < iv[b]["end"] and iv[b]["start"] < iv[a]["end"]
print("p1p2", ov("p1", "p2")); print("p1p3", ov("p1", "p3"))
print("ser", any(ov("ser", o) for o in iv if o != "ser"))
PY
  has "$T/ov" '^p1p3 False$' "LOCKS: two steps sharing db:x never overlap"
  has "$T/ov" '^p1p2 True$' "LOCKS: lock-disjoint steps DO run concurrently (positive control)"
  has "$T/ov" '^ser False$' "LOCKS: a serial step runs alone"
}

# ════════════════════════════════════════════════════════════════════════════════════════════════
case_EQUIV() {
  unset SAMEN_CI_REPO SAMEN_CI_HOME SAMEN_CI_MANIFEST
  local LEG="$ROOT/ci/legacy_markers.txt" LEGF="$ROOT/ci/legacy_fast_markers.txt" STEPS="$ROOT/ci/legacy_steps.tsv"
  # (1) the committed fixtures ARE the pre-ADR-053 scripts' markers, when that commit is here
  if git -C "$ROOT" cat-file -e 208dfc5:ci.sh 2>/dev/null; then
    git -C "$ROOT" show 208dfc5:ci.sh | python3 "$ROOT/scripts/ci_test_legacy.py" markers > "$T/leg"
    git -C "$ROOT" show 208dfc5:ci-fast.sh | python3 "$ROOT/scripts/ci_test_legacy.py" markers > "$T/legf"
    if diff -u "$LEG" "$T/leg" > "$T/d" && diff -u "$LEGF" "$T/legf" >> "$T/d"; then ok; else bad "EQUIV: fixtures drifted from git show 208dfc5:{ci,ci-fast}.sh"; cat "$T/d"; fi
  else
    echo "  note: commit 208dfc5 not in this clone — checking against the committed fixtures only"
  fi
  # (2) every legacy marker is printed by the wrapper's plan (opt-ins on / off)
  "$CI" list pr --markers --also sabotage_corpus,mutation_watchlist,multinode > "$T/on" 2>&1
  "$CI" list pr --markers > "$T/off" 2>&1
  "$CI" list fast --markers > "$T/fast" 2>&1
  { cat "$T/on" "$T/off"; echo "==> ROOT CI: ALL PASSED"; } | sort -u > "$T/have"
  { cat "$T/fast"; echo "==> CI-FAST: ALL PASSED"; } | sort -u > "$T/havef"
  local missing; missing="$(sort -u "$LEG" | comm -23 - "$T/have")"
  [[ -z "$missing" ]] && ok || bad "EQUIV: ci.sh markers the wrapper no longer prints: $missing"
  missing="$(sort -u "$LEGF" | comm -23 - "$T/havef")"
  [[ -z "$missing" ]] && ok || bad "EQUIV: ci-fast.sh markers the wrapper no longer prints: $missing"
  [[ "$(grep -c . "$LEG")" -ge 40 ]] && ok || bad "EQUIV: legacy marker fixture suspiciously short"
  # (3) the same step list: each legacy marker maps to a step with the legacy cwd + command
  python3 "$ROOT/scripts/ci_test_legacy.py" steps "$STEPS" "$LEG" "$ROOT/ci/steps.conf" > "$T/st" 2>&1 \
    && ok || { bad "EQUIV: legacy step list not preserved:"; sed 's/^/      | /' "$T/st"; }
  # (4) ordering: ci.sh's serial prefix keeps its order in the manifest (preflight → spikes → samen_core)
  local order; order="$(grep -nE 'double sweep: PASSED|spike s00_smoke: PASSED|==> samen_core: PASSED' "$T/off" | cut -d: -f1 | tr '\n' ' ')"
  [[ "$(echo $order | tr ' ' '\n' | sort -n | tr '\n' ' ')" == "$order" ]] && ok || bad "EQUIV: preflight/spikes/samen_core order changed: $order"
}

ALL=(C1 C2 C3 C4 C5 C6 C9 LOCKS EQUIV)
CASES=("$@")
[[ ${#CASES[@]} -gt 0 ]] || CASES=("${ALL[@]}")
for c in "${CASES[@]}"; do
  case " ${ALL[*]} " in *" $c "*) ;; *) echo "ci_test.sh: unknown case $c (cases: ${ALL[*]})" >&2; exit 2 ;; esac
  case_fail=0
  "case_$c"
  if [[ $case_fail -eq 0 ]]; then echo "CASE $c: PASS"; else echo "CASE $c: FAIL"; fi
done
echo "CI DRIVER SELF-TEST: $pass assertion(s) passed, $fail failed"
[[ $fail -eq 0 ]] && echo "CI DRIVER SELF-TEST: ALL PASSED" || { echo "CI DRIVER SELF-TEST: FAILED"; exit 1; }
