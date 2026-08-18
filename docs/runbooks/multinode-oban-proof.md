# Runbook — Multi-Node Oban Proof (L4 / T90)

> **What this proves:** the Oban job substrate is **safe under multiple nodes** —
> no double-execution, correct insert-time uniqueness, and correct
> leadership/failover — demonstrated on **two real BEAM nodes against one
> Postgres**, locally, with no cloud account. Local nodes satisfy spec §L4: Oban's
> coordination lives entirely in Postgres, so a two-node local cluster is the same
> mechanism as a two-node production cluster.

- **Task:** T90 (roadmap Phase 7, spec §L4). **Cloud validation** of the same
  topology on real infra is folded into L5's BLOCK (T91), credential-gated.

## What runs

`samen_core/test/multinode/oban_multinode_test.exs` boots two `:peer` nodes
(`mn_a@127.0.0.1`, `mn_b@127.0.0.1`), each with its **own** `Samen.MultiNode.Repo`
connection pool and its **own** producing Oban supervisor (`Oban.Peers.Database`
leadership + `Oban.Notifiers.Postgres`), against one dedicated database
(`samen_core_multinode_test`, migrated from the same migration set as the kernel
test DB — zero schema drift). Every node spawns and JOINS within the test's own
lifecycle; nothing is backgrounded and polled.

Three proofs (all must pass):

1. **Exactly-once fetch across nodes.** 120 DISTINCT jobs are enqueued split
   across both nodes; both nodes run producers. Each job appends one row to an
   `mn_exec` ledger keyed by job. Assertion: every key executed **exactly once**
   (no double-grab) and **both** nodes did work. This is Postgres
   `FOR UPDATE SKIP LOCKED` doing its job cluster-wide.
2. **Insert-time uniqueness (refutable).** The same `unique` job is enqueued 80×
   split across both nodes via `Oban.insert/2` → collapses to **one** execution. A
   NEGATIVE CONTROL (identical fan-out, no `unique`) fires many times — proving the
   dedup assertion is refutable, not a tautology.
3. **Reveal auto-revoke failover.** A real `Samen.Reveal.AutoRevokeWorker` job is
   scheduled at a grant's expiry on node A; node A is then **killed** before it can
   run. The surviving node B takes leadership, stages the scheduled job, and runs
   the revoke **exactly once** — `revoked_at` is set and there is **exactly one**
   `expired` audit row (no double side effect).

## How to run

```
SAMEN_MULTINODE=1 ./ci.sh          # runs it as the opt-in tier inside the full gate
# or, directly:
cd samen_core && epmd -daemon && SAMEN_MULTINODE=1 mix test test/multinode/oban_multinode_test.exs
```

**Opt-in by design** (`@moduletag :multinode`, excluded from the default `mix
test`): it needs a running `epmd`, Erlang distribution, and a dedicated
**non-sandbox** database, none of which belong in the fast inner-loop suite. The
default `./ci.sh` and `./ci-fast.sh` stay green without it; phase gates and the
final sweep run it explicitly with `SAMEN_MULTINODE=1`.

## Prerequisites

- `epmd` reachable (the ci tier runs `epmd -daemon` first).
- A local Postgres the current `$USER` can `createdb` on (same server the kernel
  suite uses). The harness drops + recreates `samen_core_multinode_test` each run,
  so the drill is repeatable.

## What would catch a regression

- Disable/weaken Oban's `SKIP LOCKED` fetch → proof #1 sees a key with two `mn_exec`
  rows (double-grab) and fails.
- Route `unique` jobs through `insert_all` (which bypasses uniqueness) or drop the
  `unique` option → proof #2's dedup assertion fails (the control already shows the
  non-unique fan-out firing many times).
- Break DB leadership (`peer: false`, so every node self-elects) → the scheduled
  failover job would double-stage / double-run and proof #3's "exactly one `expired`
  audit row" fails.

Because the guarantees here are enforced by Oban + Postgres (not by new
samen_core gate code), this item ships a **refutable proof/harness** rather than a
new sabotage patch: proof #2 carries its own in-test negative control, so the
harness is demonstrably able to fail.
