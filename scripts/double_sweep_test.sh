#!/usr/bin/env bash
# scripts/double_sweep_test.sh — regression harness for scripts/double-sweep.sh.
#
# WHY THIS EXISTS. `double-sweep.sh` is the machinery for G-06, the rule that every
# increment sweeps its sabotages against BOTH the previous HEAD and the tree about to
# ship. A guard with no demonstrated failure mode is a comment, so this harness proves
# the sweep actually goes RED — once per failure class — and proves the green case is
# not green merely because the check never fires.
#
# HOW. It builds a throwaway git repo in a temp dir with the same shape the real one
# has (scripts/sabotages/*.patch + an app with lib/ and test/), commits a BASE, then
# mutates only the WORKING TREE — exactly how a real increment reaches the sweep. Every
# scenario runs the REAL scripts/double-sweep.sh with --repo/--base pointed at that
# throwaway. Nothing in this repository is read, written or swept.
#
# WHAT IT PROVES
#   1. GREEN — a well-formed increment (new patch attacking new lib code, naming a new
#      test) passes: exit 0, anchor 1 of 1, disarm clean.
#   2. ANTI-TAUTOLOGY for the disarm half — a patch that fails in BOTH baselines is a
#      PRE-EXISTING failure, reported in both lists and NOT called a regression. Without
#      this, a check that flagged every ship-side failure would pass scenario 4 too.
#   3. ANCHOR RED — a new patch that APPLIES at PREV and names only tests that ALREADY
#      EXISTED there is refused: exit 3. This is "a patch that fails in both baselines
#      is testing nothing".
#   4. ANCHOR POSITIVE CONTROL — a new patch whose MUST_FAIL matches nothing on the
#      SHIPPING tree is refused: exit 3. Without it, a typo in a MUST_FAIL header would
#      anchor every patch for free (the absent test is trivially "not at PREV").
#   5. DISARM RED — an edit that stops an ALREADY-SHIPPED patch from applying is caught
#      and named: exit 4.
#   6. ACCOUNTING RED, BY MUTATION — a copy of double-sweep.sh with its per-patch
#      PROCESSED increment deleted must exit 5 and say its numbers are VOID. The real
#      script is untouched; the mutant proves the invariant is load-bearing rather than
#      decorative.
#
# Usage: scripts/double_sweep_test.sh
# Exit:  0 if every assertion passes; non-zero + FAIL lines otherwise.
# Residue: NONE outside the temp dir, which is removed on every exit path.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DS="$REPO_ROOT/scripts/double-sweep.sh"

pass_count=0
fail_count=0
ok()  { echo "PASS: $*"; pass_count=$((pass_count + 1)); }
bad() { echo "FAIL: $*"; fail_count=$((fail_count + 1)); }

T="$(mktemp -d "${TMPDIR:-/tmp}/samen_ds_test.XXXXXX")"
cleanup() { rm -rf "$T"; }
trap cleanup EXIT INT TERM

FIX="$T/repo"
LOGS="$T/logs"
mkdir -p "$FIX/scripts/sabotages" "$FIX/demoapp/lib" "$FIX/demoapp/test" "$LOGS"

# ── the fixture tree ────────────────────────────────────────────────────────────────
# Three-line source files keep the hunks below exact: git apply matches context byte for
# byte (no fuzz), which is precisely the property the disarm half depends on.
cat > "$FIX/demoapp/lib/guard.ex" <<'EOF'
defmodule Guard do
  def refuse?(x), do: x == :denied
end
EOF

cat > "$FIX/demoapp/test/guard_test.exs" <<'EOF'
defmodule GuardTest do
  test "old guard refuses a denied actor" do
    assert Guard.refuse?(:denied)
  end
end
EOF

# A shipped sabotage that BITES: it applies to the fixture as committed.
cat > "$FIX/scripts/sabotages/010-old-guard.patch" <<'EOF'
# SABOTAGE: fixture — the old guard stops refusing.
# APP: demoapp
# TEST_FILES: test/guard_test.exs
# MUST_FAIL: old guard refuses a denied actor
diff --git a/demoapp/lib/guard.ex b/demoapp/lib/guard.ex
--- a/demoapp/lib/guard.ex
+++ b/demoapp/lib/guard.ex
@@ -1,3 +1,3 @@
 defmodule Guard do
-  def refuse?(x), do: x == :denied
+  def refuse?(_x), do: false
 end
EOF

# A shipped sabotage that ALREADY fails in every baseline (its target does not exist).
# It is the anti-tautology control for the disarm half: it must appear in BOTH failing
# lists and must never be counted as a regression.
cat > "$FIX/scripts/sabotages/011-already-broken.patch" <<'EOF'
# SABOTAGE: fixture — pre-existing failure, targets a file that does not exist.
# APP: demoapp
# TEST_FILES: test/guard_test.exs
# MUST_FAIL: old guard refuses a denied actor
diff --git a/demoapp/lib/ghost.ex b/demoapp/lib/ghost.ex
--- a/demoapp/lib/ghost.ex
+++ b/demoapp/lib/ghost.ex
@@ -1,3 +1,3 @@
 defmodule Ghost do
-  def refuse?(x), do: x == :denied
+  def refuse?(_x), do: false
 end
EOF

git -C "$FIX" init -q
git -C "$FIX" config user.email "fixture@example.invalid"
git -C "$FIX" config user.name "double-sweep fixture"
git -C "$FIX" add -A
git -C "$FIX" -c commit.gpgsign=false commit -q -m "fixture BASE"
BASE="$(git -C "$FIX" rev-parse HEAD)"

# ── the increment's NEW, well-formed material (working tree only) ───────────────────
new_arm() {
  cat > "$FIX/demoapp/lib/newarm.ex" <<'EOF'
defmodule NewArm do
  def refuse?(x), do: x == :blocked
end
EOF
  cat > "$FIX/demoapp/test/newarm_test.exs" <<'EOF'
defmodule NewArmTest do
  test "new arm refuses a blocked actor" do
    assert NewArm.refuse?(:blocked)
  end
end
EOF
  cat > "$FIX/scripts/sabotages/020-new-arm.patch" <<'EOF'
# SABOTAGE: fixture — the NEW arm stops refusing.
# APP: demoapp
# TEST_FILES: test/newarm_test.exs
# MUST_FAIL: new arm refuses a blocked actor
diff --git a/demoapp/lib/newarm.ex b/demoapp/lib/newarm.ex
--- a/demoapp/lib/newarm.ex
+++ b/demoapp/lib/newarm.ex
@@ -1,3 +1,3 @@
 defmodule NewArm do
-  def refuse?(x), do: x == :blocked
+  def refuse?(_x), do: false
 end
EOF
}

# A new patch that attacks PRE-EXISTING lib code and names a PRE-EXISTING test.
# <name> is the patch number so the two anchor reds can be exercised separately.
stale_patch() { # stale_patch <file> <must_fail>
  cat > "$FIX/scripts/sabotages/$1" <<EOF
# SABOTAGE: fixture — attacks lib code that already existed at BASE.
# APP: demoapp
# TEST_FILES: test/guard_test.exs
# MUST_FAIL: $2
diff --git a/demoapp/lib/guard.ex b/demoapp/lib/guard.ex
--- a/demoapp/lib/guard.ex
+++ b/demoapp/lib/guard.ex
@@ -1,3 +1,3 @@
 defmodule Guard do
-  def refuse?(x), do: x == :denied
+  def refuse?(_x), do: false
 end
EOF
}

reset_tree() {
  rm -f "$FIX/scripts/sabotages/020-new-arm.patch" \
        "$FIX/scripts/sabotages/021-stale-anchor.patch" \
        "$FIX/scripts/sabotages/022-absent-must-fail.patch" \
        "$FIX/demoapp/lib/newarm.ex" "$FIX/demoapp/test/newarm_test.exs"
  git -C "$FIX" checkout -q -- demoapp/lib/guard.ex
}

# run_sweep <log-name> [extra args...] — runs the REAL script; exit code read on the
# very next line from the command itself, never from a pipeline.
RC=0
run_sweep() {
  local log="$LOGS/$1"; shift
  bash "$DS" --repo "$FIX" --base "$BASE" "$@" > "$log" 2>&1
  RC=$?
  LAST_LOG="$log"
}

expect_rc() { # expect_rc <want> <what>
  if [[ $RC -eq $1 ]]; then
    ok "$2 (exit $RC)"
  else
    echo "--- $LAST_LOG ---"; cat "$LAST_LOG"
    bad "$2 — expected exit $1, got $RC"
  fi
}

expect_says() { # expect_says <pattern> <what>
  if grep -qF -- "$1" "$LAST_LOG"; then
    ok "$2"
  else
    echo "--- $LAST_LOG ---"; cat "$LAST_LOG"
    bad "$2 — output never said: $1"
  fi
}

expect_silent() { # expect_silent <pattern> <what>
  if grep -qF -- "$1" "$LAST_LOG"; then
    echo "--- $LAST_LOG ---"; cat "$LAST_LOG"
    bad "$2 — output wrongly said: $1"
  else
    ok "$2"
  fi
}

echo "== double-sweep.sh: the green case =="
reset_tree
new_arm
run_sweep green.log
expect_rc 0 "1. a well-formed increment PASSES both halves"
expect_says "anchor half: 1 of 1 new patch(es) anchored" "1a. the NEW set is DERIVED (1 patch) and it anchored"
expect_says "disarm half: nothing already shipped stopped biting" "1b. the disarm half is clean"
expect_says "PREV half PROCESSED 2 of 2 SELECTED" "1c. the PREV half accounts for every patch it selected"
expect_says "SHIP half PROCESSED 3 of 3 SELECTED" "1d. the SHIP half accounts for every patch it selected"

echo ""
echo "== the disarm half's ANTI-TAUTOLOGY control =="
expect_says "failing at PREV (1)" "2a. the PREV failing set is re-derived, not inherited"
expect_says "failing at SHIP (1)" "2b. the SHIP failing set is re-derived, not inherited"
expect_silent "DISARMED" "2c. a patch failing in BOTH baselines is NOT reported as a regression"

echo ""
echo "== RED 1: a new patch that would fire in both baselines =="
reset_tree
new_arm
stale_patch "021-stale-anchor.patch" "old guard refuses a denied actor"
run_sweep anchor-stale.log
expect_rc 3 "3. ANCHOR red — the stale patch is refused"
expect_says "021-stale-anchor.patch — it APPLIES at PREV and every test it names ALREADY EXISTED" \
            "3a. the message names the patch and the reason"
expect_says "DOUBLE SWEEP: FAILED — ANCHOR" "3b. the verdict line says which half failed"

echo ""
echo "== RED 2: a MUST_FAIL nobody can find on the shipping tree =="
reset_tree
new_arm
stale_patch "022-absent-must-fail.patch" "a test that was never written"
run_sweep anchor-control.log
expect_rc 3 "4. ANCHOR positive control — an unfindable MUST_FAIL is refused"
expect_says "POSITIVE CONTROL: MUST_FAIL not found" "4a. the message names the control that failed"

echo ""
echo "== RED 3: an edit that disarms an already-shipped sabotage =="
reset_tree
new_arm
cat > "$FIX/demoapp/lib/guard.ex" <<'EOF'
defmodule Guard do
  def refuse?(actor), do: actor in [:denied, :blocked]
end
EOF
run_sweep disarm.log
expect_rc 4 "5. DISARM red — the shipped patch no longer applies to the tree about to ship"
expect_says "010-old-guard.patch" "5a. the DISARMED patch is named"
expect_says "DOUBLE SWEEP: FAILED — DISARM" "5b. the verdict line says which half failed"
expect_silent "ALL PASSED" "5c. no green line is printed on a red run"

echo ""
echo "== RED 4: the PROCESSED-vs-SELECTED invariant, proven by MUTATION =="
reset_tree
new_arm
MUTANT="$T/double-sweep-mutant.sh"
sed 's/^    processed=\$((processed + 1))$/    :/' "$DS" > "$MUTANT"
if grep -qF 'processed=$((processed + 1))' "$MUTANT"; then
  bad "6-pre. the mutation did not take — the accounting test below would be vacuous"
else
  ok "6-pre. mutation applied: the per-patch PROCESSED increment is gone from the copy"
fi
bash "$MUTANT" --repo "$FIX" --base "$BASE" > "$LOGS/mutant.log" 2>&1
RC=$?
LAST_LOG="$LOGS/mutant.log"
expect_rc 5 "6. a sweep that audits fewer patches than it selected exits 5"
expect_says "every number it" "6a. the mutant is told its numbers are VOID"
expect_silent "ALL PASSED" "6b. a short sweep never reports a green"

echo ""
echo "== residue =="
reset_tree
if [[ -n "$(git -C "$FIX" status --porcelain)" ]]; then
  bad "the fixture tree is dirty after reset — a scenario leaked into the next"
else
  ok "every scenario's mutation is confined to its own scenario"
fi

echo ""
echo "double-sweep harness: $pass_count passed, $fail_count failed"
[[ $fail_count -eq 0 ]] || { echo "DOUBLE SWEEP HARNESS: FAILED"; exit 1; }
echo "DOUBLE SWEEP HARNESS: ALL PASSED"
