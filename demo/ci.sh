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
#   samen.verify.vault_declared_parity (F3.1 de-vault backstop; pii_* column ⇄ route)
#   samen.verify.tnt_catalog  (T3.8 Tier-1 + T3.9 Tier-2 catalog parity)
#   samen.verify.tnt_boundary (T3.9 one-way boundary: no system→tnt_record ref)
#   samen.verify.same_org_fk  (F3.5 same-org-FK guard on every org-scoped belongs_to)
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
echo "--- step 9/10: mix samen.verify.metric_labels (T2.8 bounded-cardinality labels)"
mix samen.verify.metric_labels
echo "    PASSED"

# 10. C6 vault-declared-parity (Phase-3 review fix F3.1): every physical column
#     matching the vault storage shape `pii_<abbrev>_<name>` must have a matching
#     declared pii_attribute route. Fails closed on a DE-VAULTED free-text 🔒 field
#     (pii_smg_body / pii_pnt_rendered_body / pii_pwh_signing_secret left in the DB
#     while the resource dropped the vault route) — the exact gap C4 pii_classify
#     misses because those logical names aren't in its heuristic token-list.
echo "--- step 10/11: mix samen.verify.vault_declared_parity (F3.1 de-vault backstop)"
mix samen.verify.vault_declared_parity
echo "    PASSED"

# 11. T3.8 Tier-1 custom-field catalog parity: tnt_field ⇄ tam_table (no orphan
#     custom field on a ghost table) + bag keys ⇄ tnt_field (no INVISIBLE custom
#     field — a jsonb bag key with no tnt_field row is an uncatalogued custom
#     field, the "customization that rotted past the catalog" failure the
#     validated-at-write change prevents; this is the durable CI backstop that
#     also catches a raw-SQL write that bypassed Ash).
echo "--- step 11/12: mix samen.verify.tnt_catalog (T3.8 Tier-1 + T3.9 Tier-2 catalog parity)"
mix samen.verify.tnt_catalog
echo "    PASSED"

# 12. T3.9 one-way boundary: no demo system resource declares a relationship INTO
#     tnt_record, and no FK targets a tenant-regime table (tnt_record/tnt_object).
#     The tenant regime references OUT to system rows as validated opaque IDs,
#     never the reverse. Compile-time enforced per-resource by
#     Samen.Verifiers.TntBoundary; this is the whole-app CI backstop.
echo "--- step 12/13: mix samen.verify.tnt_boundary (T3.9 one-way boundary)"
mix samen.verify.tnt_boundary
echo "    PASSED"

# 13. C6 api_contract verifier (T3.12): diffs the live public API surface against
#     the committed `api_contract.v1.json` snapshot. Fails closed on ANY un-versioned
#     STRUCTURAL break: removed/renamed field, narrowed type, dropped route, new
#     required arg. Additive changes pass (new field, new route, new optional arg).
#     Semantic breaks (same shape, changed meaning) are explicitly out of scope per
#     the vision doc — each diagnostic states this note.
#     Re-snapshot intentional versioned changes with:
#       mix samen.verify.api_contract --version v1 --update
echo "--- step 13/14: mix samen.verify.api_contract --version v1 (C6 structural break check)"
mix samen.verify.api_contract --version v1 --snapshot "$DEMO_DIR/api_contract.v1.json"
echo "    PASSED"

# 14. F3.5 same-org-FK guard: every tenant-plane org-scoped resource that declares a
#     belongs_to FK to an org-scoped target must carry a `Samen.Policy.SameOrgFk`
#     change covering that FK. Turns the scope-authoring guide §10 prose rule into a
#     gated invariant (Gate-3 §F3.5). Fails closed on an unguarded org-scoped FK —
#     matters most now that the operator plane's cross-tenant reach is going live.
echo "--- step 14/15: mix samen.verify.same_org_fk (F3.5 same-org-FK guard)"
mix samen.verify.same_org_fk
echo "    PASSED"

# 15. C7 no_pii_columns: the token-blind aggregate plane (T4.2) must have NO pii_
#     columns at all. Whole-app backstop to the compile-time NoPiiColumns verifier +
#     transformer: (a) re-runs the C7 rules on every `use Samen.Aggregate.Resource`
#     resource (fails on a pii_attribute / vault / pii_-shaped column / relationship
#     reaching a PII-bearing resource), and (b) asserts via information_schema that
#     each aggregate projection table physically contains no pii_ column. This is the
#     "pii_ columns physically don't exist" claim asserted against the LIVE database.
echo "--- step 15/16: mix samen.verify.no_pii_columns (C7 token-blind aggregate plane)"
mix samen.verify.no_pii_columns
echo "    PASSED"

# 16. T4.5 aggregate-privacy floors gate: every aggregate-plane resource must declare a
#     fail-closed cohort spec (aggregate_cohort_spec/0) so the k-anonymity + l-diversity
#     floors are ENFORCEABLE on it. A new cross-tenant projection that forgot its cohort
#     spec fails closed only at read time (:no_cohort_spec) — this turns "every aggregate
#     cell is floor-protected" into a gated invariant. It gates the ENFORCED floor only;
#     the cross-query budget / DP layer is posture under construction (plan T6.6) and is
#     deliberately NOT gated here (the query-budget ledger is a WARN-not-enforce scaffold).
echo "--- step 16/17: mix samen.verify.aggregate_privacy (T4.5 k-anon/l-div floor cohort specs)"
mix samen.verify.aggregate_privacy
echo "    PASSED"

# 17. T4.6 ADVERSARIAL SUITE (test/adversarial/, tagged :adversarial). The consolidated
#     Phase-4 attack matrix, run as durable CI: (1) impersonation bypass matrix — every
#     egress (LiveView / JSON / webhook / CSV-iodata / logs / error messages) under an
#     impersonation session shows ••••/absent; (2) reveal-grant abuse — self-approval
#     (DB CHECK + policy), expired grant, renew-in-place, grant-row/audit-chain tamper,
#     requestor-approver collusion (documented residue, ASSERTED audit-visible);
#     (3) aggregate differencing + k-anon/l-div bypass (filters, includes, repeated
#     queries); (4) audit tamper (edit/delete/rewrite vs chain + WORM anchor);
#     (5) break-glass abuse (budget breach → auto-suspend, KMS-down bypass fails closed,
#     local-entry tamper); (6) crypto-shred completeness against the CONTROL-PLANE tiers
#     (aud_chain event survives post-shred, subject ciphertext undecryptable; the
#     post-shred destruction oracle passes on a control-plane-seeded subject — this is
#     the "extend the oracle run in CI" assertion). Every case carries a POSITIVE CONTROL
#     so the denials are non-vacuous. Excluded from the default `mix test`; run here as
#     its own gate step via `--only adversarial`.
echo "--- step 17/17: mix test --only adversarial (T4.6 Phase-4 adversarial attack matrix)"
mix test --only adversarial --warnings-as-errors
echo "    PASSED"

echo ""
echo "==> demo CI gate: ALL PASSED"
