#!/usr/bin/env bash
# Demo CI gate — exactly the §runs 3 gate:
#   mix compile --warnings-as-errors &&
#   schema.dict.json drift check (B3 / Gate-1 F5) &&
#   samen.verify.catalog_parity &&
#   samen.verify.prefixes &&
#   samen.verify.pii_reads &&
#   samen.verify.pii_classify &&
#   samen.verify.no_plaintext_pii
#
# Plus the additive Phase-2 verifier steps:
#   samen.verify.migrations   (T2.4 expand down/0)
#   samen.verify.sink_schema  (T2.7 J2 wide-event/span allow-list)
#   samen.verify.metric_labels (T2.8 bounded-cardinality label-lint; Gate-2 F2.3)
#
# T1.9 acceptance: every verifier must pass on the demo.
# Exit: 0 = all green, non-zero = first failure.

set -euo pipefail

# Gate-1 F3: run the gate against the canonical env. The verifiers query a live
# DB (catalog_parity, prefixes, no_plaintext_pii); MIX_ENV=test targets demo_test,
# which the test harness migrates and which carries the intentional shadow columns.
# Respect a caller-provided MIX_ENV (root ci.sh already sets it) but default to test
# so a direct `bash demo/ci.sh` is green without extra env setup.
export MIX_ENV="${MIX_ENV:-test}"

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DEMO_DIR"

echo "==> demo CI gate: starting (MIX_ENV=$MIX_ENV)"

# 1. Compile
echo "--- step 1/9: mix compile --warnings-as-errors"
mix compile --warnings-as-errors
echo "    PASSED"

# 1b. schema.dict.json drift check (Gate-1 F5 / plan B3).
#     Regenerate into a temp file and diff against the committed copy.
#     Fails CI if the schema has changed without updating the committed artifact.
#     This gives C4 pii_classify a real new-column baseline so existing demo
#     columns are treated as pre-existing (not flagged as all-new).
echo "--- step 1b/9: schema.dict.json drift check"
COMMITTED_DICT="$DEMO_DIR/schema.dict.json"
FRESH_DICT="$(mktemp /tmp/samen_schema_dict_XXXXXX.json)"
trap 'rm -f "$FRESH_DICT"' EXIT

mix samen.catalog.dump --output "$FRESH_DICT"

if ! diff -q "$COMMITTED_DICT" "$FRESH_DICT" > /dev/null 2>&1; then
  echo "    FAILED: schema.dict.json is stale — run 'mix samen.catalog.dump' and commit the result."
  echo "    Diff:"
  diff "$COMMITTED_DICT" "$FRESH_DICT" || true
  exit 1
fi
echo "    PASSED (schema.dict.json matches regenerated output)"

# 2. C1 catalog_parity
echo "--- step 2/9: mix samen.verify.catalog_parity"
mix samen.verify.catalog_parity
echo "    PASSED"

# 3. C2 prefixes
echo "--- step 3/9: mix samen.verify.prefixes"
mix samen.verify.prefixes
echo "    PASSED"

# 4. C3 pii_reads
echo "--- step 4/9: mix samen.verify.pii_reads"
mix samen.verify.pii_reads
echo "    PASSED"

# 5. C4 pii_classify — uses schema.dict.json as baseline so existing columns
#    are recognised as pre-existing (not re-flagged as new).
echo "--- step 5/9: mix samen.verify.pii_classify"
mix samen.verify.pii_classify --baseline "$COMMITTED_DICT"
echo "    PASSED"

# 6. C5 no_plaintext_pii
echo "--- step 6/9: mix samen.verify.no_plaintext_pii"
mix samen.verify.no_plaintext_pii
echo "    PASSED"

# 7. T2.4 expand-migration down/0 CI check: every :expand migration's down/0 is
#    exercised in a throwaway scratch DB (created + dropped by the task). Fails
#    closed if any expand's down is missing/broken/non-reversible.
echo "--- step 7/9: mix samen.verify.migrations (expand down/0 check)"
mix samen.verify.migrations
echo "    PASSED"

# 8. J2 sink-schema allow-list check (T2.7): every wide-event/span field must be a
#    bounded ID / token / enum / number. Fails on any free-string/untyped field —
#    the laundered-leak backstop the layered privacy design (C3 + J2) promises.
echo "--- step 8/9: mix samen.verify.sink_schema (J2 wide-event/span schema)"
mix samen.verify.sink_schema
echo "    PASSED"

# 9. T2.8 metric label-lint (Gate-2 F2.3): every Telemetry.Metrics definition must
#    use only bounded label dimensions. Fails on any raw org_id/actor_id/subject_id
#    tag (unbounded Prometheus cardinality). This is the "CI label-lint" the T2.8
#    acceptance names — now actually gated, not just unit-tested.
echo "--- step 9/9: mix samen.verify.metric_labels (T2.8 bounded-cardinality labels)"
mix samen.verify.metric_labels
echo "    PASSED"

echo ""
echo "==> demo CI gate: ALL PASSED"
