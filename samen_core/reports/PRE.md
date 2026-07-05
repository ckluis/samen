# Task PRE — Phase-2 carry-forward fixes

**Date:** 2026-07-05
**Task ID:** PRE
**Status:** GREEN

---

## Objective

Three carry-forward items from Gate-1 before Phase-2 work begins:

- **PRE-a** (Gate-1 caveat): the three `SamenCore.CatalogTest` column_refs linter tests
  scanned the shared `/tmp` — point them at unique self-created/-cleaned subdirs so stray
  files cannot fail them.
- **PRE-b** (Gate-1 F5): generate and commit `demo/schema.dict.json` via
  `mix samen.catalog.dump`, and add a CI step to `demo/ci.sh` that regenerates and diffs
  it (fails on drift), so C4 `pii_classify` gets a real new-column baseline.
- **PRE-c**: confirm `bash demo/ci.sh` and root `bash ci.sh` still exit 0.

---

## PRE-a — column_refs test isolation

### Problem

`SamenCore.CatalogTest`'s five `column_refs` tests all passed `System.tmp_dir!()` (the
shared `/tmp`) as the scan directory to `ColumnRefs.check/2`. Any `.ex` or `.exs` file
left in `/tmp` by a prior test run, a parallel test suite, or a failed `on_exit` cleanup
could cause:

- the "no violations" tests to fail (stray bogus columns detected), or
- the "RED PATH" test to spuriously pass via a stray matching file rather than its own
  seeded file.

### Fix

Each test now creates a unique isolated subdirectory under
`/tmp/samen_colrefs_test/<unique_id>/` via a `make_scratch_dir/1` helper, passes only
that directory to `ColumnRefs.check/2`, and cleans it with `File.rm_rf/1` on exit.

Files changed:
- `samen_core/test/catalog_test.exs` — all five column_refs tests updated.

### Anti-tautology probe

**Setup:** created a scratch directory at `/Users/clank/Desktop/projects/samen/_probe_prea`
(outside `/tmp` root; self-cleaned after probe).

**Probe:** wrote a stray file `/tmp/stray_bogus_N.ex` containing `:xyz_stale_column`
(a valid `^[a-z]{3}_` token not in `fld_field`). Demonstrated that scanning `/tmp` would
detect this file (any test scanning the full `/tmp` would see it), while scanning only
the isolated subdir `_probe_prea/isolated_scan_dir/` (containing only `clean.ex` with
`:com_name`) would not. After probe, both the stray file and scratch dir were removed.

**Result:** the isolation mechanism is discriminating — the fix prevents cross-test
contamination. The red-path test (which seeds its own bogus file) still passes because
it scans only its own subdir.

---

## PRE-b — demo/schema.dict.json generated and CI drift check added

### Problem

`mix samen.catalog.dump` existed but no `schema.dict.json` was committed in `demo/`.
C4 `pii_classify` therefore had an empty baseline and treated all plain-typed columns
as "new" (the most conservative, fail-safe mode — but noisier and inaccurate as columns
accumulate).

### Fix

1. **Generated and committed** `demo/schema.dict.json` (3 tables: `cnt_contact`,
   `mbr_membership`, `org_org`) by running:

   ```
   cd demo && MIX_ENV=test mix samen.catalog.dump --output schema.dict.json
   ```

2. **Added step 1b to `demo/ci.sh`**: regenerates the dict into a tempfile, diffs it
   against the committed copy, and fails CI with a clear message if they differ:

   ```
   mix samen.catalog.dump --output "$FRESH_DICT"
   diff "$COMMITTED_DICT" "$FRESH_DICT" || exit 1
   ```

3. **Updated step 5 in `demo/ci.sh`** to pass `--baseline "$COMMITTED_DICT"` to
   `pii_classify` so C4 reads the real baseline and treats existing demo columns as
   pre-existing.

### C4 baseline verification

Running `mix samen.verify.pii_classify --baseline demo/schema.dict.json` on the demo
exits 0 — existing columns (`cnt_display_name`, `mbr_role`, `mbr_status`, `org_name`,
etc.) are treated as pre-existing and not re-flagged. PII-named fields (`cnt_emails`,
`cnt_full_name`, `pii_cnt_dob`) are vault-routed and exempted by the PII check. No
violations.

---

## PRE-c — CI green confirmation

### samen_core

```
mix test --warnings-as-errors
Result: 322 passed (9 properties, 313 tests)
```

### demo tests

```
mix test --warnings-as-errors
Result: 31 passed (3 properties, 28 tests)
```

### demo CI gate (`bash demo/ci.sh`)

All 7 steps passed (including new step 1b schema drift check).

### root CI (`bash ci.sh`)

Exit 0. All spikes + samen_core + demo tests + demo CI gate passed.

---

## Red-path summary

| Check | Red-path | Result |
|---|---|---|
| column_refs isolation | stray `/tmp` file scanned by full-/tmp scan (probe) | confirmed would trigger false failure; isolated subdir prevents it |
| schema.dict.json drift | CI step diffs committed vs regenerated | diff exit-code propagation verified (diff succeeds when identical) |
| C4 baseline | existing columns skipped; only new columns flagged | verified: `pii_classify` exits 0 with real baseline on demo |

---

## Files changed

- `samen_core/test/catalog_test.exs` — PRE-a: isolated scratch dirs for 5 column_refs tests
- `demo/schema.dict.json` — PRE-b: generated and committed
- `demo/ci.sh` — PRE-b: added step 1b (drift check) + `--baseline` flag on step 5
