# ADR-053 — CI as a tool agents can afford: one driver, three modes, budgeted and resumable, cached by content, mirrored in GitHub Actions

- **Status:** **ACCEPTED (2026-10-10).** The operator delegated the design in full ("I'll let you
  drive this one completely"), with the goal: quality maximal for building a real B2B SaaS on
  Samen, with as little pain as needed — but not less than needed.
- **Date:** 2026-10-10
- **Build status:** **P1 BUILT** on `feat/adr-053-ci-modes` (2026-10-10): `ci/steps.conf` +
  `scripts/ci` (quick / fast / pr / full, budget + resume, content cache, digests, FLAKY, locks,
  `_ci/last.json`), `./ci.sh` + `./ci-fast.sh` as wrappers; red paths C1–C6, C9 in
  `scripts/ci_test.sh` with sabotages 496–511 (506–511 from the adversarial gate, §2.9 G1–G8);
  measured timings §1.1, as-built §2.9. P2–P4 open.

---

## 1. Context — what an agent round actually cost (observed during ADR-052, #82–#85)

The gates are right; the *tooling around them* taxes every round:

| Pain | Evidence |
|---|---|
| `./ci.sh` outlives a 600 s tool call | Every builder/gate re-ran it as hand-derived line-range segments with "header lines 1–33 prepended". Ranges drifted as the script changed; one segmenting mistake = a step silently skipped. |
| Full sabotage corpus takes hours, serially | Final ADR-052 gate: 12 hand-sized `--range` chunks, two outlived their timeout and were backgrounded by the harness. ~4 h wall-clock. |
| Re-anchoring is manual | 112, 164, 302, 421–423, 441–446, 453, 457, 460 re-anchored by hand across four PRs. |
| Logs, not verdicts | Agents read thousands of lines to find one failing test; reports quote "final lines" copied by hand. |
| No memory between runs | A docs-only fix re-runs every suite. Nothing knows what already passed on this exact tree. |
| Counts drift | CLAUDE.md said 397 sabotages / 8 modules / 61 mutants long after both moved. |
| No remote CI | `.github/workflows/` does not exist. The repo is PUBLIC (free Actions minutes); every PR is verified only by the agent that wrote it. |
| Mode confusion | `ci-fast.sh` vs `ci.sh` vs `SAMEN_SABOTAGE=1` vs `SAMEN_MUTATION=1` vs `--changed` — the right combination for "am I done with this round?" vs "is this PR mergeable?" lives in prose. |

Machine: 10 cores, 16 GB. Tooling available everywhere we run: bash, git, jq, python3 (stdlib).

### 1.1 Measured: what every step of today's gate costs (P1 step 0, 2026-10-10)

Every step of the pre-ADR-053 `ci.sh` + `ci-fast.sh`, run ONE AT A TIME (`scripts/ci pr -j 1
--no-cache`, same commands, resumed across three tool calls each) on this branch. *Cold-ish* = the
first run after switching to the branch with `_build`/PLTs as the previous session left them (a
from-scratch `_build` adds compile time not measured here); *warm* = the immediate re-run. The
spread between the two is mostly machine noise (driftwood 92 → 140 s), not caching. Seconds:

| Step | cold-ish | warm | | Step | cold-ish | warm |
|---|---:|---:|---|---|---:|---:|
| gen_flagship_probe | 164.8 | 169.8 | | samen_web gate | 57.5 | 89.2 |
| driftwood gate | 92.4 | 139.8 | | demo gate | 63.6 | 35.4 |
| sabotage `--changed` (10 patches, new in `pr`) | 118.9 | 115.3 | | pawchart gate | 28.3 | 40.9 |
| gen_post_probe | 99.1 | 95.8 | | mutation_selection_test | 37.5 | 35.7 |
| gen_deploy_probe | 92.5 | 76.7 | | sabotage_selection_test | 35.1 | 32.2 |
| samen_core suite | 90.0 | 87.5 | | ci_selftest (new) | 35.8 | 35.9 |
| dialyzer, 10 projects (sum) | 85.5 | 72.6 | | spikes, 7 (sum) | 22.2 | 14.1 |
| adapters, 5 (sum) | 26.4 | 15.1 | | preflight: toolchain, double sweep + test, apply-check, lanes test, mutation lint (sum) | 20.9 | 21.2 |
| AI tier + 3 verifiers (sum) | 7.6 | 6.1 | | gen_agent_probe | 8.2 | 5.4 |

- **Serial sum, all 46 `pr` steps:** 1086 s cold-ish / 1089 s warm (≈ 18 min).
- **Old `./ci.sh`, as it ran:** a sequential prefix of 632–690 s, then the four app gates
  concurrently (92–140 s each alone, slower together) — ≈ 13 min. It could never fit one 600 s
  tool call; every agent hand-segmented it.
- **Old `./ci-fast.sh`:** 174–195 s serial — fits.
- **Planning overhead** of the driver itself: toolchain probe ~0.9 s; `sabotage.sh --changed
  --list` 15 s and `mutate.sh --changed --list` 20 s (cached by content since — §2.9).

These numbers seed `est_s` in `ci/steps.conf` (`ceil(1.15 × max)`); the scheduler then plans with
`max(est_s, last observed)` from `_ci/timings.json`.

## 2. Decision

### 2.1 One step manifest

`ci/steps.tsv` (or equivalent single source) declares every CI step: `id`, `cmd`, `cwd`,
`inputs` (path globs whose content decides whether the step must re-run), `modes`
(`quick`/`pr`/`full`), `serial` (touches shared state, e.g. the abbrev registry or gen probes),
`db` (needs an isolated database), `est_s` (seeded from measured timings). `ci.sh` and
`ci-fast.sh` become thin wrappers over the driver and keep their exact `==> … PASSED` markers and
final lines, so every doc, test and habit that names them keeps working.

### 2.2 One driver, three modes — `scripts/ci`

| Mode | Purpose | Runs | Target wall-clock (warm) |
|---|---|---|---|
| `quick` | inside a round: "did I break anything near what I touched?" | diff-aware: affected apps only (dependency graph: `samen_core` → everything; `samen_web` → web + verticals; one vertical → itself; docs → doc tests; `index.html` → landing checks), `--warnings-as-errors` compile, their tests, `sabotage --changed`, apply-check, lints, counts check | ≤ 3 min |
| `pr` | before a PR: "is this mergeable?" | everything `ci.sh` runs today + `sabotage --changed origin/main` + `mutate --changed origin/main` | ≤ 15 min, resumable |
| `full` | nightly / milestone | `pr` + the whole sabotage corpus + the whole mutation watch-list + opt-in tiers (multinode) | parallel/sharded; ≤ 1 h locally, ≤ 30 min in Actions |

`quick` is honest about what it skipped: its final line names the mode and says
`NOT PR-READY — run: scripts/ci pr`. Only `pr` prints the PR-ready verdict.

### 2.3 Budgeted, resumable, never segmented by hand

`scripts/ci <mode> [--budget 540]` runs steps until the next one would exceed the budget, writes
`_ci/state.json` (mode, base, tree hash, per-step result), and exits with
`CI(pr): INCOMPLETE 9/23 — continue: scripts/ci resume`. `resume` continues where it stopped.
A long single step (the corpus) is itself chunked by the same budget. No agent ever computes a
line range or waits on a background job again.

### 2.4 Content-addressed step cache

Each step's key = hash of its declared `inputs` (tracked + untracked-not-ignored content) +
toolchain versions + the step's own definition. A step that PASSED under the same key is reported
`CACHED PASS` and skipped. A docs-only fix re-runs the doc tests, not samen_core. Failures are
never cached. `--no-cache` exists; `pr` mode in Actions always runs cold.

### 2.5 Verdicts, not logs

One line per step (`PASS samen_core 212.4s`, `CACHED driftwood`, `FAIL demo 48.1s`). On failure:
an extracted digest — failing test names with `file:line`, the assertion's first lines, the
sabotage that failed to flip, the dialyzer warning — plus the full log path. Machine-readable
`_ci/last.json`. A failed test is re-run once in isolation and labelled `FAIL` or
`FLAKY (passed on rerun)` — **a flaky test still fails the run** (classification, never a pass).

### 2.6 Parallelism

DB-isolated steps run concurrently up to `-j` (default: cores/2); `serial` steps run alone, in
manifest order. The sabotage corpus runs in N lanes (generalising `sabotage-lanes.sh` from 2 to N
worktrees with warm `_build`), keeping per-patch semantics and total accounting.

### 2.7 Sabotage + mutation ergonomics

- `scripts/sabotage new` — turn a working-tree edit into a headered patch (APP / TEST_FILES /
  MUST_FAIL), next number, apply-check, prove it flips.
- `scripts/sabotage reanchor <n…>` — 3-way re-apply a patch that stopped applying onto the current
  tree, prove the NAMED tests still fail under it and pass without it, rewrite it; refuses (and
  says why) when the semantics can't be preserved mechanically.
- Counts (sabotages, watch-list modules/mutants, corpus targets) are generated into CLAUDE.md
  between markers by `scripts/counts`; `quick` fails on drift.

### 2.8 GitHub Actions mirrors the modes

- `pr.yml` on every PR: jobs per manifest group (Postgres + pgvector service container), deps /
  `_build` / PLT caches keyed by `mix.lock` + toolchain, each job runs `scripts/ci pr --only <group>`
  so local and remote can never disagree on what a step is.
- `nightly.yml`: `full`, with the sabotage corpus and mutation watch-list **sharded across a
  matrix** (the harness already has `--shard`/ranges), results summarised in the job summary.
- Branch protection (required checks) is the operator's call; this ADR only makes it possible.

### 2.9 As built (P1) — deviations, manifest format, dependency graph

**Manifest** — `ci/steps.conf`, not a TSV: python3's stdlib `configparser` (interpolation off), one
`[step id]` stanza per step, continuation lines for multi-line commands and markers. A step is
`cmd`, `cwd`, `modes`, `inputs`, `reads`, `always`, `serial`, `locks`, `est_s`, `group`,
`marker`/`marker_if`/`skip_marker`, `echo_log`, `exunit_dir`, `superseded_by`, and for long
loops `shard_list`/`shard_kind`/`shard_item`/`shard_total`/`shard_each_s`/`shard_target_s`/
`shard_check`/`unsharded_cmd`. `shard_list` prints the lister's raw output; `shard_total` (required)
is the lister's own count and must match exactly once, and for `ranges` the `shard_item` matches
must number exactly that — a drifted listing format FAILS instead of reading as "0 selected — PASS".
Unknown keys are an error (a typo can never become "no inputs"). A TSV row would have been ten
columns with 300-character cells; nobody could review one in a diff. `scripts/ci list [mode]`,
`scripts/ci explain <step>` (expanded inputs, current key, cache hit, why quick would select it).

**Dependency graph** — `[app]` stanzas, verified against every `mix.exs` path dep:

| App | path-deps on | A change here selects (quick) |
|---|---|---|
| samen_core | — | everything below + the samen_core lane (suite, AI tier, verifiers, doc tests) |
| samen_web | samen_core | samen_web, driftwood, pawchart, gen probes |
| demo | samen_core | demo (demo does NOT depend on samen_web) |
| driftwood · pawchart | samen_core, samen_web | itself |
| samen_stripe · postmark · ses · resend · anthropic | samen_core | itself |
| spikes/sNN | — | itself |
| docs/, *.md | — | `doc_tests` (quick-only: doc_commands + doc_recipes) |
| index.html | — | only the whole-tree steps (double sweep, apply-check); there is no landing check to select |

`app:X` expands to X's directory plus every TRANSITIVE dep's directory minus that dep's `test/`
(deps compile `lib` only; no dependant reads a framework test file — checked). Selection and the
cache key both use it, so they cannot disagree.

**Deviations from §2.1–§2.6, and why**

1. **`inputs` vs `reads`.** The samen_core suite is not self-contained — doc tests read `docs/`,
   the anti-bypass probes and tree-wide verifiers scan every app, meta tests glob `*/test/**` — so
   its cache key is the whole tree (`reads = **`) while quick still selects it only for samen_core
   changes. Consequence: in `pr`, a docs-only change re-runs the kernel suite (§2.4 promised it
   would not); `quick` gives that promise via `doc_tests`. Narrowing samen_core's reads file by
   file is follow-up work.
2. **Order.** Serial steps are barriers, so they now form a TAIL after the parallel batch (gen
   probes, sabotage/mutation self-tests, `--changed` replays) instead of sitting mid-script;
   `ci.sh`'s markers are the same set (EQUIV test) in a different order.
3. **Dialyzer** is ten per-project steps (one `dialyzer` lock — one at a time, 2–3 GB each), so a
   vertical-only change re-checks one PLT, not ten. `ci/legacy_steps.tsv` + EQUIV prove the ten
   together are exactly `dialyzer_gate.sh`'s default list.
4. **Locks.** Every step with a non-root `cwd` holds `dir:<cwd>` (one mix process per project —
   no `_build`/`deps` race; the samen_core lane runs in sequence), plus `db:<name>` per database.
   Verified isolated: spikes s02–s06, samen_core_test, samen_web_test, demo_test (+
   samen_pitr_drill), driftwood_test (+ two PITR drill DBs), pawchart_test; adapters use none.
5. **Long loops.** Under a budget, `sabotage --changed` / the corpus shard by patch-number range
   (~300 s chunks, never splitting a number — 25 and 35 are duplicated), the mutation steps by
   `--shard i/n`; each sub-step's `PROCESSED` / `mutants run` must equal its chunk or it FAILS.
   Unbudgeted (`./ci.sh`, `--budget 0`) they run the EXACT legacy command (`sabotage-lanes.sh` on
   a clean tree, else the serial harness; `mutate.sh` unfiltered). `mutate.sh` refuses an
   OBSOLETE ledger exemption on an unfiltered run AND on a `--shard`-only run (a shard scores
   each mutant against the same owning tests, so the n shards reproduce the unfiltered check
   exactly; `mutation_selection_test.sh` 12b) — a sharded watch-list skips nothing.
6. **Toolchain** is the first manifest step (serial; keyed by the elixir/OTP/psql fingerprint).
7. **Output.** The wrappers print one verdict line per step + the legacy markers, and on failure a
   digest + `_ci/logs/<step>.log` instead of streaming every suite. The double sweep's
   no-origin/main banner lines are echoed (prefixed `##`) on every run.
8. **FLAKY rerun** = `mix test <file:line>…` once in the step's `exunit_dir`; a failure with no
   `file:line` (setup_all), or > 25 of them, is not re-run and stays FAIL.
9. **`fast`** is a fourth mode (`./ci-fast.sh`'s subset); like `quick` it is never PR-ready. Its
   coverage guard now derives the covered set from the manifest (`scripts/ci list fast --apps`).
10. **Root-script guards need an ExUnit owner.** `sabotage.sh` proves a guard by NAMED `mix test`
    failures in an APP, so `samen_core/test/meta/ci_driver_guard_test.exs` names each
    `scripts/ci_test.sh` case (APP `samen_core`); sabotages 496–511 flip them.
11. **Listing cache.** A sharded step's item list is cached under its parent's content key
    (fully warm `pr`: 30.5 s → 0.5 s).
12. **Environment.** `SAMEN_SABOTAGE`/`SAMEN_MUTATION`/`SAMEN_MULTINODE` select steps (`--also`)
    and are stripped from every step's environment (the multinode step sets its own), so
    `SAMEN_MULTINODE=1 ./ci.sh` runs the same samen_core suite as `./ci.sh` — the multinode file
    runs once, in its own step, not twice. Every other behaviour-changing variable (`SAMEN_*`
    except the driver's `SAMEN_CI_*` seams, `MIX_*`, `ELIXIR_*`, `ERL_*`, `HEX_*`, `PG*`,
    `DATABASE_URL`, `DRILL_*`, `DRIFTWOOD_*`, `GEN_PROBE_*`, `LOG_LEVEL`) is part of every cache key.
13. **PR-READY is relative to a base.** With `origin/main` missing, `pr` still runs everything
    (the double sweep prints its NOT RUN banner; `./ci.sh` still ends ALL PASSED, as before) but
    its line says `NOT PR-READY: base origin/main is missing`; with `--base X` it says
    `PR-READY (vs X)`.

**Adversarial gate (2026-10-10) — defects found in the P1 build and fixed before merge.** Each
has a red-path assertion in `scripts/ci_test.sh`; sabotages 506–511 flip them.

| # | Defect (repro) | Fix |
|---|---|---|
| G1 | **Over-caching: undeclared tree-wide reads.** samen_web's suite (`Authz.ReadScopeLint`, `Reads.Lint`) sweeps `demo/` `driftwood/` `pawchart/lib`; samen_stripe's `payment_method_test` scans `samen_web/lib`; the two selection self-tests read the real corpus / samen_core tests. An unscoped read added to `driftwood/lib` left `samen_web` CACHED → `pr` PR-READY over a red lint (`scripts/ci explain samen_web`: key unchanged). | `reads` declared on all four; EQUIV pins them (sabotage 511). |
| G2 | **A signalled step that exits 0 counted as PASS.** A step whose trap swallows the driver's SIGTERM (`trap … TERM` + exit 0; bash resumes after a TERM trap) was recorded PASS, cached, and kept as "earlier in this run" by `resume`. | Any step the driver signalled is INTERRUPTED whatever its exit code (506). |
| G3 | **Shard listing fail-open.** Items were scraped with a `sed` over `--list`; if that format drifted the scrape matched nothing and the step was a preset `PASS (nothing selected)`. | `shard_total`/`shard_item` cross-check (507). |
| G4 | **Environment leaked across cache keys.** A PASS earned under `SAMEN_UPDATE_GOLDEN=1`, `SAMEN_EMPTY_ASH_DOMAINS=1`, a stub `SAMEN_MUTATION_RUNNER`, `GEN_PROBE_GUARD_DISABLE_TRAP=1` or another `PGHOST` was reused without it. | Env fingerprint in the key; wrapper switches stripped (508). |
| G5 | **The wrappers printed ALL PASSED over a filtered run.** `./ci.sh --only demo` (args pass through) ran one step and ended `ROOT CI: ALL PASSED`; same for `./ci-fast.sh --only`, and `./ci.sh --base HEAD` moved the double sweep + `--changed` replays off origin/main. | Wrappers believe only a whole-mode, unfiltered verdict — for `./ci.sh` also base origin/main (509). |
| G6 | **Stale verdict after a driver error.** A run that died before writing a verdict (manifest error, crash) left the PREVIOUS run's `last.json` PASS in place for an agent to read; a crash also orphaned running steps (own sessions). | `last.json` = RUNNING once the lock is held, ERROR on any exception, children terminated (510). |
| G7 | **PR-READY without a base** (see 13); a cached `@base` step also lost the double sweep's NOT RUN banner on the second run in such a clone. | NOT PR-READY when the base is missing; an `@base` step is never cached without its base. |
| G8 | **Obsolete-ledger check skipped by a sharded watch-list** (deviation 5, as first built). | Enforced per shard in `mutate.sh`. |

**Measured, as built (this branch, `-j 5`)**

| Run | Result | Wall |
|---|---|---|
| `scripts/ci pr --no-cache` (cold) | INCOMPLETE 44/46 → `resume` → PASS 46/46 | 496 s + 159 s (2 calls) vs 1086 s serial |
| `scripts/ci pr` after a driver edit (`**`-keyed steps re-key) | PASS 46/46, 1 call | 355 s |
| `scripts/ci pr`, nothing changed | PASS 46/46 (45 CACHED + 1 empty shard) | 0.5 s |
| `scripts/ci quick --no-cache` (this branch: 11 of 46 selected, 24 SKIP) | PASS 11/11 — NOT PR-READY | 220 s (116 s of it the 10 new sabotages) |
| `scripts/ci quick`, cached | PASS 11/11 — NOT PR-READY | 2.4 s |
| `./ci-fast.sh --no-cache` | `CI-FAST: ALL PASSED` | 93 s |

**Not in P1:** C7/C8/C10 and `sabotage new`/`reanchor`/`scripts/counts` (P3), Actions (P2), the
CLAUDE.md rewrite (P4 — P1 adds a pointer only). `full` mode's corpus and watch-list shards were
exercised by the fake-manifest tests and `--plan`, not end to end (hours; nightly/P2).

## 3. Red paths (each with a test; sabotage where it guards a property)

| # | Must fail when |
|---|---|
| C1 | a step is skipped by the budget/resume machinery but the run still reports PASS |
| C2 | a cached PASS is reused after one of its inputs changed (incl. an untracked file) |
| C3 | a failing step is cached |
| C4 | `quick` prints a PR-ready verdict |
| C5 | a flaky test turns a run green |
| C6 | `ci.sh` (wrapper) reports ALL PASSED while a step failed (the existing background-exit contract) |
| C7 | the N-lane corpus processes ≠ the selected patch count |
| C8 | `reanchor` rewrites a patch whose named tests no longer fail under it |
| C9 | the diff-aware selection misses an app that depends on a changed app |

P1 (as built): C1–C6, C9 are cases of `scripts/ci_test.sh` (real driver, fake manifests, ~60 s, no
DB), named in `samen_core/test/meta/ci_driver_guard_test.exs`; sabotages 496 (C1), 497–498 (C2),
499 (C3), 500 (C4), 501 (C5), 502–503 (C6), 504–505 (C9) each flip their named test; the gate's
506–507 (C1), 508 (C2), 509–510 (C6) and 511 (EQUIV: declared tree-wide reads) likewise.
| C10 | counts in CLAUDE.md drift without `quick` failing |

## 4. Phasing (one PR each, all off `main`, none stacked; each phase gated adversarially)

| Phase | Content |
|---|---|
| P1 | Measure every step (cold + warm). Manifest, `scripts/ci` (quick/pr/full, budget/resume, cache, verdict digests, `_ci/last.json`, flake classification), `ci.sh`/`ci-fast.sh` as wrappers. C1–C6, C9. |
| P2 | GitHub Actions: `pr.yml` + `nightly.yml` (sharded corpus + mutation), caches, pgvector service; proven green on its own PR. |
| P3 | Sabotage/mutation ergonomics: N-lane corpus, `sabotage new`, `sabotage reanchor`, `scripts/counts`. C7, C8, C10. |
| P4 | CLAUDE.md "Suites / CI" rewritten around the three modes (shorter, not longer); `docs/ci.md`; before/after numbers for a typical round. |

## 5. Consequences

- **+** A round costs `quick` (minutes); a PR costs `pr` (resumable, cached); the hours-long corpus
  moves to sharded nightly runs and to Actions on PRs.
- **+** Nothing about what a gate *proves* is weakened: same steps, same markers, same sabotages —
  the cache keys on content, failures never cache, flakes never pass, `quick` never claims PR-ready.
- **−** A manifest to maintain; a new step that forgets to declare its inputs could be over-cached.
  Mitigation: a step with no declared inputs is never cached, and `pr` in Actions is always cold.
- **−** Actions needs the pinned toolchain (Elixir 1.20.4 / OTP 29.1.1) + pgvector available on runners.

## 6. Out of scope

Rewriting the gates themselves; changing what any sabotage asserts; deploy/CD to a hosting
provider (the deploy layer stays operator-run); branch-protection settings.
