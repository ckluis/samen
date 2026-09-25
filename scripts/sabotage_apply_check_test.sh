#!/usr/bin/env bash
# scripts/sabotage_apply_check_test.sh — regression harness for sabotage_apply_check.sh.
#
# A guard with no demonstrated failure mode is a comment. This builds a throwaway git repo
# in a temp dir (scripts/sabotages/*.patch + one lib file), runs the REAL
# scripts/sabotage_apply_check.sh against it with --repo, and proves:
#
#   1. GREEN — two patches that apply: exit 0, "2 of 2".
#   2. ROT RED — an edit to the lib file that moves one patch's context: exit 1, the
#      rotted patch is NAMED, and the patch that still applies is NOT (specificity: a
#      check that named every patch on any failure would pass a weaker test).
#   3. WORKING TREE, NOT HEAD — the same rot left UNCOMMITTED is still caught (what
#      ships is the working tree; a check against HEAD would miss an uncommitted disarm).
#   4. EMPTY CORPUS — no patches is an environment error (exit 2), never a vacuous pass.
#   5. BY MUTATION — a copy of the checker with its failure increment deleted exits 0 on
#      the rotted tree. That is the proof case 2's red comes from that line and not from
#      something incidental; the real script is untouched.
#   6. ACCOUNTING, BY MUTATION — a copy with its PROCESSED increment deleted exits 5 and
#      says its numbers are VOID.
#
# Usage: scripts/sabotage_apply_check_test.sh
# Residue: NONE outside the temp dir, which is removed on every exit path.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHK="$REPO_ROOT/scripts/sabotage_apply_check.sh"

pass_count=0
fail_count=0
ok()  { echo "PASS: $*"; pass_count=$((pass_count + 1)); }
bad() { echo "FAIL: $*"; fail_count=$((fail_count + 1)); }

T="$(mktemp -d "${TMPDIR:-/tmp}/samen_sac_test.XXXXXX")"
cleanup() { rm -rf "$T"; }
trap cleanup EXIT INT TERM

FIX="$T/repo"
mkdir -p "$FIX/scripts/sabotages" "$FIX/app/lib"

cat > "$FIX/app/lib/guard.ex" <<'EOF'
defmodule Guard do
  def a?(x), do: x == :ok
  # a
  # --
  # b
  def b?(x), do: x != :bad
end
EOF

cat > "$FIX/scripts/sabotages/1-a.patch" <<'EOF'
# APP: app
# TEST_FILES: test/guard_test.exs
# MUST_FAIL: a
diff --git a/app/lib/guard.ex b/app/lib/guard.ex
--- a/app/lib/guard.ex
+++ b/app/lib/guard.ex
@@ -1,3 +1,3 @@
 defmodule Guard do
-  def a?(x), do: x == :ok
+  def a?(x), do: x != :ok
   # a
EOF

cat > "$FIX/scripts/sabotages/2-b.patch" <<'EOF'
# APP: app
# TEST_FILES: test/guard_test.exs
# MUST_FAIL: b
diff --git a/app/lib/guard.ex b/app/lib/guard.ex
--- a/app/lib/guard.ex
+++ b/app/lib/guard.ex
@@ -5,3 +5,3 @@
   # b
-  def b?(x), do: x != :bad
+  def b?(x), do: x == :bad
 end
EOF

git -C "$FIX" init -q
git -C "$FIX" -c user.email=t@t -c user.name=t add -A
git -C "$FIX" -c user.email=t@t -c user.name=t commit -q -m base

LOG=""
RC=0
run() { # run <script> <logname>
  LOG="$T/$2"
  bash "$1" --repo "$FIX" > "$LOG" 2>&1
  RC=$?
}
expect_rc()     { if [[ $RC -eq $1 ]]; then ok "$2 (exit $RC)"; else cat "$LOG"; bad "$2 — expected exit $1, got $RC"; fi; }
expect_says()   { if grep -qF -- "$1" "$LOG"; then ok "$2"; else cat "$LOG"; bad "$2 — never said: $1"; fi; }
expect_silent() { if grep -qF -- "$1" "$LOG"; then cat "$LOG"; bad "$2 — wrongly said: $1"; else ok "$2"; fi; }

# rot patch 2 only: rewrite the line its hunk removes. Patch 1's hunk is lines 1-3 and
# patch 2's is lines 5-7, disjoint, so this cannot move patch 1 (case 2c depends on it).
rot() { sed -i.bak 's/x != :bad/x not in [:bad]/' "$FIX/app/lib/guard.ex" && rm -f "$FIX/app/lib/guard.ex.bak"; }
unrot() { git -C "$FIX" checkout -q -- app/lib/guard.ex; }

echo "== 1. green =="
run "$CHK" green.log
expect_rc 0 "1a. every patch applies"
expect_says "ALL PASSED (2 of 2 patches" "1b. both patches are counted"

echo "== 2/3. rot, left uncommitted in the working tree =="
rot
run "$CHK" rot.log
expect_rc 1 "2a. a rotted patch fails the check"
expect_says "DOES NOT APPLY  2-b.patch" "2b. the rotted patch is named"
expect_silent "DOES NOT APPLY  1-a.patch" "2c. the patch that still applies is NOT named"
expect_says "PROCESSED 2 of 2 SELECTED" "3. the rot was UNCOMMITTED, so the check read the working tree"

echo "== 5. mutation: no failure increment =="
M1="$T/mutant_nofail.sh"
grep -v 'bad=\$((bad + 1))' "$CHK" > "$M1"
if cmp -s "$CHK" "$M1"; then bad "5-pre. the mutation did not change the script (the pattern no longer matches)"; fi
run "$M1" mutant1.log
expect_rc 0 "5. with the failure increment deleted, the rotted tree PASSES — so 2a's red depends on it"

echo "== 6. mutation: no PROCESSED increment =="
M2="$T/mutant_noproc.sh"
grep -v 'processed=\$((processed + 1))' "$CHK" > "$M2"
if cmp -s "$CHK" "$M2"; then bad "6-pre. the mutation did not change the script (the pattern no longer matches)"; fi
run "$M2" mutant2.log
expect_rc 5 "6a. a checker that skips its PROCESSED count is an accounting failure"
expect_says "is VOID" "6b. it says its numbers are VOID"
unrot

echo "== 4. empty corpus =="
rm -f "$FIX"/scripts/sabotages/*.patch
run "$CHK" empty.log
expect_rc 2 "4a. no patches is an environment error, never a vacuous pass"
expect_silent "ALL PASSED" "4b. and it never claims a pass"

echo ""
echo "SABOTAGE APPLY CHECK SELF-TEST: $pass_count passed, $fail_count failed"
if [[ $fail_count -gt 0 ]]; then
  echo "SABOTAGE APPLY CHECK SELF-TEST: FAILED"
  exit 1
fi
echo "SABOTAGE APPLY CHECK SELF-TEST: ALL PASSED"
