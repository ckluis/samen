#!/usr/bin/env bash
# ci.sh — the ROOT GATE. Since ADR-053 a thin wrapper over the CI driver:
#
#     scripts/ci pr --budget 0 --markers [--also <opt-in>…] [args…]
#
# WHAT RUNS lives in ONE place, ci/steps.conf (`scripts/ci list pr` prints it; `scripts/ci explain
# <step>` says why a step would re-run). It is everything this script ran before ADR-053 — the G-06
# double sweep, apply-check, the regression harnesses, spikes, samen_core, the AI tier and three
# verifiers, the five adapter gates, the four gen probes, the mutation preflight + self-test,
# dialyzer over all ten projects, the four app gates — plus the sabotages and tier-1 mutants that
# touch your diff (`pr` mode). Same commands, same `==> … PASSED` markers (proven by
# scripts/ci_test.sh EQUIV against the pre-ADR-053 script), and it still ends `ROOT CI: ALL PASSED`.
#
# WHAT CHANGED. Steps run concurrently where they are isolated (own DB, own project dir; serial
# steps — the registry-mutating gen probes, anything patching source — run alone), a step whose
# inputs' CONTENT already passed is reported CACHED (`--no-cache` to force), each step's output
# goes to _ci/logs/<step>.log and a failure prints a digest, not the log. No budget here: this runs
# to completion. Inside a 600 s tool call use `scripts/ci pr` + `scripts/ci resume` instead.
#
# Opt-in tiers, unchanged:  SAMEN_SABOTAGE=1 (the whole sabotage corpus — two lanes on a clean
# tree, the serial harness otherwise) · SAMEN_MUTATION=1 (the tier-1 mutation watch-list) ·
# SAMEN_MULTINODE=1 (the two-node Oban proof). Extra args pass through (e.g. --no-cache, -j 2).
#
# CORRECTNESS CONTRACT (do NOT weaken): ALL PASSED prints only when the driver exited 0 AND the
# verdict it wrote to _ci/last.json is PASS. The driver collects every concurrent step's exit
# code explicitly (scripts/ci_test.sh C6 fails a run whose concurrent step failure is lost).
#
# The whole body is one { … } block: bash parses it completely before running any of it, so a
# sabotage patching this file mid-run (SAMEN_SABOTAGE=1 replays one that does) cannot change what
# is already executing.
{
  set -uo pipefail
  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  CI_DRIVER="${SAMEN_CI_DRIVER:-$REPO_ROOT/scripts/ci}"   # SAMEN_CI_DRIVER: test seam (ci_test.sh C6)
  CI_HOME="${SAMEN_CI_HOME:-$REPO_ROOT/_ci}"

  opt_in=()
  [[ "${SAMEN_SABOTAGE:-0}" == "1" ]] && opt_in+=(--also sabotage_corpus)
  [[ "${SAMEN_MUTATION:-0}" == "1" ]] && opt_in+=(--also mutation_watchlist)
  [[ "${SAMEN_MULTINODE:-0}" == "1" ]] && opt_in+=(--also multinode)

  rm -f "$CI_HOME/last.json"   # a stale PASS verdict can never vouch for this run
  "$CI_DRIVER" pr --budget 0 --markers ${opt_in[@]+"${opt_in[@]}"} "$@"
  rc=$?
  verdict="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("verdict", ""))' "$CI_HOME/last.json" 2>/dev/null || true)"

  if [[ $rc -eq 0 && "$verdict" == "PASS" ]]; then
    echo ""
    echo "==> ROOT CI: ALL PASSED"
    exit 0
  fi
  echo ""
  echo "==> ROOT CI: FAILED — scripts/ci exit $rc, verdict ${verdict:-none} (see _ci/last.json; logs in _ci/logs/). NOT all passed."
  exit 1
}
