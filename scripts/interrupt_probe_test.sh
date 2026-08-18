#!/usr/bin/env bash
# T107 — interrupt-proof harness for the gen_app-probe registry guard.
#
# Proves the fix for the recurring Phase-2 failure (T27, T28, T23): killing a gen_app
# probe mid-run (which mutates samen_core/priv/abbrev_registry.json to reserve the
# scratch app's abbrevs) used to leave the registry corrupted, requiring a manual
# `git checkout` to recover. scripts/gen_probe_guard.sh (sourced by both root ci.sh and
# this harness — same code, not a reimplementation) now snapshots the registry to a
# `mktemp`'d file before each probe and restores + SHA-256-verifies it in a trap covering
# SIGINT/SIGTERM/ERR/EXIT.
#
# Because this environment has no working process-group job control (`set -m` fails: "can't
# change option: -m"), the harness locates the REAL target process directly — it walks the
# process tree from the launcher's PID down to the `beam.smp` (BEAM VM) descendant the
# `mix run` chain execs into, and signals THAT PID specifically. This is deliberately
# surgical: it never touches any other process on the machine, only the one descendant
# chain this harness itself launched.
#
# WRAPPED (positive) case: launches `run_gen_probe` (from gen_probe_guard.sh — the exact
# code root ci.sh runs) in a background `bash -c`, polls the registry's SHA-256 until it
# diverges from pristine (the mutation window is open), sends the requested signal
# directly to the beam.smp descendant, and asserts the registry is restored byte-exact
# with zero scratch/snapshot residue.
#
# UNWRAPPED (negative control) case: launches the SAME probe with the raw pre-T107
# invocation shape (`mix run priv/gen_post_probe.exs`, no snapshot, no trap,
# SAMEN_T107_DISABLE_INNER_TRAP=1 to also disable the probe's own inner SIGTERM
# defense-in-depth) — i.e. exactly what ci.sh did before this task. Killing it mid-
# mutation MUST leave the registry corrupted. This is the anti-tautology proof: it shows
# the positive assertions above are not vacuous — they depend on gen_probe_guard.sh
# actually being wired in, and reproduce the real T27/T28/T23 failure when it isn't.
#
# Usage: scripts/interrupt_probe_test.sh
# Exit:  0 if all positive assertions pass AND the negative control shows real corruption;
#        non-zero + a FAIL line otherwise. Never leaves the repo dirty (registry is always
#        restored from an out-of-band backup before the script exits).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGISTRY="$REPO_ROOT/samen_core/priv/abbrev_registry.json"
PROBE_REL="priv/gen_post_probe.exs"
SCRATCH_PATTERN="$REPO_ROOT/_gen_post_scratch*"
SNAP_PATTERN="${TMPDIR:-/tmp}/samen_ci_registry_snapshot.*"
MUTATION_TIMEOUT_S=30

OUTER_BACKUP="$(mktemp "${TMPDIR:-/tmp}/t107_harness_outer_backup.XXXXXX")"
cp "$REGISTRY" "$OUTER_BACKUP"
PRISTINE_SHA="$(shasum -a 256 "$REGISTRY" | awk '{print $1}')"

pass_count=0
fail_count=0

note() { echo "== $* =="; }
ok() { echo "PASS: $*"; pass_count=$((pass_count + 1)); }
bad() { echo "FAIL: $*"; fail_count=$((fail_count + 1)); }

cleanup_residue() {
  rm -rf $SCRATCH_PATTERN 2>/dev/null || true
  rm -f $SNAP_PATTERN 2>/dev/null || true
}

restore_outer_backup() {
  cp "$OUTER_BACKUP" "$REGISTRY"
}

# find_beam_descendant <root-pid>: walks the process tree from <root-pid> down (following
# the first child at each level — this launcher's chain is strictly linear: bash -c ->
# [subshell ->] mix -> elixir -> erl -> beam.smp) looking for the beam.smp VM process.
# Prints its PID and returns 0, or returns 1 if not found within 6 hops.
find_beam_descendant() {
  local pid="$1"
  local hop
  for hop in 1 2 3 4 5 6; do
    local cmd
    cmd="$(ps -o command= -p "$pid" 2>/dev/null)"
    if [[ "$cmd" == *beam.smp* ]]; then
      echo "$pid"
      return 0
    fi
    local kids
    kids="$(pgrep -P "$pid" 2>/dev/null)"
    if [[ -z "$kids" ]]; then
      return 1
    fi
    pid="$(echo "$kids" | head -1)"
  done
  return 1
}

# wait_for_mutation <launcher-pid>: polls the registry's SHA-256 until it diverges from
# pristine (up to MUTATION_TIMEOUT_S), or fails if the launcher exits first.
wait_for_mutation() {
  local launcher_pid="$1"
  local waited_ms=0
  while :; do
    if ! kill -0 "$launcher_pid" 2>/dev/null; then
      return 1
    fi
    local cur_sha
    cur_sha="$(shasum -a 256 "$REGISTRY" | awk '{print $1}')"
    if [[ "$cur_sha" != "$PRISTINE_SHA" ]]; then
      echo "  (mutation window open after ~${waited_ms}ms — registry sha now $cur_sha)"
      return 0
    fi
    sleep 0.05
    waited_ms=$((waited_ms + 50))
    if [[ "$waited_ms" -gt $((MUTATION_TIMEOUT_S * 1000)) ]]; then
      return 1
    fi
  done
}

LAST_FINAL_SHA=""
LAST_RESIDUE=""

# run_wrapped_and_kill <signal>: the POSITIVE case — via scripts/gen_probe_guard.sh's
# run_gen_probe, exactly as root ci.sh invokes it.
run_wrapped_and_kill() {
  local signal="$1"
  restore_outer_backup
  cleanup_residue

  bash -c "REPO_ROOT='$REPO_ROOT'; source '$REPO_ROOT/scripts/gen_probe_guard.sh'; run_gen_probe '$PROBE_REL' 'T107 interrupt harness (wrapped)'" &
  local launcher_pid=$!

  if ! wait_for_mutation "$launcher_pid"; then
    bad "$signal (wrapped): registry never mutated within ${MUTATION_TIMEOUT_S}s, or the launcher exited early"
    wait "$launcher_pid" 2>/dev/null
    return 1
  fi

  local beam_pid
  beam_pid="$(find_beam_descendant "$launcher_pid")"
  if [[ -z "$beam_pid" ]]; then
    bad "$signal (wrapped): could not locate the beam.smp descendant to signal"
    kill -SIGKILL "$launcher_pid" 2>/dev/null || true
    wait "$launcher_pid" 2>/dev/null
    return 1
  fi

  echo "  (signaling beam.smp pid=$beam_pid with $signal)"
  kill -s "$signal" "$beam_pid"
  wait "$launcher_pid" 2>/dev/null
  echo "  (launcher exited)"

  LAST_FINAL_SHA="$(shasum -a 256 "$REGISTRY" | awk '{print $1}')"
  LAST_RESIDUE="$(ls -d $SCRATCH_PATTERN 2>/dev/null; ls $SNAP_PATTERN 2>/dev/null)"
}

# run_unwrapped_and_kill <signal>: the NEGATIVE CONTROL — the raw pre-T107 invocation
# shape (no snapshot, no outer trap, inner SIGTERM defense-in-depth also disabled via
# SAMEN_T107_DISABLE_INNER_TRAP=1) — proves killing mid-mutation WITHOUT the T107 guard
# really does corrupt the registry (anti-tautology for the positive results above).
run_unwrapped_and_kill() {
  local signal="$1"
  restore_outer_backup
  cleanup_residue

  bash -c "cd '$REPO_ROOT/samen_core' && SAMEN_T107_DISABLE_INNER_TRAP=1 mix run '$PROBE_REL'" &
  local launcher_pid=$!

  if ! wait_for_mutation "$launcher_pid"; then
    bad "$signal (unwrapped negative control): registry never mutated within ${MUTATION_TIMEOUT_S}s, or the launcher exited early"
    wait "$launcher_pid" 2>/dev/null
    return 1
  fi

  local beam_pid
  beam_pid="$(find_beam_descendant "$launcher_pid")"
  if [[ -z "$beam_pid" ]]; then
    bad "$signal (unwrapped negative control): could not locate the beam.smp descendant to signal"
    kill -SIGKILL "$launcher_pid" 2>/dev/null || true
    wait "$launcher_pid" 2>/dev/null
    return 1
  fi

  echo "  (signaling beam.smp pid=$beam_pid with $signal)"
  kill -s "$signal" "$beam_pid"
  wait "$launcher_pid" 2>/dev/null
  echo "  (launcher exited)"

  LAST_FINAL_SHA="$(shasum -a 256 "$REGISTRY" | awk '{print $1}')"
  LAST_RESIDUE="$(ls -d $SCRATCH_PATTERN 2>/dev/null; ls $SNAP_PATTERN 2>/dev/null)"
}

# --- 1/2. Positive proof: SIGINT then SIGTERM, T107 guard ENABLED ----------------------
for sig in SIGINT SIGTERM; do
  note "Positive test: kill mid-mutation with $sig (T107 guard ENABLED — run_gen_probe)"
  run_wrapped_and_kill "$sig"
  if [[ "$LAST_FINAL_SHA" == "$PRISTINE_SHA" ]]; then
    ok "$sig (wrapped): registry restored SHA-256 byte-exact ($LAST_FINAL_SHA)"
  else
    bad "$sig (wrapped): registry NOT byte-exact (pristine=$PRISTINE_SHA final=$LAST_FINAL_SHA)"
  fi
  if [[ -z "$LAST_RESIDUE" ]]; then
    ok "$sig (wrapped): zero scratch/snapshot residue"
  else
    bad "$sig (wrapped): residue left behind: $LAST_RESIDUE"
  fi
  if git -C "$REPO_ROOT" diff --stat -- samen_core/priv/abbrev_registry.json | grep -q .; then
    bad "$sig (wrapped): git diff shows a residual change to abbrev_registry.json"
  else
    ok "$sig (wrapped): git diff confirms no residual change to abbrev_registry.json"
  fi
done

# --- 3/4. Anti-tautology negative control: SIGINT then SIGTERM, guard DISABLED ---------
for sig in SIGINT SIGTERM; do
  note "Negative control: kill mid-mutation with $sig (T107 guard ABSENT — raw pre-T107 invocation)"
  run_unwrapped_and_kill "$sig"
  if [[ "$LAST_FINAL_SHA" != "$PRISTINE_SHA" ]]; then
    ok "$sig (unwrapped): registry IS corrupted without the guard (pristine=$PRISTINE_SHA final=$LAST_FINAL_SHA) — proves the positive results above are not a tautology"
  else
    bad "$sig (unwrapped): registry was unexpectedly still byte-exact without the guard — the positive proof above would be vacuous"
  fi
done

# Always leave the repo clean, regardless of how the negative control landed.
restore_outer_backup
cleanup_residue
rm -f "$OUTER_BACKUP"
final_check_sha="$(shasum -a 256 "$REGISTRY" | awk '{print $1}')"
if [[ "$final_check_sha" == "$PRISTINE_SHA" ]]; then
  echo "== harness teardown: registry confirmed byte-exact, residue swept =="
else
  echo "== harness teardown FATAL: could not restore registry after the negative control — MANUAL RECHECK REQUIRED ==" >&2
  exit 2
fi

echo ""
echo "== T107 interrupt-proof harness: $pass_count passed, $fail_count failed =="
if [[ "$fail_count" -gt 0 ]]; then
  exit 1
fi
exit 0
