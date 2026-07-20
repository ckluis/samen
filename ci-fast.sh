#!/usr/bin/env bash
# ci-fast.sh — WS-F4 QA iteration tier.
#
# The INNER-LOOP gate: spikes → samen_core → samen_web ONLY. This is the framework
# core (the pure kernel + the UI library) — the tier a builder is most often iterating
# on. It deliberately SKIPS the slow tail of the full `./ci.sh`: the three gen_app
# generative probes (each deps.get/compiles a scratch app + runs its ci.sh, ~250s
# combined), the demo dogfood + 5-verifier gate, and the driftwood/pawchart vertical
# verifier gates. Use it for fast feedback while working in samen_core/samen_web; run
# the FULL `./ci.sh` (and `SAMEN_SABOTAGE=1 ./ci.sh` for the sabotage harness) before
# committing a milestone — ci-fast.sh is NOT a substitute for the root gate.
#
# Like ci.sh: local Postgres required; compiles with --warnings-as-errors; exits
# non-zero on the first failure and ends `CI-FAST: ALL PASSED` on success.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

run_spike() {
  local spike_dir="$1"
  local spike_name
  spike_name="$(basename "$spike_dir")"
  echo "==> Running tests for spike: $spike_name"
  (
    cd "$spike_dir"
    mix deps.get --quiet
    mix test
  )
  echo "==> spike $spike_name: PASSED"
}

# --- spike list (same set as ci.sh) ---
run_spike "$REPO_ROOT/spikes/s00_smoke"
run_spike "$REPO_ROOT/spikes/s02_transformer"
run_spike "$REPO_ROOT/spikes/s03_fragments"
run_spike "$REPO_ROOT/spikes/s04_catalog_tx"
run_spike "$REPO_ROOT/spikes/s05_vault"
run_spike "$REPO_ROOT/spikes/s07_pii_reads"

echo ""
echo "==> All spikes passed."

# --- samen_core kernel tests ---
echo ""
echo "==> Running samen_core tests"
(
  cd "$REPO_ROOT/samen_core"
  mix deps.get --quiet
  mix test --warnings-as-errors
)
echo "==> samen_core: PASSED"

# --- samen_web framework UI library gate (ADR-009) ---
echo ""
echo "==> Running samen_web gate (compile --warnings-as-errors + two-plane render/masking suite)"
(
  cd "$REPO_ROOT/samen_web"
  bash ci.sh
)
echo "==> samen_web gate: PASSED"

echo ""
echo "==> CI-FAST: ALL PASSED"
