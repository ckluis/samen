#!/usr/bin/env bash
# scripts/mutate_test.sh -- regression harness for scripts/mutate.sh, the mutation engine.
#
# A mutation tool that reports zero survivors is worthless unless it can be SHOWN to find one,
# a kill, and a stillborn -- and to leave the tree byte-exact. This pins all of that, in
# seconds, against a throwaway Elixir fixture (no mix, no DB), exactly as sabotage.sh's own
# selection harness pins its selector. It proves, end to end through the real engine:
#
#   1. KILLED    -- a mutation of a guard a test PINS makes the scoped test fail (the engine's
#                   exit-code handling is right: test-fail => KILLED).
#   2. SURVIVED  -- a mutation of a guard NOTHING asserts leaves the scoped test green, and the
#                   engine reports it SURVIVED (the finding a mutation tool exists to surface).
#   3. STILLBORN -- a mutation that does not compile is classified STILLBORN, never mistaken
#                   for a kill or a survivor.
#   4. ACCOUNTING-- the MUTANTS: line reconciles generated == run + skipped, with the exact
#                   killed/survived/stillborn breakdown (non-negotiable #3).
#   5. RESTORE   -- the fixture's sha-256 is identical before and after the whole run, and the
#                   engine asserts its own byte-exact restore (non-negotiable #1).
#   6. NEGATIVE CONTROL (anti-tautology) -- the KILLED and SURVIVED verdicts land on DIFFERENT
#                   sites; a broken engine that reported one verdict everywhere would fail here.
#
# Residue: NONE. The fixture + throwaway targets file live under scripts/__mutate_selftest_scratch/
# with a distinctive name and are removed on EVERY exit path (trap EXIT/INT/TERM). Nothing
# tracked is ever modified.
#
# Usage: scripts/mutate_test.sh   Exit: 0 iff every assertion passes.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MUTATE="$REPO_ROOT/scripts/mutate.sh"

SCRATCH_REL="scripts/__mutate_selftest_scratch"
SCRATCH="$REPO_ROOT/$SCRATCH_REL"
GUARD_REL="$SCRATCH_REL/st_guard.ex"
GUARD="$REPO_ROOT/$GUARD_REL"
TESTFILE="$SCRATCH/st_guard_test.exs"
TARGETS="$SCRATCH/targets.cfg"

pass_count=0
fail_count=0
ok()  { echo "PASS: $*"; pass_count=$((pass_count + 1)); }
bad() { echo "FAIL: $*"; fail_count=$((fail_count + 1)); }

cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT INT TERM

mkdir -p "$SCRATCH"

# ---- the throwaway fixture ---------------------------------------------------------------
# covered/2  is PINNED by the test  -> a flip-comparison mutant is KILLED.
# uncovered/2 is asserted by NOTHING -> a flip-comparison mutant SURVIVES.
# classify/1  has an arm whose tuple-arm reconstruction is unbound (`_`) -> STILLBORN.
cat > "$GUARD" <<'EOF'
defmodule MutateSelftest.Guard do
  def covered(count, max) do
    count <= max
  end

  def uncovered(a, b) do
    a <= b
  end

  def classify(x) do
    case x do
      {:ok, _v} = ok -> ok
      {:err, _} -> :bad
    end
  end
end
EOF

cat > "$TESTFILE" <<'EOF'
ExUnit.start()
Code.require_file("st_guard.ex", __DIR__)

defmodule MutateSelftest.GuardTest do
  use ExUnit.Case
  alias MutateSelftest.Guard

  # Pins covered/2 ONLY. uncovered/2 and classify/1 are deliberately unasserted.
  test "covered/2 is at-or-under, exclusive over" do
    assert Guard.covered(5, 10)
    assert Guard.covered(10, 10)
    refute Guard.covered(11, 10)
  end
end
EOF

COVERED_LINE=$(/usr/bin/grep -n 'count <= max' "$GUARD" | cut -d: -f1)
UNCOVERED_LINE=$(/usr/bin/grep -n 'a <= b' "$GUARD" | cut -d: -f1)
STILLBORN_LINE=$(/usr/bin/grep -n '{:err, _} ->' "$GUARD" | cut -d: -f1)

# ---- the throwaway targets config (proves the config-list + --targets mechanism) ---------
cat > "$TARGETS" <<EOF
covered/2|$GUARD_REL|^  def covered\\(|flip-comparison|$SCRATCH_REL|elixir -e 'Code.compile_file("st_guard.ex")'|elixir st_guard_test.exs
uncovered/2|$GUARD_REL|^  def uncovered\\(|flip-comparison|$SCRATCH_REL|elixir -e 'Code.compile_file("st_guard.ex")'|elixir st_guard_test.exs
classify/1|$GUARD_REL|^  def classify\\(|tuple-arm|$SCRATCH_REL|elixir -e 'Code.compile_file("st_guard.ex")'|elixir st_guard_test.exs
EOF

SHA_BEFORE=$(shasum -a 256 "$GUARD" | awk '{print $1}')

echo "== running the engine against the throwaway fixture =="
OUT="$SCRATCH/run.log"
bash "$MUTATE" --targets "$TARGETS" >"$OUT" 2>&1
engine_rc=$?
sed 's/^/   | /' "$OUT"
echo

# ---- assertions --------------------------------------------------------------------------
if [[ $engine_rc -eq 0 ]]; then
  ok "engine exited 0 (ran cleanly, tree restored)"
else
  bad "engine exited $engine_rc (expected 0)"
fi

if /usr/bin/grep -Eq "KILLED +${GUARD_REL}:${COVERED_LINE}\b" "$OUT"; then
  ok "KILLED reported for the PINNED guard (covered/2 flip, line $COVERED_LINE)"
else
  bad "no KILLED verdict at covered/2 (line $COVERED_LINE) -- exit-code handling or mapping broken"
fi

if /usr/bin/grep -Eq "SURVIVED +${GUARD_REL}:${UNCOVERED_LINE}\b" "$OUT"; then
  ok "SURVIVED reported for the UNPROVEN guard (uncovered/2 flip, line $UNCOVERED_LINE)"
else
  bad "no SURVIVED verdict at uncovered/2 (line $UNCOVERED_LINE) -- the tool cannot find a survivor"
fi

if /usr/bin/grep -Eq "STILLBORN +${GUARD_REL}:${STILLBORN_LINE}\b" "$OUT"; then
  ok "STILLBORN reported for the non-compiling mutant (classify/1 arm, line $STILLBORN_LINE)"
else
  bad "no STILLBORN verdict at classify/1 (line $STILLBORN_LINE) -- compile classification broken"
fi

# NEGATIVE CONTROL: the KILLED and SURVIVED verdicts landed on DIFFERENT lines. A broken
# engine that stamped one verdict everywhere would already have failed above; this makes the
# distinctness explicit so it can never pass by coincidence.
if [[ "$COVERED_LINE" != "$UNCOVERED_LINE" ]] \
   && /usr/bin/grep -Eq "KILLED +${GUARD_REL}:${COVERED_LINE}\b" "$OUT" \
   && ! /usr/bin/grep -Eq "SURVIVED +${GUARD_REL}:${COVERED_LINE}\b" "$OUT"; then
  ok "NEGATIVE CONTROL: the covered/2 site is KILLED and NOT also reported SURVIVED"
else
  bad "NEGATIVE CONTROL failed: verdicts are not site-distinct"
fi

if /usr/bin/grep -Eq 'MUTANTS: generated 3, run 3, killed 1, survived 1, stillborn 1' "$OUT"; then
  ok "accounting line reconciles: generated 3, run 3, killed 1, survived 1, stillborn 1"
else
  bad "accounting line wrong or missing (expected generated 3, run 3, killed 1, survived 1, stillborn 1)"
fi

if /usr/bin/grep -q 'git status (targets) clean' "$OUT"; then
  ok "engine asserted its own byte-exact restore + clean tree"
else
  bad "engine did not assert a clean restore"
fi

SHA_AFTER=$(shasum -a 256 "$GUARD" | awk '{print $1}')
if [[ "$SHA_BEFORE" == "$SHA_AFTER" ]]; then
  ok "RESTORE: fixture sha-256 identical before and after the whole run"
else
  bad "RESTORE: fixture sha changed ($SHA_BEFORE -> $SHA_AFTER)"
fi

# ---- SIGINT PROOF: interrupt a live run mid-mutant; the trap must restore byte-exact ------
# The pause hook (MUTATE_PAUSE_BEFORE_RESTORE) holds a mutant LIVE on disk so the signal is
# guaranteed to land mid-mutant. `set -m` puts the engine in its own process group so the
# SIGINT reaches its children (the pause `sleep`) too, and the trap fires promptly.
echo "== SIGINT proof: interrupt mid-mutant, trap must restore byte-exact =="
SIG_BEFORE=$(shasum -a 256 "$GUARD" | awk '{print $1}')
set -m
MUTATE_PAUSE_BEFORE_RESTORE=4 bash "$MUTATE" --targets "$TARGETS" --only covered/2 \
  >"$SCRATCH/sigint.log" 2>&1 &
SIG_PID=$!
sig_sent=0
for _ in $(seq 1 200); do
  kill -0 "$SIG_PID" 2>/dev/null || break
  if [[ "$(shasum -a 256 "$GUARD" | awk '{print $1}')" != "$SIG_BEFORE" ]]; then
    kill -INT -- "-$SIG_PID"          # negative PID = signal the whole process group
    sig_sent=1
    break
  fi
  sleep 0.2
done
wait "$SIG_PID"; sig_rc=$?
set +m
SIG_AFTER=$(shasum -a 256 "$GUARD" | awk '{print $1}')
if [[ "$sig_sent" -eq 1 && "$sig_rc" -eq 130 && "$SIG_BEFORE" == "$SIG_AFTER" ]]; then
  ok "SIGINT mid-mutant: engine exited 130 and restored the fixture byte-exact"
else
  sed 's/^/   | /' "$SCRATCH/sigint.log"
  bad "SIGINT proof failed (sent=$sig_sent rc=$sig_rc before=$SIG_BEFORE after=$SIG_AFTER)"
fi
if /usr/bin/grep -q 'ABORTED (signal)' "$SCRATCH/sigint.log"; then
  ok "aborted run names its status ABORTED (signal) -- never reads as clean"
else
  bad "aborted run did not print an ABORTED status line"
fi

cleanup
if [[ -e "$SCRATCH" ]]; then
  bad "scratch residue left behind"
else
  ok "zero residue (scratch fixture + targets file removed)"
fi

echo ""
echo "mutation self-test: $pass_count passed, $fail_count failed"
[[ $fail_count -eq 0 ]] || { echo "MUTATION SELF-TEST: FAILED"; exit 1; }
echo "MUTATION SELF-TEST: ALL PASSED"
