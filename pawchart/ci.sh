#!/usr/bin/env bash
# PawChart CI gate — the FULL samen_core verifier gate (the §runs "runs" section),
# run against PawChart's mounted Billing scope (reused AS-IS, no reshape) + the vertical
# Clinical resources (Patient / Pet) + the Tier-2 VaccineLot machinery + the token-blind
# aggregate plane.
#
#   mix compile --warnings-as-errors
#   schema.dict.json drift check
#   samen.verify.catalog_parity / prefixes / pii_reads / pii_classify / no_plaintext_pii
#   samen.verify.migrations / sink_schema / metric_labels / vault_declared_parity
#   samen.verify.tnt_catalog / tnt_boundary
#   samen.verify.same_org_fk / no_pii_columns / aggregate_privacy
#   mix test --warnings-as-errors (the red paths: microchip vault round-trip, owner PII
#        masked on the operator plane, Tier-2 VaccineLot org-scoped + contained, cross-org
#        denied, Billing reuse, dogfood walkthrough)
#   the anti-tautology probe on the microchip vault path (must flip + revert)
#
# Exit: 0 = all green, non-zero = first failure.

set -euo pipefail

export MIX_ENV="${MIX_ENV:-test}"

PC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PC_DIR"

echo "==> pawchart CI gate: starting (MIX_ENV=$MIX_ENV)"

# 1. Compile (warnings are errors).
echo "--- step 1/17: mix compile --warnings-as-errors"
mix compile --warnings-as-errors
echo "    PASSED"

# 1a. Bootstrap: recreate + migrate pawchart_test, so the standalone verifiers (which
#     query the LIVE DB) have a migrated schema.
echo "--- step 1a/17: DB bootstrap (migrate)"
mix run --no-start priv/ci_bootstrap.exs
echo "    PASSED"

# 1b. schema.dict.json drift check.
echo "--- step 1b/17: schema.dict.json drift check"
COMMITTED_DICT="$PC_DIR/schema.dict.json"
FRESH_DICT="$(mktemp /tmp/pawchart_schema_dict_XXXXXX.json)"
trap 'rm -f "$FRESH_DICT"' EXIT

mix samen.catalog.dump --output "$FRESH_DICT"

if ! diff -q "$COMMITTED_DICT" "$FRESH_DICT" > /dev/null 2>&1; then
  echo "    FAILED: schema.dict.json is stale — run 'mix samen.catalog.dump --output schema.dict.json' and commit."
  diff "$COMMITTED_DICT" "$FRESH_DICT" || true
  exit 1
fi
echo "    PASSED (schema.dict.json matches regenerated output)"

# 2. C1 catalog_parity
echo "--- step 2/17: mix samen.verify.catalog_parity"
mix samen.verify.catalog_parity
echo "    PASSED"

# 3. C2 prefixes
echo "--- step 3/17: mix samen.verify.prefixes"
mix samen.verify.prefixes
echo "    PASSED"

# 4. C3 pii_reads
echo "--- step 4/17: mix samen.verify.pii_reads"
mix samen.verify.pii_reads
echo "    PASSED"

# 5. C4 pii_classify (baseline = committed schema.dict.json; PawChart registers NO
#    non_pii! — the additive case has no plain-column PII heuristics to clear).
echo "--- step 5/17: mix samen.verify.pii_classify"
mix samen.verify.pii_classify --baseline "$COMMITTED_DICT"
echo "    PASSED"

# 6. C5 no_plaintext_pii
echo "--- step 6/17: mix samen.verify.no_plaintext_pii"
mix samen.verify.no_plaintext_pii
echo "    PASSED"

# 7. T2.4 expand-migration down/0 check.
echo "--- step 7/17: mix samen.verify.migrations"
mix samen.verify.migrations
echo "    PASSED"

# 8. J2 sink-schema allow-list.
echo "--- step 8/17: mix samen.verify.sink_schema"
mix samen.verify.sink_schema
echo "    PASSED"

# 9. T2.8 metric label-lint.
echo "--- step 9/17: mix samen.verify.metric_labels"
mix samen.verify.metric_labels
echo "    PASSED"

# 10. C6 vault-declared-parity.
echo "--- step 10/17: mix samen.verify.vault_declared_parity"
mix samen.verify.vault_declared_parity
echo "    PASSED"

# 11. T3.8 Tier-1 + T3.9 Tier-2 catalog parity.
echo "--- step 11/17: mix samen.verify.tnt_catalog"
mix samen.verify.tnt_catalog
echo "    PASSED"

# 12. T3.9 one-way boundary.
echo "--- step 12/17: mix samen.verify.tnt_boundary"
mix samen.verify.tnt_boundary
echo "    PASSED"

# 13. F3.5 same-org-FK guard.
echo "--- step 13/17: mix samen.verify.same_org_fk"
mix samen.verify.same_org_fk
echo "    PASSED"

# 14. C7 no_pii_columns (token-blind aggregate plane).
echo "--- step 14/17: mix samen.verify.no_pii_columns"
mix samen.verify.no_pii_columns
echo "    PASSED"

# 15. T4.5 aggregate-privacy floors.
echo "--- step 15/17: mix samen.verify.aggregate_privacy"
mix samen.verify.aggregate_privacy
echo "    PASSED"

# 16. Default test suite (the four red paths + Billing reuse + dogfood walkthrough).
echo "--- step 16/17: mix test (default suite)"
mix test --warnings-as-errors
echo "    PASSED"

# 17. Anti-tautology probe on the microchip vault path (flip under sabotage + revert).
#     The script System.halt(1)s if the baseline fails, the sabotage does NOT flip the
#     assertions (a tautology), or the revert does not recover.
echo "--- step 17/17: anti-tautology probe (pii_pet_microchip vault path)"
mix run priv/anti_tautology_probe.exs
echo "    PASSED"

echo ""
echo "==> pawchart CI gate: ALL PASSED"
