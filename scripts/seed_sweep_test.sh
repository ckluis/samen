#!/usr/bin/env bash
# scripts/seed_sweep_test.sh — self-test for scripts/seed-sweep.sh (issue #42).
#
# WHY THIS EXISTS. A sweep tool with no demonstrated failure mode is a comment, not a
# gate. This proves seed-sweep.sh actually (1) runs every selected seed and reports
# `PROCESSED N of N`, (2) names the SPECIFIC seeds that failed, (3) exits non-zero iff
# a seed failed, and (4) that the "all green" path is REALLY green — not green because
# the check never fired (the anti-tautology half every gate in this repo insists on;
# see scripts/sabotage.sh, scripts/double_sweep_test.sh).
#
# WHY THIS IS MEMORY-LIGHT. This machine OS-kills a full samen_core/samen_web suite
# under low memory, so this self-test never touches either real app or Postgres. It
# builds two throwaway, dependency-free Mix projects in a temp dir:
#   - a MIXED fixture whose single test reads ExUnit's own seed
#     (`ExUnit.configuration()[:seed]`) and asserts `rem(seed, 2) == 0` — genuinely
#     SEED-DETERMINED (same seed always gets the same verdict; different seeds can
#     disagree) and reads/writes NOTHING but its own process state: no DB, no files,
#     no network.
#   - a GREEN fixture whose single test is `assert true` — passes under every seed,
#     the positive control that "ALL PASSED" really means the runs were green and not
#     that the sweep silently skipped them.
# Both compile in well under a second and need no `mix deps.get` (zero deps).
#
# WHAT IT PROVES, run by run:
#   1. explicit odd+even seed list against MIXED -> PROCESSED 6 of 6, exactly the three
#      odd seeds named FAILED, exit 1.
#   2. explicit all-even seed list against MIXED -> ALL PASSED, exit 0 (anti-tautology:
#      proves the mixed fixture is not just always-red — its parity logic really does
#      let seeds pass).
#   3. --seeds 5 (auto-generated) against GREEN -> PROCESSED 5 of 5, ALL PASSED, exit 0
#      (the positive control that the "all green" path is real).
#   4. --file targeting just the mixed fixture's test file, one odd seed -> the file
#      flag narrows to that file and still reports the failing seed by name.
#
# Usage: scripts/seed_sweep_test.sh
# Exit:  0 if every assertion passes; non-zero + FAIL lines otherwise.
# Residue: NONE outside the temp dir, which is removed on every exit path.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWEEP="$REPO_ROOT/scripts/seed-sweep.sh"

pass_count=0
fail_count=0
ok()  { echo "PASS: $*"; pass_count=$((pass_count + 1)); }
bad() { echo "FAIL: $*"; fail_count=$((fail_count + 1)); }

T="$(mktemp -d "${TMPDIR:-/tmp}/samen_seedsweep_test.XXXXXX")"
cleanup() { rm -rf "$T"; }
trap cleanup EXIT INT TERM

# ── fixture builders ──────────────────────────────────────────────────────────────
# Deliberately NO deps, NO lib/, NO config referencing Ecto/Postgres — mix test on
# these two projects touches nothing outside the temp dir.
mk_mix_exs() { # mk_mix_exs <dir> <app_atom>
  cat > "$1/mix.exs" <<EOF
defmodule $2.MixProject do
  use Mix.Project

  def project do
    [
      app: :$2,
      version: "0.1.0",
      elixir: "~> 1.20",
      deps: []
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end
end
EOF
}

MIXED="$T/mixed_fixture"
GREEN="$T/green_fixture"
mkdir -p "$MIXED/test" "$GREEN/test"

mk_mix_exs "$MIXED" SeedSweepMixedFixture
mk_mix_exs "$GREEN" SeedSweepGreenFixture

cat > "$MIXED/test/test_helper.exs" <<'EOF'
ExUnit.start()
EOF

# Seed-determined, DB-free: the ONLY input to the assertion is ExUnit's own seed.
cat > "$MIXED/test/seed_determined_test.exs" <<'EOF'
defmodule SeedDeterminedTest do
  use ExUnit.Case

  test "passes only for even ExUnit seeds (deterministic, no DB, no I/O)" do
    seed = ExUnit.configuration()[:seed]
    assert rem(seed, 2) == 0, "seed #{seed} is odd by construction — expected failure"
  end
end
EOF

cat > "$GREEN/test/test_helper.exs" <<'EOF'
ExUnit.start()
EOF

cat > "$GREEN/test/always_green_test.exs" <<'EOF'
defmodule AlwaysGreenTest do
  use ExUnit.Case

  test "passes under every seed (positive control)" do
    assert true
  end
end
EOF

# ── scenario 1: mixed odd+even list -> PROCESSED 6 of 6, 3 named failures, exit 1 ──
OUT1="$T/out1.log"
"$SWEEP" --app "$MIXED" --seed-list "1,2,3,4,5,6" > "$OUT1" 2>&1
rc1=$?

if [[ $rc1 -ne 0 ]]; then
  ok "scenario 1: mixed seed list exits non-zero (got $rc1)"
else
  bad "scenario 1: mixed seed list should exit non-zero, got 0"
fi

if grep -q "SEED-SWEEP: PROCESSED 6 of 6" "$OUT1"; then
  ok "scenario 1: reports PROCESSED 6 of 6"
else
  bad "scenario 1: missing 'PROCESSED 6 of 6' line"
fi

all_named=1
for s in 1 3 5; do
  grep -q "SEED-SWEEP: seed $s FAILED" "$OUT1" || { all_named=0; bad "scenario 1: seed $s not named as FAILED"; }
done
[[ $all_named -eq 1 ]] && ok "scenario 1: names all three failing seeds (1, 3, 5)"

false_named=0
for s in 2 4 6; do
  grep -q "SEED-SWEEP: seed $s FAILED" "$OUT1" && { false_named=1; bad "scenario 1: passing seed $s wrongly named FAILED"; }
done
[[ $false_named -eq 0 ]] && ok "scenario 1: does not name passing seeds (2, 4, 6) as failed"

# ── scenario 2: all-even list against the SAME mixed fixture -> ALL PASSED, exit 0 ──
# Anti-tautology control: proves scenario 1's failures are the parity logic actually
# discriminating, not the fixture (or the runner) always reporting red.
OUT2="$T/out2.log"
"$SWEEP" --app "$MIXED" --seed-list "2,4,8,10" > "$OUT2" 2>&1
rc2=$?

if [[ $rc2 -eq 0 ]]; then
  ok "scenario 2 (anti-tautology): all-even seed list against MIXED exits 0"
else
  bad "scenario 2 (anti-tautology): all-even seed list against MIXED should exit 0, got $rc2"
fi
if grep -q "SEED-SWEEP: PROCESSED 4 of 4" "$OUT2" && grep -q "SEED-SWEEP: ALL PASSED (4 seeds)" "$OUT2"; then
  ok "scenario 2: reports PROCESSED 4 of 4 and ALL PASSED"
else
  bad "scenario 2: missing PROCESSED 4 of 4 / ALL PASSED lines"
fi

# ── scenario 3: GREEN fixture, auto-generated seeds -> positive control ───────────
OUT3="$T/out3.log"
"$SWEEP" --app "$GREEN" --seeds 5 > "$OUT3" 2>&1
rc3=$?

if [[ $rc3 -eq 0 ]]; then
  ok "scenario 3 (positive control): GREEN fixture exits 0 under 5 auto-generated seeds"
else
  bad "scenario 3 (positive control): GREEN fixture should exit 0, got $rc3"
fi
if grep -q "SEED-SWEEP: PROCESSED 5 of 5" "$OUT3" && grep -q "SEED-SWEEP: ALL PASSED (5 seeds)" "$OUT3"; then
  ok "scenario 3: reports PROCESSED 5 of 5 and ALL PASSED"
else
  bad "scenario 3: missing PROCESSED 5 of 5 / ALL PASSED lines"
fi

# ── scenario 4: --file narrows to one file and still names the failing seed ───────
OUT4="$T/out4.log"
"$SWEEP" --app "$MIXED" --file "test/seed_determined_test.exs" --seed-list "7" > "$OUT4" 2>&1
rc4=$?

if [[ $rc4 -ne 0 ]]; then
  ok "scenario 4: --file targeted run on odd seed exits non-zero"
else
  bad "scenario 4: --file targeted run on odd seed should exit non-zero, got 0"
fi
if grep -q "SEED-SWEEP: seed 7 FAILED" "$OUT4" && grep -q "SEED-SWEEP: PROCESSED 1 of 1" "$OUT4"; then
  ok "scenario 4: names seed 7 as FAILED and reports PROCESSED 1 of 1"
else
  bad "scenario 4: missing seed-7 FAILED / PROCESSED 1 of 1 lines"
fi

echo ""
echo "SEED-SWEEP SELF-TEST: $pass_count passed, $fail_count failed"
if [[ $fail_count -gt 0 ]]; then
  exit 1
fi
exit 0
