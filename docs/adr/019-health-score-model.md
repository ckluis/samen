# ADR-019 — Composite, explainable per-tenant health score (compute layer, not a new PII surface)

- **Status:** Accepted (design; WS-B phase B4 implements).
- **Date:** 2026-07-13
- **Task:** WS-B / G17 — replace the single subscription-status health pill with a multi-signal, explainable score + account drill-down.
- **Deciders:** opus (WS-B design), grounded in `docs/gap-discovery/operator.md` G6 and the gate-noted health/dunning incoherence (`gate-operator-plane.md` follow-up #1: accounts health ignores past-due invoices Billing shows).

---

## 1 · Context

Health today is `Operator.Reads.health/1` — a single pill from subscription status (active→healthy, past_due→at_risk, cancelled→churned). The operator-plane gate itself flagged the incoherence: the pill ignores past-due invoices that the Billing surface shows. All the richer inputs (dunning, open/breaching tickets, seats, subscription state) are ALREADY assembled in `Operator.Reads` — the missing piece is a scoring + explanation layer, not new plumbing.

## 2 · Decision

**A composite `Samen.Web.Operator.HealthScore.score/1` over the already-assembled account row, returning an EXPLAINABLE `%HealthBreakdown{score: 0..100, band, factors: [%Factor{name, weight, value, contribution, explanation}]}`.** Four config-weighted factors: billing state (40), activity (25, from G12 `pae`, graceful `:unknown` when absent), support load (20), adoption (15). The breakdown is explainable by construction — each factor carries its raw value/weight/contribution/explanation, so the drill-down renders "why this score" without a second computation. A new operator LiveView `AccountDetailLive` at `/operator/accounts/:id` (declared in `samen_operator_routes/2`, inherited at 0 vertical LOC) renders the breakdown + MRR-movement timeline + tickets.

## 3 · Rationale

- **Pure compute over existing inputs** — highest joy-per-effort; no new substrate; fixes the gate-noted incoherence directly (past-due invoices now lower the score).
- **Explainable-by-construction beats a mystery number** — CSMs need to know WHY an account is at-risk; carrying the factor breakdown on the return value makes the drill-down free and the score auditable.
- **Health is NOT a new PII surface** — every factor input is a bounded count/enum/amount/timestamp; no name/email/freeform string enters the score or breakdown, so it needs no per-plane masking fork (it inherits the tenant-plane-clear posture of the accounts CRM it reads).
- **Graceful degradation decouples G17 from G12** — the activity factor is `:unknown` until G12 emits, so G17 ships and gates independently and gains fidelity when G12 lands.

## 4 · Consequences

**Positive** — a real, auditable health model; the drill-down surface CSMs live in; the health/dunning incoherence closed; verticals inherit at 0 LOC.

**Negative / accepted** — weights are heuristic (config-defaulted, tunable); the score is a signal, not a guarantee. Live-computed by default (no `hsc` rollup) — if per-page compute proves hot at scale, a materialized `hsc` snapshot is a phase-time option (abbrev reserved then, not now).

**Neutral** — cross-tenant health distribution is aggregate-only (see §5), reusing existing floors.

## 5 · Red paths

- **AC-G17-2:** an active-but-past-due account scores below an active-current one (the incoherence fix, as a test).
- **AC-G17-5 (masking):** the breakdown rendered on any plane contains zero plaintext PII and no `vt_` token leak.
- **AC-G17-6 (aggregate floor):** cross-tenant health-band distribution routes through `operator_aggregate` + a `CohortSpec` on `band`; a band with <5 accounts renders `%Suppressed{}` (probe: 4 at-risk → suppressed, 5th → count appears). The cross-tenant view NEVER bypasses the k-anon floor.
