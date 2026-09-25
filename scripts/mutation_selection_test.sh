#!/usr/bin/env bash
# scripts/mutation_selection_test.sh — the MUTATION GATE'S OWN anti-tautology
# harness (ADR-049 §6). Fast (seconds), needs NO database, applies no real mutant:
# every assertion drives scripts/mutate.sh against a throwaway probe module with a
# STUB test runner ($SAMEN_MUTATION_RUNNER), so the thing under test is the gate's
# SCORING LOGIC, not any real suite.
#
# WHY THIS EXISTS. A mutation gate is a machine that reports a percentage, and the
# failure mode of such a machine is not a crash — it is a confident, wrong number.
# Three ways it can lie, each of which has a negative control below:
#
#   · score everything as KILLED (e.g. count a non-zero exit as a kill). A gate
#     that cannot report a survivor reports 100% forever. → assertion 5.
#   · score a COMPILE BREAKAGE as a kill. The mutant never reached a test, so the
#     suite earned nothing, but the arithmetic looks identical. → assertion 6.
#   · score mutants against a RED baseline. Every mutant "fails" a suite that was
#     already failing, so the gate reports 100% over a broken suite. → assertion 7.
#
# Plus the ledger: it is the one lever that can turn a red gate green, so its
# guards get controls too — a stale content hash (9), a missing `ref=` (10), a
# too-short reason (11), and an exemption that outlived its gap (12).
#
# ASSERTIONS
#   1  the engine enumerates the probe's known sites (EQ/REL/BOOLOP/BOOLLIT)
#   2  the engine REFUSES a stale site (token mismatch) and leaves the file alone
#   3  apply is an exact splice — mutate then mutate back is byte-identical
#   4  POSITIVE: a runner that fails with a NAMED test header → all KILLED, gate passes
#   5  NEGATIVE CONTROL: a runner that always passes → all SURVIVED, gate FAILS
#   6  NEGATIVE CONTROL: a failure with NO test header → BUILD-REFUSED, zero kills
#   7  NEGATIVE CONTROL: a RED baseline → gate FAILS before scoring anything
#   8  a matching ledger entry turns a survivor into a disclosed exemption
#   9  NEGATIVE CONTROL: a ledger entry whose line hash is stale → lint FAILS
#  10  NEGATIVE CONTROL: ACCEPTED_GAP with no ref= → lint FAILS
#  11  NEGATIVE CONTROL: a reason too short to be a reason → lint FAILS
#  12  NEGATIVE CONTROL: an exemption whose mutant is now KILLED → gate FAILS obsolete
#  13  lint refuses a target with ZERO mutation sites (certifies nothing)
#  14  lint refuses a missing owning test file (the gate's quietest failure mode)
#  15  --shard partitions the mutant list EXACTLY: shards are disjoint and their
#      union is the whole selection (no mutant run twice, none skipped)
#  16  --changed sees an UNTRACKED probe (the sabotage --changed miss, not repeated)
#  17  owning-test derivation (issue #20), over throwaway probe TEST files:
#      a) POSITIVE: a test naming the probe through `alias Samen, as: S` +
#         `S.MutationProbe` is derived AND handed to the runner — listed-but-not-run
#         would be a false fix; a second probe test does the same through a
#         multi-alias (`alias Samen.{MutationProbe}`), each form on its own
#      b) NEGATIVE CONTROL: a test naming only a SUBMODULE of the probe, with the
#         probe's name in a string, is NOT derived (exact names, not substrings)
#      c) POSITIVE: `# MUTATION_OWNS: <probe>` derives a test that never names it
#      d) NEGATIVE CONTROL: lint refuses a MUTATION_OWNS naming a missing file,
#         and one outside a *_test.exs file (the gate never reads it there)
#      (With NO test deriving, the declared rows must survive untouched — that is
#      what 4-16 already exercise, since they run before any probe test exists.)
#  18  zero residue: every probe file removed, the tree as we found it
#
# Usage: scripts/mutation_selection_test.sh
# Exit:  0 if every assertion passes; non-zero + FAIL lines otherwise.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MUTATE="$REPO_ROOT/scripts/mutate.sh"
LINT="$REPO_ROOT/scripts/mutation_lint.sh"
ENGINE="$REPO_ROOT/scripts/mutation/mutate.exs"

PROBE_REL="samen_core/lib/samen/__mutation_probe.ex"
PROBE="$REPO_ROOT/$PROBE_REL"
EMPTY_REL="samen_core/lib/samen/__mutation_probe_empty.ex"
EMPTY="$REPO_ROOT/$EMPTY_REL"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/samen_mutation_selftest.XXXXXX")"

pass_count=0
fail_count=0
ok()  { echo "PASS: $*"; pass_count=$((pass_count + 1)); }
bad() { echo "FAIL: $*"; fail_count=$((fail_count + 1)); }

REF_TEST_REL="test/__mutation_probe_ref_test.exs"
MULTI_TEST_REL="test/__mutation_probe_multi_test.exs"
SUB_TEST_REL="test/__mutation_probe_sub_test.exs"
OWNS_TEST_REL="test/__mutation_probe_owns_test.exs"
BADOWNS_TEST_REL="test/__mutation_probe_badowns_test.exs"
DEADOWNS_REL="test/__mutation_probe_deadowns.exs"
PROBE_TESTS=("$REPO_ROOT/samen_core/$REF_TEST_REL" "$REPO_ROOT/samen_core/$MULTI_TEST_REL"
             "$REPO_ROOT/samen_core/$SUB_TEST_REL"
             "$REPO_ROOT/samen_core/$OWNS_TEST_REL" "$REPO_ROOT/samen_core/$BADOWNS_TEST_REL"
             "$REPO_ROOT/samen_core/$DEADOWNS_REL")

cleanup() { rm -f "$PROBE" "$EMPTY" "${PROBE_TESTS[@]}"; rm -rf "$SCRATCH"; }
trap cleanup EXIT INT TERM

# ── the probe module: five sites, one per operator family plus a second REL ────
write_probe() {
  cat > "$PROBE" <<'PROBE'
defmodule Samen.MutationProbe do
  @moduledoc false
  # Scratch fixture for scripts/mutation_selection_test.sh. Never compiled by a real
  # run — created and deleted inside that script. Five mutation sites, deliberately
  # one per operator family so the engine's coverage is asserted, not assumed.
  def eq?(x), do: x == 1
  def rel?(x, y), do: x > 0 and y < 10
  def lit?, do: true
end
PROBE
}
write_probe
PROBE_SHA_BEFORE="$(shasum -a 256 "$PROBE" | cut -d' ' -f1)"

# The owning test file is a REAL one so the lint's existence checks pass; it is
# never executed, because every run below overrides the runner with a stub.
TARGETS="$SCRATCH/targets.tsv"
printf '%s\tsamen_core\ttest/files_upload_test.exs\n' "$PROBE_REL" > "$TARGETS"
EMPTY_LEDGER="$SCRATCH/ledger.empty.tsv"
printf '# no exemptions\n' > "$EMPTY_LEDGER"

# ── stub runners ──────────────────────────────────────────────────────────────
# A kill = non-zero exit WITH a `N) test ...` header, exactly what ExUnit prints.
R_KILL='if [ "$MUT_PHASE" = baseline ]; then exit 0; else echo "  1) test the probe guard is pinned (Samen.MutationProbeTest)"; exit 1; fi'
R_SURVIVE='exit 0'
R_NO_HEADER='if [ "$MUT_PHASE" = baseline ]; then exit 0; else echo "** (CompileError) lib/x.ex:1: undefined function"; exit 1; fi'
R_RED_BASELINE='if [ "$MUT_PHASE" = baseline ]; then echo "  1) test something unrelated was already broken (Samen.SomeTest)"; exit 1; else exit 0; fi'

run_gate() { # run_gate <runner> [extra args...] -> prints output, returns exit
  local runner="$1"; shift
  SAMEN_MUTATION_RUNNER="$runner" bash "$MUTATE" --targets "$TARGETS" --ledger "$EMPTY_LEDGER" "$@" 2>&1
}

echo "== 1-3: the engine (pure; no runner, no gate) =="

sites="$(cd "$REPO_ROOT" && elixir "$ENGINE" list "$PROBE_REL")"
for fam in EQ REL BOOLOP BOOLLIT; do
  if grep -q "	$fam	" <<<"$sites"; then
    ok "engine enumerates a $fam site in the probe"
  else
    echo "$sites"
    bad "engine found no $fam site in the probe — that operator family regressed"
  fi
done
site_n="$(grep -c '' <<<"$sites")"
if [[ "$site_n" -eq 5 ]]; then
  ok "engine enumerates EXACTLY the probe's 5 sites (no phantom sites, none missed)"
else
  echo "$sites"
  bad "engine found $site_n sites in the probe, expected 5"
fi

# 2. A stale site (right file, wrong token at that column) must be REFUSED, not
#    spliced blindly — otherwise a moved line silently corrupts a source file.
if (cd "$REPO_ROOT" && elixir "$ENGINE" apply "$PROBE_REL" 5 1 '==' '!=') >/dev/null 2>&1; then
  bad "engine applied a mutant at a column that does not hold '==' — a stale site can corrupt a file"
else
  ok "NEGATIVE CONTROL: engine REFUSES to splice where the expected token is not present"
fi
if [[ "$(shasum -a 256 "$PROBE" | cut -d' ' -f1)" == "$PROBE_SHA_BEFORE" ]]; then
  ok "a refused apply left the file byte-identical"
else
  bad "a refused apply MODIFIED the file"
fi

# 3. The splice is exact: mutate, then mutate back, and the bytes must return.
eq_line="$(awk -F'\t' '$4 == "EQ" { print $2; exit }' <<<"$sites")"
eq_col="$(awk -F'\t' '$4 == "EQ" { print $3; exit }' <<<"$sites")"
(cd "$REPO_ROOT" && elixir "$ENGINE" apply "$PROBE_REL" "$eq_line" "$eq_col" '==' '!=') >/dev/null 2>&1
if [[ "$(shasum -a 256 "$PROBE" | cut -d' ' -f1)" != "$PROBE_SHA_BEFORE" ]]; then
  ok "apply actually changed the file (the splice is not a no-op)"
else
  bad "apply did not change the file — every 'kill' downstream would be meaningless"
fi
(cd "$REPO_ROOT" && elixir "$ENGINE" apply "$PROBE_REL" "$eq_line" "$eq_col" '!=' '==') >/dev/null 2>&1
if [[ "$(shasum -a 256 "$PROBE" | cut -d' ' -f1)" == "$PROBE_SHA_BEFORE" ]]; then
  ok "apply is an EXACT splice — mutate then mutate back is byte-identical (SHA-256)"
else
  bad "mutate-then-unmutate did not restore the bytes — the splice is lossy"
fi

echo ""
echo "== 4-7: the gate's scoring logic, and the three ways it could lie =="

out="$(run_gate "$R_KILL")"; st=$?
if [[ $st -eq 0 ]] && grep -q "MUTATION GATE: ALL PASSED" <<<"$out"; then
  ok "POSITIVE: a runner that fails with a NAMED test header scores every mutant KILLED and the gate passes"
else
  echo "$out"
  bad "the gate did not pass when every mutant was killed (exit $st)"
fi
if grep -qE "killed +: 5" <<<"$out"; then
  ok "the report counts all 5 mutants as killed"
else
  echo "$out"
  bad "the report did not count 5 kills"
fi

out="$(run_gate "$R_SURVIVE")"; st=$?
if [[ $st -ne 0 ]] && grep -q "MUTATION GATE: FAILED" <<<"$out" && grep -q "SURVIVED (UNEXEMPT)" <<<"$out"; then
  ok "NEGATIVE CONTROL: a runner that always PASSES makes every mutant SURVIVE and the gate FAILS (it can report a survivor)"
else
  echo "$out"
  bad "the gate did NOT fail when no mutant was killed — it cannot report a survivor, so its 100% means nothing"
fi

out="$(run_gate "$R_NO_HEADER")"; st=$?
if grep -q "BUILD-REFUSED" <<<"$out" && grep -qE "killed +: 0" <<<"$out"; then
  ok "NEGATIVE CONTROL: a non-zero exit with NO test header is BUILD-REFUSED, not a kill (contract 2)"
else
  echo "$out"
  bad "a compile failure was scored as a kill — the gate credits the suite for the compiler's work"
fi

out="$(run_gate "$R_RED_BASELINE")"; st=$?
if [[ $st -ne 0 ]] && grep -q "owning suite is RED before any mutation" <<<"$out"; then
  ok "NEGATIVE CONTROL: a RED baseline FAILS the gate before any mutant is scored (contract 1)"
else
  echo "$out"
  bad "the gate scored mutants against a RED baseline — every mutant would 'die' against an already-failing suite"
fi
if grep -q "killed" <<<"$out" && grep -q "mutation score" <<<"$out"; then
  bad "the gate printed a mutation score for a run it aborted on a red baseline"
else
  ok "no score is printed for a run aborted on a red baseline (no misleading number)"
fi

echo ""
echo "== 8-12: the ledger — the only lever that turns a red gate green =="

# A ledger covering all five sites, keyed exactly as the engine reports them.
LEDGER_OK="$SCRATCH/ledger.ok.tsv"
: > "$LEDGER_OK"
while IFS=$'\t' read -r f line col family from to lsha; do
  printf '%s\t%s\t%s\t%s\t%s>%s\tEQUIVALENT\tprobe fixture exemption for the self-test; no behaviour to change\n' \
    "$f" "$lsha" "$col" "$family" "$from" "$to" >> "$LEDGER_OK"
done <<<"$sites"

out="$(SAMEN_MUTATION_RUNNER="$R_SURVIVE" bash "$MUTATE" --targets "$TARGETS" --ledger "$LEDGER_OK" 2>&1)"; st=$?
if [[ $st -eq 0 ]] && grep -q "ledger-exempt" <<<"$out" && grep -q "SURVIVED (ledger-exempt" <<<"$out"; then
  ok "a MATCHING ledger entry turns a survivor into a DISCLOSED exemption and the gate passes"
else
  echo "$out"
  bad "a matching ledger entry did not exempt its survivor (exit $st)"
fi
if grep -qE "survived \(unexempt\): 0" <<<"$out"; then
  ok "the exempted survivors are counted separately from unexempt ones (the report cannot hide them)"
else
  echo "$out"
  bad "exempt and unexempt survivors are not counted separately"
fi

# 9. STALE: same key, wrong line hash. This is the anti-rot property — an exemption
#    must not survive an edit to the line it excuses.
LEDGER_STALE="$SCRATCH/ledger.stale.tsv"
sed 's/\t[0-9a-f]\{12\}\t/\tdeadbeefcafe\t/' "$LEDGER_OK" > "$LEDGER_STALE"
if bash "$LINT" --targets "$TARGETS" --ledger "$LEDGER_STALE" >"$SCRATCH/stale.out" 2>&1; then
  cat "$SCRATCH/stale.out"
  bad "lint ACCEPTED a ledger entry whose line hash matches no live site — exemptions could outlive their code"
else
  if grep -q "STALE" "$SCRATCH/stale.out"; then
    ok "NEGATIVE CONTROL: lint refuses a STALE ledger entry by name (content-pinned, not line-pinned)"
  else
    cat "$SCRATCH/stale.out"
    bad "lint failed on the stale ledger but not for staleness"
  fi
fi

# 10. ACCEPTED_GAP with no ref=.
LEDGER_NOREF="$SCRATCH/ledger.noref.tsv"
sed 's/\tEQUIVALENT\t/\tACCEPTED_GAP\t/' "$LEDGER_OK" > "$LEDGER_NOREF"
if bash "$LINT" --targets "$TARGETS" --ledger "$LEDGER_NOREF" >"$SCRATCH/noref.out" 2>&1; then
  bad "lint ACCEPTED an ACCEPTED_GAP with no ref= — a deferred hole with no owner is a forgotten hole"
else
  grep -q "no 'ref='" "$SCRATCH/noref.out" \
    && ok "NEGATIVE CONTROL: lint refuses an ACCEPTED_GAP that names no owning ADR/backlog item" \
    || { cat "$SCRATCH/noref.out"; bad "lint failed but not for the missing ref="; }
fi

# 11. A reason that is not a reason.
LEDGER_SHORT="$SCRATCH/ledger.short.tsv"
awk -F'\t' 'BEGIN{OFS="\t"} { $7 = "n/a"; print }' "$LEDGER_OK" > "$LEDGER_SHORT"
if bash "$LINT" --targets "$TARGETS" --ledger "$LEDGER_SHORT" >"$SCRATCH/short.out" 2>&1; then
  bad "lint ACCEPTED 'n/a' as an exemption reason"
else
  grep -q "real justification" "$SCRATCH/short.out" \
    && ok "NEGATIVE CONTROL: lint refuses a reason too short to be a justification" \
    || { cat "$SCRATCH/short.out"; bad "lint failed but not for the empty reason"; }
fi

# 12. OBSOLETE: the mutant is killed now, so the exemption is dead weight.
out="$(SAMEN_MUTATION_RUNNER="$R_KILL" bash "$MUTATE" --targets "$TARGETS" --ledger "$LEDGER_OK" 2>&1)"; st=$?
if [[ $st -ne 0 ]] && grep -q "OBSOLETE ledger entries" <<<"$out"; then
  ok "NEGATIVE CONTROL: an exemption whose mutant is now KILLED FAILS the gate as obsolete (the ledger cannot become a blindfold)"
else
  echo "$out"
  bad "an obsolete exemption was accepted silently (exit $st)"
fi

echo ""
echo "== 13-14: lint refuses watch-list rows that would certify nothing =="

cat > "$EMPTY" <<'EMPTYMOD'
defmodule Samen.MutationProbeEmpty do
  @moduledoc false
  @doc false
  def passthrough(x), do: x
end
EMPTYMOD
TARGETS_EMPTY="$SCRATCH/targets.empty.tsv"
printf '%s\tsamen_core\ttest/files_upload_test.exs\n' "$EMPTY_REL" > "$TARGETS_EMPTY"
if bash "$LINT" --targets "$TARGETS_EMPTY" --ledger "$EMPTY_LEDGER" >"$SCRATCH/zero.out" 2>&1; then
  bad "lint ACCEPTED a target with ZERO mutation sites — it would inflate the target count while proving nothing"
else
  grep -q "ZERO mutation sites" "$SCRATCH/zero.out" \
    && ok "NEGATIVE CONTROL: lint refuses a target with zero mutation sites" \
    || { cat "$SCRATCH/zero.out"; bad "lint failed but not for the zero-site target"; }
fi

TARGETS_MISSING="$SCRATCH/targets.missing.tsv"
printf '%s\tsamen_core\ttest/__no_such_test_file_test.exs\n' "$PROBE_REL" > "$TARGETS_MISSING"
if bash "$LINT" --targets "$TARGETS_MISSING" --ledger "$EMPTY_LEDGER" >"$SCRATCH/missing.out" 2>&1; then
  bad "lint ACCEPTED a target whose owning test file does not exist"
else
  grep -q "owning test file does not exist" "$SCRATCH/missing.out" \
    && ok "NEGATIVE CONTROL: lint refuses a missing owning test file by name" \
    || { cat "$SCRATCH/missing.out"; bad "lint failed but not for the missing owning test"; }
fi

echo ""
echo "== 15-16: selection (--list only — nothing applied, nothing run) =="

# Extract one stable identifier per listed mutant: `<line>:<col> <FAMILY> <from> -> <to>`.
# (The relpath is column-padded in the listing, so match on the mutant tail instead.)
mutant_ids() { grep -oE '[0-9]+:[0-9]+ +[A-Z]+ +[^ ]+ -> [^ ]+'; }

full="$(bash "$MUTATE" --targets "$TARGETS" --ledger "$EMPTY_LEDGER" --list 2>&1 | mutant_ids | sort)"
full_n="$(grep -c '' <<<"$full")"
if [[ "$full_n" -eq 5 ]]; then
  ok "the partition assertions below run over all 5 probe mutants (not a 1-element near-tautology)"
else
  bad "expected 5 listed mutants to partition, got $full_n — the shard assertions would be near-vacuous"
fi
shard_all=""
for i in 1 2 3; do
  shard_all+="$(bash "$MUTATE" --targets "$TARGETS" --ledger "$EMPTY_LEDGER" --shard "$i/3" --list 2>&1 | mutant_ids)"$'\n'
done
shard_sorted="$(grep -v '^$' <<<"$shard_all" | sort)"
shard_n="$(grep -c '' <<<"$shard_sorted")"
if [[ "$shard_n" -eq "$full_n" ]] && [[ "$shard_sorted" == "$full" ]]; then
  ok "--shard partitions EXACTLY: the 3 shards' union is the full $full_n-mutant selection"
else
  bad "--shard is not a partition: union has $shard_n mutants vs $full_n in the full selection"
fi
if [[ "$(sort -u <<<"$shard_sorted" | grep -c '')" -eq "$shard_n" ]]; then
  ok "--shard shards are DISJOINT (no mutant is run twice across a sharded sweep)"
else
  bad "--shard shards overlap — a sharded sweep would double-run some mutants and could still miss others"
fi

# 16. The probe file is UNTRACKED (never git add-ed), exactly like a brand-new
#     guard module mid-batch; --changed must still select its mutants.
if (cd "$REPO_ROOT" && git ls-files --others --exclude-standard) | grep -qxF "$PROBE_REL"; then
  ok "precondition: the probe target is UNTRACKED (git diff alone cannot see it)"
else
  bad "precondition broken: the probe target is tracked — assertion 16 would be vacuous"
fi
changed="$(bash "$MUTATE" --targets "$TARGETS" --ledger "$EMPTY_LEDGER" --changed HEAD --list 2>&1)"
if grep -qF "$PROBE_REL" <<<"$changed" && grep -qF "changed=HEAD+untracked" <<<"$changed"; then
  ok "--changed selects an UNTRACKED target's mutants and the banner discloses the union"
else
  echo "$changed"
  bad "--changed missed an untracked target — the same under-selection that bit the sabotage harness"
fi

echo ""
echo "== 17: owning-test derivation (issue #20) =="

# Probe TEST files. Plain modules, not ExUnit cases: they exist only for the
# engine to parse and are deleted by cleanup on every exit path.
cat > "$REPO_ROOT/samen_core/$REF_TEST_REL" <<'T'
defmodule Samen.MutationProbeRefTest do
  @moduledoc false
  alias Samen, as: S
  def ref, do: S.MutationProbe.eq?(1)
end
T
cat > "$REPO_ROOT/samen_core/$MULTI_TEST_REL" <<'T'
defmodule Samen.MutationProbeMultiTest do
  @moduledoc false
  alias Samen.{MutationProbe}
  def ref, do: MutationProbe.eq?(1)
end
T
cat > "$REPO_ROOT/samen_core/$SUB_TEST_REL" <<'T'
defmodule Samen.MutationProbeSubTest do
  @moduledoc false
  def ref, do: {Samen.MutationProbe.Inner, "Samen.MutationProbe"}
end
T
cat > "$REPO_ROOT/samen_core/$OWNS_TEST_REL" <<T
# MUTATION_OWNS: $PROBE_REL
defmodule Samen.MutationProbeOwnsTest do
  @moduledoc false
end
T

owners="$(cd "$REPO_ROOT" && elixir "$ENGINE" owners samen_core "$PROBE_REL" 2>&1)"

# a) derived AND run: the stub runner records exactly what it was handed.
R_RECORD='echo "$MUT_TEST_FILES" >> "$MUT_RECORD"; if [ "$MUT_PHASE" = baseline ]; then exit 0; else echo "  1) test the probe guard is pinned (Samen.MutationProbeTest)"; exit 1; fi'
export MUT_RECORD="$SCRATCH/handed.txt"; : > "$MUT_RECORD"
run_gate "$R_RECORD" --family EQ >"$SCRATCH/derive.out"; st=$?
if grep -qxF "$PROBE_REL	$REF_TEST_REL" <<<"$owners" \
   && [[ $st -eq 0 ]] && grep -qF "$REF_TEST_REL" "$MUT_RECORD" \
   && grep -qF "test/files_upload_test.exs" "$MUT_RECORD"; then
  ok "a test naming the probe through an as:-alias is DERIVED and HANDED to the runner, alongside the declared owner"
else
  echo "$owners"; cat "$SCRATCH/derive.out"; cat "$MUT_RECORD"
  bad "back-reference derivation missed a test that names the probe through an as:-alias (or the gate listed it but never ran it)"
fi
if grep -qxF "$PROBE_REL	$MULTI_TEST_REL" <<<"$owners"; then
  ok "a test naming the probe through a multi-alias is DERIVED"
else
  echo "$owners"
  bad "back-reference derivation missed a test that names the probe through a multi-alias"
fi

# b) a submodule is not its parent; a string is not a reference.
if grep -qF "$SUB_TEST_REL" <<<"$owners"; then
  bad "a test naming only Samen.MutationProbe.Inner (and the probe's name in a STRING) was derived — substring matching would make a parent module owned by every child's tests"
else
  ok "NEGATIVE CONTROL: a submodule reference / string mention is NOT derived as ownership"
fi

# c) the co-located declaration, for proofs that drive a guard through a resource.
if grep -qxF "$PROBE_REL	$OWNS_TEST_REL" <<<"$owners"; then
  ok "a MUTATION_OWNS declaration derives a test that never names the module in code"
else
  echo "$owners"
  bad "MUTATION_OWNS did not derive its test — resource-driven proofs would drop out of the gate again"
fi

# d) a typo'd declaration owns nothing, so the lint must refuse it by name.
cat > "$REPO_ROOT/samen_core/$BADOWNS_TEST_REL" <<'T'
# MUTATION_OWNS: samen_core/lib/samen/__no_such_guard.ex
defmodule Samen.MutationProbeBadOwnsTest do
  @moduledoc false
end
T
if bash "$LINT" --targets "$TARGETS" --ledger "$EMPTY_LEDGER" >"$SCRATCH/badowns.out" 2>&1; then
  bad "lint ACCEPTED a MUTATION_OWNS naming a file that does not exist"
else
  grep -q "MUTATION_OWNS names a file that does not exist: samen_core/lib/samen/__no_such_guard.ex" "$SCRATCH/badowns.out" \
    && ok "NEGATIVE CONTROL: lint refuses a MUTATION_OWNS naming a missing file" \
    || { cat "$SCRATCH/badowns.out"; bad "lint failed but not for the missing MUTATION_OWNS path"; }
fi
rm -f "$REPO_ROOT/samen_core/$BADOWNS_TEST_REL"
# A REAL path, so only the file-name rule can refuse it.
printf '# MUTATION_OWNS: %s\n' "$PROBE_REL" > "$REPO_ROOT/samen_core/$DEADOWNS_REL"
if bash "$LINT" --targets "$TARGETS" --ledger "$EMPTY_LEDGER" >"$SCRATCH/deadowns.out" 2>&1; then
  bad "lint ACCEPTED a MUTATION_OWNS outside a *_test.exs file — a claim the gate never reads"
else
  grep -q "samen_core/$DEADOWNS_REL: MUTATION_OWNS outside a \*_test.exs file" "$SCRATCH/deadowns.out" \
    && ok "NEGATIVE CONTROL: lint refuses a MUTATION_OWNS outside a *_test.exs file" \
    || { cat "$SCRATCH/deadowns.out"; bad "lint failed but not for the non-test MUTATION_OWNS"; }
fi
rm -f "${PROBE_TESTS[@]}"

echo ""
echo "== 18: residue =="
if [[ "$(shasum -a 256 "$PROBE" | cut -d' ' -f1)" == "$PROBE_SHA_BEFORE" ]]; then
  ok "the probe target is byte-identical after every run (no mutant residue)"
else
  bad "the probe target was left MUTATED"
fi
cleanup
residue=0
for f in "$PROBE" "$EMPTY" "${PROBE_TESTS[@]}"; do [[ -e "$f" ]] && residue=1; done
if [[ $residue -eq 1 ]]; then
  bad "scratch residue left behind"
else
  ok "zero residue (both probe modules and every probe test file removed)"
fi

echo ""
echo "mutation-gate self-test: $pass_count passed, $fail_count failed"
[[ $fail_count -eq 0 ]] || { echo "MUTATION SELF-TEST: FAILED"; exit 1; }
echo "MUTATION SELF-TEST: ALL PASSED"
