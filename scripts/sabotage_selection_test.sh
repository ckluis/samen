#!/usr/bin/env bash
# scripts/sabotage_selection_test.sh — regression harness for sabotage.sh's SELECTION
# logic (ADR-047 batch A4, fold (a)).
#
# THE BUG THIS PINS. `--changed [<ref>]` is the verifier primitive ("replay the
# sabotages relevant to my diff"). It derived its touched set from
# `git diff --name-only <ref>`, which lists ONLY TRACKED paths — so any batch that ADDS
# files silently under-selected. A3 hit this for real: its own new patches 247, 248 and
# 249 touch `samen_core/lib/samen/ai/agent/{tool_result,tools}.ex`, which were BRAND NEW,
# so `--changed HEAD` selected 11 patches and MISSED three of that batch's four. A
# verifier who trusted `--changed` alone would have certified A3 without ever replaying
# its own tool-result sabotages. An under-selecting selector is worse than no selector,
# because it reports a confident green over a hole.
#
# THE FIX. `--changed` now unions `git diff --name-only <ref>` with
# `git ls-files --others --exclude-standard`, and the FILTERED banner/label says
# `changed=<ref>+untracked` so the union is visible in the run's own output.
#
# WHAT THIS SCRIPT PROVES (all via `--list`, so NO patch is ever applied and no test runs):
#
#   1. POSITIVE — an untracked patch whose touched file is itself UNTRACKED IS selected
#      by `--changed HEAD`. This is the exact A3 miss, reproduced and closed.
#   2. THE MECHANISM IS THE UNION, not an accident — the same probe path is asserted
#      ABSENT from `git diff --name-only HEAD` (it is untracked, so git diff cannot see
#      it) and PRESENT in `git ls-files --others --exclude-standard`. Without this the
#      positive case could pass merely because the file happened to be tracked.
#   3. NEGATIVE CONTROL (anti-tautology) — a patch touching a path that is NEITHER
#      changed NOR untracked is NOT selected. Without this, "selects everything" would
#      pass assertion 1.
#   4. THE BANNER IS HONEST — the `--list` header for a `--changed` run names the union
#      (`changed=HEAD+untracked`), so a reader can never mistake it for the tracked-only
#      selector that shipped before.
#   5. FILTERS STILL COMPOSE AS AN INTERSECTION — `--changed HEAD --range` narrows to the
#      intersection and does not resurrect the probe patch.
#
# Usage: scripts/sabotage_selection_test.sh
# Exit:  0 if every assertion passes; non-zero + FAIL lines otherwise.
# Residue: NONE — every scratch file is created under scripts/sabotages/ + samen_core/lib/
# with a distinctive `__sabotage_selection_probe` name and removed on EVERY exit path
# (trap covering EXIT/INT/TERM). Nothing tracked is ever modified.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SABOTAGE="$REPO_ROOT/scripts/sabotage.sh"

PROBE_SRC_REL="samen_core/lib/samen/__sabotage_selection_probe.ex"
PROBE_SRC="$REPO_ROOT/$PROBE_SRC_REL"
# 999 keeps the probe out of every real --range window a gate would use.
PROBE_PATCH="$REPO_ROOT/scripts/sabotages/999-sabotage-selection-probe.patch"
ABSENT_PATCH="$REPO_ROOT/scripts/sabotages/998-sabotage-selection-absent-probe.patch"
ABSENT_REL="samen_core/lib/samen/__sabotage_selection_absent.ex"

pass_count=0
fail_count=0
ok()  { echo "PASS: $*"; pass_count=$((pass_count + 1)); }
bad() { echo "FAIL: $*"; fail_count=$((fail_count + 1)); }

cleanup() {
  rm -f "$PROBE_SRC" "$PROBE_PATCH" "$ABSENT_PATCH"
}
trap cleanup EXIT INT TERM

# A probe patch carrying the house header set (APP/TEST_FILES/MUST_FAIL) so the ALWAYS-ON
# header preflight (scripts/sabotage_lint.sh) stays green while these probes exist. The
# body is never applied — every assertion below runs `--list`.
write_probe_patch() { # write_probe_patch <patch-path> <touched-rel-path>
  cat > "$1" <<EOF
# SABOTAGE: scripts/sabotage_selection_test.sh scratch probe — NEVER applied (every
# assertion in that harness runs --list, which applies nothing). Present only for the
# lifetime of that script; removed on every exit path.
# APP: samen_core
# TEST_FILES: test/ai/agent_tools_test.exs
# MUST_FAIL: sabotage selection probe
diff --git a/$2 b/$2
--- a/$2
+++ b/$2
@@ -1,1 +1,1 @@
-# probe
+# probe (sabotaged)
EOF
}

echo "== sabotage.sh --changed selection: untracked files must be in the touched set =="

# The probe SOURCE file is created but NEVER `git add`ed — it is untracked, exactly like
# a brand-new module mid-batch.
printf '# probe\n' > "$PROBE_SRC"
write_probe_patch "$PROBE_PATCH" "$PROBE_SRC_REL"
# ...and a second probe patch touching a path that does not exist and was never changed.
write_probe_patch "$ABSENT_PATCH" "$ABSENT_REL"

listing="$(cd "$REPO_ROOT" && bash "$SABOTAGE" --changed HEAD --list 2>&1)"
list_status=$?

if [[ $list_status -ne 0 ]]; then
  echo "$listing"
  bad "--changed HEAD --list exited $list_status (expected 0)"
else
  ok "--changed HEAD --list exited 0"
fi

# 2. THE MECHANISM: git diff cannot see the probe; ls-files --others can.
if (cd "$REPO_ROOT" && git diff --name-only HEAD) | grep -qxF "$PROBE_SRC_REL"; then
  bad "precondition broken: $PROBE_SRC_REL is TRACKED — assertion 1 would be vacuous"
else
  ok "precondition: git diff --name-only HEAD does NOT list the untracked probe (the old selector's blind spot)"
fi

if (cd "$REPO_ROOT" && git ls-files --others --exclude-standard) | grep -qxF "$PROBE_SRC_REL"; then
  ok "git ls-files --others --exclude-standard DOES list the untracked probe (the union's second half)"
else
  bad "git ls-files --others --exclude-standard did not list $PROBE_SRC_REL"
fi

# 1. POSITIVE: the untracked-file patch is selected.
if grep -qF "999-sabotage-selection-probe.patch" <<<"$listing"; then
  ok "--changed HEAD SELECTS a patch whose only touched file is UNTRACKED (the A3 247/248/249 miss, closed)"
else
  echo "$listing"
  bad "--changed HEAD did NOT select the untracked-file patch — the union regressed"
fi

# 3. NEGATIVE CONTROL: a patch touching a neither-changed-nor-untracked path is NOT
#    selected. Without this, a selector that returned every patch would pass above.
if grep -qF "998-sabotage-selection-absent-probe.patch" <<<"$listing"; then
  echo "$listing"
  bad "--changed HEAD selected a patch touching an UNCHANGED, UNTRACKED-ABSENT path — the filter is vacuous"
else
  ok "NEGATIVE CONTROL: a patch touching a neither-changed-nor-untracked path is NOT selected"
fi

# 4. THE BANNER IS HONEST about what the touched set actually contains.
if grep -qF "changed=HEAD+untracked" <<<"$listing"; then
  ok "the FILTERED selection banner names the union (changed=HEAD+untracked) — no silent widening"
else
  echo "$listing"
  bad "the --changed banner does not disclose the untracked half of the union"
fi

# 5. FILTERS STILL COMPOSE AS AN INTERSECTION (the union widened the touched set, it did
#    not turn --changed into a union WITH the other filters).
narrowed="$(cd "$REPO_ROOT" && bash "$SABOTAGE" --changed HEAD --range 1-2 --list 2>&1)"
if grep -qF "999-sabotage-selection-probe.patch" <<<"$narrowed"; then
  echo "$narrowed"
  bad "--changed + --range did not intersect: the out-of-range probe survived"
else
  ok "filters still COMPOSE as an intersection (--changed HEAD --range 1-2 excludes the probe)"
fi

cleanup

# Residue check: the probes are gone and the tree is exactly as we found it.
if [[ -e "$PROBE_SRC" || -e "$PROBE_PATCH" || -e "$ABSENT_PATCH" ]]; then
  bad "scratch residue left behind"
else
  ok "zero residue (probe source + both probe patches removed)"
fi

echo ""
echo "sabotage-selection harness: $pass_count passed, $fail_count failed"
[[ $fail_count -eq 0 ]] || { echo "SABOTAGE SELECTION HARNESS: FAILED"; exit 1; }
echo "SABOTAGE SELECTION HARNESS: ALL PASSED"
