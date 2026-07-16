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

# --- gen_app tier: the flagship generative proof (WS-D D6, AC-X-1) ---
# The PERMANENT gen_app test tier (design.md §4). In ONE automated run it generates a
# fresh app with the FULL running product (--web --api --seeds --observability), runs
# its entire ci.sh (verifier gate + generated tests + all red-paths), seeds it via the
# emitted `mix <app>.seed`, boots it and HTTP-probes /healthz + the framework LiveViews
# + the bounded deny-by-default JSON:API, and drives TWO sabotages (API allowlist,
# observability db_statement) that each flip the gate and revert byte-exact — proving the
# generated gate is non-vacuous. Kept as a SEPARATE step (not folded into `mix test`)
# because it deps.get/compiles a scratch app and runs its ci.sh five times (~100s); it
# needs local Postgres. Zero scratch residue; the committed abbrev registry is restored
# byte-exact on every exit path.
echo ""
echo "==> Running gen_app flagship probe (WS-D D6 / AC-X-1 — generate → ci.sh → seed → boot → 2 sabotages)"
(
  cd "$REPO_ROOT/samen_core"
  mix run priv/gen_app_flagship_probe.exs
)
echo "==> gen_app flagship probe: PASSED"

# --- samen_web framework UI library gate (ADR-009) ---
echo ""
echo "==> Running samen_web gate (compile --warnings-as-errors + two-plane render/masking suite)"
(
  cd "$REPO_ROOT/samen_web"
  bash ci.sh
)
echo "==> samen_web gate: PASSED"

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
echo "==> Running Driftwood CI gate (full 19-step verifier gate + crypto-shred game-day)"
(
  cd "$REPO_ROOT/driftwood"
  mix deps.get --quiet
  MIX_ENV=test bash ci.sh
)
echo "==> Driftwood CI gate: PASSED"

# --- PawChart second-vertical thin slice gate (Phase 6, T6.2) ---
echo ""
echo "==> Running PawChart CI gate (full 17-step verifier gate + microchip anti-tautology probe)"
(
  cd "$REPO_ROOT/pawchart"
  mix deps.get --quiet
  MIX_ENV=test bash ci.sh
)
echo "==> PawChart CI gate: PASSED"

echo ""
echo "==> ROOT CI: ALL PASSED"
