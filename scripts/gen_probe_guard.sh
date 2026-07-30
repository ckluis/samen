#!/usr/bin/env bash
# T107 — interrupt-safe wrapper for the registry-mutating gen_app probes.
#
# The three root-ci gen_app probes (samen_core/priv/gen_app_flagship_probe.exs,
# gen_post_probe.exs, gen_app_deploy_probe.exs) temporarily mutate the committed
# samen_core/priv/abbrev_registry.json (reserving abbrevs for their scratch app) and
# restore it byte-exact on NORMAL exit at the Elixir level (see each probe's REGISTRY
# SAFETY note) — but that Elixir-level cleanup does NOT run on an OS-level kill
# (SIGINT/SIGTERM): a signal delivered straight to the BEAM process terminates it
# immediately, before any `rescue`/`cleanup.()` runs, and SIGINT specifically cannot even
# be trapped inside the BEAM (`System.trap_signal/3` has no :sigint clause — confirmed by
# hand: `elixir -e 'System.trap_signal(:sigint, :x, fn -> :ok end)'` raises FunctionClauseError;
# only :sigquit/:sigterm/:sigusr1/:sighup/:sigabrt/:sigalrm/:sigusr2/:sigchld/:sigstop/
# :sigtstp are trappable). This recurred 4+ times in Phase 2 (T27, T28, T23) — an
# interrupted probe left the registry corrupted (+45/+48 stray lines), requiring a manual
# `git checkout` to recover.
#
# This wrapper is the AUTHORITATIVE, OS-level backstop, independent of whether the probe
# itself gets a chance to clean up: it snapshots the registry (bytes + SHA-256) to a
# `mktemp`'d scratch file BEFORE invoking the probe, and restores it byte-exact from that
# snapshot in a trap covering SIGINT/SIGTERM/ERR/EXIT — so whether the probe exits
# cleanly, crashes, or is killed outright (by an operator, a tool timeout killing the
# whole ci.sh process tree, or an orphaned-tree scenario), the registry always comes back
# byte-exact, the trap fires exactly once (idempotency guard), and any `_gen_*_scratch*`
# residue (legacy fixed-name dirs or the mktemp'd unique-per-run dirs the probes now
# create) is swept. Restore is ASSERTED SHA-256-equal to the pre-probe snapshot, not
# merely attempted — a mismatch halts loudly (exit 2) rather than silently leaving
# corruption, matching CLAUDE.md's HANDS-OFF invariant.
#
# Sourced by root ci.sh AND by scripts/interrupt_probe_test.sh (the T107 interrupt-proof
# harness) — both exercise this exact same code, not a reimplementation, so a proof
# against the harness is a proof against the real ci.sh path. Requires REPO_ROOT to
# already be set by the sourcing script.

: "${REPO_ROOT:?gen_probe_guard.sh: REPO_ROOT must be set before sourcing}"

GEN_PROBE_REGISTRY="$REPO_ROOT/samen_core/priv/abbrev_registry.json"
GEN_PROBE_SNAP=""
GEN_PROBE_PRISTINE_SHA=""
GEN_PROBE_LABEL=""
GEN_PROBE_RESTORED=1 # 1 = nothing pending (guards double-fire + spurious no-op calls)

gen_probe_restore() {
  if [[ "$GEN_PROBE_RESTORED" == 1 ]]; then
    return 0
  fi
  GEN_PROBE_RESTORED=1

  cp "$GEN_PROBE_SNAP" "$GEN_PROBE_REGISTRY"
  local post_sha
  post_sha="$(shasum -a 256 "$GEN_PROBE_REGISTRY" | awk '{print $1}')"
  rm -f "$GEN_PROBE_SNAP"

  # Sweep scratch residue: legacy fixed-name dirs AND mktemp'd unique-per-run dirs
  # (T107 switched gen_*_probe.exs to `mktemp -d _gen_*_scratch.XXXXXX`).
  rm -rf "$REPO_ROOT"/_gen_flagship_scratch "$REPO_ROOT"/_gen_flagship_scratch.* \
    "$REPO_ROOT"/_gen_post_scratch "$REPO_ROOT"/_gen_post_scratch.* \
    "$REPO_ROOT"/_gen_deploy_scratch "$REPO_ROOT"/_gen_deploy_scratch.*

  if [[ "$post_sha" != "$GEN_PROBE_PRISTINE_SHA" ]]; then
    echo "==> FATAL: ${GEN_PROBE_LABEL:-gen_app probe} could not restore $GEN_PROBE_REGISTRY" \
      "SHA-256 byte-exact (pristine=$GEN_PROBE_PRISTINE_SHA restored=$post_sha)." \
      "MANUAL RECHECK REQUIRED." >&2
    exit 2
  fi
}

# run_gen_probe <probe-relative-path> <label>
# Snapshots the registry, installs the interrupt trap, runs `mix run <probe>` from
# samen_core, restores + verifies on every path, then reports PASSED/FAILED like the
# other ci.sh steps.
run_gen_probe() {
  local probe_rel="$1"
  local label="$2"

  GEN_PROBE_SNAP="$(mktemp "${TMPDIR:-/tmp}/samen_ci_registry_snapshot.XXXXXX")"
  cp "$GEN_PROBE_REGISTRY" "$GEN_PROBE_SNAP"
  GEN_PROBE_PRISTINE_SHA="$(shasum -a 256 "$GEN_PROBE_REGISTRY" | awk '{print $1}')"
  GEN_PROBE_LABEL="$label"
  GEN_PROBE_RESTORED=0

  # GEN_PROBE_GUARD_DISABLE_TRAP=1 skips installing the interrupt trap while keeping
  # everything else (snapshot, mktemp, restore-on-normal-exit) identical. NEVER set this
  # in ci.sh itself — it exists ONLY so scripts/interrupt_probe_test.sh's negative control
  # can prove the harness is refutable: same code path, trap removed, kill → corruption.
  if [[ "${GEN_PROBE_GUARD_DISABLE_TRAP:-0}" != 1 ]]; then
    trap gen_probe_restore SIGINT SIGTERM ERR EXIT
  fi

  echo ""
  echo "==> Running $label"
  local code=0
  (cd "$REPO_ROOT/samen_core" && mix run "$probe_rel") || code=$?

  gen_probe_restore
  trap - SIGINT SIGTERM ERR EXIT

  if [[ "$code" != 0 ]]; then
    echo "==> $label: FAILED (exit $code)"
    return "$code"
  fi
  echo "==> $label: PASSED"
}
