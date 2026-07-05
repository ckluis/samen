#!/usr/bin/env bash
# Demo CI gate — exactly the §runs 3 gate:
#   mix compile --warnings-as-errors &&
#   samen.verify.catalog_parity &&
#   samen.verify.prefixes &&
#   samen.verify.pii_reads &&
#   samen.verify.pii_classify &&
#   samen.verify.no_plaintext_pii
#
# T1.9 acceptance: every verifier must pass on the demo.
# Exit: 0 = all green, non-zero = first failure.

set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DEMO_DIR"

echo "==> demo CI gate: starting"

# 1. Compile
echo "--- step 1/6: mix compile --warnings-as-errors"
mix compile --warnings-as-errors
echo "    PASSED"

# 2. C1 catalog_parity
echo "--- step 2/6: mix samen.verify.catalog_parity"
mix samen.verify.catalog_parity
echo "    PASSED"

# 3. C2 prefixes
echo "--- step 3/6: mix samen.verify.prefixes"
mix samen.verify.prefixes
echo "    PASSED"

# 4. C3 pii_reads
echo "--- step 4/6: mix samen.verify.pii_reads"
mix samen.verify.pii_reads
echo "    PASSED"

# 5. C4 pii_classify
echo "--- step 5/6: mix samen.verify.pii_classify"
mix samen.verify.pii_classify
echo "    PASSED"

# 6. C5 no_plaintext_pii
echo "--- step 6/6: mix samen.verify.no_plaintext_pii"
mix samen.verify.no_plaintext_pii
echo "    PASSED"

echo ""
echo "==> demo CI gate: ALL PASSED"
