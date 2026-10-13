# Samen — house conventions (read before touching anything)

Elixir/Ash SaaS foundry. Layout: `samen_core` (kernel: vault/PII, policy, catalog, engines,
verifiers, generators) · `samen_web` (framework UI library: LiveViews, Mount/Plane, kit) ·
`demo` (dogfood host, API-only) · `driftwood` (freight vertical) · `pawchart` (vet vertical) ·
`spikes/` (frozen mechanism spikes). Design records live in `docs/adr/` + per-workstream
`docs/ws-*/{design,build-plan}.md` — consult the ADR before changing anything it governs.

## Code exploration — codemunch FIRST (MANDATORY, not optional)
Before you Read/Grep/Glob to orient yourself in this tree, use codemunch — this has been missed
repeatedly (agents keep defaulting to raw Read/Grep sweeps). The rule, verbatim and enforced in
`driftwood/CLAUDE.md`: your FIRST orientation action is `codemunch:explore`/`codemunch:search`/
`codemunch:fetch`/`codemunch:refs`, NOT a multi-file Read or a large-tree Grep. WHEN it fires:
reading >1 source file to understand something, or grepping/globbing any of `samen_core/`,
`samen_web/`, `driftwood/`, `pawchart/`, `demo/`, `docs/` for a symbol/caller/structure → route it
through codemunch first. A single grep for one exact string in one known file is fine; a *sweep* is
not — that is what codemunch replaces. See `driftwood/CLAUDE.md` for the full rules + decision tree.

## Suites / CI (local Postgres + pgvector required) — reference: `docs/ci.md`
Use the driver; never hand-segment `ci.sh`, never background a run and poll it (run each call in the foreground).
- `scripts/ci quick` during a round (diff-aware vs origin/main incl. untracked files; NEVER PR-ready) ·
  `scripts/ci pr` before a PR: each call is budgeted to 540 s, on `INCOMPLETE n/m` run `scripts/ci resume`
  until the last line is `CI(pr): PASS n/n … — PR-READY` · `scripts/ci full` = nightly/opt-in (whole corpus +
  watch-list; Actions runs it nightly). `./ci.sh` / `./ci-fast.sh` are unbudgeted wrappers over the same steps.
- A red step prints a digest + `_ci/logs/<step>.log`; `scripts/ci status` · `explain <step>` · `list pr`;
  verdict in `_ci/last.json`. Content-cached (`--no-cache` forces); a FAIL is never cached and a FLAKY test
  still fails the run — fix the flake. Steps live in `ci/steps.conf`; a step must declare every path it reads.
- Never weaken a gate, ledger, ignore-file or test to go green. CI compiles with `--warnings-as-errors`.
- Sabotages (`scripts/sabotages/*.patch`, header APP / TEST_FILES / MUST_FAIL): add one with `scripts/sabotage
  new` — `git add` your fix FIRST, make ONLY the sabotage edit unstaged, then run it. `MUST_FAIL` is a literal test
  name, never interpolated. A patch that stopped applying: `scripts/sabotage reanchor <n>`; never delete it.
  Replay: `scripts/sabotage.sh` (filters) / `scripts/sabotage-lanes.sh` (N lanes). Unfiltered runs need `scripts/ci full`.
- Counts are generated (`scripts/counts --write`, never by hand): <!--count:sabotages-->592<!--/count--> sabotages
  (driver red paths `scripts/ci_test.sh` <!--count:driver_sabotages-->496–598<!--/count-->), watch-list <!--count:watchlist_modules-->12<!--/count-->
  modules / <!--count:watchlist_mutants-->166<!--/count--> mutants, corpus <!--count:corpus_targets-->228<!--/count--> targets /
  <!--count:corpus_mutants-->3,960<!--/count--> mutants.
- Toolchain floor `.tool-versions` (Elixir 1.20.4 / OTP 29.1.1); the `toolchain` step fails on older — raise the pin
  when upgrading. Prerequisite: Postgres WITH `pgvector` (`brew install pgvector`; ADR-043 §7.1/M3) — else the
  samen_core suite fails at setup with "pgvector not installed".
- Tests needing a shared Ecto sandbox call `Samen.TestSandbox.shared!(Repo)`; a raw `Sandbox.mode(_, {:shared, _})` fails
  `Samen.TestSandboxGuardTest` (it made the test process the owner: the `owner exited` flake). A step may drop
  `<app>/test/*_test.exs` from its key only if it never runs ExUnit on that app (`NARROW` proves it).
- Dialyzer (`dialyzer_*` steps; `scripts/dialyzer_gate.sh [app…]`): a warning not in that project's
  `.dialyzer_ignore.exs` fails, and so does an UNUSED entry. Fix it or add it WITH its reason — never a bare
  entry. PLTs (`*/priv/plts/`) are gitignored — never commit them (#77).

## Mutation gate (ADR-049) — the converse question the sabotage corpus cannot ask
Sabotages prove the guarantees we CLAIM; the gate asks whether some OTHER change to the same file survives its
owning tests. `./scripts/mutate.sh` scores the tier-1 watch-list (`scripts/mutation/targets.tsv`; `--list`,
`--changed` runs in `pr`, chunk with `--shard i/n`); owning tests are declared ∪ derived (a proof file that never
names the module needs `# MUTATION_OWNS: <lib path>`). Ends `MUTATION GATE: ALL PASSED`.
- NEVER weaken it: baseline green before scoring; a kill is a NAMED test failure (a compiler refusal is
  `BUILD-REFUSED`, not a kill); byte-exact SHA-256 restore; an unexempt survivor fails the run; full report, then fail.
- Close a survivor by writing the test that kills it, or — only if the mutation provably cannot change behaviour —
  a `scripts/mutation/ledger.tsv` row (`EQUIVALENT` + proof, or `ACCEPTED_GAP` + `ref=`; rows are content-pinned).
  Never widen a target's owning tests to turn red green. Promotion: `--emit-patches <dir>` → write the test, fill
  `MUST_FAIL`, move the patch into `scripts/sabotages/`.

## Fail-honest adapter contract (ADR-014, ADR-024, ADR-026)
An unconfigured/unimplemented adapter NEVER returns `{:ok, _}` for work it did not do —
it returns `{:error, :not_configured | :not_implemented}`. Precedents: `Samen.Delivery.Smtp`,
`Samen.Files.Storage.S3`, the `--deploy` runtime raises on missing secrets. A stub that
claims success is the exact lie the gates sabotage-test for
(`samen_core/test/files_storage_test.exs`). Never "make it pass" by faking an ok.

## Per-plane masking tests (the masking watch-list discipline)
Every surface rendering a vault-routed (🔒) field ships THREE proofs — green: tenant plane
(and operator-with-grant) resolves plaintext; red: operator-without-grant renders `••••`,
NEVER plaintext, NEVER a `vt_*` token in DOM/CSV/API; sabotage twin: the mask assertion is
proven refutable (plane flip goes clear; a modeled leak IS detected). Use `Samen.MaskingCase`
(`use Samen.MaskingCase` — `resolve_on_plane/4`, `assert_plane_clear!/2`,
`assert_plane_masked!/2`, `assert_masked_dom!/2`, `assert_leak_detected!/2`). Reference
tests: `samen_web/test/samen/web/file_preview_masking_test.exs` (first consumer),
`samen_web/test/samen/web/notifications_masking_test.exs`. All reads resolve through
`Samen.Api.PiiResolution` on the actor's plane — never bypass it, never hand-mask.

## Chokepoints / guards (governed-by-construction — never weaken to make a test pass)
- Files: `Samen.Files.upload/3` is the ONLY path minting a `storage_key`;
  `Samen.Files.ChokepointGuard` structurally refuses direct creates/updates. Fresh files
  are `:quarantined` (fail-closed); promotion only via a clean scan (`Scanner.Reject` default).
- PII writes: through governed actions only — `Samen.Pii.WriteGuard` + `Samen.Vault.Change`;
  `Samen.Type.VaultField` is the last-line guard refusing raw plaintext.
- Reads: org-scoped (`Samen.Policy.OrgScope`) + keyset-bounded via the Reads helpers.
- Test infra ships in lib: `Samen.RedPath`, `Samen.Factory`, `Samen.MaskingCase` — every
  red-path pairs denial with a positive control (anti-tautology; a test that cannot fail is a bug).

## Abbrev registry — HANDS-OFF
NEVER add/edit rows in any `priv/abbrev_registry.json` by hand. Allocation goes through the
sanctioned allocator only (`mix samen.abbrev.reserve`, driven by `mix samen.gen.*`; ADR-023).
Any probe/script touching the registry must restore it SHA-256 byte-exact on every exit path
— INCLUDING an OS-level interrupt (SIGINT/SIGTERM), not just normal/error returns (T107).
Enforced by `run_gen_probe` (`scripts/gen_probe_guard.sh`) around each `samen_core/priv/gen_*_probe.exs` of the four
`gen_*_probe` steps: the probe works on a PRIVATE copy of the registry (`SAMEN_ABBREV_REGISTRY`), so flagship/post/deploy
run concurrently (`gen_agent_probe` stays serial) and the committed file is never written; the guard still snapshots it
and, in a trap covering SIGINT/SIGTERM/ERR/EXIT (SIGINT is not trappable inside the BEAM at all), verifies it
byte-identical — a difference is repaired from the snapshot and FAILS the probe. `GEN_PROBE_SHARED_REGISTRY=1` is the old
in-place mode, used only by the T107 interrupt harness. `Samen.AbbrevRegistry` refuses `SAMEN_ABBREV_REGISTRY` unless the
guard's companion `SAMEN_ABBREV_REGISTRY_GUARD` is set, and `scripts/ci` strips all three from every step — never export them.

## Framework-first, ≈0-LOC vertical mounts
Features live in samen_core/samen_web; verticals adopt via one router/macro call
(e.g. `samen_files_routes`) or a scope mount at ≈0 authored LOC. Never re-implement
framework behavior inside demo/driftwood/pawchart — that fails the leverage guard.

## Agents / process
Serialized agents: ONE deliverable per agent call, fan-out concurrency 1. Every phase ends
with an adversarial gate: sabotages flip named tests and revert byte-exact; suites + every
ci.sh green before/after. Phase commits follow `git log --oneline -5` house style.
