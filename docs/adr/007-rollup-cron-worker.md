# ADR-007 — Rollup refresh as a real AshOban cron worker vs a plain function

- **Status:** Accepted (decision: define the spec-registration bridge; DEFER wiring vertical
  rollups until a 3rd vertical confirms the Spec shape)
- **Date:** 2026-07-07
- **Task:** T6.1 (extraction retro, plan §7 Phase 6). Item **A5** in
  `docs/extraction-retro.md`; a Gate-5-flagged carry-to-P6 item
  (`docs/gate-5-report.md`: "rollup refresh is a plain function not an AshOban cron worker";
  `docs/claim-evidence.md` D1 CAVEAT).
- **Deciders:** opus (T6.1), grounded in `driftwood/reports/T5.3.md` ("honest residues") and
  the identical honest comment in `demo/lib/demo/aggregate/rebuild.ex` +
  `driftwood/lib/driftwood/{broker_rollup,aggregate/rebuild}.ex`.
- **Relates to:** T2.1 (`Samen.Jobs`, the Oban conventions), T2.3
  (`Samen.Rollup` / `Samen.Rollup.Spec`, the rollup framework +
  rebuild-or-exclude-on-erasure), `Samen.Jobs.RollupRefreshWorker`.

---

## 1 · Context — what the substrate already has, and what the verticals bypass

The doc's data-tier claim is: *"dashboards read a rollup, refreshed on a schedule — not a live
scan"* with an AshOban `trigger :refresh_rollup do … scheduler_cron "*/10 * * * *" end`
(`samen-foundry.txt` §data). The substrate **already implements this**:

- `Samen.Jobs.RollupRefreshWorker` — a real `use Oban.Worker` on queue `:rollups`
  (concurrency 2), wired into `Samen.Jobs.default_crontab/0` at `*/10 * * * *`. It calls
  `Samen.Rollup.rebuild_all/1` over every registered `Samen.Rollup.Spec`.
- `Samen.Rollup.Spec` — a declarative rollup descriptor (table, subject column, suppressed
  column, `{delete_sql, insert_sql}` rebuild pair, bounded columns) registered via
  `config :samen_core, :rollups`. **Three** subsystems share the one spec: the refresh worker,
  the erasure `rebuild-or-exclude-on-erasure` policy, and the `no_plaintext_pii` oracle tier.
- `demo` **wires the worker's crontab** in `demo/config/config.exs`
  (`{Oban.Plugins.Cron, crontab: [{"*/10 * * * *", Samen.Jobs.RollupRefreshWorker}]}`).

So the mechanism is present and load-bearing. What the retro found is that the **vertical**
rollups do not use it:

- `Demo.Aggregate.Rebuild` and `Driftwood.{BrokerRollup, Aggregate.Rebuild}` materialize their
  rollups with **plain functions the dogfood/test drives** — not registered `Samen.Rollup.Spec`s,
  not driven by `RollupRefreshWorker`.
- Both hosts carry the *identical* honest comment: *"In production this would be an AshOban rollup
  worker (like `Samen.Jobs.RollupRefreshWorker`); here it is a plain function."*

That identical comment in two hosts is the copy-paste signal: the gap is a **bridge**, not a
missing mechanism.

## 2 · Why the verticals bypassed the worker (the real gap)

`Samen.Rollup.Spec`'s `rebuild_sql` recomputes a rollup **from the raw append-only `aud_event`
tier** — that is the substrate's model (a rollup summarizes events). But the vertical rollups
summarize **domain tables**, not events:

- `Driftwood.BrokerRollup` recomputes `dbs_broker_summary` (per-org load-by-status + settlement
  net-payable) from `stl_settlement` / load tables, reproducing the `Samen.Context` reshape math
  in SQL.
- `Driftwood.Aggregate.Rebuild` / `Demo.Aggregate.Rebuild` recompute cross-tenant token-blind
  projections (MRR-by-tier, queue depth) from `bsb_subscription` / `stk_ticket` / settlement
  tables.

These are legitimate rollups, but their source is a **domain table join**, not `aud_event`. The
current `Spec` shape assumes an event-sourced rebuild and (via `raw_retained?/2`) an
`aud_event`-based erasure arm. Forcing the vertical rollups into today's `Spec` would either
misrepresent their source or require the erasure policy to understand domain-table-sourced rollups
— which it does not yet. So the verticals correctly took the plain-function escape hatch and named
it honestly rather than shoehorn a wrong Spec.

## 3 · The decision

**Define the spec-registration bridge as the target, but DEFER wiring the vertical rollups until a
3rd real vertical confirms the generalized `Spec` shape.**

The target design has two parts:

1. **Generalize `Samen.Rollup.Spec` to a `:source` dimension.** Today's specs are implicitly
   `source: :aud_event`. Add an explicit `source` (`:aud_event` | `:domain`) so a domain-sourced
   rollup registers its `{delete_sql, insert_sql}` recompute over domain tables, and the erasure
   arm chooses correctly: event-sourced rollups keep the existing `raw_retained?`-driven
   rebuild/suppress; domain-sourced rollups take a rebuild arm that recomputes after the domain
   rows are erased (the subject's driver rows are already gone post-shred, so the recompute is
   subject-free — exactly what `Driftwood.Aggregate.Rebuild` does manually today).
2. **Register the vertical rollups as Specs and drop the crontab in.** Once (1) exists,
   `dbs_broker_summary`, the load-volume and MRR projections register as `Samen.Rollup.Spec`s in
   the host's `:rollups` config, and the host wires `RollupRefreshWorker` into its Oban crontab
   (as `demo` already does for the worker itself). The plain-function `Rebuild` modules become thin
   shims over `Samen.Rollup.refresh/2`, or are deleted.

### Why defer part (1)'s implementation

- **Count = 2 hosts** (demo + driftwood), both mine → conservative default is extract-on-3rd.
- **The `:source` generalization is a real design commitment** on the erasure policy — the piece
  the substrate's whole crypto-shred guarantee rests on. Getting the domain-sourced erasure arm
  right matters more than getting it fast. A 3rd vertical with a *differently-shaped* domain rollup
  (not a settlement/subscription sum) is the cheapest way to confirm the `:source` dimension is the
  right abstraction and not a two-host coincidence.
- It is **not** a 50+ file change (it is `Samen.Rollup` + the erasure policy + tests), so the
  blast-radius argument is weaker here than for ADR-006 — but the *correctness* argument (don't
  rush the erasure arm) is stronger. Deferring to confirm the shape is the right call.

The honest interim, meanwhile, is exactly what the hosts do today and is **not a faked pass**: the
rollups ARE materialized (dashboards read `dbs_broker_summary`, never a live scan — the doc's
load-bearing claim holds), the refresh is just driven by a function the dogfood calls rather than a
cron tick. The crypto-shred game-day (T5.4) exercises BOTH erasure arms on a real driver-keyed
rollup, so the erasure behavior the target design must preserve is already proven.

## 4 · Consequences

**Positive**
- The target design is specified, so the T6.2 (PawChart thin slice) / T6.4 (generators) work has a
  concrete `Spec` `:source` extension to build against and a 3rd-vertical confirmation trigger.
- No premature commitment to a domain-sourced erasure arm before a 3rd vertical validates the shape.

**Negative / accepted**
- Until wired, vertical rollups are refreshed on demand (dogfood/test), not on the cron cadence —
  so a production deployment of a vertical would need the operator to schedule the refresh (named as
  the honest residue in `T5.3.md`, `claim-evidence.md` D1). Documented, not hidden.

**Neutral**
- The doc's read-side claim ("dashboards read a rollup, not a live scan") is **already met** — the
  rollup tables exist and are read; only the *refresh cadence* is the residue.

## 5 · Red paths

No code changed in this ADR (it is a design + deferral decision). The erasure behavior the target
design must preserve is already red-pathed and will gate the eventual implementation:

- `samen_core/test/rollup_test.exs` — the rebuild + suppress arms and the oracle-tier
  non-plaintext assertion (the existing framework).
- `driftwood` T5.4 crypto-shred game-day — BOTH arms on a real driver-keyed rollup: REBUILD (raw
  retained → recompute driver-free → post-shred count 0, no resurrection) and SUPPRESS (window
  archived → `drl_suppressed = TRUE`).

When part (1) lands, its red path is: **a domain-sourced rollup, after a subject's domain rows are
erased, recomputes to a subject-free summary (post-shred count 0) — and a sabotaged recompute that
still counts the erased subject FAILS the oracle** (the same rebuild-or-exclude-on-erasure
discriminator, extended to the `:domain` source).
