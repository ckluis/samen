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
#   T5.4 crypto-shred game-day (the destruction-oracle auditor artifact, reports/T5.4.md)
#   T5.5 PITR game-day #2 (production-sized dataset, both recovery arms + red-path
#        probe + key-store exclusion; drill evidence + reports/T5.5.md)
#
# Exit: 0 = all green, non-zero = first failure.

set -euo pipefail

export MIX_ENV="${MIX_ENV:-test}"

DW_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DW_DIR"

echo "==> driftwood CI gate: starting (MIX_ENV=$MIX_ENV)"

# 1. Compile (warnings are errors).
echo "--- step 1/20: mix compile --warnings-as-errors"
mix compile --warnings-as-errors
echo "    PASSED"

# 1a. Bootstrap: recreate + migrate driftwood_test and register the reviewed
#     non_pii! rows, so the standalone verifiers (which query the LIVE DB) have a
#     migrated schema + the non_pii registry pii_classify reads.
echo "--- step 1a/20: DB bootstrap (migrate + register non_pii!)"
mix run --no-start priv/ci_bootstrap.exs
echo "    PASSED"

# 1b. schema.dict.json drift check.
echo "--- step 1b/20: schema.dict.json drift check"
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
echo "--- step 2/20: mix samen.verify.catalog_parity"
mix samen.verify.catalog_parity
echo "    PASSED"

# 3. C2 prefixes
echo "--- step 3/20: mix samen.verify.prefixes"
mix samen.verify.prefixes
echo "    PASSED"

# 4. C3 pii_reads
echo "--- step 4/20: mix samen.verify.pii_reads"
mix samen.verify.pii_reads
echo "    PASSED"

# 5. C4 pii_classify (baseline = committed schema.dict.json; reviewed non_pii! from step 1a).
echo "--- step 5/20: mix samen.verify.pii_classify"
mix samen.verify.pii_classify --baseline "$COMMITTED_DICT"
echo "    PASSED"

# 6. C5 no_plaintext_pii
echo "--- step 6/20: mix samen.verify.no_plaintext_pii"
mix samen.verify.no_plaintext_pii
echo "    PASSED"

# 7. T2.4 expand-migration down/0 check.
echo "--- step 7/20: mix samen.verify.migrations"
mix samen.verify.migrations --min-expand 1
echo "    PASSED"

# 8. J2 sink-schema allow-list.
echo "--- step 8/20: mix samen.verify.sink_schema"
mix samen.verify.sink_schema
echo "    PASSED"

# 9. T2.8 metric label-lint.
echo "--- step 9/20: mix samen.verify.metric_labels"
mix samen.verify.metric_labels
echo "    PASSED"

# 9b. B-OBAN worker-queue ⊆ configured-queue parity. Discovers every queue enqueued
#     to by a compiled Oban.Worker (hand-written AND AshOban-generated trigger
#     workers/schedulers) and asserts each has a producer in this host's RESOLVED
#     runtime Oban config. A job on an unconfigured queue never drains and never
#     errors. Fails CLOSED on empty discovery.
echo "--- step 9b/20: mix samen.verify.oban_queues (B-OBAN worker/queue parity)"
mix samen.verify.oban_queues
echo "    PASSED"

# 10. C6 vault-declared-parity.
echo "--- step 10/20: mix samen.verify.vault_declared_parity"
mix samen.verify.vault_declared_parity
echo "    PASSED"

# 11. T3.8 Tier-1 + T3.9 Tier-2 catalog parity.
echo "--- step 11/20: mix samen.verify.tnt_catalog"
mix samen.verify.tnt_catalog
echo "    PASSED"

# 12. T3.9 one-way boundary.
echo "--- step 12/20: mix samen.verify.tnt_boundary"
mix samen.verify.tnt_boundary
echo "    PASSED"

# 13. C6 api_contract structural-break check. F1 (Gate-5 carry): Driftwood now mounts a
#     versioned public JSON:API over Driftwood.Freight (Driver at /api/v1/drivers, the
#     two key classes, allowlist serialization, + a load.status/driver.updated webhook).
#     The committed api_contract.v1.json pins the Driver routes + fields (cdl_number /
#     full_name as vault fields); the verifier fails the build on any un-versioned
#     structural break (a removed field / narrowed type / dropped route).
echo "--- step 13/20: mix samen.verify.api_contract --version v1"
mix samen.verify.api_contract --version v1 --snapshot "$DW_DIR/api_contract.v1.json"
echo "    PASSED"

# 14. F3.5 same-org-FK guard.
echo "--- step 14/20: mix samen.verify.same_org_fk"
mix samen.verify.same_org_fk
echo "    PASSED"

# 14b. ADR-046 §6 erasure_completeness (CAPSTONE): every out-of-DEK-envelope residue
#      (derived-linkable _bidx columns, storage_key blobs, pii_declared bags) discovered
#      from the LIVE schema has a registered subject_id-keyed erasure arm. Fail-closed on
#      empty discovery (non-vacuous: email_bidx + storage_key exist).
echo "--- step 14b/20: mix samen.verify.erasure_completeness (ADR-046 §6)"
mix samen.verify.erasure_completeness
echo "    PASSED"

# 15. C7 no_pii_columns (token-blind aggregate plane).
echo "--- step 15/20: mix samen.verify.no_pii_columns"
mix samen.verify.no_pii_columns
echo "    PASSED"

# 15b. B5 no_pan_columns (ADR-038 §3.5; T23) — no resource/table ANYWHERE (every
#      plane, not just aggregate) may carry a PAN/CVC-shaped column.
echo "--- step 15b/20: mix samen.verify.no_pan_columns"
mix samen.verify.no_pan_columns
echo "    PASSED"

# 16. T4.5 aggregate-privacy floors.
echo "--- step 16/20: mix samen.verify.aggregate_privacy"
mix samen.verify.aggregate_privacy
echo "    PASSED"

# 16b. T6.5 never-read-current lint. Driftwood does NOT opt into the CDC analytics
#      tier (opt-in per product, default off), so the lint is vacuously satisfied
#      here — but wiring it into the gate proves the guard travels with a real
#      vertical and would fire the moment a product turned the mirror on and read a
#      'current' value from it (doc line 635).
echo "--- step 16b/20: mix samen.verify.never_read_current (CDC tier off — T6.5)"
mix samen.verify.never_read_current
echo "    PASSED"

# 16c. ai_prompt_masking (ADR-043 §3.4, T65 INV-7 no-PII-egress structural gate; T134):
#      (b) no vault-routed field is embeddable (grants never unlock embedding, §7.2);
#      (c) no managed Prompt template body embeds a `vt_` vault token (§7.5). The masker
#      (Samen.AI.Chokepoint) is framework code Driftwood inherits at runtime — this step
#      re-verifies Driftwood's OWN AI surface / vault resources in its own gate.
echo "--- step 16c/20: mix samen.verify.ai_prompt_masking (INV-7 no-PII-egress structural gate)"
mix samen.verify.ai_prompt_masking
echo "    PASSED"

# 17. Default test suite (settlement property test, FMCSA gate red paths, CDL vault
#     round-trip, cross-org denial, dispatch worker).
echo "--- step 17/20: mix test (default suite)"
mix test --warnings-as-errors
echo "    PASSED"

# 18. The Driftwood adversarial attack matrix (tagged :adversarial).
echo "--- step 18/20: mix test --only adversarial"
mix test --only adversarial --warnings-as-errors
echo "    PASSED"

# 19. T5.4 CRYPTO-SHRED GAME-DAY against the live app — the auditor artifact.
#     Seeds a REAL driver across every tier, shreds, runs the destruction oracle CLI
#     (`mix samen.verify.no_plaintext_pii --subject <uuid> --tiers all`) as a separate
#     OS process and asserts it EXITS 0, exercises BOTH rollup arms, proves the audit
#     chain still verifies post-shred, runs the per-tier red paths + the anti-tautology
#     sabotage, and writes the full transcript to reports/T5.4.md. Committed writes, so
#     the DB is re-bootstrapped first and the KMS keystore is pinned to a scratch dir
#     shared with the oracle subprocess. The script `System.halt(1)`s on any failure.
echo "--- step 19/20: T5.4 crypto-shred game-day (writes reports/T5.4.md)"
DRIFTWOOD_KMS_KEY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/driftwood_gameday_kms.XXXXXX")"
export DRIFTWOOD_KMS_KEY_DIR
trap 'rm -f "$FRESH_DICT"; rm -rf "$DRIFTWOOD_KMS_KEY_DIR"' EXIT
mix run --no-start priv/ci_bootstrap.exs > /dev/null
mix run priv/gameday/crypto_shred_gameday.exs
echo "    PASSED"

# 20. T5.5 PITR / reverse-migration GAME-DAY #2 against a PRODUCTION-SIZED Driftwood
#     dataset. The bash orchestrator generates thousands of loads/settlements across
#     several tenants (committed to throwaway drill DBs), applies an expand + a
#     deliberately BAD contract (DROP COLUMN stl_advances_cents), detects the breakage
#     via the settlement-integrity harness, runs BOTH recovery arms — (i) expand
#     reversal via the tested down/0 + forward-fix, (ii) full pg_dump/restore into a
#     fresh DB + validate — proves key-store exclusion (restore resurrects the driver
#     CDL ciphertext, never the key), and measures wall-clock for each arm. It then
#     runs the RED-PATH PROBE (--probe-corrupt: corrupt the restore target, assert
#     validation fails closed) and writes reports/T5.5.md. The in-suite red-path test
#     (test/pitr_gameday2_test.exs) already ran in step 17. The script exits non-zero
#     on ANY arm/probe failure. The throwaway drill DBs are created + dropped here (NOT
#     driftwood_test), so this step is independent of the CI DB bootstrap above.
echo "--- step 20/20: T5.5 PITR game-day #2 (both arms + red-path probe, writes reports/T5.5.md)"
bash priv/gameday/pitr_gameday_sim.sh
echo "    (running red-path probe: corrupt restore target, must fail closed)"
bash priv/gameday/pitr_gameday_sim.sh --probe-corrupt
echo "    PASSED"

echo ""
echo "==> driftwood CI gate: ALL PASSED"
