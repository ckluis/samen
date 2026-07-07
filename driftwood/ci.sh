#!/usr/bin/env bash
# Driftwood CI gate — the FULL verifier gate exactly as demo/ci.sh (the §runs "runs"
# section), run against Driftwood's mounted CRM scope + the vertical Freight
# resources (Driver / Settlement / DispatchEvent) + the Driftwood.Context reshape.
#
#   mix compile --warnings-as-errors
#   schema.dict.json drift check
#   samen.verify.catalog_parity / prefixes / pii_reads / pii_classify / no_plaintext_pii
#   samen.verify.migrations / sink_schema / metric_labels / vault_declared_parity
#   samen.verify.tnt_catalog / tnt_boundary / api_contract --version v1
#   samen.verify.same_org_fk / no_pii_columns / aggregate_privacy
#   mix test --only adversarial
#
# Exit: 0 = all green, non-zero = first failure.

set -euo pipefail

export MIX_ENV="${MIX_ENV:-test}"

DW_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DW_DIR"

echo "==> driftwood CI gate: starting (MIX_ENV=$MIX_ENV)"

# 1. Compile (warnings are errors).
echo "--- step 1/18: mix compile --warnings-as-errors"
mix compile --warnings-as-errors
echo "    PASSED"

# 1a. Bootstrap: recreate + migrate driftwood_test and register the reviewed
#     non_pii! rows, so the standalone verifiers (which query the LIVE DB) have a
#     migrated schema + the non_pii registry pii_classify reads.
echo "--- step 1a/18: DB bootstrap (migrate + register non_pii!)"
mix run --no-start priv/ci_bootstrap.exs
echo "    PASSED"

# 1b. schema.dict.json drift check.
echo "--- step 1b/18: schema.dict.json drift check"
COMMITTED_DICT="$DW_DIR/schema.dict.json"
FRESH_DICT="$(mktemp /tmp/driftwood_schema_dict_XXXXXX.json)"
trap 'rm -f "$FRESH_DICT"' EXIT

mix samen.catalog.dump --output "$FRESH_DICT"

if ! diff -q "$COMMITTED_DICT" "$FRESH_DICT" > /dev/null 2>&1; then
  echo "    FAILED: schema.dict.json is stale — run 'mix samen.catalog.dump --output schema.dict.json' and commit."
  diff "$COMMITTED_DICT" "$FRESH_DICT" || true
  exit 1
fi
echo "    PASSED (schema.dict.json matches regenerated output)"

# 2. C1 catalog_parity
echo "--- step 2/18: mix samen.verify.catalog_parity"
mix samen.verify.catalog_parity
echo "    PASSED"

# 3. C2 prefixes
echo "--- step 3/18: mix samen.verify.prefixes"
mix samen.verify.prefixes
echo "    PASSED"

# 4. C3 pii_reads
echo "--- step 4/18: mix samen.verify.pii_reads"
mix samen.verify.pii_reads
echo "    PASSED"

# 5. C4 pii_classify (baseline = committed schema.dict.json; reviewed non_pii! from step 1a).
echo "--- step 5/18: mix samen.verify.pii_classify"
mix samen.verify.pii_classify --baseline "$COMMITTED_DICT"
echo "    PASSED"

# 6. C5 no_plaintext_pii
echo "--- step 6/18: mix samen.verify.no_plaintext_pii"
mix samen.verify.no_plaintext_pii
echo "    PASSED"

# 7. T2.4 expand-migration down/0 check.
echo "--- step 7/18: mix samen.verify.migrations"
mix samen.verify.migrations
echo "    PASSED"

# 8. J2 sink-schema allow-list.
echo "--- step 8/18: mix samen.verify.sink_schema"
mix samen.verify.sink_schema
echo "    PASSED"

# 9. T2.8 metric label-lint.
echo "--- step 9/18: mix samen.verify.metric_labels"
mix samen.verify.metric_labels
echo "    PASSED"

# 10. C6 vault-declared-parity.
echo "--- step 10/18: mix samen.verify.vault_declared_parity"
mix samen.verify.vault_declared_parity
echo "    PASSED"

# 11. T3.8 Tier-1 + T3.9 Tier-2 catalog parity.
echo "--- step 11/18: mix samen.verify.tnt_catalog"
mix samen.verify.tnt_catalog
echo "    PASSED"

# 12. T3.9 one-way boundary.
echo "--- step 12/18: mix samen.verify.tnt_boundary"
mix samen.verify.tnt_boundary
echo "    PASSED"

# 13. C6 api_contract structural-break check (Driftwood mounts no public API in T5.2 —
#     the tenant UI/API is T5.3 — so the v1 contract is empty; the verifier still runs
#     to guarantee no un-versioned structural break slips in when it IS mounted).
echo "--- step 13/18: mix samen.verify.api_contract --version v1"
mix samen.verify.api_contract --version v1 --snapshot "$DW_DIR/api_contract.v1.json"
echo "    PASSED"

# 14. F3.5 same-org-FK guard.
echo "--- step 14/18: mix samen.verify.same_org_fk"
mix samen.verify.same_org_fk
echo "    PASSED"

# 15. C7 no_pii_columns (token-blind aggregate plane).
echo "--- step 15/18: mix samen.verify.no_pii_columns"
mix samen.verify.no_pii_columns
echo "    PASSED"

# 16. T4.5 aggregate-privacy floors.
echo "--- step 16/18: mix samen.verify.aggregate_privacy"
mix samen.verify.aggregate_privacy
echo "    PASSED"

# 17. Default test suite (settlement property test, FMCSA gate red paths, CDL vault
#     round-trip, cross-org denial, dispatch worker).
echo "--- step 17/18: mix test (default suite)"
mix test --warnings-as-errors
echo "    PASSED"

# 18. The Driftwood adversarial attack matrix (tagged :adversarial).
echo "--- step 18/18: mix test --only adversarial"
mix test --only adversarial --warnings-as-errors
echo "    PASSED"

echo ""
echo "==> driftwood CI gate: ALL PASSED"
