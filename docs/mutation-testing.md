# Mutation testing (`scripts/mutate.sh`)

An opt-in, source-level mutation-testing harness. The sabotage harness
(`scripts/sabotage.sh`) proves the guards someone remembered to sabotage; this tool finds
the guards with **no proof at all**. For each target guard it parses out the mutable sites,
writes a mutated copy of the source, runs a **scoped** test command, and classifies:

| test command | outcome | meaning |
|---|---|---|
| **fails** (rc≠0) | **KILLED** | a test caught the change — the guard is proven |
| **passes** (rc=0) | **SURVIVED** | nothing asserts this guard — reported loudly |
| **does not compile** | **STILLBORN** | reported separately; not a kill, not a survivor |

It is **not** wired into `ci.sh` — run it by hand.

## Run it

```sh
scripts/mutate.sh                 # all built-in v1 targets
scripts/mutate.sh --only context  # only targets whose LABEL/FILE matches a substring
scripts/mutate.sh --list          # print the resolved target set and exit
scripts/mutate.sh --targets FILE  # load targets from FILE instead of the built-in list
scripts/mutate_test.sh            # the self-test (seconds; throwaway fixture, no DB)
```

Exit code: `0` = ran cleanly (tree restored), even if survivors were found (they are
informational). Non-zero = an operational failure (restore mismatch / dirty tree /
accounting mismatch) or an abort by signal (`130`). Every run ends with a reconciled line:

```
MUTANTS: generated <g>, run <r>, killed <k>, survived <s>, stillborn <b>[, skipped <n>]
```

with `g == r + n` and `r == k + s + b`. An abort names the mutants it did not run.

## The four operators

Declared in `scripts/mutate_ops.py` (`OPERATORS` registry + `OPERATOR_ORDER`). These are the
shapes this project actually shipped unproven:

1. **drop-conjunct** — `A and B` → `A` (and, symmetrically, → `B`). CF-17(c) exactly.
2. **flip-comparison** — `>`↔`<=`, `<`↔`>=`, `==`↔`!=`.
3. **force-guard** — an `if`/`unless`/`while` condition replaced by `true`, then `false`.
4. **tuple-arm** — a pattern-match arm's body replaced by a passthrough of what it bound
   (the `dispatch/4` / SILENT-FLATTEN shape).

**Add a fifth operator** by writing one function `op_<name>(lines, a, e)` in `mutate_ops.py`
and registering it in `OPERATORS` + `OPERATOR_ORDER`. The engine core does not change.

## Targets and the test mapping

Targets are a **config list** — one `|`-delimited record each:

```
LABEL | FILE | ANCHOR | OPS | TESTDIR | COMPILE | TEST
```

- **ANCHOR** is a Python regex that uniquely matches the target clause's opening line; the
  clause spans from it to the matching `end` at the same indentation.
- **TEST** is the *scoped* command whose exit status alone decides KILLED vs SURVIVED — it
  names only the test files that exercise the target, so one `mix test` per mutant stays fast.
- **COMPILE** must exit 0 for a mutant to be considered compilable (else STILLBORN).

The v1 built-in list lives in `builtin_targets()` inside `scripts/mutate.sh`:

| target | file | scoped test |
|---|---|---|
| `context_gate/6` | `samen_core/lib/samen/ai/agent.ex` | `mix test test/ai/agent_loop_test.exs` |
| `dispatch/4:complete` | `samen_core/lib/samen/ai/chokepoint.ex` | `mix test test/chokepoint_test.exs` |

`context_gate/6` is exercised by **no** test on main; the agent-loop suite drives the run
loop that *calls* it, so the harness surfaces which parts of the gate that suite incidentally
constrains and which — notably the second conjunct `foldable(views, lines) == []` — it does
not. Add the chokepoint / pii / egress guard set later by appending records; no code change.

## The non-negotiables it enforces

- **Byte-exact restore, sha-256 verified, on every exit path** including SIGINT/SIGTERM
  (trap over INT/TERM/EXIT). Each target is snapshotted before mutation and restored +
  re-verified after every mutant; the run ends with `git status` (scoped to the targets)
  clean, asserted.
- **The verdict reads the test command's status directly** (`cmd; rc=$?`); output is
  redirected to files so the captured status is the command's, never a pipeline's.
- **Processed-vs-generated accounting** that reconciles and names what an abort did not run.

## Caveat

A KILLED/SURVIVED verdict is only as trustworthy as the scoped suite's own determinism. The
`samen_core` test helper drops and recreates the Postgres test database on every `mix test`;
a flaky suite can therefore mis-report a mutant. The baseline gate refuses to run a target
whose scoped test is not green to begin with, but stabilise a flaky suite before trusting its
KILLED counts.
