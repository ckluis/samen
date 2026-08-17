# P17 — Tenant-own-org analytics: design brief (office-hours record)

- **Status:** DESIGN-ONLY — problem/context/options + a recommendation for the operator to decide. Authors no product code. Touches no `lib/`, `test/`, `config/`, schema, sabotage, or abbrev registry.
- **Date:** 2026-08-17
- **Decider:** operator (Chris). This is the ADR-045 §3 "P17 remains a **build-or-defer decision for the operator**, not a defect" item, brought to office hours.
- **Binding constraints (must not be re-litigated here):**
  - **T144** — the operator-only cross-tenant analytics gate. ADR-045 §3 is explicit: whatever P17 does, it **"must not weaken T144: the gate refuses tenant actors *and* impersonation before any row is read, and any tenant-facing analytics surface has to be built as a separate, org-scoped path rather than by relaxing that gate."**
  - **INV-7** — no PII egress (the two-plane masking/egress invariant).
  - **ADR-046** — erasure completeness (a shredded subject must not survive in any derived/aggregate row).

---

## 1 · PROBLEM — what P17 is, in the operator's terms

A tenant wants **aggregate insight over its *own* org's data** — "how many contacts converted this quarter," "MRR by plan across my accounts," "ticket volume by category" — **without any surface exposing an individual subject's PII**. This is the *intra-org* twin of the cross-tenant operator analytics we already ship (`Samen.AI.Analytics` / `Samen.Aggregate`, gated operator-only by T144).

The demand is real for a B2B SaaS: adopters expect a dashboard/"ask" box over their own book of business. But the naive build — "just let the tenant run the aggregate reads" — is a trap, because **the existing aggregate plane is org-less by construction and T144 refuses tenant actors**. So P17 is not "expose the existing plane to tenants"; it is "**design a new, org-scoped aggregate path that reuses the shipped privacy floor without touching T144.**"

The crisp use-case that decides everything (see §5, Q1): **is the consumer the org OWNER (who already sees own-org PII in the clear), or a LOWER-privilege tenant role** (an analyst/`:member` who is subject to `••••` masking)? Only the second case makes analytics worth its risk — and it is also the *only* case where the privacy floor earns its keep.

---

## 2 · CONTEXT & CONSTRAINTS — tied to the real code

### 2.1 · The existing machinery, and why it does NOT already solve P17

We already have a complete, shipped **token-blind aggregate plane** — but it is **cross-tenant and org-less**, mutually exclusive with the tenant plane in both directions:

- `Samen.Aggregate.read_all/2` (`samen_core/lib/samen/aggregate.ex`) reads as the singleton **org-less** `Samen.Aggregate.Actor` (no `org_id`). `Samen.Policy.OrgScope` (`org_scope.ex:47`) filters an actor with **`nil` org_id to `expr(false)` → zero rows**, and `Samen.Policy.AggregateActorOnly` refuses every non-aggregate actor. So a tenant actor cannot read the aggregate plane, and the aggregate actor cannot read the tenant plane. **P17 cannot ride this actor.**
- `Samen.AI.Analytics.ask/4` (`samen_core/lib/samen/ai/analytics.ex`) is the NL narration surface — and its **T144** gate (`platform_caller?/1` → `platform_actor?/1`) **denies every tenant member and every impersonation session, fail-closed, before any row is read.** Sabotage `55-t144-ai-analytics-caller-authz-bypass.patch` proves that gate is load-bearing; `52-t71-ai-analytics-aggregate-suppress-bypass.patch` proves the suppression under it is load-bearing.

**What IS reusable — and this is where P17's value lives — is the *output-privacy floor pipeline*, which is decoupled from the actor question:**

- `Samen.Aggregate.Privacy.apply/3` — enforced **k-anonymity + l-diversity** floors. Config `:k_anonymity_min_cohort` (**default 5**), `:l_diversity_min_distinct` (**default 2**). A cohort `< k` (count-of-one included) or `< l` distinct-sensitive has its value columns REPLACED by `%Samen.Aggregate.Suppressed{}`.
- `Samen.Aggregate.Suppressed` — the fail-closed cell: carries only the *reason*, **never the value**; renders `⊘` across `String.Chars`/`Inspect`/`Jason`. It is the aggregate-plane analogue of `Samen.Masked`.
- `Samen.Aggregate.CohortSpec` — per-resource "what is a cohort" declaration; a `nil` spec is a **fail-closed** `{:error, :no_cohort_spec}` (mask-unknown-by-default).
- `Samen.Verifiers.NoPiiColumns` (via `use Samen.Aggregate.Resource`) — **compile-time C7 gate**: an aggregate resource that declares a vault / `pii_attribute` / `pii_`-shaped column / a relationship reaching PII **does not compile**.
- `mix samen.verify.aggregate_privacy` — whole-app CI backstop: every aggregate resource must declare a fail-closed cohort spec with non-empty `cohort_count_column` + `value_columns`.
- `Samen.Aggregate.QueryBudget` (WARN-not-enforce scaffold, opt-in enforce T6.6) + `Samen.Aggregate.Dp` (opt-in Laplace, honestly *not* a composed ε-budget) — the cross-query layer, "posture under construction," not a solved proof.

### 2.2 · Why an aggregate is a covert channel (the real threat model)

Token-blindness is *input* privacy; it "says nothing about what the answers leak" (`Privacy` moduledoc). Within a single org, the classic aggregate attacks all reconstruct a **masked** value that a lower-privilege tenant role is not entitled to read directly:

- **count-of-1 cohort** → re-identifies one subject ("avg X where name=Y" with one member = Y's X).
- **min/max/sample-row** → surfaces a raw individual value verbatim under an "aggregate" label.
- **diff-over-time / differencing** → two near-identical cohorts reveal the delta = one subject.

This is exactly why P17's floor is not decorative: **within an org, k-anonymity protects a `••••`-masked sensitive value from being reconstructed by a tenant role that can enumerate the cohort key but is not entitled to read the value** through `Samen.Api.PiiResolution`. The floor is the intra-org enforcement of the same two-plane masking rule (`Samen.MaskingCase`, the operator-without-grant `••••` rule) — projected onto the *output* plane. If the only consumer is the org owner (who already resolves own-org PII in the clear — the "tenant-as-owner rule," `identity/invite.ex:450`), the floor protects nothing the consumer can't already see, and P17 buys risk with no benefit. **The role question (§5 Q1/Q3) is therefore the gating decision, not a detail.**

### 2.3 · INV-7 interaction

INV-7 ( `egress_opts` `Keyword.take` allowlist + `grant_egress?: false` pinned LAST + no `vt_*` token to any provider) governs the **AI narration** path, if P17 grows an "ask over my org" box. Two facts keep it intact **provided P17 reads a vault-excluded projection or floored aggregates only**:

1. The narration input is bounded scalars + the `Suppressed` sentinel — "catalog-derived / already-governed context" (§3.2), with no vault-routed field to bind through `PiiResolution`. `Samen.AI.Analytics` already demonstrates this shape.
2. If narrated, it must route through `Samen.AI.Chokepoint` like any other AI surface (`grant_egress?: false`, the `vt_`/shape scrub still runs). A tenant-analytics path that let a raw vaulted column into the projection would be an INV-7 violation *and* a masking violation — which is exactly why v1 must inherit the C7 `NoPiiColumns` compile-time refusal (§4), not hand-roll its own column filter.

### 2.4 · Erasure interaction (ADR-046) — the sharpest constraint

`Samen.Erasure.shred/2` is **key-destruction, not copy-chase**. For *derived* rows it runs a separate **rollup-governance** step (`erasure.ex:299`, `Samen.Rollup`): each **registered** rollup takes the **rebuild** arm (recompute subject-free) or the **suppress** arm. The post-shred oracle **fails closed if any registered rollup was not governed** (`no_plaintext_pii/tiers/post_shred/db_content.ex:246-259`, "an absent rollup is an ungoverned aggregate gap"). The demo dogfood (`demo/test/rollup_dogfood_test.exs`) proves an erased subject does **not** survive in `rol_daily_event_count` after shred.

The consequence for P17 is a hard fork:

- A **live, at-query-time** aggregate over current tenant-plane rows is **derived-safe for free**: an erased subject's vaulted values are undecryptable, `non_pii!` columns are redacted, domain rows may be deleted — so they contribute nothing to a fresh count.
- A **materialized/precomputed** tenant-analytics store is **only safe if it is a registered `Samen.Rollup` spec** so `shred/2` governs it. An ad-hoc analytics summary table that is *not* registered would **resurrect an erased subject** → ADR-046 violation, caught (if at all) only by the post-shred oracle. **v1 must not introduce an ungoverned precomputed store.**

### 2.5 · The T144 boundary, restated as a build rule

P17 is **a new, separate, org-scoped path**. It must not touch `Samen.AI.Analytics.ask/4`'s `platform_caller?/1`, must not admit a tenant actor or impersonation session to the cross-tenant plane, and must not relax `AggregateActorOnly` / the org-less `Aggregate.Actor`. Any relaxation of those is out of scope by ADR-045 §3 fiat.

---

## 3 · OPTIONS

### Option A — Org-scoped aggregate plane (mirror the cross-tenant one, partitioned by org)

**What it is.** A new sibling to `Samen.Aggregate` — call it an **org-scoped read surface** (`Samen.Aggregate.read_all_for_org/3` or a thin `Samen.OrgAnalytics` module) that runs as the **tenant's own org actor** (so `OrgScope` narrows to their org, never cross-org) over **vault-excluded, org-partitioned projections** (`rol_*`/summary tables carrying an `org_id`, no `pii_` columns — same `use Samen.Aggregate.Resource` C7 refusal). It then routes every row through the **exact same** `Privacy.apply/3` floor pipeline with a **within-org cohort spec** (cohort = subjects in *this* org sharing the cohort key). Optional NL narration reuses `Samen.AI.Verbs`/`Chokepoint` unchanged.

**Invariants.** T144 **untouched** — this is the separate org-scoped path ADR-045 §3 demands, not a relaxation. Masking respected: the C7 compile-time `NoPiiColumns` guarantees no vault column is reachable; the floor protects masked values from lower-priv roles (§2.2). INV-7 intact (§2.3). Erasure: projections are **registered `Samen.Rollup` specs** → governed on shred (§2.4).

**Where it lives.** `samen_core/lib/samen/aggregate/` (new read surface) + org-partitioned aggregate resources; tenant surface in `samen_web` behind `Samen.Web.TenantRole` (role gate). Gated by an extended `mix samen.verify.aggregate_privacy` (org-scoped arm) + the C7 verifier + new sabotage arms (§4).

**Cost / complexity.** Low-to-moderate. Reuses ~all of the shipped floor machinery; the genuinely new code is (a) the org-scoped read wrapper, (b) org-partitioned rollup projections + their registration, (c) the role gate. No new privacy primitive to design.

**Risk surface.** The org-partition boundary (a projection or read that forgets `org_id` leaks cross-org) and the role gate (which tenant roles may query) — both are *known* seams with existing enforcement to lean on (`OrgScope`, `TenantRole`).

### Option B — Restricted aggregate query DSL the guard can prove safe

**What it is.** A small query builder that lets a tenant compose `GROUP BY` + `COUNT`/`SUM` over an **allowlist of bounded, non-vault columns**, each result floored by `Privacy.apply/3` at query time. A guard statically proves each emitted query is aggregate-safe (no `min`/`max`/sample-row, no vault-routed column projectable).

**Invariants.** T144 untouched (own-org only). The hard part is the **guard**: it must *prove* safety over a combinatorial query space, which is a much larger attack surface than fixed projections. Masking/INV-7 hinge entirely on the guard being airtight — a single provable-safe gap (a `min` that slips through, a joinable vault reach) is a raw-value leak.

**Where it lives.** New `samen_core` DSL + a verifier arm proving no vault column is ever projectable and no non-aggregate shape is emittable. Substantial.

**Cost / complexity.** High. The guard is the whole ballgame and the whole risk.

**Risk surface.** Largest of the options — every added DSL capability is new proof obligation. Wrong first move for v1.

### Option C — Differential-privacy noised aggregates

**What it is.** Layer `Samen.Aggregate.Dp` (already built, opt-in Laplace) over Option A's outputs.

**Invariants.** Doesn't change the T144/org boundary. But `Dp` is **honestly documented as *not* a composed ε-budget** — single-query noise only; the floor remains the real defence. Selling "differential privacy" on a single-query noiser over-promises.

**Cost / complexity.** Moderate on top of A; **weak ROI for v1** — it dresses up the floor without closing the cross-query gap (`QueryBudget` is the honest place for that, and it is WARN-not-enforce).

**Risk surface.** Reputational (over-claim) more than technical. A **v2 layer on top of A**, not a v1 primitive.

### Option D — Defer / don't build (with rationale)

**What it is.** Keep P17 as the ADR-045 §3 carried decision; build nothing now.

**Rationale.** The org owner **already sees own-org PII in the clear** (tenant-as-owner rule), so unless there is a named lower-privilege consumer (§2.2), analytics buys covert-channel risk with **zero informational benefit**. Every aggregate surface is attack surface. Deferring costs nothing today (the operator-plane analytics already exists for the *platform's* needs) and waits for a concrete adopter demand + a named role.

**Risk surface.** Product/competitive only — an adopter who expects a self-serve dashboard doesn't get one yet.

---

## 4 · RECOMMENDATION

**Build Option A, scoped tight — but gate the build on the operator answering §5 Q1 (is there a lower-privilege consumer?). If the honest answer is "only the owner," ship Option D and stop.** Option A is the only choice that reuses the entire shipped floor pipeline, respects T144 as a *separate* path (per ADR-045 §3), and has a bounded, known risk surface. B is a v2-or-never; C is a v2 layer; D is the correct answer if the role question comes back empty.

**k-anon default: k = 5, l = 2.** Reuse the shipped `:k_anonymity_min_cohort` (5) / `:l_diversity_min_distinct` (2) config and defaults verbatim — one knob across both planes, and 5 is the common k-anon floor already argued in `Samen.Aggregate.Privacy`. Within an org the cohort is "subjects in *this* org sharing the cohort key," and k=5 means no masked value is releasable for a group smaller than five of the org's own subjects. Flag per-field escalation as an operator decision (§5 Q2), but default one floor.

**New verifier / sabotage arms (house style):**

- **Verifier:** extend `mix samen.verify.aggregate_privacy` with an **org-scoped arm** — every org-scoped aggregate resource must (a) declare a fail-closed `aggregate_cohort_spec/0`, (b) carry an `org_id` partition column, (c) pass the existing C7 `NoPiiColumns` compile-time refusal. Keep the non-vacuity floor (empty discovery FAILS, per the A2/X9 lesson).
- **Sabotage `NNN-p17-org-analytics-cohort-floor-neutered.patch`** — `k: 1` admits a count-of-one cohort; a `Samen.MaskingCase` twin asserts a lower-priv tenant role gets `••••` on the field directly AND `⊘` on the count-of-1 cohort; the patch flips the floor and the masked value reconstructs → **leak detected** (`assert_leak_detected!/2`). This is the load-bearing proof that the floor *is* the intra-org masking enforcement.
- **Sabotage `NNN-p17-org-aggregate-reads-cross-org.patch`** — the org-scoped read drops the `org_id` narrowing / reads as an org-less actor; a positive-control test proves another org's rows appear → `OrgScope` regression caught.
- **Sabotage `NNN-p17-org-rollup-survives-shred.patch`** — an org-analytics rollup registered but not governed (or not registered at all) resurrects an erased subject; the post-shred DbContent oracle must fail → ADR-046 regression caught.

**Scope boundary — v1 DOES:**
- count/sum aggregates over bounded, non-vault columns, org-partitioned, read as the tenant's **own** org actor;
- `k=5`/`l=2` floored via the shipped `Privacy.apply/3`, `⊘`-suppressed cells;
- projections that are **registered `Samen.Rollup` specs** (governed on shred) **or** live-computed at query time — never an ungoverned precomputed store;
- gated behind a **`Samen.Web.TenantRole` role check** naming exactly which roles may query;
- optional NL narration through the existing `Samen.AI.Chokepoint` (`grant_egress?: false`).

**Scope boundary — v1 does NOT:**
- release min / max / median / sample-row / count-of-one values;
- ship a free-form query DSL (Option B);
- do anything cross-org (that stays T144 / operator-only, untouched);
- claim differential privacy (`Dp` stays opt-in research; `QueryBudget` stays WARN-not-enforce unless the operator arms it);
- expose analytics to roles below the named threshold, or weaken T144 / `AggregateActorOnly` / the org-less `Aggregate.Actor` in any way.

---

## 5 · OPEN QUESTIONS FOR THE OPERATOR

1. **Is there a real lower-privilege consumer?** Who is the analytics for — the org *owner* (who already sees own-org PII in the clear, making the floor moot and the risk unjustified → **defer**), or a *lower-privilege* tenant role (analyst/`:member` subject to `••••` masking, the only case where P17's floor earns its keep and the build is justified)? **This single answer decides A-vs-D.**
2. **k value and sensitive dimensions.** Accept **k=5 / l=2** (the shipped default, one knob), or should specific fields (salary, health-band, revenue) carry a higher per-field floor? A per-field floor is more code and more config surface.
3. **Which tenant roles may query analytics** (via `Samen.Web.TenantRole`), and is the intent specifically to give a masked role insight-without-PII? If yes, accept that every released aggregate is a *deliberate, floored* channel into masked data — is that trade worth it for the demand you see?
4. **Precompute vs live.** Accept the ADR-046 constraint (every analytics rollup registered as a `Samen.Rollup` spec so `shred/2` governs it), or restrict v1 to **live-computed aggregates only** (derived-safe for free, simpler, but no materialized dashboard performance)?
5. **Appetite / sequencing.** Is P17 worth a workstream now, or does it wait behind the erasure/gate-integrity backlog? ADR-045 already carries it as build-or-defer with no deadline.
