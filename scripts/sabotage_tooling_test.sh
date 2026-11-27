#!/usr/bin/env bash
# scripts/sabotage_tooling_test.sh — red-path harness for `scripts/sabotage new` and `scripts/sabotage reanchor`
# (ADR-053 P3; C8 is the re-anchor refusal).
#
# Every case runs the REAL scripts (sabotage, sabotage.sh, sabotage_lint.sh, double-sweep.sh, counts,
# sabotage_new.sh, sabotage_reanchor.py) copied into a throwaway git repo that has an `origin/main` ref and a
# FAKE `mix` on PATH — no Elixir, no DB, seconds. The fake `mix test` flips a named test when its lib file
# carries a marker, fails to compile on `BROKEN`, and can be told to stop flipping (FAKE_MIX_NOFLIP=1) or to
# fail its baseline (FAKE_MIX_RED=1). Each refusal is paired with a positive control (a case that succeeds)
# and asserts the tree is left EXACTLY as it was.
#
#   new        N1 happy path (header format, byte-exact restore, next number, counts) · N2 an interpolated
#              MUST_FAIL · N3 a MUST_FAIL absent from the test source · N4 a compile/migration breaker ·
#              N5 a captured UNSTAGED fix · N6 the staged-fix workflow (positive control: the staged fix is
#              neither captured nor lost) · N7 no anchor against origin/main · N8 a sabotage that flips
#              nothing · N9 no edit against the index / an untracked file · N10 the wrong test named ·
#              N11 numbering · N12 unstaged WIP beside the sabotage is captured but never LOST (kept copy)
#   ledger     L1 a LISTED patch whose build is refused with the required substring is KILLED (a pass) · L2 refused
#              WITHOUT the substring: wrong refusal · L3 listed but the build SUCCEEDS: stale entry, whatever the tests
#              do · L4 refused and NOT listed: fails exactly as before (no global leniency) · L5 an entry naming a patch
#              that does not exist / an empty substring / a duplicate fails at the start · L6 a KILLED patch is
#              restored byte-exact and the other listed patches are still replayed
#   reanchor   R0 already applies · R1 re-anchored (3-way, header byte-identical, proven) · R2 a conflict ·
#              R3 (C8) the named test no longer fails under the re-anchored patch · R4 the named test is gone ·
#              R5 a red baseline · R6 unknown / ambiguous numbers · R7 (C8) a patch outside the corpus
#
# Usage: scripts/sabotage_tooling_test.sh [new|reanchor|ledger]    (default: all)    Residue: none (temp dir).
set -uo pipefail

# the fixture must never act on the REAL repo (SAMEN_SABOTAGE_ROOT points sabotage_new.sh at one)
unset SAMEN_SABOTAGE_ROOT

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WHICH="${1:-all}"
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPTS_DIR/fixture_guard.sh" || { echo "sabotage_tooling_test: cannot load fixture_guard.sh" >&2; exit 1; }
T="$(fixture_mktemp samen_sabotage_tooling)" || { echo "sabotage_tooling_test: no usable temp root — refusing to run, nothing was touched" >&2; exit 1; }
fixture_arm "$T" "$(cd "$SCRIPTS_DIR/.." && pwd)" sabotage_tooling_test || exit 1
_fg_exit() { local rc=$?; fixture_finish || rc=1; rm -rf "$T"; trap - EXIT; exit "$rc"; }
trap _fg_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

pass_count=0; fail_count=0
ok()  { pass_count=$((pass_count + 1)); echo "PASS: $*"; }
bad() { fail_count=$((fail_count + 1)); echo "FAIL: $*"; }
eq()  { if [[ "$1" == "$2" ]]; then ok "$3"; else bad "$3 — got [$1], want [$2]"; fi; }
says()   { if grep -qF -- "$2" "$1"; then ok "$3"; else bad "$3 — never said: $2"; sed 's/^/      | /' "$1" | tail -15; fi; }
silent() { if grep -qF -- "$2" "$1"; then bad "$3 — wrongly said: $2"; else ok "$3"; fi; }

BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/mix" <<'FAKE'
#!/usr/bin/env bash
[[ "$1" == test ]] || exit 0
shift
f=lib/a.ex
if grep -q BROKEN "$f"; then echo "** (CompileError) lib/a.ex: boom"; exit 1; fi
if grep -q REFUSED "$f"; then
  printf '== Compilation error in file lib/a.ex ==\n** (Spark.Error.DslError) [A]\n  reveal action violates the probe rule: :reveal_x takes the identity argument :actor_id: nope\n'; exit 1
fi
fails=()
if [[ -z "${FAKE_MIX_NOFLIP:-}" ]]; then
  grep -q 'def ok?, do: false' "$f" && fails+=("ok is true")
  grep -q 'def limit, do: 11' "$f" && fails+=("limit is ten")
fi
[[ -n "${FAKE_MIX_RED:-}" ]] && fails+=("ok is true")
for a in "$@"; do
  [[ "$a" == test/name_test.exs ]] && ! grep -q 'def name, do: "b"' "$f" && fails+=("name is b")
done
(( ${#fails[@]} )) || { echo "all tests passed"; exit 0; }
i=0; for t in "${fails[@]}"; do i=$((i + 1)); echo "  $i) test $t (ATest)"; done
exit 2
FAKE
chmod +x "$BIN/mix"
# counts.py asks `elixir <engine> list <file>` for a file's mutants: three, always
printf '#!/usr/bin/env bash\nprintf "m1\\nm2\\nm3\\n"\n' > "$BIN/elixir"; chmod +x "$BIN/elixir"

F="$T/fx"
git_() { git -C "$F" -c user.email=t@t -c user.name=t "$@"; }

# Everything scripts/counts derives a number from, in miniature: ONE patch (naming the driver guard test), one
# watch-list row, two ADRs, two verifiers, the four gate scripts, CLAUDE.md's six counts and the seven front-door
# docs. All current at the base; adding a patch makes `sabotages`, `corpus_targets` and `corpus_mutants` stale in
# CLAUDE.md and `sabotages` stale in README.md and docs/guides/cookbook.md.
mkcounts_fixture() {
  mkdir -p "$F/scripts/mutation" "$F/docs/adr" "$F/docs/guides" "$F/samen_core/lib/mix/tasks" "$F/samen_core/priv/templates" "$F/driftwood" "$F/pawchart"
  printf 'defmodule ADriverGuardTest do\n  test "guard", do: assert(true)\nend\n' > "$F/app1/test/ci_driver_guard_test.exs"
  : > "$F/scripts/mutation/mutate.exs"
  cat > "$F/scripts/mutate.sh" <<'STUB'
#!/usr/bin/env bash
corpus=0; for a in "$@"; do [[ "$a" == --corpus ]] && corpus=1; done
rows=1; (( corpus )) && rows=$(ls scripts/sabotages/*.patch | wc -l | tr -d ' ')
echo "MUTATION TARGETS: $rows rows"
for ((i = 1; i <= rows; i++)); do printf 'app1/lib/a.ex\tx%d\n' "$i"; done
STUB
  : > "$F/docs/adr/ADR-001-a.md"; : > "$F/docs/adr/ADR-002-b.md"
  : > "$F/samen_core/lib/mix/tasks/samen.verify.one.ex"; : > "$F/samen_core/lib/mix/tasks/samen.verify.two.ex"
  printf 'echo "--- step 1/3: a"\n' > "$F/samen_core/priv/templates/ci_sh.eex"
  printf 'echo "--- step 1/4: a"\n' > "$F/samen_core/priv/templates/ci_sh_api.eex"
  printf 'echo "--- step 1/5: a"\n' > "$F/driftwood/ci.sh"; printf 'echo "--- step 1/6: a"\n' > "$F/pawchart/ci.sh"
  local ad='<!--count:adrs-->2<!--/count-->' ve='<!--count:verifiers-->2<!--/count-->' ga='<!--count:gate_steps_app-->3<!--/count-->'
  local gi='<!--count:gate_steps_app_api-->4<!--/count-->' gd='<!--count:gate_steps_driftwood-->5<!--/count-->' gp='<!--count:gate_steps_pawchart-->6<!--/count-->' sa='<!--count:sabotages-->1<!--/count-->'
  printf '# doc\n- total %s\n- driver <!--count:driver_sabotages-->1–1<!--/count-->\n- watch <!--count:watchlist_modules-->1<!--/count--> <!--count:watchlist_mutants-->3<!--/count-->\n- corpus <!--count:corpus_targets-->1<!--/count--> <!--count:corpus_mutants-->3<!--/count-->\n' "$sa" > "$F/CLAUDE.md"
  printf '%s %s %s\n' "$ad" "$gi" "$sa" > "$F/README.md"
  printf '%s\n' "$ad" > "$F/docs/README.md"; printf '%s\n' "$ad" > "$F/docs/adr/README.md"
  printf '%s %s %s %s\n' "$ve" "$ga" "$gd" "$gp" > "$F/docs/guides/gate-failures.md"
  printf '%s\n' "$ga" > "$F/docs/guides/getting-started.md"; printf '%s %s\n' "$ga" "$sa" > "$F/docs/guides/cookbook.md"
  printf '%s\n' "$ga" > "$F/docs/guides/generators.md"
}

build_fixture() { # build the pristine fixture repo at $F (done ONCE; see mkfix)
  rm -rf "$F"; mkdir -p "$F/scripts/sabotages" "$F/app1/lib" "$F/app1/test"
  local f
  for f in sabotage sabotage.sh sabotage_lint.sh sabotage_new.sh sabotage_reanchor.sh sabotage_reanchor.py double-sweep.sh counts counts.py; do
    cp "$SCRIPTS/$f" "$F/scripts/$f"
  done
  : > "$F/app1/mix.exs"
  cat > "$F/app1/lib/a.ex" <<'EOF'
defmodule A do
  def ok?, do: true
  def name, do: "a"
  # filler one
  # filler two
  # filler three
  # filler four
  # filler five
end
EOF
  cat > "$F/app1/test/a_test.exs" <<'EOF'
defmodule ATest do
  test "ok is true", do: assert(A.ok?())
end
EOF
  mkcounts_fixture
  git -C "$F" init -q -b main
  # the one existing patch (ok? -> false), generated by git itself so its index lines are real
  sed -i.bak 's/def ok?, do: true/def ok?, do: false/' "$F/app1/lib/a.ex"; rm -f "$F/app1/lib/a.ex.bak"
  { printf '# SABOTAGE: existing\n#\n# Flips the named test(s).\n# APP: app1\n# TEST_FILES: test/a_test.exs test/ci_driver_guard_test.exs\n# MUST_FAIL: ok is true\n'
    git -C "$F" add -N app1/lib/a.ex; git -C "$F" diff --no-color -- app1/lib/a.ex; } > "$F/scripts/sabotages/1-existing.patch"
  git -C "$F" rm -q --cached app1/lib/a.ex 2>/dev/null; git -C "$F" reset -q 2>/dev/null
  sed -i.bak 's/def ok?, do: false/def ok?, do: true/' "$F/app1/lib/a.ex"; rm -f "$F/app1/lib/a.ex.bak"
  git_ add -A; git_ commit -q -m base
  git_ update-ref refs/remotes/origin/main HEAD
  # the branch under test adds a function (far below ok?) and its test
  python3 - "$F" <<'PY'
import sys
r = sys.argv[1]
p = r + "/app1/lib/a.ex"
s = open(p).read().replace("  # filler five\nend\n", "  # filler five\n  def limit, do: 10\n\n  # doc\n  def max, do: 99\nend\n")
open(p, "w").write(s)
p = r + "/app1/test/a_test.exs"
s = open(p).read().replace("end\n", '  test "limit is ten", do: assert(A.limit() == 10)\nend\n')
open(p, "w").write(s)
PY
  git_ add -A; git_ commit -q -m branch
}
# Every case starts from the SAME pristine fixture, so it is built once (~60 files, a git init, two commits) and
# each case gets a copy-on-write clone of it (one clonefile(2) per tree on APFS, a plain copy elsewhere). Building
# it 14 times was a few hundred file creations and renames, and file creation is what stalls on a loaded disk.
TPL="$T/tpl"
mkfix() {
  if [[ ! -d "$TPL" ]]; then
    local real_f="$F"; F="$TPL"; build_fixture; F="$real_f"
  fi
  rm -rf "$F"
  if [[ "$(uname)" == Darwin ]]; then cp -Rpc "$TPL" "$F" 2>/dev/null || { rm -rf "$F"; cp -Rp "$TPL" "$F"; }
  else cp -a --reflink=auto "$TPL" "$F"; fi
}
sab() { # sab <outfile> <args…> — run the fixture's scripts/sabotage; RC
  local o="$1"; shift
  ( cd "$F" && PATH="$BIN:$PATH" SAMEN_COUNTS_CACHE="$T/cc" bash scripts/sabotage "$@" ) > "$o" 2>&1; RC=$?
}
sabotage_limit() { sed -i.bak 's/def limit, do: 10/def limit, do: 11/' "$F/app1/lib/a.ex"; rm -f "$F/app1/lib/a.ex.bak"; }
sha_of() { shasum -a 256 "$1" | cut -d' ' -f1; }
tree_state() { { git -C "$F" status --porcelain; git -C "$F" diff; git -C "$F" diff --cached; } | shasum -a 256 | cut -d' ' -f1; }
no_patch() { [[ -z "$(ls "$F/scripts/sabotages" | grep -v '^1-existing.patch$' | grep -v '^2-limit-eleven.patch$')" ]]; }
NEWARGS=(limit-eleven --app app1 --test-file test/a_test.exs --must-fail "limit is ten")

run_new() {
  echo "== new =="
  # N1 ─ happy path
  mkfix; sabotage_limit
  sab "$T/n1" new "${NEWARGS[@]}" --description "the limit guard is dropped" -- app1/lib/a.ex
  eq "$RC" 0 "N1: a sabotage edit becomes a patch"
  says "$T/n1" "SABOTAGE NEW: CREATED scripts/sabotages/2-limit-eleven.patch" "N1: ... numbered one past the highest (1 -> 2)"
  says "$T/n1" "anchored  : the patch does not apply at PREV" "N1: ... anchored by the double sweep itself"
  eq "$(head -6 "$F/scripts/sabotages/2-limit-eleven.patch")" "$(printf '# SABOTAGE: the limit guard is dropped\n#\n# Flips the named test(s).\n# APP: app1\n# TEST_FILES: test/a_test.exs\n# MUST_FAIL: limit is ten')" "N1: ... in the exact existing header format"
  eq "$(sed -n 7p "$F/scripts/sabotages/2-limit-eleven.patch")" "diff --git a/app1/lib/a.ex b/app1/lib/a.ex" "N1: ... followed by the diff"
  ( cd "$F" && git diff --quiet -- app1/lib/a.ex ) && ok "N1: the lib file is restored byte-exact from the index" || bad "N1: a.ex still differs from the index"
  ( cd "$F" && git apply --check scripts/sabotages/2-limit-eleven.patch ) && ok "N1: the patch applies to the restored tree" || bad "N1: patch does not apply"
  eq "$(grep -c 'count:sabotages-->2<' "$F/CLAUDE.md")" 1 "N1: scripts/counts --write updated CLAUDE.md (1 -> 2), no hand edit"
  eq "$(git -C "$F" status --porcelain | LC_ALL=C sort | tr '\n' ' ')" " M CLAUDE.md  M README.md  M docs/guides/cookbook.md ?? scripts/sabotages/2-limit-eleven.patch " "N1: ... and nothing else in the tree changed but the counts' files"
  # the counts are ALL current when it succeeds: CLAUDE.md's six (the corpus ones move with the new patch) and the docs
  ( cd "$F" && PATH="$BIN:$PATH" SAMEN_COUNTS_CACHE="$T/cc" bash scripts/counts --check > "$T/n1c" 2>&1 ); eq "$?" 0 "N1: every count in CLAUDE.md is current after sabotage new (corpus targets and mutants included)"
  says "$T/n1c" "COUNTS: OK (6 count" "N1: ... all six checked"
  ( cd "$F" && PATH="$BIN:$PATH" SAMEN_COUNTS_CACHE="$T/cc" bash scripts/counts --check --docs > "$T/n1d" 2>&1 ); eq "$?" 0 "N1: the README/docs front-door numbers are current after sabotage new"
  eq "$(grep -c 'count:sabotages-->2<' "$F/README.md")" 1 "N1: ... README.md's sabotage count moved 1 -> 2"
  eq "$(grep -c 'count:sabotages-->2<' "$F/docs/guides/cookbook.md")" 1 "N1: ... and the cookbook's"
  eq "$(grep -c 'count:corpus_targets-->2<' "$F/CLAUDE.md")" 1 "N1: ... and CLAUDE.md's corpus target count (not only the sabotage ones)"

  # N2 ─ an interpolated MUST_FAIL
  mkfix; sabotage_limit; before="$(tree_state)"; sum="$(sha_of "$F/app1/lib/a.ex")"
  sab "$T/n2" new limit-eleven --app app1 --test-file test/a_test.exs --must-fail 'limit is #{n}' -- app1/lib/a.ex
  eq "$RC" 1 "N2: an interpolated MUST_FAIL is refused"
  says "$T/n2" "contains an interpolation" "N2: ... with the interpolation pitfall explained"
  says "$T/n2" "grep -F" "N2: ... naming the grep -F rule"
  eq "$(tree_state)" "$before" "N2: ... and the tree is exactly as it was"
  eq "$(sha_of "$F/app1/lib/a.ex")" "$sum" "N2: ... sabotage edit included"
  no_patch && ok "N2: ... and no patch was kept" || bad "N2: a patch was kept"

  # N3 ─ a MUST_FAIL that is not in the test source
  mkfix; sabotage_limit; before="$(tree_state)"
  sab "$T/n3" new limit-eleven --app app1 --test-file test/a_test.exs --must-fail 'limit is eleven' -- app1/lib/a.ex
  eq "$RC" 1 "N3: a MUST_FAIL absent from the test source is refused"
  says "$T/n3" "not found literally (grep -F)" "N3: ... saying why"
  eq "$(tree_state)" "$before" "N3: ... tree untouched"

  # N4 ─ a compile / migration breaker
  mkfix; sed -i.bak 's/def limit, do: 10/def limit, do: BROKEN/' "$F/app1/lib/a.ex"; rm -f "$F/app1/lib/a.ex.bak"
  before="$(tree_state)"; sum="$(sha_of "$F/app1/lib/a.ex")"
  sab "$T/n4" new "${NEWARGS[@]}" -- app1/lib/a.ex
  eq "$RC" 1 "N4: a sabotage that breaks the compile is refused"
  says "$T/n4" "NO named test failure" "N4: ... because the harness cannot see a named flip"
  says "$T/n4" "compile or a migration" "N4: ... explained"
  eq "$(tree_state)" "$before" "N4: ... tree exactly as it was"
  eq "$(sha_of "$F/app1/lib/a.ex")" "$sum" "N4: ... the user's edit kept"
  no_patch && ok "N4: ... no patch kept" || bad "N4: a patch was kept"

  # N5 ─ an UNSTAGED fix captured into the patch
  mkfix; printf 'defmodule NameTest do\n  test "name is b", do: assert(A.name() == "b")\nend\n' > "$F/app1/test/name_test.exs"
  sed -i.bak 's/def name, do: "a"/def name, do: "b"/; s/def limit, do: 10/def limit, do: 11/' "$F/app1/lib/a.ex"; rm -f "$F/app1/lib/a.ex.bak"
  before="$(tree_state)"; sum="$(sha_of "$F/app1/lib/a.ex")"
  sab "$T/n5" new limit-eleven --app app1 --test-file test/a_test.exs --test-file test/name_test.exs --must-fail "limit is ten" -- app1/lib/a.ex
  eq "$RC" 1 "N5: a patch that captured an unstaged fix is refused"
  says "$T/n5" "even WITHOUT the sabotage" "N5: ... because the baseline is red once the fix is restored away"
  says "$T/n5" "Stage the fix first" "N5: ... telling the author how to do it"
  eq "$(sha_of "$F/app1/lib/a.ex")" "$sum" "N5: ... and the fix is NOT lost: the working tree is as it was"
  eq "$(tree_state)" "$before" "N5: ... no residue"

  # N6 ─ positive control: STAGE the fix, then sabotage
  mkfix; printf 'defmodule NameTest do\n  test "name is b", do: assert(A.name() == "b")\nend\n' > "$F/app1/test/name_test.exs"
  sed -i.bak 's/def name, do: "a"/def name, do: "b"/' "$F/app1/lib/a.ex"; rm -f "$F/app1/lib/a.ex.bak"
  git_ add app1/lib/a.ex; staged_before="$(git -C "$F" diff --cached | shasum -a 256)"
  sabotage_limit
  sab "$T/n6" new limit-eleven --app app1 --test-file test/a_test.exs --test-file test/name_test.exs --must-fail "limit is ten" -- app1/lib/a.ex
  eq "$RC" 0 "N6: with the fix STAGED the same edit becomes a patch"
  eq "$(grep -c '"b"' "$F/scripts/sabotages/2-limit-eleven.patch")" 0 "N6: ... which does not contain the staged fix"
  eq "$(git -C "$F" diff --cached | shasum -a 256)" "$staged_before" "N6: ... the index is untouched"
  eq "$(grep -c 'def name, do: "b"' "$F/app1/lib/a.ex")" 1 "N6: ... and the fix is still in the working tree"
  eq "$(grep -c 'limit, do: 10' "$F/app1/lib/a.ex")" 1 "N6: ... the sabotage is gone from it"

  # N7 ─ no anchor: sabotaging code AND naming a test that already exist at origin/main
  mkfix; sed -i.bak 's/def ok?, do: true/def ok?, do: false/' "$F/app1/lib/a.ex"; rm -f "$F/app1/lib/a.ex.bak"; before="$(tree_state)"
  sab "$T/n7" new ok-false --app app1 --test-file test/a_test.exs --must-fail "ok is true" -- app1/lib/a.ex
  eq "$RC" 1 "N7: a patch that fires in BOTH baselines is refused"
  says "$T/n7" "does not anchor 2-ok-false.patch against origin/main" "N7: ... by the double sweep's verdict"
  says "$T/n7" "APPLIES at PREV and every test it names ALREADY EXISTED" "N7: ... quoting its reason"
  eq "$(tree_state)" "$before" "N7: ... tree as it was"
  sab "$T/n7b" new ok-false --app app1 --test-file test/a_test.exs --must-fail "ok is true" --base nonexistent-ref -- app1/lib/a.ex
  eq "$RC" 1 "N7: an unknown --base is refused, not skipped"

  # N8 ─ a sabotage that flips nothing
  mkfix; sed -i.bak 's/def name, do: "a"/def name, do: "z"/' "$F/app1/lib/a.ex"; rm -f "$F/app1/lib/a.ex.bak"; before="$(tree_state)"
  sab "$T/n8" new name-z --app app1 --test-file test/a_test.exs --must-fail "limit is ten" -- app1/lib/a.ex
  # (an edit that anchors by its own new context but breaks no test)
  eq "$RC" 1 "N8: an edit that flips nothing is refused"
  eq "$(tree_state)" "$before" "N8: ... tree as it was"
  no_patch && ok "N8: ... no patch kept" || bad "N8: patch kept"

  # N9 ─ no edit / untracked
  mkfix; before="$(tree_state)"
  sab "$T/n9" new limit-eleven "${NEWARGS[@]:1}" -- app1/lib/a.ex
  eq "$RC" 1 "N9: a file with no edit against the index is refused"
  says "$T/n9" "git add your real fix" "N9: ... with the stage-first workflow"
  echo x > "$F/app1/lib/new.ex"
  sab "$T/n9b" new limit-eleven "${NEWARGS[@]:1}" -- app1/lib/new.ex
  eq "$RC" 1 "N9: an untracked file is refused"
  says "$T/n9b" "is not tracked" "N9: ... saying so"

  # N10 ─ the wrong test named: the suite fails, but not the named test
  mkfix; sabotage_limit
  sab "$T/n10" new limit-eleven --app app1 --test-file test/a_test.exs --must-fail "ok is true" -- app1/lib/a.ex
  eq "$RC" 1 "N10: naming a test that does not flip is refused"
  no_patch && ok "N10: ... no patch kept" || bad "N10: patch kept"

  # N11 ─ numbering
  mkfix; sabotage_limit
  sab "$T/n11a" new limit-eleven "${NEWARGS[@]:1}" --number 1 -- app1/lib/a.ex
  eq "$RC" 1 "N11: an explicit --number that is taken is refused"
  sab "$T/n11b" new limit-eleven "${NEWARGS[@]:1}" --number 40 -- app1/lib/a.ex
  eq "$RC" 0 "N11: an explicit free --number is used"
  [[ -f "$F/scripts/sabotages/40-limit-eleven.patch" ]] && ok "N11: ... as 40-limit-eleven.patch" || bad "N11: no 40-…"

  # N12 ─ unstaged work in progress next to the sabotage, which the named tests do not exercise: every check passes
  # (it cannot be told apart), so it lands in the patch and leaves the working tree — it must never be LOST
  mkfix
  sed -i.bak 's/  def max, do: 99/  def max, do: 100  # WIP, not staged/' "$F/app1/lib/a.ex"; rm -f "$F/app1/lib/a.ex.bak"
  sabotage_limit; sum="$(sha_of "$F/app1/lib/a.ex")"
  sab "$T/n12" new "${NEWARGS[@]}" -- app1/lib/a.ex
  eq "$RC" 0 "N12: an edit with unstaged WIP beside the sabotage still becomes a patch (indistinguishable)"
  says "$T/n12" "|+  def max, do: 100  # WIP, not staged" "N12: ... and prints every line it captured (the WIP line included)"
  kept="$(git -C "$F" rev-parse --git-common-dir)"; kept="$(cd "$F" && cd "$kept" && pwd)/samen-sabotage-new/2-limit-eleven.patch/app1/lib/a.ex"
  eq "$(sha_of "$kept" 2>/dev/null)" "$sum" "N12: ... and the pre-command file (WIP included) is KEPT, byte-exact, where it says"
  says "$T/n12" "kept      : " "N12: ... naming where"
}

run_ledger() {
  echo "== ledger =="
  LEDGER_F="scripts/sabotages/BUILD_REFUSED.tsv"
  SUB='takes the identity argument :actor_id'
  # a committed corpus patch 3 whose mutation the fake compiler refuses (the marker REFUSED), and patch 4 whose
  # mutation builds and flips (ok? -> false would clash with patch 1, so it moves `max`)
  prepl() {
    mkfix
    sed -i.bak 's/  def name, do: "a"/  def name, do: "a"  # REFUSED/' "$F/app1/lib/a.ex"; rm -f "$F/app1/lib/a.ex.bak"
    { printf '# SABOTAGE: refused\n#\n# Flips the named test(s).\n# APP: app1\n# TEST_FILES: test/a_test.exs\n# MUST_FAIL: ok is true\n'
      git -C "$F" diff --no-color -- app1/lib/a.ex; } > "$F/scripts/sabotages/3-refused.patch"
    git -C "$F" checkout -q -- app1/lib/a.ex
    git_ add -A; git_ commit -q -m "patch 3"
  }
  ledger() { printf '# header comment\n\n%s\t%s\t%s\n' "$1" "$2" "$3" > "$F/$LEDGER_F"; }

  # L1 ─ listed, refused, the required substring present: KILLED, a pass
  prepl; ledger 3-refused.patch "$SUB" "the probe rule refuses an identity argument"; before="$(tree_state)"
  sab "$T/l1" --range 3-3
  eq "$RC" 0 "L1: a listed patch whose build is refused with the required substring passes"
  says "$T/l1" "KILLED (build refused: $SUB)" "L1: ... reported as KILLED by the refusal, naming the substring"
  says "$T/l1" "restore: byte-exact" "L1: ... still restored byte-exact"
  says "$T/l1" "SABOTAGE HARNESS: ALL PASSED" "L1: ... a green run"
  says "$T/l1" "PROCESSED 1 of 1 SELECTED" "L1: ... counted as processed"
  eq "$(tree_state)" "$before" "L1: ... tree exactly as it was"

  # L2 ─ listed, refused, but the output lacks the substring: a wrong refusal
  prepl; ledger 3-refused.patch "a different refusal message" "x"
  sab "$T/l2" --range 3-3
  eq "$RC" 1 "L2: a listed patch refused WITHOUT the required substring fails"
  says "$T/l2" "WRONG REFUSAL" "L2: ... as a wrong refusal"
  silent "$T/l2" "KILLED" "L2: ... never KILLED"
  eq "$(git -C "$F" status --porcelain | grep -v BUILD_REFUSED)" "" "L2: ... tree restored"

  # patch 4: an ordinary sabotage that builds and flips "ok is true"
  mkbuilds() {
    sed -i.bak 's/def ok?, do: true/def ok?, do: false/' "$F/app1/lib/a.ex"; rm -f "$F/app1/lib/a.ex.bak"
    { printf '# SABOTAGE: builds\n#\n# Flips the named test(s).\n# APP: app1\n# TEST_FILES: test/a_test.exs\n# MUST_FAIL: ok is true\n'
      git -C "$F" diff --no-color -- app1/lib/a.ex; } > "$F/scripts/sabotages/4-builds.patch"
    git -C "$F" checkout -q -- app1/lib/a.ex; git_ add -A; git_ commit -q -m "patch 4"
  }

  # L3 ─ listed, but the build SUCCEEDS (and the tests even flip): a stale entry
  prepl; mkbuilds
  ledger 4-builds.patch "$SUB" "x"
  sab "$T/l3" --range 4-4
  eq "$RC" 1 "L3: a listed patch whose build succeeds fails, whatever the tests do"
  says "$T/l3" "STALE BUILD_REFUSED.tsv entry" "L3: ... naming the entry as stale"
  says "$T/l3" "the rule no longer refuses this mutation" "L3: ... and why"
  silent "$T/l3" "flip confirmed" "L3: ... the flip is not accepted as the proof"

  # L4 ─ NOT listed, refused: fails exactly as today (positive control: the same patch passes once listed, L1)
  prepl; printf '# only comments\n' > "$F/$LEDGER_F"
  sab "$T/l4" --range 3-3
  eq "$RC" 1 "L4: an unlisted patch whose build is refused still fails (no global leniency)"
  says "$T/l4" "no test-failure headers found (compile error?)" "L4: ... with today's message"
  silent "$T/l4" "KILLED" "L4: ... never KILLED"
  rm -f "$F/$LEDGER_F"
  sab "$T/l4b" --range 3-3
  eq "$RC" 1 "L4: ... and with no ledger file at all"

  # L5 ─ a bad entry fails at the start, before any patch is applied
  prepl; ledger 99-nope.patch "$SUB" "x"
  sab "$T/l5a" --range 3-3
  eq "$RC" 1 "L5: an entry naming a patch file that does not exist fails"
  says "$T/l5a" "names a patch that does not exist: '99-nope.patch'" "L5: ... naming it"
  silent "$T/l5a" "==> [1/1] sabotage" "L5: ... before any patch was replayed"
  ledger 3-refused.patch "" "x"
  sab "$T/l5b" --range 3-3
  eq "$RC" 1 "L5: an entry with an empty substring fails"
  says "$T/l5b" "empty required substring" "L5: ... saying so"
  ledger 3-refused.patch "   " "x"
  sab "$T/l5c" --range 3-3
  eq "$RC" 1 "L5: ... a blank substring too"
  printf '3-refused.patch\t%s\tr\n3-refused.patch\t%s\tr\n' "$SUB" "$SUB" > "$F/$LEDGER_F"
  sab "$T/l5d" --range 3-3
  eq "$RC" 1 "L5: a patch listed twice fails"
  ledger 3-refused.patch "$SUB" ""
  sab "$T/l5e" --range 3-3
  eq "$RC" 1 "L5: an entry with an empty reason fails"
  ledger 3-refused.patch "$SUB" "r"
  sab "$T/l5f" --range 3-3
  eq "$RC" 0 "L5: positive control — the same entry, valid, passes"

  # L6 ─ a ledgered patch next to an ordinary one: both replayed, the ordinary one still has to flip
  prepl; mkbuilds; ledger 3-refused.patch "$SUB" "r"
  sab "$T/l6" --range 3-4
  eq "$RC" 0 "L6: a ledgered patch and an ordinary patch in one run both pass"
  says "$T/l6" "flip confirmed: ok is true" "L6: ... the ordinary patch still flips its named test"
  says "$T/l6" "PROCESSED 2 of 2 SELECTED" "L6: ... both counted"
  ( cd "$F" && FAKE_MIX_NOFLIP=1 PATH="$BIN:$PATH" SAMEN_COUNTS_CACHE="$T/cc" bash scripts/sabotage --range 3-4 ) > "$T/l6b" 2>&1; RC=$?
  eq "$RC" 1 "L6: ... and an ordinary patch that stops flipping still fails the run beside it"
}

run_reanchor() {
  echo "== reanchor =="
  # a fixture whose corpus holds patch 2 = the limit sabotage, committed and applying
  prep() {
    mkfix; sabotage_limit
    { printf '# SABOTAGE: limit\n#\n# Flips the named test(s).\n# APP: app1\n# TEST_FILES: test/a_test.exs\n# MUST_FAIL: limit is ten\n'
      git -C "$F" diff --no-color -- app1/lib/a.ex; } > "$F/scripts/sabotages/2-limit-eleven.patch"
    git -C "$F" checkout -q -- app1/lib/a.ex
    git_ add -A; git_ commit -q -m "patch 2"
    P="$F/scripts/sabotages/2-limit-eleven.patch"; ORIG="$(sha_of "$P")"
  }
  drift() { sed -i.bak 's/  # doc$/  # documented/' "$F/app1/lib/a.ex"; rm -f "$F/app1/lib/a.ex.bak"; git_ commit -q -am "drift"; }

  # R0 ─ already applies
  prep
  sab "$T/r0" reanchor 2
  eq "$RC" 0 "R0: a patch that applies needs no re-anchor"
  says "$T/r0" "already applies" "R0: ... and says so"
  eq "$(sha_of "$P")" "$ORIG" "R0: ... untouched"

  # R1 ─ re-anchored: the context drifted, the lines it edits did not
  prep; drift
  ( cd "$F" && git apply --check scripts/sabotages/2-limit-eleven.patch 2>/dev/null ) && bad "R1: setup — the patch still applies" || ok "R1: setup — the patch no longer applies"
  hdr_before="$(sed -n '1,/^diff --git/p' "$P" | sed '$d' | shasum -a 256)"
  before="$(tree_state)"
  sab "$T/r1" reanchor 2
  eq "$RC" 0 "R1: a drifted patch is re-anchored"
  says "$T/r1" "REANCHOR 2-limit-eleven.patch: OK" "R1: ... reported"
  says "$T/r1" "flip confirmed: limit is ten" "R1: ... after the named test was seen to flip"
  eq "$(sed -n '1,/^diff --git/p' "$P" | sed '$d' | shasum -a 256)" "$hdr_before" "R1: ... header byte-identical"
  ( cd "$F" && git apply --check scripts/sabotages/2-limit-eleven.patch ) && ok "R1: ... and the rewritten patch applies" || bad "R1: rewritten patch does not apply"
  [[ "$(sha_of "$P")" != "$ORIG" ]] && ok "R1: ... and differs from the old one" || bad "R1: patch unchanged"
  grep -q 'documented' "$P" && ok "R1: ... carrying the NEW context" || bad "R1: new context missing"
  eq "$(git -C "$F" status --porcelain)" " M scripts/sabotages/2-limit-eleven.patch" "R1: ... only the patch changed; the tree is byte-exact after the replay"
  sab "$T/r1b" --range 2-2
  eq "$RC" 0 "R1: ... and scripts/sabotage.sh --range 2-2 replays it"

  # R2 ─ a conflict
  prep; sed -i.bak 's/def limit, do: 10/def limit, do: 12/' "$F/app1/lib/a.ex"; rm -f "$F/app1/lib/a.ex.bak"; git_ commit -q -am "limit moved"
  before="$(tree_state)"
  sab "$T/r2" reanchor 2
  eq "$RC" 1 "R2: a 3-way conflict is refused"
  says "$T/r2" "3-way merge CONFLICT" "R2: ... saying why"
  eq "$(sha_of "$P")" "$ORIG" "R2: ... original byte-identical"
  says "$T/r2" "original patch is untouched" "R2: ... and says so"
  eq "$(tree_state)" "$before" "R2: ... tree untouched"

  # R3 (C8) ─ re-anchored, but the named test no longer fails under it
  prep; drift; before="$(tree_state)"
  ( cd "$F" && FAKE_MIX_NOFLIP=1 PATH="$BIN:$PATH" SAMEN_COUNTS_CACHE="$T/cc" bash scripts/sabotage reanchor 2 ) > "$T/r3" 2>&1; RC=$?
  eq "$RC" 1 "R3 (C8): a re-anchor whose named tests no longer fail is REFUSED"
  says "$T/r3" "the named tests no longer fail" "R3 (C8): ... with that reason"
  eq "$(sha_of "$P")" "$ORIG" "R3 (C8): ... the original patch is byte-identical (nothing was rewritten)"
  eq "$(tree_state)" "$before" "R3 (C8): ... tree untouched"
  silent "$T/r3" "REANCHOR 2-limit-eleven.patch: OK" "R3 (C8): ... never an OK"

  # R4 ─ the named test is gone
  prep; drift; sed -i.bak '/limit is ten/d' "$F/app1/test/a_test.exs"; rm -f "$F/app1/test/a_test.exs.bak"; git_ commit -q -am "test removed"
  sab "$T/r4" reanchor 2
  eq "$RC" 1 "R4: a named test that no longer exists is refused"
  says "$T/r4" "the named test no longer exists" "R4: ... saying so"
  eq "$(sha_of "$P")" "$ORIG" "R4: ... original byte-identical"

  # R5 ─ a red baseline cannot prove "passes without it"
  prep; drift
  ( cd "$F" && FAKE_MIX_RED=1 PATH="$BIN:$PATH" SAMEN_COUNTS_CACHE="$T/cc" bash scripts/sabotage reanchor 2 ) > "$T/r5" 2>&1; RC=$?
  eq "$RC" 1 "R5: a red baseline is refused"
  says "$T/r5" "baseline is RED" "R5: ... saying so"
  eq "$(sha_of "$P")" "$ORIG" "R5: ... original byte-identical"

  # R6 ─ unknown / ambiguous numbers
  prep
  sab "$T/r6a" reanchor 99
  eq "$RC" 1 "R6: an unknown number is refused"
  cp "$P" "$F/scripts/sabotages/2-twin.patch"
  sab "$T/r6b" reanchor 2
  eq "$RC" 1 "R6: a number shared by two patches is refused as ambiguous"
  says "$T/r6b" "ambiguous" "R6: ... saying so"

  # R7 (C8) ─ a patch OUTSIDE the corpus: the proof replays the corpus patch with the same number, so a drifted
  # outside patch whose own edit flips nothing would be "proven" by corpus patch 2's flip and rewritten
  prep; mkdir -p "$T/out"
  sed -i.bak 's/def name, do: "a"/def name, do: "z"/' "$F/app1/lib/a.ex"; rm -f "$F/app1/lib/a.ex.bak"
  { printf '# SABOTAGE: other\n#\n# Flips the named test(s).\n# APP: app1\n# TEST_FILES: test/a_test.exs\n# MUST_FAIL: limit is ten\n'
    git -C "$F" diff --no-color -- app1/lib/a.ex; } > "$T/out/2-other.patch"
  git -C "$F" checkout -q -- app1/lib/a.ex
  sed -i.bak 's/  # filler three$/  # filler 3/' "$F/app1/lib/a.ex"; rm -f "$F/app1/lib/a.ex.bak"; git_ commit -q -am drift
  sab "$T/r7a" reanchor 2; git_ commit -q -am "corpus patch 2 re-anchored"
  outside="$(sha_of "$T/out/2-other.patch")"
  sab "$T/r7" reanchor "$T/out/2-other.patch"
  eq "$RC" 1 "R7 (C8): a patch outside scripts/sabotages/ is refused (its proof would replay corpus patch 2)"
  says "$T/r7" "is not a numbered patch in scripts/sabotages/" "R7 (C8): ... saying why"
  eq "$(sha_of "$T/out/2-other.patch")" "$outside" "R7 (C8): ... and it is not rewritten"
}

case "$WHICH" in
  new) run_new ;;
  reanchor) run_reanchor ;;
  ledger) run_ledger ;;
  all) run_new; run_reanchor; run_ledger ;;
  *) echo "usage: sabotage_tooling_test.sh [new|reanchor|ledger]" >&2; exit 2 ;;
esac

echo ""
echo "SABOTAGE TOOLING SELF-TEST ($WHICH): $pass_count passed, $fail_count failed"
[[ $fail_count -eq 0 ]] || { echo "SABOTAGE TOOLING SELF-TEST: FAILED"; exit 1; }
echo "SABOTAGE TOOLING SELF-TEST: ALL PASSED"
