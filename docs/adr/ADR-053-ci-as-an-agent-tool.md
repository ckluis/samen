# ADR-053 — CI as a tool agents can afford: one driver, three modes, budgeted and resumable, cached by content, mirrored in GitHub Actions

- **Status:** **ACCEPTED (2026-10-10).** The operator delegated the design in full ("I'll let you
  drive this one completely"), with the goal: quality maximal for building a real B2B SaaS on
  Samen, with as little pain as needed — but not less than needed.
- **Date:** 2026-10-10
- **Build status:** P1 in progress on `feat/adr-053-ci-modes`.

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
