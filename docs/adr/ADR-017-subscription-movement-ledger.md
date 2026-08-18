# ADR-017 — Subscription-change ledger via the StatusChange seam (not audit-event reconstruction)

- **Status:** Accepted (design; WS-B phase B1 implements).
- **Date:** 2026-07-13
- **Task:** WS-B / G7 revenue analytics — MRR movement attribution (new/expansion/contraction/churn/reactivation) needs subscription-change EVENTS that do not exist today.
- **Deciders:** opus (WS-B design), grounded in `docs/gap-discovery/operator.md` G1 ("needs subscription-change history — a small append-only ledger if not present") and the live `Billing.Subscription` blueprint (no status-change trail).

---

## 1 · Context

Snapshot MRR is a live sum over active subscriptions × monthly price (`Operator.Reads.platform_billing/2`). Movement decomposition is a diff over subscription state THROUGH TIME — two subscriptions both `active` at $99 carry no information about whether one is a new sale and the other a downgrade. **Movements require captured events.** Three candidate sources exist:

1. **`Samen.AuditEvent` (`aud` tier)** — captures system events (reveal/erasure/policy-denial), NOT general resource create/update, and carries NO before/after values. Reconstructing movements from it is impossible (the data isn't there) and would overload the compliance audit tier with product-analytics semantics.
2. **`Samen.WideEvent`** — a 7-day-TTL observability struct, not persisted, wrong shape for a durable financial ledger.
3. **`Samen.Notifications.StatusChange`** — an existing Ash `change` already attached to `Invoice` (`change({StatusChange, event_prefix: "invoice", statuses: [...]})`), proven in WS-A, that fires on create/update at the write boundary.

## 2 · Decision

**Capture movements with a dedicated append-only kernel resource `Billing.SubscriptionEvent` (abbrev `mov`), written by a new `Samen.Billing.SubscriptionMovement` Ash change attached to `Billing.Subscription` — modeled on the proven `StatusChange` seam, NOT reconstructed from the audit tier.**

The change fires on subscription create/update, computes the movement kind via a pure `Samen.Billing.MovementClassifier.classify(before, after)`, and appends one `mov` row carrying the SIGNED `mov_mrr_delta_cents` plus `mov_mrr_before_cents`/`mov_mrr_after_cents` so the ledger is self-contained and reconciles without re-joining price history.

`mov` is token-blind by construction: every column is a bounded id, enum, integer, or timestamp (no PII). It is `OrgScope`d and erasure-covered (subject-keyed on `mov_customer_id`, shreds via the standard rollup erasure arm).

## 3 · Rationale

- **The audit tier is the wrong home** — it is the compliance/tamper-evidence surface (reveal/erasure/policy), not a product-event log; it has no before/after and mixing financial movement semantics into it pollutes the hash-chained integrity claim.
- **The StatusChange seam is proven and framework-first** — Invoice already uses it; extending the same pattern to Subscription is low-risk, and verticals inherit emission at 0 LOC (the change is on the kernel blueprint).
- **Self-contained rows reconcile deterministically** — carrying before/after MRR on the row means the waterfall sums to the snapshot delta without a temporal price re-join (the ADR's load-bearing reconciliation invariant, R1).
- **Non-PII by construction keeps it on the aggregate plane** — `mov` mirrors cleanly through the CDC projection and feeds cross-tenant revenue tiers under the k-anon floors without a masking fork.

## 4 · Consequences

**Positive** — movements exist from install forward; the reconciliation red-path (R1) is testable; cross-tenant revenue rides existing aggregate floors; verticals inherit at 0 LOC.

**Negative / accepted** — pre-install history is absent. Mitigated honestly by `MovementBackfill.from_snapshot/1` seeding one synthetic `:new` movement per currently-active subscription (so day-one MRR reconciles); deeper history is DISCLOSED absent, never fabricated (design §7).

**Neutral** — a new kernel resource + one abbrev (`mov`); the change adds one write per subscription mutation (append-only, cheap).

## 5 · Red paths

- **Reconciliation (R1):** `opening_mrr + Σ(mov_mrr_delta_cents) == closing_mrr` over a seeded lifecycle; sabotaging the classifier to misattribute a movement makes the sum diverge → the test FAILS (AC-G7-4/5). The ledger is only trustworthy because it reconciles, and the test proves the reconciliation is load-bearing.
- **Erasure:** after a subject's `mov` rows shred, the domain-sourced revenue rollup recomputes subject-free; a sabotaged recompute still counting the subject FAILS the oracle (AC-G7-7, the rebuild-or-exclude discriminator extended to `:domain` source — see ADR-018).
- **Non-PII:** `no_pii_columns` + `sink_schema` green on `mov` (AC-G7-3).
