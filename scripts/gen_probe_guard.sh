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
# ADR-053 P5 — PRIVATE REGISTRY (the probes run concurrently): `run_gen_probe` points the probe at its OWN copy
# of the registry (`SAMEN_ABBREV_REGISTRY`, honoured by Samen.AbbrevRegistry.path/0 — also by the generated
# app's compile, which asks it), so the committed file is never written and two probes cannot clobber each
# other's reservations. The committed file is still SHA-256-verified byte-identical afterwards (a probe that
# somehow wrote it fails loudly), and the scratch sweep only removes THIS probe's `_gen_*_scratch.*` dirs (the old
# sweep of all three families would delete a concurrent probe's working tree). `GEN_PROBE_SHARED_REGISTRY=1`
# restores the pre-P5 behaviour (probe mutates the committed file, the trap restores it) — only
# scripts/interrupt_probe_test.sh sets it, to keep the T107 interrupt proof about the real mutation window.
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
GEN_PROBE_PRIVATE="" # the probe's private registry copy ("" = shared mode)
GEN_PROBE_SCRATCH="" # this probe's scratch-dir stem (_gen_<x>_scratch)

# gen_probe_scratch_stem <probe-relative-path> — the `_gen_<x>_scratch` stem the probe mktemp's under REPO_ROOT.
gen_probe_scratch_stem() {
  case "$1" in
    *gen_app_flagship_probe*) echo _gen_flagship_scratch ;;
    *gen_post_probe*) echo _gen_post_scratch ;;
    *gen_app_deploy_probe*) echo _gen_deploy_scratch ;;
    *) echo "" ;; # gen_agent_probe: scratch lives under samen_core/lib + test and cleans itself
  esac
}

gen_probe_restore() {
  if [[ "$GEN_PROBE_RESTORED" == 1 ]]; then
    return 0
  fi
  GEN_PROBE_RESTORED=1

  local post_sha
  if [[ -n "$GEN_PROBE_PRIVATE" ]]; then
    # private mode: the committed file must be exactly what it was; nothing to restore, only to prove — and
    # if a probe wrote it anyway, repair it from the snapshot and fail below (never leave it corrupted)
    post_sha="$(shasum -a 256 "$GEN_PROBE_REGISTRY" | awk '{print $1}')"
    if [[ "$post_sha" != "$GEN_PROBE_PRISTINE_SHA" ]]; then
      cp "$GEN_PROBE_SNAP" "$GEN_PROBE_REGISTRY"
    fi
    rm -f "$GEN_PROBE_SNAP" "$GEN_PROBE_PRIVATE"
  else
    cp "$GEN_PROBE_SNAP" "$GEN_PROBE_REGISTRY"
    post_sha="$(shasum -a 256 "$GEN_PROBE_REGISTRY" | awk '{print $1}')"
    rm -f "$GEN_PROBE_SNAP"
  fi

  # Sweep scratch residue of THIS probe only (legacy fixed-name dir AND the mktemp'd unique-per-run dirs, T107).
  # Shared mode keeps the pre-P5 sweep of every family (the interrupt harness launches one probe at a time).
  if [[ -n "$GEN_PROBE_PRIVATE" ]]; then
    if [[ -n "$GEN_PROBE_SCRATCH" ]]; then
      rm -rf "$REPO_ROOT/$GEN_PROBE_SCRATCH" "$REPO_ROOT/$GEN_PROBE_SCRATCH".*
    fi
  else
    rm -rf "$REPO_ROOT"/_gen_flagship_scratch "$REPO_ROOT"/_gen_flagship_scratch.* \
      "$REPO_ROOT"/_gen_post_scratch "$REPO_ROOT"/_gen_post_scratch.* \
      "$REPO_ROOT"/_gen_deploy_scratch "$REPO_ROOT"/_gen_deploy_scratch.*
  fi

  if [[ "$post_sha" != "$GEN_PROBE_PRISTINE_SHA" ]]; then
    echo "==> FATAL: ${GEN_PROBE_LABEL:-gen_app probe} left $GEN_PROBE_REGISTRY changed" \
      "(pristine=$GEN_PROBE_PRISTINE_SHA now=$post_sha; private mode repairs it from the snapshot, shared mode could not)." \
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
  GEN_PROBE_SCRATCH="$(gen_probe_scratch_stem "$probe_rel")"
  GEN_PROBE_PRIVATE=""
  if [[ "${GEN_PROBE_SHARED_REGISTRY:-0}" != 1 ]]; then
    GEN_PROBE_PRIVATE="$(mktemp "${TMPDIR:-/tmp}/samen_ci_registry_private.XXXXXX")"
    cp "$GEN_PROBE_REGISTRY" "$GEN_PROBE_PRIVATE"
  fi
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
  if [[ -n "$GEN_PROBE_PRIVATE" ]]; then
    (cd "$REPO_ROOT/samen_core" && SAMEN_ABBREV_REGISTRY="$GEN_PROBE_PRIVATE" mix run "$probe_rel") || code=$?
  else
    (cd "$REPO_ROOT/samen_core" && mix run "$probe_rel") || code=$?
  fi

  gen_probe_restore
  trap - SIGINT SIGTERM ERR EXIT

  if [[ "$code" != 0 ]]; then
    echo "==> $label: FAILED (exit $code)"
    return "$code"
  fi
  echo "==> $label: PASSED"
}
