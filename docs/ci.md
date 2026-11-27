# CI for agents and humans — the reference

One driver (`scripts/ci`), one manifest (`ci/steps.conf`), three modes. Decision record and
measurements: `docs/adr/ADR-053-ci-as-an-agent-tool.md`. CLAUDE.md carries only the rules an agent must
not break; everything else is here. `scripts/docs_check` fails `quick`/`pr`/`full` when a command,
step id or `scripts/…` path named in this file or in CLAUDE.md stops existing.

Prerequisites: a local Postgres WITH the `pgvector` extension (`brew install pgvector`, or build 0.8.0
from source against your pg major) and the toolchain in `.tool-versions` (Elixir 1.20.4 / OTP 29.1.1;
the `toolchain` step fails on an older Elixir or OTP — raise the pin when you upgrade). Without pgvector
the samen_core suite fails at setup with a clear "pgvector not installed" guard message
(`samen_core/test/test_helper.exs`; ADR-043 §7.1/M3). The suites connect as `$USER`/`$PGUSER`; any role
name works, the role just has to exist (`psql -d postgres -c '\du'`). `node` must be on `PATH` too:
`samen_web/test/samen/web/confirm_interlock_test.exs` runs the served client script under it and fails with
"node is required for the app.js handler test" otherwise. `.tool-versions` pins only Elixir and Erlang, so node is not pinned
there; the GitHub Actions runners (`ubuntu-24.04`) ship a node, and no workflow step installs one.

## 1. Modes and verdicts

| Mode | Use it | Runs | Last line |
|---|---|---|---|
| `scripts/ci quick` | during a round | diff-aware vs `origin/main` (tracked diff + untracked files): only the apps your diff reaches through the dependency graph, plus the `always` steps (`toolchain`, `apply_check`, `counts`, `docs_check`) and `double_sweep` (keyed on the whole tree, so any diff selects it), plus `sabotage --changed` | `CI(quick): PASS 19/19 in 197.5s — NOT PR-READY — run: scripts/ci pr` |
| `scripts/ci pr` | before a PR | every step of the old `ci.sh` + `sabotage --changed` + `mutate --changed` vs the base | `CI(pr): PASS 47/47 in 35.3s — PR-READY` |
| `scripts/ci full` | nightly / milestone | `pr` + the whole sabotage corpus + the whole mutation watch-list + `multinode` | same shape, `CI(full): …` |
| `scripts/ci fast` | `./ci-fast.sh`'s subset | spikes, samen_core, samen_web | like `quick`, never PR-ready |

Only an unfiltered `pr` against an existing base prints `PR-READY`. `quick`, `fast`, any `--only`/
`--only-steps`/`--slice` run, and a `pr` whose base is missing print `NOT PR-READY` (with `--base X` the
verdict is `PR-READY (vs X)`). Step lines: `PASS <id> 12.3s`, `CACHED <id>`, `SKIP <id> (not affected)`
(quick), `FAIL <id> 48.1s`, `FLAKY <id> 20.0s (passed on rerun)`, `INTERRUPTED <id>`.

| Final line | Meaning | Exit |
|---|---|---|
| `CI(pr): PASS n/n in Ns — PR-READY` | everything planned ran green | 0 |
| `CI(pr): FAIL step=<id> (k/n) — see _ci/last.json` | a step failed; the digest above it names the failing tests, `file:line`, the assertion, and `_ci/logs/<id>.log` | 1 |
| `CI(pr): INCOMPLETE k/n — continue: scripts/ci resume` | the 540 s budget stopped it; NOT a failure and NOT a pass | 3 |
| `CI(pr): ERROR — …` | the driver itself broke (bad manifest, crash); `last.json` says `ERROR` | 2 |
| usage / environment error | e.g. `--require-base` and the base does not resolve | 2 |
| interrupted | SIGINT/SIGTERM; running steps are terminated | 130 |

`scripts/ci status` prints the last run (per-step lines + the verdict), `_ci/last.json` is the same in
machine-readable form (`verdict`, `final_line`, per-step `status`/`log`/`head`/`tree`). `_ci/state.json`
is the resume state. `_ci/` is gitignored; never commit it.

Every `SAMEN_CI_TEST_*` variable (`HOLD_LAUNCH`, `HOLD_KIND`, `HOLD_LIMIT_S`, `TERM_GRACE_S`, `KILL_LINGER_S`, `KILL_WAIT_S`) is a test-only seam of `scripts/ci_test.sh`; never export one. They change how the driver launches, stops and waits (a zero SIGTERM grace skips the traps that restore the tree), so none can alter a real run silently: a seam is honoured only together with `SAMEN_CI_SELFTEST=ci_test.sh`, which only `scripts/ci_test.sh` sets. Set without it, or with a value that is not a finite number of seconds >= 0 (or a `HOLD_KIND` other than `step`/`rerun`), the driver exits 2 at startup, before any step runs, naming the variable (`SEAMGUARD` case). The marker and every seam are stripped from every step's environment. `HOLD_LAUNCH` makes the driver hold a launched process before releasing it; it is bounded (60 s by default, then the driver fails naming it) and stops on Ctrl-C/SIGTERM.

After SIGKILL (the SIGTERM grace expired, or a member outlived its leader) the driver waits until the process group is GONE, not until the leader is reaped: a SIGKILLed grandchild stays a zombie until launchd reaps it, and under load that outlasted the driver. The wait is bounded (10 s: SIGKILL cannot be handled, so only a process in uninterruptible sleep outlives it); the leader is reaped on the same bound, never with an unbounded wait. Past the bound the driver says `process group N (<step>) is STILL ALIVE` (the group) or `leader of process group N (<step>) did not exit` (the leader) on stderr and keeps the group in `state.json` `running`, so the next invocation refuses to overlap with it. `TERM_GRACE_S`, `KILL_LINGER_S` (report the group and the leader alive this long after SIGKILL) and `KILL_WAIT_S` are the seams of the `KILLWAIT` case.

**The next run refuses with `step X from an earlier invocation is still running (process group N)` (or `may still be running (pgid N)`) and nothing of yours is running.** The record is a process-group id, and ids are reused: after a reboot, a crash or a long gap the number can belong to an unrelated process. Check: `ps -o pid,pgid,etime,command -g N` (or `ps -axo pid,pgid,command | awk '$2==N'`). If the members are this repo's `mix`/`beam`/step commands, wait for them or `kill -TERM -- -N` (then `kill -KILL -- -N`) and rerun. If the group is something else (or nothing is listed and the message was the permission variant), the record is stale: remove only that entry from `_ci/state.json` (the `running` object: delete the `"X": N` pair, or set `"running": {}`) and run `scripts/ci` again. Leave the rest of `state.json` alone: it is the resume state, and `scripts/ci resume` after a fresh run needs a fresh state anyway. Deleting `_ci/state.json` entirely also works but discards that resume state.

## 2. The round recipe

```
scripts/ci quick                  # after each change; fix what the digest names; repeat
scripts/ci pr                     # when the round is done; on INCOMPLETE:
scripts/ci resume                 # …repeat until  CI(pr): PASS n/n … — PR-READY
```

Every call is a single foreground tool call: the default budget is 540 s so it fits a 600 s ceiling. **An agent must
invoke every `scripts/ci pr`, `resume` and `full` call with a tool timeout of at least 600 s (600000 ms)**: each call
is budgeted to 540 s, and a harness's default tool timeout (Claude Code's is 120 s) kills it long before that, leaving
a half-run step and no verdict.
Never background a run and poll it, and never hand-segment `ci.sh`. A failing step prints its digest;
read that and `_ci/logs/<id>.log`, fix, re-run the same command — passed steps are CACHED, so you only
pay for what changed. `scripts/ci pr` re-keys on any edit, so the final run is the one on the tree you
will push (commit first, then run, or the tree changes between the run and the push).

`./ci.sh` and `./ci-fast.sh` are unbudgeted wrappers over the same manifest and print the legacy
`==> … PASSED` markers and `ROOT CI: ALL PASSED` / `CI-FAST: ALL PASSED`. They believe only a whole-mode
unfiltered verdict (`./ci.sh --only demo` never ends ALL PASSED). `SAMEN_SABOTAGE=1 ./ci.sh`,
`SAMEN_MUTATION=1 ./ci.sh` and `SAMEN_MULTINODE=1 ./ci.sh` add the opt-in tiers.

## 3. Options

| Option | Effect |
|---|---|
| `--budget S` | stop STARTING steps once the next one's `est_s` would overrun S seconds (default 540; `0` = no budget). The first step of an invocation always runs. |
| `-j N` | concurrent non-serial steps (default cores/2). Serial steps run alone. |
| `--only X[,Y]` | run only these steps or groups; never PR-ready. `--only-steps` takes step ids only (a step named like a group does not select the group). `--also X` adds an opt-in step outside the mode. |
| `--no-cache` | ignore cached PASSes (this run's own progress still resumes). |
| `--plan` | print what would run and what is CACHED; runs nothing, writes no state. |
| `--base REF` | diff base for quick, `--changed` steps and the double sweep (default `origin/main`). |
| `--require-base` | exit 2 when the base does not resolve (Actions uses it: a missing base must never read as a pass). |
| `--keep-going` | keep starting steps after a failure (default: stop at the first). |
| `--slice i/n` | the i-th of n balanced slices of every sharded step (the nightly matrix); each slice asserts `PROCESSED == its chunk`. |
| `--markers` | also print the legacy marker lines (the wrappers). |

Examples that exist and print a plan without running anything:
`scripts/ci quick --plan`, `scripts/ci pr --plan --only dialyzer`,
`scripts/ci full --plan --only-steps sabotage_corpus --slice 3/24`. `scripts/ci list pr` is the step
table (est, serial, group, locks); `scripts/ci list quick --apps` the apps quick covers;
`scripts/ci explain <step>` prints a step's expanded inputs, current cache key, whether it is CACHED,
and why quick would select it (try `scripts/ci explain counts`).

Budgeted long loops (the corpus, `sabotage --changed`, the mutation steps) are split into sub-steps
named `sabotage_changed[1/13]`; each must report exactly its chunk or it FAILS. A chunk is sized on
`max(shard_each_s, learned per-item rate)`; the replays also learn what EACH patch cost (`shard_cost`) and size
chunks by those lane-seconds through a fitted model (below), so a 35 s guard patch no longer prices a chunk of 3 s
patches. **A resume never discards finished work:** the partition of a (step, selection) is stored under
`_ci/partition/`; a finished chunk (a PASS in this run's state, or a cached PASS) stays exactly as planned — found
by its key, so a changed slot number (`[3/13]` → `[3/15]`) does not void it — and only the unfinished stretches
between finished chunks are re-planned at the current rate. Modulo shards (`mutation_*`) keep finished classes and
split only a class that outgrew `shard_target_s` (x % M == r-1 is the union of x % kM == r-1+jM) into at most as many
sub-classes as it has mutants, and a fresh plan never has more classes than mutants: a class holding no mutant is never a step
(`mutate.sh --shard r/m` rightly fails "selection is empty"; one in a stored partition is dropped, and an Actions `--slice`
past the last mutant is an "empty slice" PASS). Each sub-step
still reports exactly its chunk, no re-planned chunk outgrows the target (G10), and the chunks still sum to the
lister's count. `--no-cache` ignores cached PASSes (so nothing counts as finished unless this run did it).
Cost model (`ranges` steps with `shard_cost`): chunk wall-clock ≈ margin × (overhead + share × lane-seconds),
fitted to the last twelve passed chunks — only with ≥ 4 observations spread over half the largest, else the
prior (10 s, share 1) — never planning a chunk past 1.5× the largest lane-seconds seen to complete; the margin is
the worst observed wall-clock over its prediction. Measured here: ≈ 60 s lane start-up + 0.32 × lane-seconds.
A step may declare the FIXED cost of one invocation of its command (`shard_overhead_s`; `mutation_changed`: 50 s, the lint,
compile and baseline run of one `mutate.sh`). It is paid once per chunk: a chunk of n items is planned as overhead + n x
per-item, and the per-item rate is learned as (duration - overhead) / n. Without it a one-mutant chunk taught a rate of
overhead + each, the rate ratcheted up (it only comes down by a factor of 4) and a 28-mutant selection was planned as 26
single-mutant runs that took hours (`MUTOVH` proves the plan and the learned rate).
Unbudgeted (`--budget 0`, `./ci.sh`) the loops run as one command.

## 4. Cache semantics

- A step's key = hash of its `inputs` + `reads` content (tracked AND untracked-not-ignored files) +
  toolchain versions + the step's own definition + every behaviour-changing environment variable
  (`SAMEN_*` except the driver's `SAMEN_CI_*` seams, `MIX_*`, `ELIXIR_*`, `ERL_*`, `HEX_*`, `REBAR*`, `PG*`,
  `DATABASE_URL`, `DRILL_*`, `DRIFTWOOD_*`, `GEN_PROBE_*`, `LOG_LEVEL`). Same key and a recorded PASS →
  `CACHED`.
- Only a PASS is cached. A FAIL or FLAKY is never cached and EVICTS an earlier cached PASS under the same
  key. A step with no `inputs` and no `reads` is never cached; a step whose inputs changed while it ran is
  not cached; a step the driver signalled counts as INTERRUPTED whatever its exit code.
- `FLAKY`: a failing ExUnit test is re-run once in isolation (`mix test <file:line>…` in the step's
  `exunit_dir`). If it passes the step is labelled `FLAKY (passed on rerun)` and STILL fails the run — a
  flake is a bug to fix, not a pass. A failure with no `file:line` (a `setup_all`), or more than 25 of them,
  is not re-run and stays FAIL.
- Narrowed keys (P5): a step that never runs ExUnit on an app may declare `!<app>/test/*_test.exs` (an
  exclusion is global to the step). Only the four gen probes and the ten `dialyzer_*` steps do — dialyzer reads
  compiled `.ex`, and the probes run `mix test` only inside the generated scratch app (gen_agent: its own emitted
  file). Everything Mix compiles (`lib/`, `test/support/`, `mix.exs`, `mix.lock`, `config/`, `priv/`,
  `test/test_helper.exs`) stays in the key, so a kernel `lib/` edit still re-runs them. `NARROW` in `ci_test.sh`
  proves the exclusion drops exactly the `*_test.exs` files and nothing Mix compiles, that no probe/guard/dialyzer
  script names a kernel test path, and that the driver honours it; it was also executed (all four probes and all
  ten dialyzer steps PASS with every `*_test.exs` deleted).
- Tree-wide readers (the samen_core suite, samen_web's lint sweeps, the selection self-tests) key on the
  whole tree (`reads = **`), so in `pr` a docs-only change re-runs the kernel suite; `quick` gives the
  cheap path through `doc_tests`.
- `pr` in GitHub Actions never restores `_ci/cache`: it is always cold (`--no-cache`).
- PR-READY is relative to a base: with `origin/main` missing, `pr` still runs everything but says
  `NOT PR-READY: base origin/main is missing`, and a `@base` step (double sweep, `--changed` replays) is
  never cached without its base.
- Gen-probe dependency cache (P6) — a SECOND cache, below the step cache and not a verdict cache: each gen probe
  generates an app and compiles ≈ 62 hex dependencies, two thirds of its wall-clock. `scripts/gen_deps_cache.py`
  seeds the app's `_build/test/lib/<hex dep>` from an earlier identical build (after `mix deps.get`) and stores a new
  one after a green `mix compile`. Lives in `${XDG_CACHE_HOME:-~/.cache}/samen/gen_deps/v1/<key>/` (≈ 70 MB per key,
  the 4 newest kept; `SAMEN_GEN_DEPS_CACHE=<dir>` relocates it, `=off` disables it — a `SAMEN_*` variable, so it is
  part of the step key). The key is a sha-256 of the generated `mix.lock` bytes, the `mix_exs*.eex` templates,
  Elixir + OTP + architecture, `MIX_ENV`, the build-relevant environment (`MIX_*`, `ELIXIR_*`, `ERL_*`, `REBAR*`,
  `CC`/`CXX`/`*FLAGS`, plus every variable a hex dependency's own `mix.exs`/`rebar.config(.script)` names, minus
  `GITHUB_*`/`COVERALLS_*` run metadata) and the COMPILE-TIME config (config.exs + imports, read by `Config.Reader`;
  runtime.exs is not compile input) of every configured app except the app itself and `samen_*` — so a
  `compile_env` difference or a `config :logger, compile_time_purge_matching:` is a different key (Gate P6, ADR-053
  §2.9). It never contains `samen_core`, `samen_web` or the generated app — those are what the probe tests and compile from source every time (a `samen_web` edit with a warm
  cache still fails the probe; proven live in ADR-053 §2.9 P6). An entry is built in a temp dir, published by one
  rename, and used only after every file re-hashes to its `MANIFEST` (bound by a `COMPLETE` marker): a corrupt or
  partial entry is deleted and the probe compiles from scratch; a seed cut short (entry evicted mid-copy, full disk)
  removes every dependency it had copied. The first probe to miss holds `<key>.lock`; the
  others wait (bounded, 420 s) and then seed from it. A failed compile stores nothing. `GENDEPS` in `ci_test.sh`
  is the red-path harness. On Actions the same directory is carried by `actions/cache` (composite action
  `.github/actions/ci-job`, only for jobs that run a `gen_*` step; the key carries the ISO week because the generated
  app's lock resolves from hex at run time) — a transport only: the entries inside are re-verified before use.
- Do not suspect the cache before the log: `scripts/ci explain <step>` shows the key and what feeds it; to
  prove a result, `scripts/ci pr --no-cache` (or `--only <step> --no-cache`).

## 5. The manifest — `ci/steps.conf`

Python `configparser` INI (interpolation off, so `$` and `%` are literal), one stanza per thing,
continuation lines indented. **Unknown keys are an error.** The header comment of the file documents
every key; the ones you will touch:

| Key | Meaning |
|---|---|
| `[app NAME]` `path`, `deps` | the dependency graph quick uses; `app:NAME` in `inputs` expands to NAME's dir plus every transitive dep's dir minus that dep's `test/` |
| `[group NAME]` `marker` | a group of steps for `--only` and the wrapper markers |
| `cmd`, `cwd` | bash command (`set -euo pipefail`), working dir; exported: `REPO_ROOT`, `CI_MODE`, `CI_STEP`, `CI_BASE`, `CI_BASE_SHA`, `CI_MERGE_BASE`, `CI_SHARD_ARGS` |
| `modes` | any of `quick fast pr full` |
| `inputs` | patterns deciding quick selection AND the cache key: `dir/`, globs (`*` crosses `/`), exact paths, `**` (whole tree), `app:NAME`, `!pattern` (exclude), `@base` (key on the base too) |
| `reads` | extra patterns that feed the cache key only (files read at runtime outside the app) |
| `always` | `1` = quick selects it whatever the diff |
| `serial` | `1` = runs alone, in manifest order (anything touching shared files: abbrev registry, source patches, probe files) |
| `locks` | resources steps must not share concurrently (`dir:<cwd>` is implicit for non-root cwd; add `db:<name>` per database) |
| `est_s` | measured seconds; the scheduler plans with `max(est_s, last observed)` (`_ci/timings.json`) |
| `group`, `actions_job`, `actions_skip` | Actions job placement (below); `actions_skip = <reason of at least 12 characters>` excludes a step and is printed in every job summary |
| `marker`, `marker_if`, `skip_marker`, `echo_log` | legacy wrapper output |
| `exunit_dir` | enables the FLAKY rerun |
| `shard_*`, `unsharded_cmd` | split a long loop into budget-sized sub-steps (`shard_list` prints the lister's raw output; `shard_total` is a regex for the lister's own count and must match exactly once) |
| `shard_cost` | `ranges` only, optional: ONE regex with two groups (item name, seconds) read from a PASSED chunk's log; chunks are then cost-weighted (§3) |
| `superseded_by` | drop this step when a named step is also planned (the corpus covers `--changed`) |

**Add a step** (worked example): a new lint script that reads `samen_web/lib`:

```ini
[step foo_lint]
cmd = bash scripts/foo_lint.sh
modes = quick pr full
inputs = scripts/foo_lint.sh samen_web/lib/
est_s = 5
group = preflight
```

Then check it: `scripts/ci explain <your step>` (the inputs expand to files; quick selects it for the right
diff), `scripts/ci pr --plan --only <your step>`, and `scripts/ci actions plan pr` (it FAILS, naming the
step, if the step is in no Actions job — `group` is what places it). **Inputs discipline:** list every
path the step reads, including tree-wide scans of other apps; an undeclared read means a stale CACHED
PASS over a real regression (this bit samen_web's lint sweeps once). When unsure use `reads = **`. Add the
script's own path to `inputs` and to `ci_selftest`'s inputs if it has a self-test.

## 5b. Running one project by hand, and dialyzer

`cd samen_core && mix test` (test_helper owns the DB lifecycle); `cd samen_web && mix test` (an alias sets up
the scratch DB); verticals and demo: `MIX_ENV=test bash ci.sh` in their directory (the full verifier
gate). CI compiles with `--warnings-as-errors` and a framework/adapter `lib/` warning fails (a path dep's
warnings never fail a dependant's compile, so each project's lib is compiled by its own step) — keep zero warnings.

The read-scope lint (`Samen.Lint.ReadScope`: a direct `authorize?: false` read with no `org_id`/`id` narrowing returns every
org's rows) runs in every host and every generated app as the `ci.sh` step `mix samen.verify.read_scope --max-sanctioned N` over that
app's own `lib/` (the `demo`, `driftwood` and `pawchart` steps, the generated-app probes); `samen_core` and `samen_web` run no such
step — their `lib/` is covered by the five-tree sweep in `samen_web`'s suite, which also covers the three verticals. An unreadable or
unparseable file, a subdirectory it cannot list, a missing or empty source dir, a positional argument, and more sanctioned reads
(`# authz-scope:` markers, one per read) than the pinned ceiling fail it. Run it by hand from any app: `mix samen.verify.read_scope`.

The catalog-meaning verifier (`mix samen.verify.catalog_meaning`, `Samen.CatalogMeaning`) runs in `demo`, `driftwood` and `pawchart` as
`ci.sh` step 1c, right after the `schema.dict.json` drift check. It fails when a catalogued table or field has no description, or a
present one is low quality (trimmed, at least 3 words, at most 300 characters, no TODO/TBD/FIXME or `vt_`, not a restatement of the
name), and on bad synonyms (1-40 characters, unique within a resource, never another field's name or label, and, across the app's
tables, never another table's label, name or synonym) or bad units. It reads compile-time metadata only and needs NO database, so it
sits before every DB-backed verifier. It fails closed: zero resources, or a resource whose meaning it cannot read, is a violation.
The debt that exists today is each app's committed `<app>/catalog_meaning.baseline`: a sorted list of its undescribed `table_name` and
`table_name.logical_name` entries under a `# ceiling: N` header equal to the count. The undescribed set must EQUAL the list: a new
undescribed entry is always a violation (new tables and fields are described from day one), and a described entry still listed is a
violation until `mix samen.verify.catalog_meaning --shrink` removes it. `--init` writes the file once (it refuses an existing one);
with no file the verifier is strict (a brand-new app before adoption). A host that has paid all its debt KEEPS its file at
`# ceiling: 0` with no entries; it never deletes it. A quality violation is never baselinable.
The list can only shrink: `samen_core/test/catalog_meaning_ratchet_test.exs` compares each host baseline with the merge base
(`Samen.CatalogMeaning.Baseline.ratchet/3`; a missing merge base fails under `CI`, as for the swallow ceilings). A baseline absent
at the merge base is tolerated only while the merge base predates the verifier itself (the adoption PR); once
`samen_core/lib/samen/catalog_meaning/baseline.ex` exists there, a missing host file is a failure (deleted and re-initialised).
Not every entry is one an author can describe: demo's 21 entries for the `ash_paper_trail` Version tables (`cbl_block_versions`,
`cpg_page_versions`, `cpt_post_versions`) belong to generated resources, so they stay until the framework describes them by default.
The test also fails a `catalog_meaning.baseline` under an app that is not in its host list, and pins the exact `ci.sh` line
`mix samen.verify.catalog_meaning` (whole, uncommented, no `|| true`, no `--baseline`) after the dict drift step in each host. The baseline is inside
each host step's `inputs = app:<host>` and the ratchet test inside `samen_core`'s `reads = **`, so a cached PASS cannot survive a
baseline edit. `samen_web` has no domains of its own and no step.

Dialyzer (`scripts/dialyzer_gate.sh [app…]`, the ten `dialyzer_*` steps, one at a time, 2-3 GB each):
any warning not in that project's `.dialyzer_ignore.exs` fails, and so does an UNUSED ignore entry. Every
entry says why it is a false positive or deliberate code; fix a new warning or add it WITH its reason,
never a bare entry. PLTs live in `*/priv/plts/` (gitignored — never commit them; #77 once did). A path dep is
invisible to dialyxir's lockfile hash, so samen_web keeps samen_core IN its PLT and the script rebuilds it
when samen_core's source hash changes (~95 s); the other eight keep the framework OUT of their PLT and
ignore `Samen.`-scoped unknown calls. Cached runs are ~8 s per project; a first build ~2 min.

The old `ci.sh` order (spikes → samen_core → AI tier → adapters → gen probes → sabotage → app gates) is now
the manifest's: parallel DB-isolated steps first (the flagship/post/deploy gen probes among them: each works on a
private copy of the abbrev registry, `SAMEN_ABBREV_REGISTRY` + its companion `SAMEN_ABBREV_REGISTRY_GUARD`, both set
only by `scripts/gen_probe_guard.sh` and stripped by the driver from every step's environment), then the
`serial` steps (`gen_agent_probe`, which writes a scratch scope into `samen_core/lib` + `test`, selection self-tests,
`--changed` replays) as a tail. Markers are the same set in a different order.

## 6. Sabotages

A sabotage is `scripts/sabotages/NNN-slug.patch`: a header (`# SABOTAGE:` why, `# APP:`, `# TEST_FILES:`,
`# MUST_FAIL:`) and a `git diff` that breaks a guard. The harness applies it, runs the TEST_FILES in APP,
requires the NAMED tests (`MUST_FAIL`, a LITERAL substring matched with `grep -F` — never interpolated
with `#{…}`) to fail, reverts, and verifies a SHA-256 byte-exact restore. A patch that no longer applies
is a guard with no red: re-anchor it, never delete it.

**New sabotage — `scripts/sabotage new`.** Order matters (this is the ADR-052 accident made impossible):

1. `git add` the files holding your REAL change (the fix the sabotage is about).
2. Edit the lib file(s) in the working tree with ONLY the sabotage, unstaged.
3. `scripts/sabotage new <slug> --app samen_core --test-file test/foo_test.exs --must-fail "literal test name" -- samen_core/lib/samen/foo.ex`

The patch is the diff of the named files against the index; the files are restored from the index.
It is kept only if: every `--must-fail` is literally in the test files; header lint and
`git apply --check` pass; it ANCHORS (`scripts/double-sweep.sh --base origin/main` must say ANCHORED — a
patch that would fire in both baselines tests nothing this branch added, so the tested code or test must
be NEW in your branch); `scripts/sabotage.sh --range N-N` flips the named tests and restores byte-exact
(a compile/migration breaker is refused); and the baseline is green with the sabotage removed. On any
refusal the patch is deleted and the tree is as it was, your sabotage edit included. Unstaged work in a named
file that the tests do not exercise cannot be told apart from the sabotage, so the files' pre-command bytes
are always kept in `<git-dir>/samen-sabotage-new/<patch name>/` and every captured line is printed — read
it. Before the replay (the guard tests check the counts against the patch directory) it snapshots every file
`scripts/counts --files` lists and runs `scripts/counts --write` and `scripts/counts --write --docs`; on a refusal
it restores them byte-identical. The patch is left untracked, so `git add` it and the count files `git status` shows. Options: `--number`, `--description`, `--base`. `scripts/sabotage new --help`
is the full text.

**Refused at build time — `scripts/sabotages/BUILD_REFUSED.tsv`.** A mutation that a named compile-time rule refuses
(a `DslError` from a transformer, e.g. `Samen.Reveal.ProbeGuard` on a reveal action that takes an identity argument)
cannot flip a test: the build never reaches one. The refusal is the kill, and the harness says so only for a patch listed
in the ledger (`patch`, `required substring of the compiler output`, `reason`; the substring is the rule's own message,
never "error"). A listed patch whose build is refused with the substring is reported `KILLED (build refused: …)` and counts
as a pass (still restored byte-exact); refused without it is a WRONG REFUSAL; a build that succeeds is a STALE entry
(the rule no longer refuses it) and fails whatever the tests do. An unlisted patch whose build is refused fails as ever —
there is no global leniency for compile errors — and an entry naming a missing patch, an empty substring or reason, or a
patch listed twice fails at the start (`scripts/sabotage_lint.sh`). `sabotage reanchor` replays through the same harness,
so it honours the ledger; `scripts/sabotage-lanes.sh` runs `sabotage.sh` per lane, so do the lanes. A shipped patch keeps
its name, header and mutation: re-anchor its hunk and list it, never swap the mutation.

**Drifted patch — `scripts/sabotage reanchor <n…>`** (or `apply_check` failing): 3-way merges each
section against the current tree, proves the named tests are green without it and flip with it, and
rewrites it with a byte-identical header. It REFUSES (original untouched) on a conflict, missing pre-image
blob (history rewritten), create/delete/rename patch, vanished named test, red baseline, a candidate that
no longer flips or breaks the compile, a patch outside `scripts/sabotages/`, or a number shared by two
patches (25, 35). When refused, regenerate the patch from a real edit with `sabotage new` — unless it is a SHIPPED patch
whose target moved (`reanchor` says "moved or deleted"): a patch is never deleted or renamed, so re-anchor it by hand in place
(same name, same header, new diff paths), as 8889c4fc did for 666 and 682.

**Replaying.** `scripts/sabotage.sh` (filters compose as an intersection; repeating one flag is an
error; a FILTERED run certifies only its subset; the header preflight still lints ALL patch headers): `--app`, `--not-app`, `--range lo-hi` / `--from`/`--to`,
`--touching <path>…`, `--changed [<ref>]`, `--shard i/n`, `--list`/`--dry-run`. `scripts/ci pr` already runs
`--changed`. The full corpus (hundreds of patches; a few are 60-second guard patches) is `scripts/ci full`
or `SAMEN_SABOTAGE=1 ./ci.sh`.

**Lanes — `scripts/sabotage-lanes.sh [--lanes N] [--working-tree] [selection flags]`.** The replay as N
concurrent `sabotage.sh --shard k/N` lanes, each in a git worktree under `.git/samen-lanes/<b|c|d…>` with
its own databases (`SAMEN_TEST_DB_SUFFIX`, each app's `config/test.exs` appends it; lane k>1 uses the
inherited suffix + `_lane<k>`). Default N = `min(cores/2, RAM GB/3, free Postgres connections/22, 8)`,
never more than selection/12; `SAMEN_LANES=N` overrides (`1` = plain harness). It refuses a dirty tree
unless `--working-tree` syncs your edits into every lane (the driver passes it). It FAILS unless every
lane exits 0 with `PROCESSED n of n`, and the SELECTED and PROCESSED sums equal the selection. In the
driver: locally `sabotage_changed` and `sabotage_corpus` use lanes; with `GITHUB_ACTIONS` set, or
`SAMEN_LANES=1`, they use the plain harness (each Actions slice is already a runner).

**Double sweep.** `scripts/double-sweep.sh` (the `double_sweep` step) is the cheap, no-DB half: (a) ANCHOR —
each NEW patch must apply-fail or name a missing test against a pristine archive of the base; (b) DISARM —
every shipped patch must still `git apply` on the tree about to ship. `apply_check`
(`scripts/sabotage_apply_check.sh`) additionally requires every patch to `git apply --check` on the working
tree: a patch that fails in BOTH baselines is "pre-existing" to the double sweep by design, so without it a
patch that stopped applying would be a guard with no red (issue #53). Neither replaces the replay.

**Driver red paths.** `scripts/ci_test.sh [CASE…]` (the `ci_selftest` step) holds the driver's and the CI
tooling's own red paths (C1–C10, A1–A3, SABNEW, DOCS, ESCAPE, …), each with a positive control, and each case is a named
test in `samen_core/test/meta/ci_driver_guard_test.exs` so a sabotage can flip it (the range is in CLAUDE.md). A
change to `scripts/ci*`, `ci/steps.conf`, `ci.sh`/`ci-fast.sh` or the sabotage/counts/docs tooling adds or extends
a case there and proves it with `scripts/sabotage new`. The self-tests that build throwaway git repos (`ci_test.sh`,
`sabotage_{tooling,lanes,apply_check}_test.sh`, `double_sweep_test.sh`) source `scripts/fixture_guard.sh`: it fails closed
without a usable temp root, shadows `git` so a fixture command can only act on a repository inside that root (physical
paths), and re-checks the real repo's HEAD / branch / `origin/main` / staged index on exit (not the working tree: other steps and Python's bytecode cache write there). Never write a fixture builder as
`cd "$R" && … ; …` — a failed `cd` then runs the rest in the real repo.

## 7. Mutation gate (ADR-049)

The sabotage corpus proves the guarantees we CLAIM; the mutation gate asks whether some OTHER change to the
same file survives its owning tests. `scripts/mutate.sh` (default: the tier-1 watch-list in
`scripts/mutation/targets.tsv`; `--list` shows it, counts in CLAUDE.md). Mutants come from the AST
(`scripts/mutation/mutate.exs`: EQ, REL, BOOLOP, BOOLLIT), each run against only that target's owning
tests = DECLARED (`targets.tsv`, sabotage `TEST_FILES`) ∪ DERIVED (test files in the target's app whose AST names
one of the target's modules — aliases expanded, exact names, never a submodule — or carrying `# MUTATION_OWNS:
<repo-relative lib path>`; the lint refuses a missing file; `--list` prints the derived additions). Flags
(repeating one is an error, different ones intersect):
`--app`, `--file`, `--family`, `--changed [<ref>]`, `--shard i/n`, `--list`, `--list-targets`, `--corpus`
(targets derived from sabotage headers: a soak, not a gate step), `--emit-patches <dir>`, `--targets`,
`--ledger`. Ends `MUTATION GATE: ALL PASSED`. Full watch-list ≈ 47 min serial (401 mutants / 23 modules, measured after ARCH-26; was ≈ 15 min at 166): use the driver (`mutation_changed`
in `pr`, six slices nightly) or `--shard`/`--file` chunks.

Never weaken it: (1) baseline green before scoring; (2) a kill is a NAMED test failure — a non-zero exit
without an `N) test` header is `BUILD-REFUSED`, never a kill, and owning suites deliberately run without
`--warnings-as-errors`; (3) byte-exact SHA-256 restore; (4) an unexempt survivor fails the run; (5) full
report, then fail. A survivor is closed one of two honest ways: write the test that kills it, or, only if
the mutation provably cannot change behaviour, add its printed key to `scripts/mutation/ledger.tsv` as
`EQUIVALENT` + a specific proof, or `ACCEPTED_GAP` + a mandatory `ref=`. Ledger rows hash the source line
they excuse (editing it expires the exemption; an exemption whose mutant is now killed fails as obsolete).
Do not widen a target's owning tests to make red go green unless the added file genuinely guards the module.

**Promotion path:** `scripts/mutate.sh --corpus --file <lib path> --emit-patches <dir>` writes each survivor
as a sabotage-format patch with `MUST_FAIL` left TODO; write the killing test, fill `MUST_FAIL`, move the
patch into `scripts/sabotages/` (or recreate it with `scripts/sabotage new`), and the hole is a permanent
guarantee. `mutation_lint` and `mutation_selection_test` run in every mode; `SAMEN_MUTATION=1 ./ci.sh`
adds the replay tier.

## 8. Generated counts

CLAUDE.md states the sabotage count, the driver-guard range, the watch-list size and the corpus size
between `<!--count:NAME-->…<!--/count-->` markers. They are derived (`scripts/counts --list`), checked
by the `counts` step of quick/pr/full, and fixed with `scripts/counts --write`. `--check` fails on a stale
value, a vanished marker or an unknown name; `--write` rewrites values only. `sabotage new` updates the
two sabotage counts for you. Never hand-edit a count; a moved marker needs `scripts/counts.py` updating.

## 9. Doc drift — `scripts/docs_check`

The `docs_check` step (quick/pr/full, ~1 s) reads CLAUDE.md and `docs/ci.md` and fails when: a
`scripts/ci <subcommand>` is not in `scripts/ci --help`; a `--flag` on a `scripts/ci` command is not in
its help; a step id given to `explain`/`--only`/`--only-steps`/`--also` (or a backticked token that is
snake_case and whose first word starts some step id, such as `dialyzer_*` or `double_*`; `samen_*` is
skipped) is not in `ci/steps.conf`; a repo path under `scripts/`, `ci/`, `docs/` or `.github/` (also written
`./scripts/…`) does not exist (globs must match something); `docs/ci.md` is missing or CLAUDE.md does not point
at it; or a document resolves nothing at all. Not checked: flags of the other scripts (`sabotage.sh`,
`mutate.sh`, …), paths outside those four directories, `ini` code fences. Unquoted prose naming the driver
followed by a plain word reads as a subcommand: write `scripts/ci` in backticks. Fix the doc, not the check.

### Local paths — `scripts/no_local_paths`

The `no_local_paths` step (quick/pr/full, ~1 s) fails when any tracked text file names a path on someone's
machine: a home directory (`/Users/<name>/`, `/home/<name>/`), a `~/Desktop`, `~/Downloads` or `~/Documents`
path, a macOS temp dir (`/private/tmp`, `/private/var`) or an agent scratchpad. On GitHub, name a file in this
repo by its GitHub URL (`https://github.com/ckluis/samen/blob/<sha>/<path>`, a commit permalink, or `blob/main/…`);
name a file that never left a laptop by what it is, not where it was. Placeholders like `/Users/<name>` pass.

## 10. GitHub Actions

- `.github/workflows/pr.yml` (on `pull_request` to main; `contents: read`; never `pull_request_target`;
  concurrency per PR): `plan` → `ci` matrix → `ci-pr`. `plan` runs `scripts/ci actions plan pr --json`: the
  matrix is derived from the manifest (a step's job is its `group`, or `actions_job`). It FAILS on a step in
  no job, in two, or excluded without a reason. Each `ci` job (composite action
  `.github/actions/ci-job`) has a `pgvector/pgvector:0.8.0-pg16` service, the pinned toolchain, and runs
  `scripts/ci pr --only-steps <ids> --budget 0 -j 2 --no-cache --require-base`.
- `ci-pr` (**the one check to require**) needs `plan` and `ci` to be `success` and runs
  `scripts/ci actions verify pr --results … --expect-head $GITHUB_SHA --expect-base <PR base>`: the union of
  steps that actually ran must equal `scripts/ci list pr` minus the exclusions, each exactly once, all
  PASS/CACHED, every job on the PR's base SHA, the merge commit and its exact tree.
- Job timeouts: `timeout-minutes: ${{ matrix.timeout_min }}` in both workflows; `scripts/ci actions plan` puts
  `timeout_min` on every job from `ci/actions_timeouts.tsv` — twice the slowest successful run seen in
  `gh run list` / `gh run view --json jobs`, floor 15 min, 60 for a job with no row (it was a flat 350 / 120). A row
  that is not that formula of its own observation is refused: change the observation, not the timeout alone.
  Today: preflight/spikes/app_*/mutation* 15, adapters/samen_core/gen_flagship/app_driftwood 20, gen_probes and
  mutation_watchlist_* 30, dialyzer_core and sabotage_corpus_* 35, dialyzer_adapters_a 40, dialyzer_verticals 50,
  sabotage_changed 60 (the 29.8 min PR that touched the driver).
  The two `--changed` jobs' work scales with the diff, not with history, so the PR workflow's `plan` job runs
  `scripts/ci actions plan pr --selection --base <PR base>` (it needs the toolchain: `mutate.sh --list` runs the
  mutation engine): it asks each such step's own lister how many items this diff selects and sets
  `timeout = min(360, max(history value, 5 * ceil(2 * selected * shard_each_s / 60 / 5)))` — twice the lane-seconds at
  the manifest's conservative per-item rate (`shard_each_s`: 32 s per sabotage patch, 20 s per mutant for `mutation_changed`), never below the
  history value, never over GitHub's ceiling. A lister that fails or has no count line REFUSES the plan. Without
  `--selection` (a local `actions plan`) the history value alone applies. Not distinguished: guard vs ordinary
  patches (one rate; the 2x margin and the cap carry it).
  **`mutation_changed` is sized per TARGET, not at one flat rate.** Targets whose owning tests are slow cost a multiple of
  the flat 20 s (PR #177: 28 `vault.ex` mutants, 48.5 s each; the flat rate gave a 1,120 s limit for ~1,360 s of work and the
  job was cancelled). `scripts/mutation/rates.tsv` holds the measured seconds per mutant per target (a source for every
  row; `vault.ex` = 49); a target with no row costs `shard_each_s`. The plan reads the per-target counts the lister prints
  (`shard_rate_item`), estimates the job as the sum of count x rate, sets the limit to 2 x the estimate (5 min steps) and,
  when the estimate exceeds `actions_slice_max_s` (1,800 s: the 2 x rule then gives the 60 min a job is allowed), splits the
  step into `ceil(estimate / 1800)` matrix slices `mutation_changed_01..k` running `--slice i/k` (= `mutate.sh --shard i/k`,
  a round-robin share of every target; a slice past the last mutant is an empty-slice PASS). Per-target counts that do not
  sum to the lister's total refuse the plan. Because the slice count depends on the diff, the `plan` job publishes
  `plan.json` as the `actions-plan` artifact and `ci-pr` runs `scripts/ci actions verify … --from-plan plan.json`: the
  verifier checks the results against the plan that was actually run (each slice 1..k once, PROCESSED summing to the
  selected total). A row is a measurement, never a guess: `scripts/mutation_lint.sh` refuses a row whose path is not a row of
  `targets.tsv` (a renamed target must not leave a stale rate the lookup silently ignores), a non-positive rate, a duplicate,
  or a source under 20 characters. **When a job is cancelled for time nothing learns from it, and CI never raises a limit
  from its own history.** Instead every `mutate.sh` run prints, as each target finishes and again in its report,
  `seconds per mutant: <path> <rate> (<n> mutants, <s>s)` - the measured wall clock per target (a target's baseline run is
  charged to its first mutant); read it from a slow or cancelled job's log and update the row by hand, citing the run.
- `.github/workflows/nightly.yml`: cron `17 3 * * *` (03:17 UTC) + `workflow_dispatch`; `scripts/ci full`, the
  same jobs as `pr` minus the two `--changed` jobs, plus `multinode`, 24 corpus slices (`--slice i/24`) and 6
  mutation slices; `ci-full` sums the slices against the lister's total and `ls scripts/sabotages/*.patch`.
- Caches (`actions/cache`): `<proj>/deps`, `<proj>/_build`, dialyzer PLTs, keyed by OS + OTP + Elixir + job
  + `hashFiles('**/mix.lock')`; slices of one step share a cache. A restored `_build` cannot go stale
  against sources (checked, not assumed). A nightly on `main` seeds the cache every PR can read.
- Postgres runs as role `samen_ci` (`USER`/`PGUSER`); nothing may assume the maintainer's role.
- Third-party actions are pinned to full SHAs; no `${{ }}` inside `run:`; no secrets.
- Limits: a PR runs its OWN workflow files, `ci/steps.conf` and driver, so requiring `ci-pr` is only as
  strong as review of `.github/`, `ci/` and `scripts/ci*` (CODEOWNERS or a required workflow from `main`).
  `sabotage_changed` is one job: a PR touching most of samen_core replays hundreds of patches in a single job.
  `mutation_changed` is one job until its estimate passes the slice ceiling, then k slices (above).
- Reading a failure: the job summary has the digest; artifact `ci-result-<job>` holds `last.json`.
  A FLAKY job turning green on a re-run shows as attempt 2 — a human action GitHub records.

## 11. Measured: a typical round

Round = a two-line whitespace edit to `samen_core/lib/samen/custom_fields.ex` (a kernel module, 2 sabotage
patches touch it; no comment, logic-neutral), measured 2026-10-12 on the 10-core 16 GB dev machine, branch
`feat/adr-053-p4-docs` at e9332ab, other sessions running (load averages are `uptime` before each run). Calls
= tool calls (each ≤ 600 s). "Warm" = the cache held a full `pr` PASS of the unedited tree.

| Measurement | Calls | Wall | Load (1 min) |
|---|---:|---:|---:|
| `scripts/ci quick`, warm (19 steps selected, only the edit new) | 1 | 197.5 s | 7.9 |
| `scripts/ci quick`, no change | 1 | 0.4 s | 15.7 |
| `scripts/ci quick --no-cache` (cold) | 1 | 242.4 s | 11.4 |
| `scripts/ci pr`, warm after the edit (the gen probes re-run: serial, ≈ 370 s) | 2 | 438 + 270 = 708 s | 15.7 |
| `scripts/ci pr`, no change | 1 | 0.6 s | 11.4 |
| `scripts/ci pr --no-cache` (cold, all 47 steps) | 2 | 534 + 568 = 1102 s | 16.4 |

Before (ADR-053 §1.1, measured at P1 step 0, same machine): the serial sum of the 46 `pr` steps was 1086 s
cold-ish / 1089 s warm; the old `./ci.sh` ≈ 13 min and could never fit one 600 s call (every agent
hand-segmented it, ≥ 3 calls, ranges drifting), old `./ci-fast.sh` 174–195 s with no diff-awareness, no
caching (a docs-only fix re-ran everything) and no verdict. Sabotage corpus: serial ≈ 79 min
(estimated from per-patch timings; ≈ 4 h wall-clock hand-chunked in ADR-052) vs 51 min through the budgeted
driver (35 min of lane time, 3–4 lanes under load, P3).

| | Before | After |
|---|---|---|
| inside a round | `./ci-fast.sh` 174–195 s, everything | `quick` warm ≈ 3.3 min for a kernel edit; ≈ 0.4 s when nothing changed; a vertical-only edit selects only that vertical |
| before a PR | `./ci.sh` ≈ 13 min, hand-segmented | `pr` cold 18 min / 2 calls; warm after a kernel edit 12 min / 2 calls; no change 0.6 s / 1 call |
| failure | thousands of log lines | digest + `_ci/logs/<id>.log` + `last.json` |
| full sabotage corpus | ≈ 79 min serial / ≈ 4 h by hand | 51 min budgeted (N lanes), nightly sliced in 24 on Actions |

Read the table honestly: the cold paths are not faster. `quick` after a KERNEL edit (≈ 3.3 min) is no faster
than the old `./ci-fast.sh` (2.9–3.25 min) — it runs every dependant app plus `sabotage --changed`, where
`ci-fast.sh` ran spikes, samen_core and samen_web only — and a cold `pr` (18 min) is slower than the old
`./ci.sh` (≈ 13 min) because `pr` runs more (`sabotage`/`mutate --changed`, the selection and driver
self-tests). The win is that every call fits a tool call and resumes, nothing unchanged is paid for twice, a
vertical-only or docs-only edit costs only what it touches, and the verdict is one machine-readable line.

GitHub Actions (`gh run list --workflow pr.yml`, `ubuntu-24.04`, 4 vCPU, `-j 2` per job; wall = created →
updated): cold caches 16.8 min (P2's first run, 38084336919 — it FAILED with 15 of 18 jobs green, so read it
as a floor); warm, small PR 9.0 min (run 38262212285; longest jobs gen_probes 516 s, samen_core 474 s); a PR
whose diff touched ≈ 53 driver-guard patches 30.1 min (run 38307973704: `sabotage_changed` 1785 s, one job,
serial on Actions); a PR with cold dialyzer PLTs 25.4 min (run 38248251069: dialyzer jobs 805–1500 s). Nightly
(`gh run list --workflow nightly.yml`): cold 32.0 min (47 jobs incl. queueing), warm 14.9–23.6 min (four
runs: 14.9, 15.7, 20.6, 23.6). No scheduled (`schedule`) nightly had run yet when measured: the cron only
fires from `main`, so the first one also seeds the default-branch caches.

**P5 (2026-10-13, same machine, branch `feat/adr-053-p5-followups`; `uptime` 1-min load in brackets).** The four
gen probes, `scripts/ci pr --only gen_probes --no-cache --budget 0`: serial (flagship 163.3 s + post 105.7 + deploy
79.0 + agent 5.2) **353.8 s** [2.6 → 8]; flagship/post/deploy concurrent on private registry copies **351.2 s**
[5.5 → 13: flagship 339 s, post 271 s, deploy 237 s: other sessions and a 6-core VM held the cores, so the three
probes (CPU-bound: generated-app dependency compile + test suite) just shared them]; the same concurrent run in a
scratch worktree **215.5 s** [6.2]. Concurrency is correct and proven (isolation proven, two green concurrent runs plus the closing `pr`) but it only converts idle cores into wall-clock: on a quiet 10-core box expect the max of the three probes
(≈ 160-210 s), on a saturated one nothing. The next lever is per-probe CPU: each generated app compiles its own ≈ 62
dependencies (≈ half a probe) — sharing a compiled dependency cache between probes is the follow-up.
`sabotage_changed` on a branch that touches the driver (66 patches, 17 chunks): 5 calls cold (3 → 3 → 2 → 2 → 1
chunks; the plan re-chunked from 17 to 13 chunks mid-run and kept the 5 finished chunks — the old driver voided
them and needed ≥ 6 calls and lost ≈ 30 min in the P3 builder).

Where the time goes now: `pr` after a kernel `lib/` edit is dominated by the three probes' dependency compile and
test suites, then samen_core's tree-wide keys; a test-only edit no longer re-runs the probes or any dialyzer step.

## 12. Troubleshooting

| Symptom | Do |
|---|---|
| `INCOMPLETE k/n` | not a failure: `scripts/ci resume`, repeat. It never says PASS until every planned step is done. |
| `FAIL step=<id>` | read the digest, then `_ci/logs/<id>.log`; fix; re-run the same command. |
| `FLAKY … (passed on rerun)` | the run FAILS by design. Find the nondeterminism (sandbox ownership, ordering, timing); a flake that reproduces only in a full suite is an ordering bug. Known class: a test whose sandbox owner exited before an async insert (`aud_event`) or an `on_exit` call — `** (EXIT) shutdown: "owner … exited"`. Use `Samen.TestSandbox.shared!(Repo)` (a dedicated owner that outlives the test process); the raw `Sandbox.mode(_, {:shared, _})` is forbidden by `Samen.TestSandboxGuardTest`. Second class: a module that leaves the pool in `:auto` (no owner, so nothing ends it) puts every later sync module on an unsandboxed pool until something resets `:manual` (issue #103); the seed does not fix sync-module order, so reproduce by running the two modules together until the order flips. A test that must commit uses `Samen.TestSandbox.auto!(Repo)`; the raw `Sandbox.mode(_, :auto)` is forbidden too. |
| `{:error, :already_up}` / `MatchError` in a test helper, CI bootstrap script or probe, or `Samen.TestDb: could not drop database …` | Symptom seen once on Actions (`ci (app_demo)`): the old helpers discarded the drop's result (`_ = storage_down`), so the cause was never recorded. Two candidates fit: (1) a live session still attached (SQLSTATE 55006), (2) a slow `DROP DATABASE` that `storage_down/1` abandoned after its 15 s client timeout while the server was still dropping, so the next `CREATE DATABASE` saw the old catalog row. Never `storage_down` + `:ok = storage_up` by hand, never `mix ecto.drop … \|\| true`, never a sleep/retry, never `WITH (FORCE)` (it would silently kill another checkout's run on the same database name): use `Samen.TestDb.reset!(config)` / `drop!(config)`. They wait for the server's answer (no client timeout; the step budget bounds it) and raise with the real Postgres error. If a session is attached, the error lists it (pid, role, `application_name`, client address, state, age) and kills nothing: that is another checkout/worktree running this app's tests on the same database name (set `SAMEN_TEST_DB_SUFFIX`), or a psql/iex session. They refuse a database whose name is not `<words>_test[N]` (plus `_lane<N>` / `_<tag>_<N>` scratch suffixes or `_downcheck_<hex>`), and any call without Mix loaded. `Samen.TestDbGuardTest` fails the old patterns (and `ecto.drop`/`dropdb` `\|\| true`) anywhere outside `spikes/`. |
| result looks stale | `scripts/ci explain <step>` (key, inputs, CACHED?); prove with `scripts/ci pr --no-cache`. Failures are never cached, so a stale GREEN means undeclared inputs: fix `inputs`/`reads`. |
| `role "…" does not exist` | the suites connect as `$USER`/`$PGUSER`: `psql -d postgres -c '\du'` lists roles; export `PGUSER` to one that exists (superuser-capable). Never hardcode a role in a migration or test. |
| `pgvector not installed` | `brew install pgvector`, then `CREATE EXTENSION vector` works in your server. |
| `NOT PR-READY: base origin/main is missing` | `git fetch origin main` (or pass `--base`). |
| `apply_check` / `double_sweep` red on a patch | `scripts/sabotage reanchor <n>`; if refused, regenerate with `sabotage new`. |
| `counts` red | `scripts/counts --write`, commit the CLAUDE.md change. |
| `docs_check` red | the line names the file, line and missing command/step/path; fix the doc. |
| `no_local_paths` red | the line names the file and the local path; replace it with the file's GitHub URL (or describe a file that was never published). |
| lane leftovers | lane trees `.git/samen-lanes/<b|c|d>` are kept on purpose (warm `_build`). Drop them with `git worktree remove --force .git/samen-lanes/b` (then `git worktree prune`) and the `*_lane<k>` databases with `psql -d postgres -Atc "select datname from pg_database where datname ~ '_lane[0-9]+$'"` → `dropdb <name>` per row. Never while a replay is running. |
| a chunk passed earlier is re-running | its inputs changed (any edit re-keys a `**` step), or `--no-cache` was given: a rising per-item rate alone no longer voids finished chunks (§3, `_ci/partition/`). |
| patch N fails once under lanes, passes alone | the lanes print `scripts/sabotage.sh --range N-N` to re-check it alone; a flaky guard still fails the run — fix the timing dependence (patch 368 is a known compile-vs-run race). |
| a gen probe is slow, or you suspect its dependency cache | each probe prints `gen_deps_cache: HIT|MISS|STORED|CORRUPT …` in `_ci/logs/<probe>.log`. `rm -rf ~/.cache/samen/gen_deps` (or `python3 scripts/gen_deps_cache.py clear`) forgets every entry; `SAMEN_GEN_DEPS_CACHE=off scripts/ci pr --only gen_post_probe --no-cache` proves a result without it. A stale entry cannot be served (a different lock/toolchain/env/dependency config is a different key; a damaged entry fails its MANIFEST check), so this is for disk space or curiosity, not correctness. |
| a run is "stuck" | another driver holds the lock (a concurrent driver is refused); `scripts/ci status`. Never start a second one beside it. |

## 13. Known limits and follow-ups

- samen_core's own suite keys on the whole tree (`reads = **`); the gen probes and dialyzer steps re-run on any
  kernel `lib/` edit (but no longer on a test-module-only edit).
- The three concurrent gen probes are CPU-bound. Their hex dependencies are cached (§4, P6); what stays cold on
  every run, by design, is `samen_core` + `samen_web` + the generated app (≈ 12 s alone, more under load), the
  probe's own `ci.sh`, its sabotages and boot checks.
- `sabotage_changed` is one job on Actions and there it uses the plain harness, so its chunks are cost-weighted
  only from item costs learned on that runner (Actions starts cold: unknown items are priced at the old per-item
  rate). Per-item costs live in `_ci/timings.json` on the machine that ran the replay.
- Mutation shards are sized by count (`modulo`), not by cost.
- Only samen_core's scratch databases got the lane suffix; the PITR drill databases of demo/driftwood
  (`samen_pitr_drill*`) are not touched by any sabotage today.
- `reanchor` needs the patch's pre-image blob in the object database and does not handle
  create/delete/rename patches.
- Branch protection (require `ci-pr`) is the operator's call.
