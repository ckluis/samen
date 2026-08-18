# Outward-claim sweep — the honesty capstone (K3)

**What this is.** Samen's internal claim-evidence ethos ([`docs/claim-evidence.md`](claim-evidence.md))
maps every *internal* guarantee to a proof. This document applies that same discipline to the
**outward face** — the surfaces a stranger reads before they read the code: the landing page
([`index.html`](../index.html)), the [`README`](../README.md), [`SECURITY.md`](../SECURITY.md),
and the two compliance docs ([`compliance-story.md`](compliance-story.md), this file).

**The rule.** Every externally-facing claim must trace to real evidence — a test, a verifier, an
ADR, a game-day, or an independent verdict under [`_orch/verify/`](../_orch/verify/). Where a
claim was unsupported, stale, or overclaimed, the claim was **fixed** (corrected or softened) —
never papered over with invented evidence.

**Sweep date:** 2026-08-17 · branch `saas-readiness-phase-1` (pre-merge) · tree over `68034a4`.

---

## 1. Headline result

- **Overclaim hunt (certification / audit / production deployment): ZERO found.** A
  case-insensitive scan of `index.html`, `README.md`, `SECURITY.md`, and `compliance-story.md`
  for the forbidden phrasings ("SOC 2 certified", "GDPR compliant" unqualified, "fully
  compliant", "audit-proof", "certified by", "out of the box compliance", "we are compliant",
  …) returns **no positive/unqualified hit**. Every occurrence of a compliance word sits inside
  an explicit **negation or honest-split context** ("**not** SOC 2 certified"; "Nothing here
  asserts that a system built on it **is** compliant"; the "Samen is **not**" column).
- **Pre-merge + not-certified caveats: PRESENT and PROMINENT** on both the landing page (the
  "honesty boundary" callout leads the compliance section) and `compliance-story.md` (the first
  block, before any capability table).
- **Corrections applied this sweep: 3** (stale sabotage count on the landing and README; stale
  ADR count in README) — all made the outward number **more accurate**, none softened a real
  guarantee.

---

## 2. Corrections applied (stale/inaccurate → fixed)

| Surface | Claim as found | Live truth | Fix |
|---|---|---|---|
| `index.html` (4 total-count sites) | "278 sabotages / patches" | `ls scripts/sabotages/*.patch` == **285** (L4/L6 shipped sab 285 after the index rebuild) | Corrected 278 → **285** at all 4 total-count sites. The `sab 276–278` citation on the tenant-analytics money-shot is a *specific patch-range reference*, not a total — left unchanged. |
| `README.md` (3 sites: L115, L151, L205) | "233 today / 233/233 flipped" | **285** patches | Corrected 233 → **285**. |
| `README.md` (L104) | "the 48 ADRs" | `ls docs/adr/*.md` == **49** | Corrected 48 → **49**. |

*Direction of every correction: the outward face was **understating** (fewer sabotages, fewer
ADRs than reality) — no overclaim was masking as an understatement. Undercounting is not an
overclaim, but the outward face should be accurate, so it was corrected.*

---

## 3. Landing page (`index.html`) — load-bearing claims → evidence

| Claim | Evidence | Status |
|---|---|---|
| 285 sabotages; each proves its named test fails when broken | `ls scripts/sabotages/*.patch` == 285; sabotage harness header contract (APP/TEST_FILES/MUST_FAIL) | SUPPORTED (corrected count) |
| 22-verifier fail-closed gate | `ls samen_core/lib/mix/tasks/samen.verify.*.ex` == 22 | SUPPORTED |
| Two-plane masking; `%Masked{}` is the default; `••••` to operator-without-grant | claim-evidence §B C2, §D E2/E3; MaskingCase | SUPPORTED |
| Crypto-shred reaches every tier; destruction oracle attests | claim-evidence §C D2/D3/D4; `erasure_completeness`; driftwood game-day | SUPPORTED |
| Propose-then-approve AI writes; requester ≠ approver DB CHECK; ADR-047 accepted | ADR-047 (ACCEPTED); `adr047-a4-write-approval-verdict.json`; `apv_distinct_party` | SUPPORTED |
| INV-7 no-PII-egress incl. EG2 remask | `adr047-a3-tools-eg2-verdict.json`; `ai_prompt_masking` | SUPPORTED |
| Multi-node exactly-once + failover (L4); backup-verify (L6) | `phase7-l4-l6-verdict.json` (3/3, 13/13) | SUPPORTED |
| Test counts: 2,786 kernel · 1,773 framework · 631 demo · 251 freight · 125 vet | `index-html-rebuild-verdict.json`: "internally consistent, plausible, not re-run this pass" | SUPPORTED-as-of-rebuild (see §5 note) |
| "This is a foundry on an open pre-merge branch, not a deployed product" (honest-edges) | true of the branch; recontextualizes every "live/port/HTTP 200" | SUPPORTED — the load-bearing honesty framing |
| **New** compliance-posture section — GDPR-relevant capabilities / supports your SOC 2 journey | each card cites a claim-evidence anchor or verdict; honesty-boundary callout leads | SUPPORTED — control-posture framing only, no certification claim |

---

## 4. README + SECURITY + compliance-story — spot audit

| Surface | Claim | Evidence | Status |
|---|---|---|---|
| README hero | PII masked by default; second-party, time-boxed, tenant-audited reveal; token-blind cross-tenant views | claim-evidence §A/§B; the "retired as false-by-construction" note on the stronger claim is itself an honesty marker | SUPPORTED |
| README claim table (13 rows) | each row cites a named test/verifier/probe | claim-evidence §J/§K/§L + the covering suites | SUPPORTED |
| README "Status & caveats" | not hosted, not on Hex, no stability promise; real infra locally simulated; fail-honest adapters | matches `SECURITY.md` scope + claim-evidence honest edges | SUPPORTED — strong honest framing |
| README suite-total table | 2606 / 1711 / 465 / 123 / 49 test counts | explicitly hedged: "treat exact counts as directional and rerun `mix test` for the live number" | HEDGED-OK (see §5) |
| SECURITY.md | "operates no production deployment"; adapters are fail-honest stubs "by design, not a vulnerability"; auth is host-owned | matches the fail-honest contract (ADR-014/024/026) and the two-plane governance claims | SUPPORTED |
| compliance-story.md | every "day one" row cites a mechanism + proof; "operator responsibility" rows make no Samen claim | grounded per row in claim-evidence / verdicts; honesty boundary leads the doc | SUPPORTED — control-posture, not certification |

---

## 5. Residuals (named, not fixed — and why)

- **README suite-total counts (2606/1711/465/123/49) diverge from the landing's counts
  (2786/1773/631/251/125).** Both are the same class of figure captured at different snapshots;
  README explicitly frames its numbers as *directional — rerun `mix test` for the live number*,
  which is the honest hedge. Re-deriving the exact live totals needs a full multi-suite run and
  was **not** done this sweep; inventing a reconciled number without running would violate the
  no-invented-evidence rule. Left as **HEDGED-OK**, divergence recorded here. *Recommended
  follow-up:* a future gate re-derives both surfaces' counts from one `mix test` pass.
- **Landing "15 verifiers green on first run" (PawChart context)** and the **PawChart
  3,284/33,640 LOC** figures are carried from an earlier gate; the `index-html-rebuild-verdict`
  already flagged them as minor/plausible/non-blocking. Not a certification/production concern;
  out of this sweep's honesty-capstone scope, noted for completeness.

---

## 6. Method

- Forbidden-phrase scan: `grep -rniE '<forbidden set>' index.html README.md SECURITY.md docs/compliance-story.md`
  → each hit read in context to confirm it is a negation/honest-split, not an assertion.
- Count verification: `ls scripts/sabotages/*.patch | wc -l` (285), `ls samen_core/lib/mix/tasks/samen.verify.*.ex | wc -l` (22), `ls docs/adr/*.md | wc -l` (49).
- Every capability statement in [`compliance-story.md`](compliance-story.md) traced to a
  claim-evidence section or a `_orch/verify/*.json` verdict before it was written.

*Companion docs: [`claim-evidence.md`](claim-evidence.md) (internal ledger) ·
[`compliance-story.md`](compliance-story.md) (GDPR/SOC 2 posture) · [`SECURITY.md`](../SECURITY.md).*
