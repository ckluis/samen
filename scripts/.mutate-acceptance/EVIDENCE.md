# mutate.sh — acceptance evidence

Captured at origin/main (`0216ce8`) on branch `chore/mutation-testing`. Every artifact in
this directory is reproducible: re-run `scripts/mutate.sh` (v1 targets) and
`scripts/.mutate-acceptance/sigint-proof.sh`.

## 1. GROUND-TRUTH SURVIVOR (required)

`context_gate/6` in `samen_core/lib/samen/ai/agent.ex` is asserted by NO test on main.
Independent proof (`coverage-grep.txt`): `grep -rl context_gate samen_core/test` returns
nothing (rc=1), while the positive control `grep -rl defmodule samen_core/test` hits.

Running the engine on `context_gate/6` (`run-v1.log`), the CF-17(c) mutation is SURVIVED:

    >>> SURVIVED  samen_core/lib/samen/ai/agent.ex:1267  [drop-conjunct]
        drop-conjunct: keep LEFT, drop `and foldable(views, lines) == []`

That is exactly the second conjunct `foldable(views, lines) == []` being dropped — no test
kills it. The harness is more discriminating than "everything survives": the agent-loop
tests DO incidentally kill mutations that make the gate fire unconditionally
(drop-LEFT-conjunct, `>`→`<=`, force-`true`), because those break the run loop — but the
specific second conjunct, the `==`→`!=` flip, and force-`false` all SURVIVE. Result for the
target: 3 survived, 3 killed.

## 2. A KILL (required)

Demonstrated in-tree on the v1 targets themselves (`run-v1.log`) — no throwaway needed:

    KILLED    samen_core/lib/samen/ai/agent.ex:1267  [flip-comparison]  `>` -> `<=`
    KILLED    samen_core/lib/samen/ai/agent.ex:1267  [force-guard]  if condition -> true
    KILLED    samen_core/lib/samen/ai/agent.ex:1267  [drop-conjunct]  keep RIGHT, drop LEFT

The scoped test `mix test test/ai/agent_loop_test.exs` FAILS (rc≠0) → mutant KILLED,
proving the engine's exit-code handling detects a caught mutation. The self-test
(`scripts/mutate_test.sh`) also demonstrates KILLED / SURVIVED / STILLBORN on a fixture.

Full-run accounting (`run-v1.log`):

    MUTANTS: generated 9, run 9, killed 3, survived 6, stillborn 0

## 3. RESTORE PROOF

`sha-before.txt` == `sha-after.txt` for both targets (byte-exact), and
`git status --porcelain` of the two target files was empty after the run:

    agent.ex     f56c9a27…165202  (before == after)
    chokepoint.ex 7d449af3…dc12e  (before == after)

The engine re-verifies each target's sha-256 after every mutant and at the end, and asserts
`git status (targets) clean`.

## 4. SIGINT PROOF

`sigint-proof.sh` launches a run with the pause hook, waits until a mutant is LIVE on disk
(agent.ex sha ≠ baseline), sends SIGINT to the process group, and checks the result
(`sigint-run.log`):

    engine exit: 130          trap fired
    after sha == baseline     agent.ex restored byte-exact
    RUN STATUS: ABORTED (signal) + "NOT RUN (aborted before completion): 6 mutant(s)"

The abort is NAMED, never read as clean. The permanent version of this proof runs inside
`scripts/mutate_test.sh`.

## SELF-TEST

`scripts/mutate_test.sh` → 11 passed, 0 failed, in ~4.5s against a throwaway Elixir fixture
(no mix, no DB), covering KILLED, SURVIVED, STILLBORN, accounting reconciliation, byte-exact
restore, SIGINT trap-restore, aborted-status naming, and zero residue.

## Deliberately deferred

- The chokepoint/pii/egress guard set (files/chokepoint_guard.ex, pii/write_guard.ex, the
  egress scrubbers) is left for a follow-up: it is a config-list addition (append records to
  `builtin_targets()`), no engine change.
- `dispatch/4`'s 3 tuple-arm SURVIVORS are surfaced but their scoped tests
  (`chokepoint_test.exs`) are STRUCTURAL source scanners that do not execute the clause, so
  they cannot kill a behavior mutation — a note for whoever adds runtime dispatch coverage.
- Not wired into `ci.sh` (an open PR owns that file); shipped opt-in.
