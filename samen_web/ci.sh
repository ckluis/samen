#!/usr/bin/env bash
# samen_web/ci.sh — the framework UI library gate (ADR-009 §9).
#
#   1. mix compile --warnings-as-errors  (the lib + test-support host compile clean)
#   2. mix test                          (component + Mount/Plane/Router unit tests +
#                                         the two-plane render tests against the scratch
#                                         samen_web_test DB — tenant clear / operator ••••
#                                         / operator token-absent red path)
#
# The `mix test` alias runs `samen_web.test_setup` first (drop/create/migrate the scratch
# DB), so this is a single self-contained gate. Exits non-zero on the first failure.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR"

echo "==> samen_web: mix deps.get"
mix deps.get --quiet

echo "==> samen_web: compile --warnings-as-errors"
MIX_ENV=test mix compile --warnings-as-errors

echo "==> samen_web: test (component + two-plane render/masking suite)"
MIX_ENV=test mix test --warnings-as-errors

# T84b / P8 (phase6-punchlist) — mix samen.verify.fleet_wire, beside aggregate_privacy /
# no_pii_columns in the verticals' own gates: RP-J-4 (wire class discipline), RP-J-4b
# (route surface cross-checked against the REAL Samen.WebTest.FleetCockpitRouter,
# fleet_cockpit: true), and P8 (closed-catalog MEMBERSHIP, live-smoke-checked against
# the :fleet_wire_catalogs fixture declared in config/test.exs).
echo "==> samen_web: mix samen.verify.fleet_wire (RP-J-4 / RP-J-4b / P8)"
MIX_ENV=test mix samen.verify.fleet_wire --host samen_web --router Samen.WebTest.FleetCockpitRouter

# T2.4 expand-migration down/0 check (pawchart/ci.sh:82, driftwood/ci.sh:81). samen_web points
# :verify_repo at Samen.WebTest.Repo (config/config.exs:33), which lives under test/support and is
# only compiled under MIX_ENV=test (mix.exs:44-45) — so this step follows samen_web's own
# MIX_ENV=test convention (ci.sh:21, ci.sh:24, ci.sh:32 above) rather than pawchart/driftwood's
# bare form.
echo "==> samen_web: mix samen.verify.migrations (T2.4 expand-migration down/0 check)"
MIX_ENV=test mix samen.verify.migrations --min-expand 1

echo "==> samen_web: PASSED"
