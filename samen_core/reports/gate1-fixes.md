# Gate-1 fixes — F1, F3, F6

- **Date:** 2026-07-05
- **Scope:** the two mandatory Gate-1 findings (F1, F3) plus the F6 housekeeping item, as
  diagnosed in `docs/gate-1-report.md`.
- **Environment:** Elixir 1.20.2 / OTP 29, local Postgres `localhost:5432`, role `clank`, no password.

## Baseline (before any change)

| Suite | Result |
|---|---|
| `samen_core` `mix test --warnings-as-errors` | 321 passed (9 properties, 312 tests) |
| `demo` `mix test --warnings-as-errors` | 30 passed (3 properties, 27 tests) |
| `bash demo/ci.sh` (default dev env) | **FAILS at step 2 (catalog_parity)** — F3 reproduced |
| Empty registry probe in `demo/` | `EMPTY pii_attributes size: 0`, `FULL size: 6` — F1's fail-open condition reproduced |

## Final (after all fixes)

| Suite | Result |
|---|---|
| `samen_core` `mix test --warnings-as-errors` | **322 passed** (9 properties, 313 tests) |
| `demo` `mix test --warnings-as-errors` | **31 passed** (3 properties, 28 tests) |
| `bash demo/ci.sh` (clean shell, default env) | **exit 0 — ALL 6 PASSED** |
| root `bash ci.sh` | **exit 0 — ROOT CI: ALL PASSED** |

---

## F1 — `pii_reads` fails OPEN on an empty PII registry (safety defect, MANDATORY)

### The defect
`Samen.PiiReads.Registry` discovered PII resources exclusively from
`Application.get_env(:samen_core, :ash_domains, [])`. A consumer that configures domains the
standard Ash way (`config :my_app, ash_domains: [...]`) got an **empty** PII registry, so the
taint set was empty and every leak passed — the mix task printed "OK" and exited 0. Meanwhile C1
(`catalog_parity`) and C4 (`pii_classify`) already discover from `Mix.Project.config()[:app]`'s
`:ash_domains`, so on a standard consumer C1/C4 worked while C3 silently no-op'd.

### Fix (a) — fail closed on an empty registry
`lib/mix/tasks/samen.verify.pii_reads.ex`: after `Registry.build()`, `run/1` now calls
`halt_if_registry_empty!/1`. If the built registry has zero PII attributes it prints a config
diagnostic ("refusing to run against an EMPTY PII registry … configure `ash_domains` …") and
`:erlang.halt(1)`. A vacuous check can never pass. Moduledoc updated with the guard's contract.

### Fix (b) — unify domain discovery
`lib/samen/pii_reads/registry.ex`: `discover_domains/0` now reads
`Application.get_env(Mix.Project.config()[:app], :ash_domains, [])` (the standard convention C1/C4
use) and merges the legacy `:samen_core, :ash_domains` key only as a de-duped fallback alias, so a
mid-migration consumer is fully covered and a pre-existing `:samen_core`-only consumer keeps
working. Moduledoc "Discovery" section rewritten to match.

### Red paths
1. **Empty-registry + planted leak => exit 1** (`test/verify_pii_reads_task_test.exs`, new
   `:exit_code` test). Runs the mix task in a child OS process with
   `SAMEN_EMPTY_ASH_DOMAINS=1` (new test-only hook in `config/test.exs` that clears
   `:ash_domains`), scanning the same `task_leak` corpus. Asserts exit 1 + the empty-registry
   refusal diagnostic. This reproduces the exact fail-open the gate found in `demo/` (exit 0) and
   proves it is now closed.
2. **Demo-convention config builds a non-empty registry and catches the leak** (`demo/test/verifiers_test.exs`,
   new C3 test). Builds the registry via the discovery path (no explicit `:resources`/`:domains`,
   so it reads `config :demo, ash_domains: [Demo.Crm]` — `Mix.Project.config()[:app] == :demo`),
   asserts a non-empty `pii_attributes` set with `:full_name` present, then feeds a planted
   `Logger.info(contact.full_name)` source to the harness and asserts it is caught (`code == 1`, a
   `:direct_leak` naming `:full_name`).

### Anti-tautology probe
Sabotaged the guard in place (`if false and MapSet.size(...) == 0`), re-ran
`test/verify_pii_reads_task_test.exs`: the empty-registry red-path test **FAILED** — observed
exit 0 with output `"samen.verify.pii_reads: OK — no violations found."`, expected 1. This
confirms the test observes the real process exit status and reproduces the fail-open. Reverted the
sabotage from a backup; test suite returned to 3/3 passed.

---

## F3 — demo CI gate red in the default dev env (MANDATORY)

### The defect
`bash demo/ci.sh` failed at step 2 (`catalog_parity`) because the `catalog_parity_allow_list`
(the intentional `non_pii!` shadow columns `cnt_notes`, `cnt_subject_id`) lived **only** in
`demo/config/test.exs`. In the default dev env those two columns were flagged as uncatalogued.

### Fix (belt-and-suspenders, both halves)
Reasoning: the allow-list is a property of the demo schema, not of a test run, so it belongs in
shared config; and the verifiers query a live DB, so the gate should target the canonical,
guaranteed-migrated database.

1. **Moved the allow-list to shared config** (`demo/config/config.exs`), keyed under `:demo` (the
   verifier reads `Application.get_env(Mix.Project.config()[:app], :catalog_parity_allow_list)`).
   Removed the duplicate from `config/test.exs`, leaving a pointer note. The allow-list now applies
   in every `MIX_ENV`.
2. **`demo/ci.sh` self-selects `MIX_ENV`:** `export MIX_ENV="${MIX_ENV:-test}"`. It respects a
   caller-provided env (root `ci.sh` already sets `test`) but defaults to `test` so a direct
   `bash demo/ci.sh` targets `demo_test` (which the harness migrates and which carries the shadow
   columns) with no extra setup.

### Verify
`bash demo/ci.sh` from a clean shell: **exit 0**. Final banner:

```
==> demo CI gate: starting (MIX_ENV=test)
--- step 1/6 … 6/6 all PASSED
==> demo CI gate: ALL PASSED
```

---

## F6 — housekeeping (root ci.sh spike rows + erl_crash.dump)

- **`demo/erl_crash.dump`:** already deleted by the orchestrator; confirmed absent and matched by
  the root `.gitignore` (`erl_crash.dump`).
- **`spikes/s03_fragments` and `spikes/s04_catalog_tx` rows in root `ci.sh`:** **re-enabled.**
  Verified both suites pass against local Postgres — s03: 15 passed, s04: 6 passed. Since they are
  green, re-running them is preferred over dropping coverage; added a one-line note in `ci.sh`
  explaining the re-enable. (s03 emits one harmless "Inspect protocol already consolidated" warning
  during tests — a test-time protocol re-impl notice, not a failure.)

### Verify
Root `bash ci.sh` end-to-end: **exit 0**. Sequence: s00 (4), s02 (11), s03 (15), s04 (6), s05
(50), s07 (13) → all spikes passed; samen_core 322 passed; demo 31 passed; demo CI gate ALL
PASSED; `ROOT CI: ALL PASSED`.

---

## Caveat — pre-existing test-isolation fragility (NOT introduced here, out of F1/F3/F6 scope)

The three `SamenCore.CatalogTest` "mix samen.verify.column_refs — CI linter" tests scan the shared
`System.tmp_dir!()` (`/tmp`) rather than an isolated sub-directory. If `/tmp` contains any stray
`.ex`/`.exs` files (e.g. probe/backup debris from earlier gate or orchestrator sabotage-and-revert
cycles, or leftover full-project scratch copies like `/tmp/demo_scratch`), the linter picks up
their `abc_`-shaped tokens and these three tests fail with "unknown storage column reference".

This is environmental pollution, not a regression from the F1/F3/F6 changes — the isolated
`mix test` and the gate's own run both recorded a clean `samen_core` suite in an unpolluted `/tmp`.
The stray files were removed (including this task's own probe backups) and the full root `ci.sh`
then passed 0. Recommendation (future, not in this task's scope): point those three tests at a
`Path.join(System.tmp_dir!(), unique_dir)` they create and clean up, so the linter never scans the
shared `/tmp`.
