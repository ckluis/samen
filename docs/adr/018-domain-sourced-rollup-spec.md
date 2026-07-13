# ADR-018 — Implement the `:source :domain` rollup Spec dimension now (resolving the ADR-007 defer)

- **Status:** Accepted (design; WS-B phase B2 implements). **Resolves the ADR-007 deferral.**
- **Date:** 2026-07-13
- **Task:** WS-B / G7 — the revenue-movement rollup is a domain-table-sourced rollup, which the current `Samen.Rollup.Spec` (implicitly `source: :aud_event`) cannot express. ADR-007 deferred this generalization until a 3rd vertical confirmed the shape.
- **Deciders:** opus (WS-B design), grounded in ADR-007 §3 (the deferred target design) and the live `Samen.Rollup` framework.

---

## 1 · Context — the ADR-007 defer and its trigger

ADR-007 defined the target: generalize `Samen.Rollup.Spec` with an explicit `:source` (`:aud_event | :domain`) so a domain-sourced rollup registers a `{delete_sql, insert_sql}` recompute over domain tables and the erasure arm chooses correctly. It DEFERRED implementation "until a 3rd real vertical confirms the generalized `Spec` shape," because (a) count was 2 hosts (both same author) and (b) the `:source` generalization is a real commitment on the erasure policy — the piece the crypto-shred guarantee rests on — and a 3rd, differently-shaped domain rollup was "the cheapest way to confirm the `:source` dimension is the right abstraction."

WS-B's `RevenueRollup` is exactly that trigger: a **movement-sum** rollup over the `mov` domain ledger (ADR-017), shaped differently from the existing settlement/subscription-sum rollups (`Driftwood.BrokerRollup`, the MRR-by-tier projections). It is the 3rd-vertical-shaped confirmation ADR-007 waited for.

## 2 · Decision

**Implement the `:source` dimension on `Samen.Rollup.Spec` now, and register `RevenueRollup` (abbrev `mrr`) as a `source: :domain` spec.** Today's specs become explicitly `source: :aud_event` (unchanged behavior). A `source: :domain` spec:

- recomputes its `{delete_sql, insert_sql}` over domain tables (the `mov` ledger), grain `(org_id, period_month, mov_kind) → sum(mov_mrr_delta_cents), count`;
- takes the erasure REBUILD arm that recomputes AFTER the subject's domain rows are erased — post-shred the subject's `mov` rows are already gone, so the recomputed period sums are subject-free by construction (exactly what `Driftwood.Aggregate.Rebuild` does manually today), with NO dependence on the `aud_event` `raw_retained?` check.

## 3 · Rationale

- **The trigger condition ADR-007 named is met** — a 3rd, differently-shaped domain rollup exists; deferring further would block G7 for no gain.
- **The correctness concern ADR-007 raised is addressed head-on** — the domain-sourced erasure arm is the load-bearing piece; its red-path (post-shred subject-free recompute; sabotaged recompute still counting the subject FAILS the oracle) is a first-class WS-B AC (AC-G7-7), gating the implementation exactly as ADR-007 required.
- **It unblocks the ADR-007 backlog** — once `:source` lands, the deferred vertical rollups (`dbs_broker_summary`, the MRR/queue projections) can register as Specs and drop the plain-function shims, closing the ADR-007 residue for the whole fleet.

## 4 · Consequences

**Positive** — G7's waterfall reads a cron-refreshed rollup, never a live movement scan (the doc's load-bearing "read a rollup, not a live scan" claim, now met for revenue). The `:source` abstraction is confirmed by a real 3rd shape. The ADR-007 vertical-rollup backlog becomes actionable.

**Negative / accepted** — a real commitment on the erasure policy (two arms by source). Bounded to `Samen.Rollup` + the erasure policy + tests (not a 50+ file change, per ADR-007 §3), and gated by AC-G7-7's red-path.

**Neutral** — existing `:aud_event` specs are unchanged (they default to the current arm); the change is additive.

## 5 · Red paths

- **AC-G7-6:** `RevenueRollup` refreshes via `RollupRefreshWorker`; the dashboard reads `mrr_revenue_rollup`, never a live scan.
- **AC-G7-7 (the erasure discriminator, extended to `:domain`):** after a subject's `mov` rows are erased, the domain-sourced rollup recomputes to a subject-free summary (the erased subject contributes 0 to period sums); a sabotaged recompute that still counts the subject FAILS the `no_plaintext_pii` / rollup oracle. This is the SAME rebuild-or-exclude-on-erasure discriminator the existing framework red-paths (`rollup_test.exs`, the driftwood crypto-shred game-day), now proven for the `:domain` source.
