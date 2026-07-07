#!/usr/bin/env bash
# ci.sh — run all spike test suites + samen_core + demo gate in sequence.
# Exits non-zero on the first failure.
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

# --- spike list ---
run_spike "$REPO_ROOT/spikes/s00_smoke"
run_spike "$REPO_ROOT/spikes/s02_transformer"
# Gate-1 F6: s03/s04 re-enabled — both suites pass (s03 15 tests, s04 6 tests)
# against local Postgres. Their mechanisms are also ported into samen_core, but
# the spike suites are green so we run them rather than drop coverage.
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

# --- demo dogfood gate ---
echo ""
echo "==> Running demo dogfood tests"
(
  cd "$REPO_ROOT/demo"
  mix deps.get --quiet
  mix test --warnings-as-errors
)
echo "==> demo tests: PASSED"

echo ""
echo "==> Running demo CI gate (5 verifiers)"
(
  cd "$REPO_ROOT/demo"
  MIX_ENV=test bash ci.sh
)
echo "==> demo CI gate: PASSED"

# --- Driftwood reference-vertical gate (Phase 5, T5.2) ---
echo ""
echo "==> Running Driftwood CI gate (full 18-step verifier gate)"
(
  cd "$REPO_ROOT/driftwood"
  mix deps.get --quiet
  MIX_ENV=test bash ci.sh
)
echo "==> Driftwood CI gate: PASSED"

echo ""
echo "==> ROOT CI: ALL PASSED"
