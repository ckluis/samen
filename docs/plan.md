# Samen — Implementation Plan (v1)

**Date:** 2026-07-04
**Source of truth:** `~/Downloads/samen-foundry.html` (canonical combined doc, 2026-06-23). `samen-concept.html` (Zig-era) and `samen-foundry-thesis.html` are superseded and used only for scope-level object lists already restated in the canonical doc.
**Status of the project:** greenfield. The doc describes what must be built; **no code exists**. Every mechanism below is "to be implemented," not "exists." Where the doc itself marks something as posture-under-construction (the DP query budget) or a carve-out (trace-sink pseudonyms, `non_pii!`), the plan preserves that honesty rather than promising more.
**Execution model:** later sessions drive this plan via the Workflow tool. Every phase has a workflow spec (fan-out shape, subagent roster, verify stages, gate). A machine-readable task graph is at the end.

---

## 1 · Executive summary

Samen is a governed substrate for B2B SaaS on Elixir/Phoenix/LiveView/Ash 3.x/Oban/one-Postgres-per-product: six idioms (self-qualifying storage, machine catalog, PII vault, Postgres-as-engine, malleability ladder, two-planes-one-core) applied uniformly to every object in seven universal scopes, with a fail-closed verifier suite and a crypto-shreddable, externally-keyed PII vault as the load-bearing guarantees.

The plan builds it in **seven phases with hard adversarial gates**:

- **Phase 0 — Spikes.** Prove the five highest-uncertainty idioms in isolation before anything else: the Spark abbrev transformer, fragment single-table composition, catalog-in-migration-transaction, the vault/KMS/crypto-shred key hierarchy, and the `pii_reads` AST verifier. If any of these can't be made real, the architecture changes here, cheaply.
- **Phase 1 — `samen_core`.** The base macro, catalog, PII DSL/vault/mask/reveal-grant/shred, and the full five-verifier suite — each verifier shipped with red-path (must-fail) tests. Nothing ships without fail-closed proof.
- **Phase 2 — Engine & ops.** Oban conventions, the partitioned append-only event tier + rollups, expand/contract migration tooling with timeouts and the `contract_ready?` gate, PII-safe OTel observability, and the full **destruction oracle** (`no_plaintext_pii --subject --tiers all`).
- **Phase 3 — Universal scopes + malleability + external surface.** Identity first (proves the pattern), then a parallel fan-out of CRM/Billing/Marketing/CMS/Support/Primitives; Tier-0/1/2 of the ladder; the versioned public API + webhooks + `api_contract` verifier.
- **Phase 4 — Two-plane control plane.** Masked impersonation, second-party reveal grants, the token-blind aggregate actor + `NoPiiColumns` verifier, hash-chained tenant-readable audit + WORM anchor, break-glass deferred-anchor, k-anon/l-diversity floors. Ends with the heaviest adversarial gate in the plan.
- **Phase 5 — Reference vertical (recommended: Driftwood, freight).** One real SaaS end-to-end on the substrate — bounded-context renames, settlement billing reshape, both planes live — with crypto-shred and PITR game-days run against the real app. This is where the guarantees stop being claims.
- **Phase 6 — Generalize.** Extraction retro, a second-vertical thin slice to prove reuse, the LLM-grounding workflow, generators, optional ClickHouse CDC, and the DP/query-budget hardening track.

Model routing follows the rubric: **opus** for all design, security, verifier, and gate work; **sonnet** for spec-driven implementation, scaffold fan-outs, tests, and docs. Every phase gate is an opus find→independently-verify→sign-off workflow whose findings become fix tasks **inside that phase**.

---

## 2 · Architecture analysis & component inventory

Every component cites the doc passage that mandates it. Section names refer to the canonical doc's headings ("How it actually runs" = §runs, "The honest edges" = §limits, etc.). Legend: **[claimed]** = the doc asserts it as a property of the finished system; **[mechanism]** = the doc specifies concrete machinery (code, DSL, task names) that must be implemented as written; **[posture]** = the doc explicitly marks it as under-construction/carve-out.

### A. Foundation / DSL layer (`samen_core`)

| # | Component | Doc passage | Class |
|---|---|---|---|
| A1 | `use Samen.Resource` base macro — injects abbrev transformer + `Samen.Catalog` + `Samen.Pii` extensions, `id`/`org_id`/timestamps | §runs "one base macro wires the transformer + catalog + vault + verifiers"; §core code block | mechanism |
| A2 | **Abbrev storage transformer** (Spark, compile-time): `attribute :name` → stored `com_name`; every column carries its resource's 3-letter abbrev; abbrevs permanent/never-recycled | §"Self-qualifying storage": "a compile-time transformer projects it to com_name in the DB, CDC, logs, and catalog" | mechanism |
| A3 | **Single-table composition** via `base: Core.Person` — `Spark.Dsl.Fragment` folding attrs+pii into ONE resource → ONE physical table; explicitly NOT class inheritance, NOT Postgres `INHERITS`; FKs target composed resources, never fragments | §core "The proof — one base, many shapes" + the `Core.Person`/`Lumen.Patient` code block | mechanism |
| A4 | `Samen.Context` bounded-context DSL: `alias_resource` (kernel noun re-identified), `reshape` w/ Ash calculations (money reshaped); thin anti-corruption layer | §core `Lumen.Context` code block; "two of the three are bounded-context translations" | mechanism |
| A5 | Abbrev registry (collision check, permanence, ticker-like) | §"Self-qualifying storage": "no rename drift"; memory: "permanent/never-recycled like a ticker" | mechanism |

### B. Catalog

| # | Component | Doc passage | Class |
|---|---|---|---|
| B1 | `tam_table` / `fld_field` catalog resources, generated from `Ash.Resource.Info` introspection | §"A catalog for machines": "A generated data dictionary (tam_table/fld_field) names every object and field" | mechanism |
| B2 | Catalog rows written **in the migration transaction** (`INSERT INTO fld_field` inside the same `BEGIN…COMMIT` as the `ALTER TABLE`) | §runs code block: "the catalog is generated IN the migration transaction … atomic · fail-closed" | mechanism |
| B3 | Committed `schema.dict.json` artifact for LLM grounding | memory (v2 hardening); doc §llm "the agent grounds on … the resource-qualified catalog entry" | mechanism |
| B4 | CI linter rejecting code referencing uncatalogued columns / unknown `^[a-z]{3}_` names | §llm: "a CI linter rejects any reference to a column that isn't catalogued — a hallucinated field doesn't compile" | mechanism |

### C. Verifier suite (all fail-closed: non-zero exit on violation; §runs "3 · The build fails closed")

| # | Verifier | Spec (from §runs code block + §llm) |
|---|---|---|
| C1 | `mix samen.verify.catalog_parity` | column ⇄ `fld_field` row, **both directions** |
| C2 | `mix samen.verify.prefixes` | every column carries its resource abbrev |
| C3 | `mix samen.verify.pii_reads` | AST/Spark: a vault-routed value (keyed on the `pii do`/vault **declaration**, not column name) reaches a span/log/sink **only inside `:reveal`**. Explicitly a dataflow match, NOT a sound taint proof; laundered leaks are caught by the sink schema allow-list (J2). Scope-aware — "knows a declaration site from a sink, which a grep cannot." **No grep smoke check exists by design.** |
| C4 | `mix samen.verify.pii_classify` | heuristic name+value scanner over NEW plain-typed string/date columns; flags likely-PII names (ssn·dob·mrn·cdl·tax_id·email) and PII-shaped sample/seed values; fails build until declared `pii_attribute` OR cleared by **review-gated `non_pii!`** (2nd reviewer sign-off; forbidden on likely-PII string/date without review); every accepted override **registered in the catalog**. Flag-on-hit, not assume-all-strings-PII. |
| C5 | `mix samen.verify.no_plaintext_pii` | **the destruction oracle.** CI mode: token-only-downstream invariant across every projected tier (CDC mirror, rollups, matviews, app-log sink, `aud_event`, trace/event sink schema) + asserts `db_statement: :disabled`. Post-shred mode (`--subject <uuid> --tiers all`) orchestrates **three checks**: (1) DB-tier content scan (live·replica·cdc_mirror·rollup·audit·**registered_non_pii** — the override tier asserts row-level deletion/redaction ran); (2) backup/PITR-history scan (key absent from every DB tier + PITR history; key is external-KMS, never a Postgres row); (3) **KMS destruction attestation** (an attestation the oracle reads — the KMS is the system of record). Trace sink = **ingress-class** tier (schema-asserted token/pseudonym-only at write), not a content scan. |
| C6 | `mix samen.verify.api_contract --version v1` | schema-diff contract test; fails build on un-versioned **structural** break (field/type/route removal or narrowing); semantic breaks explicitly out of scope (§scale "external surface") |
| C7 | `NoPiiColumns` Spark verifier for the token-blind aggregate plane | §control: "an aggregate actor … whose resources have no pii_ columns at all"; memory CP-v2 fix (1) |

### D. PII vault

| # | Component | Doc passage | Class |
|---|---|---|---|
| D1 | Composite types (`Samen.Type.FullName/Emails/Phones` — Twenty-derived spec, re-implemented in Ash) as the PII-classification unit | §core person table; memory ("Twenty = a SPEC, not a dependency") | mechanism |
| D2 | `pii do … pii_attribute :field, Type, vault: :pii_name` DSL; composite fields route by vault name; scalar `pii_` fields carry the prefix; verifier keys on **declaration**, not name | §core "PII routing note" | mechanism |
| D3 | Vault tables (`pii_*`), FK tokens in domain rows, encrypted at rest | §"PII in a vault" | mechanism |
| D4 | **Per-subject key in an external KMS, outside the WAL/PITR surface** — "the per-subject key is not itself a Postgres row"; restore brings back ciphertext, never the key | §data (token-only-downstream paragraph); §limits erasure bullet | mechanism — **highest-risk design (R1)** |
| D5 | `%Masked{}` as the field's **normal value** (type-level fail-closed masking); plaintext only via one decrypt chokepoint; masked renders `••••` in UI/CSV/API/logs by omission | §control "masking is the field type's normal value — no CSV, API, or log path leaks by omission"; memory CP-v2 fix (3) | mechanism |
| D6 | `:reveal` action + grant model: `RevealRequest` → distinct-party approval (dual-control / tenant-gate / audited break-glass); DB `CHECK (granted_by <> requestor_id)`; `expires_at` (minutes-scale default); policy denies on `now() > expires_at` even if the row lingers; Oban auto-revoke job **scheduled in the same transaction** that writes the grant; no renew-in-place | §control "'Time-boxed' is a built mechanism, not an adjective" | mechanism |
| D7 | **Crypto-shred**: destroy the subject's external-KMS key → all vault-tokenized PII undecryptable across live/replica/backup-PITR/CDC/rollup/audit at once; tokens → dangling / SHREDDED sentinel | §data; §limits; §cto "erasure is provable" | mechanism |
| D8 | `non_pii!` registry (plaintext-at-rest by design; erased by row-level deletion/redaction; a tier the oracle scans) | §llm `pii_classify` paragraph; §limits carve-out (b) | mechanism |
| D9 | Mask-unknown-by-default: every field type must be classified or it defaults to PII | §limits "The privacy DSL is only as safe as its coverage"; memory v2 keystone fix | mechanism |

### E. Malleability ladder

| # | Tier | Doc passage |
|---|---|---|
| E1 | Tier 0 — config reference rows in fixed-schema system tables (~70% of customization, full guarantees) | §"A malleability ladder"; memory |
| E2 | Tier 1 — end-user custom fields: `xxx_custom jsonb` bag + `tnt_field` runtime metadata, validated-at-write | §core `per_custom jsonb — Tier-1 bag`; §limits "System is provable; tenant is best-effort" |
| E3 | Tier 2 — custom objects: `tnt_record` + `tnt_object`/`tnt_field` (Twenty metadata model, re-implemented; one-way boundary) | memory; §core PawChart "a VaccineLot object clinics define themselves" |
| E4 | Tier 3 — builder code-composition + bounded context (= A3/A4; "the top rung is a context boundary") | §"A malleability ladder" |

### F. Universal scopes (Ash domains; §"The inherited 80%")

| Scope | Objects (🔒 = vault-routed) |
|---|---|
| Identity | org · user🔒 · membership · role · api_key · invitation🔒 · audit |
| CRM | company · person🔒 · opportunity · pipeline · activity · attachment |
| Billing | customer🔒 · subscription · plan · price · invoice · payment · usage · entitlement |
| Marketing | campaign · segment · subscriber🔒 · template · send · email_event · suppression |
| CMS | page · post · block · media · navigation · seo_meta · content_version |
| Support | ticket · conversation · message🔒 · agent🔒 · sla · macro · csat |
| Primitives | notification🔒 · file · search · audit · webhook🔒 · feature_flag |

### G. Two-plane control plane (§"Running the business" + memory CP-v2)

| # | Component | Doc passage |
|---|---|---|
| G1 | Operator plane from the same objects: operator CRM (accounts = tenant orgs), ticketing, billing rollups | §control lead |
| G2 | **Masked impersonation**: operator session scoped to a target org, no reveal grant by default → `••••` | §control; §"Two planes, one core" |
| G3 | **Token-blind aggregate actor**: named actor, own default-deny domain, NO `org_id`, reads a vault-excluded projection where `pii_` columns physically don't exist; **mutually exclusive** with `:reveal` | §control "Two planes, two operator paths"; C7 verifier |
| G4 | Hash-chained, tenant-readable, operator-uneditable audit log; out-of-band WORM anchor; stores vault tokens + key-destroyable ciphertext only (immutable AND shreddable) | §control "Immutable and crypto-shreddable don't contradict" |
| G5 | Break-glass: locally-durable **deferred-anchor** audit (fsync'd append-only hash chain on the operator node, anchored on reconnect); reveal still requires a live KMS call; KMS down ⇒ fail closed; per-operator breadth budget + auto-suspend | §limits "'Can't log it ⇒ can't see it'" bullet |
| G6 | Aggregate privacy: k-anonymity min-cohort + l-diversity floors **enforced today**; global/per-cohort query budget + DP posture + t-closeness = **posture under construction** (per-actor accounting named as the wrong unit) | §control ∴ block; §limits "Token-blind isn't inference-blind" | 

### H. Jobs / events / data tier (§data)

| # | Component |
|---|---|
| H1 | Oban/AshOban: durable jobs, cron, same-transaction enqueue, SKIP LOCKED, per-queue concurrency limits |
| H2 | `aud_event` append-only event/audit tier: monthly RANGE partitioning, BRIN on time, detach-for-archival gated on erasure-relevant rollup window |
| H3 | Rollups/matviews refreshed by AshOban; dashboards read rollups, never raw scans; **rebuild-or-exclude-on-erasure** policy (rebuild where raw retained; suppress where archived) |
| H4 | Optional ClickHouse CDC (ClickPipes/PeerDB) mirroring token-blind rows; second Ecto repo (`ecto_ch`); opt-in per product, default off; never read "current" values from it |

### I. External surface (§scale "The external surface")

| # | Component |
|---|---|
| I1 | AshJsonApi/AshGraphql public API over the same resources; URL-versioned `/api/v1`; **opt-in allowlist** field exposure (default not-exposed); catalog names only, never storage names or vault routing |
| I2 | Two api_key classes: tenant-plane (org-bound, reads own PII per own RBAC, no grant) vs operator-plane cross-tenant (masked by default, crosses the reveal seam) |
| I3 | Webhooks: Oban-backed, at-least-once, capped exponential backoff, DLQ, per-event idempotency keys, HMAC body + timestamp signing (anti-replay), allowlisted masked payloads |

### J. PII-safe observability (§runs 4a–4d)

| # | Component |
|---|---|
| J1 | OTel tracing: one context from `mount/3` through LiveView event → Ash action → policy → SQL → vault reveal, **across the Oban boundary** (span id rides the job row); `OpentelemetryEcto db_statement: :disabled`; `:reveal` span attrs allow-listed to `subject_id, grant_id, reason`; server-side sampled `auto_explain` is the plan source (token-only by the same invariant) |
| J2 | Structured wide events: one canonical event per request; **every field a bounded ID / token / enum / number** — build-time schema allow-list check; `actor_id = HMAC(subject_key, subject_id)` per-subject-keyed pseudonym (unlinkable on key destruction); sink TTL |
| J3 | Bounded-cardinality Prometheus metrics (no raw org_id/actor_id labels; hashed/bucketed tenant-tier) + exemplars linking to traces |
| J4 | BEAM introspection runbook: guarded remote console, `Process.info`, reduction/message-queue telemetry, Oban + Ecto pool checkout telemetry |

### K. Resilience / migration safety (§runs 2–2b; §limits blast-radius bullet)

| # | Component |
|---|---|
| K1 | Expand/contract migrations; expand additive + reversible with tested `down/0`; contract in a separate later release behind a `contract_ready?` bake-window check |
| K2 | DDL tx: `lock_timeout = 5s`, `statement_timeout = 15s`; **carve-outs**: `CREATE INDEX CONCURRENTLY` and chunked batched backfills run outside that transaction with long/disabled per-statement bounds |
| K3 | PITR posture (Neon branch-and-restore), quarterly game-day on a production-sized branch; RPO ≤ 1 min steady-state; bad-contract effective RPO = detection latency (stated honestly); RTO ≤ 30 min forward-fix/expand-reversal (target), ≤ 2 h full PITR (drilled) |
| K4 | Deploy: single `mix release` (UI+logic+workers+cron), Fly rolling deploy, expand migration as a release command, `dns_cluster`/libcluster + PubSub, jittered reconnect, presence-aware draining |

### L. UI layer

LiveView tenant-plane UI, operator-plane UI, masked-value render components, impersonation entry/exit UX, reveal-request/approval flows. (Doc: §scale LiveView section; §control.)

### M. Reference verticals (§core "one base, many shapes")

PawChart (vet — additive easy case) · **Driftwood** (freight — Company→Carrier/Shipper, Opportunity→Load, settlement-netting billing, `pii_drv_cdl_number`) · Lumen Health (telehealth — Activity→Encounter, patient_responsibility+payer_claim split, HIPAA-grade PII). The plan builds **one** end-to-end (Phase 5) and a thin slice of a second (Phase 6) to prove reuse.

---

## 3 · Dependency graph & build order

```
A2 transformer ──┐
A3 fragments ────┼──> A1 base macro ──> B catalog ──> C1/C2 verifiers
                 │                        │
D2 pii DSL ──────┘                        ├──> B3 schema.dict.json ──> LLM grounding (P6)
   │                                      │
   ├──> D1 composite types               C4 pii_classify (needs B + D2)
   ├──> D3 vault tables ──> D4 KMS keys ──> D7 crypto-shred ──> C5 oracle (post-shred mode
   │                         │                                   also needs H2/H3/J2 tiers)
   ├──> D5 %Masked{} ──> D6 reveal grants ──> G2 impersonation ──> G4 audit chain ──> G5 break-glass
   └──> C3 pii_reads (needs D2 + J1 sink inventory)
H1 Oban ──> H2 event tier ──> H3 rollups ──> (H4 ClickHouse, opt-in, P6)
K1/K2 migration tooling ──> K3 PITR drills
F Identity ──> F other six scopes ──> G1 operator plane ──> G3 token-blind actor (+C7) ──> G6 aggregate floors
E1/E2/E3 ladder (needs A1 + B)          I1/I2/I3 external surface (needs F.Identity + C6)
ALL OF THE ABOVE ──> M Driftwood vertical (P5) ──> generalization (P6)
```

**Build order rationale.** The transformer (A2), fragment composition (A3), catalog-in-migration-tx (B2), the vault/KMS key hierarchy (D4/D7), and the AST verifier (C3) are the **novel, load-bearing idioms with no off-the-shelf precedent** — everything else is well-trodden Elixir/Ash engineering. If any of the five fails as designed, the architecture must change while the codebase is a spike, not a platform. Hence Phase 0. Identity precedes the other scopes because org/user/membership/policy is a dependency of every policy check in the system. The control plane needs scopes to exist (its objects ARE the scopes). The vertical needs everything. ClickHouse CDC is explicitly "a power-up, not a prerequisite" (§data ≈ block) — deferred to Phase 6.

---

## 4 · Risk register → spikes / mitigations

Derived from §limits (the doc's own risk register) plus implementation risks the doc doesn't face because it isn't code yet. **P0-class risks get Phase-0 spikes.**

| ID | Risk | Source | Severity | Retiring task |
|---|---|---|---|---|
| R1 | **Per-subject external-KMS key design doesn't exist yet.** One AWS KMS CMK per subject costs ~$1/subject/mo — economically absurd. A wrapped per-subject DEK stored in Postgres is inside the PITR surface — breaks the doc's core "restore brings back ciphertext, never the key" claim. The key store must be external, destructible, attestable, un-backed-up, and cheap per subject. | §limits erasure bullet; §data | **P0** | **S0.8** (threat-model + key-hierarchy design, opus xhigh) → **S0.5** (spike). Recommended default: per-subject DEKs wrapped by a small set of KMS master keys, wrapped-DEKs stored in a dedicated external store with backups/PITR disabled (e.g. DynamoDB w/ PITR off, or HashiCorp Vault transit named keys); destruction = delete wrapped DEK + attestation = query the store. Decision recorded as ADR-001. |
| R2 | **Spark transformer setting `source:` may fight AshPostgres codegen** (migration generator, identities, FK naming) — the whole "you write idiomatic Ash" promise rests on this being invisible. | §"Self-qualifying storage" | **P0** | **S0.2** spike: transformer + `mix ash.codegen` round-trip; acceptance = generated migration says `com_name`, app code/API say `:name`, red-path = missing abbrev fails compile. |
| R3 | **Fragment `base:` composition semantics unproven** — `Spark.Dsl.Fragment` exists, but folding fragments via a macro option, PII-DSL sections crossing the fragment boundary, and FK targeting rules need proof. | §core clarity note | **P0** | **S0.3** spike: `Core.Person` fragment + two composed resources; assert single table per resource, `belongs_to` resolves to composed table, generated DDL contains no `INHERITS`. |
| R4 | **Catalog-in-migration-transaction has no native Ash hook** — Ash codegen emits DDL, not data rows; need a custom codegen extension or migration helper that emits `INSERT INTO fld_field` in the same tx, and keeps parity on rollback. | §runs code block | **P0** | **S0.4** spike; fallback design if codegen can't be extended: a `Samen.Migration` wrapper macro that snapshots catalog diffs per migration. |
| R5 | **`pii_reads` AST verifier feasibility** — dataflow matching over Elixir AST is hard; risk of useless false-positive walls or silent false negatives. The doc already bounds the claim (not a sound taint proof; sink schema is the backstop for laundering). | §runs 4a; §runs code NOTE | **P0** | **S0.7** spike on a toy corpus with seeded direct leaks + laundered leaks; measure catch/false-positive rates; the layered design (AST for direct, sink allow-list for laundered) is the accepted mitigation. |
| R6 | **`%Masked{}` as the field's normal value vs Ash/LiveView machinery** — casting, changesets, forms, calculations, JSON encoding all touch field values; masking must fail closed through all of them. | §control; memory CP-v2 fix (3) | P0 (folded into S0.5) | S0.5 acceptance includes: masked value survives changeset round-trip, renders `••••` in LiveView + JSON, raises on accidental `to_string` plaintext path. |
| R7 | Aggregate-plane inference (differencing, homogeneity); per-actor budgets don't compose vs collusion | §limits token-blind bullet | P1 | T4.5 builds the k-anon + l-diversity floors NOW; the query budget ships as a scaffold with global/per-cohort accounting; DP/t-closeness stays a named posture-under-construction track (T6.6). The plan must never claim more than the doc does. |
| R8 | Break-glass local durable audit assumes a node disk that survives — Fly machines are ephemeral | §limits break-glass bullet | P1 | T4.4 design task (opus): persistent volume per operator node OR degraded-mode definition that tolerates node loss (e.g. synchronous write to two local nodes); residue documented, monitored. |
| R9 | WORM anchor needs an out-of-band notary target | §control; memory CP-v2 fix (5) | P2 | T4.3: recommend S3 Object Lock (compliance mode) as the anchor; decision ADR-002. |
| R10 | One-substrate blast radius (truth+queue+cron+audit+vault on one Postgres) | §limits blast-radius bullet | P1 | Phase 2 as a whole: Oban queue isolation, read replica, K1–K3 posture, drilled game-days. The mitigation IS the phase. |
| R11 | Tier-2 custom objects = re-implementing Twenty's metadata model — scope-creep magnet | memory ("Twenty = a SPEC") | P1 | T3.10 scoped to minimal viable (define object, define fields, CRUD in `tnt_record`, catalog rows, org-scope) — no workflow builder, no UI designer. Expansion is P6+. |
| R12 | Ecosystem/version drift: Ash 3.x, AshOban, AshCloak (may not support per-subject keys → custom Cloak vault), OTel libs | implementation reality | P1 | S0.1 pins versions; S0.5 evaluates AshCloak vs custom `Cloak.Vault`-per-subject and records ADR-003. |
| R13 | Erasure residues: derived aggregates computed pre-shred; already-archived partitions | §limits erasure bullet | P1 | T2.3 implements rebuild-or-exclude-on-erasure; oracle tier list includes rollups; archival detach gated on erasure window (H2). |
| R14 | Single-builder bandwidth / Elixir pond | §limits first bullet | P2 | The plan itself: workflow-driven build, catalog-grounded agents, opus-designed specs executed by sonnet fan-outs. Serialize big fan-outs per [[feedback_serialize_workflow_fanouts]] (session limits). |
| R15 | Doc is a sales/vision artifact — some claims are positioning, not spec (e.g. 2M sockets, CFO math) | doc §scale honesty notes | P2 | This plan's inventory marks claimed vs mechanism; tasks cite passages; anything invented lands in Open Decisions, not silently in code. |

---

## 5 · Model-routing rubric (applied to every task)

- **opus** — deep reasoning / correctness-critical / adversarial / wide solution space: architecture & DSL/API design; the Spark transformer + compile-time verifier design; security/privacy threat modeling + crypto-shred/KMS design; distributed-systems & migration-safety design; ALL evaluation/adversarial-review/synthesis stages; ambiguity resolution. **When unsure on a design/verify task → opus.**
- **sonnet** — fast, cost-efficient, high-volume, well-specified: implementing a spec opus already designed; scaffolding/boilerplate; the universal-scope resources once the base macro exists; test scaffolds & fixtures; docs; mechanical refactors; large parallel fan-outs; first drafts opus then reviews. **When bulk/mechanical → sonnet.**
- **effort** — `low` mechanical · `medium` standard implementation · `high` design/integration · `xhigh` adversarial verification, security design, and phase gates.

Standing pattern per non-trivial component: **opus designs (spec + acceptance) → sonnet implements → sonnet writes tests to the spec → opus adversarially reviews (tries to break it) → findings become fix tasks in-phase.**

---

## 6 · Testing & evaluation strategy (non-negotiable)

1. **No guarantee ships without a passing test AND a red-path (must-fail) test.** Every verifier has a fixture app seeded with violations that MUST fail CI with exit ≠ 0: an unprefixed column (C2), an uncatalogued column and an orphaned catalog row (C1 — both directions), a vault value flowing to `Logger`/span outside `:reveal` (C3, direct AND laundered-through-helper — the latter must be caught by the sink schema, proving the layered design), an `attribute :ssn, :string` (C4), a plaintext PII column in a rollup / a `db_statement` left enabled (C5 CI mode), an un-versioned field removal (C6), a `pii_` column reachable from the aggregate domain (C7).
2. **Unit + integration + property-based** (StreamData) per module. Property targets: transformer (∀ attribute names → prefixed storage, round-trip read/write), catalog parity (∀ resources → bijection), masking (∀ PII types → masked render in every serialization path), grant policy (∀ clock positions vs `expires_at` → deny after).
3. **Adversarial security/privacy suites** (opus-authored, run in CI from the phase that builds each surface):
   - **Crypto-shred completeness** via the destruction oracle across ALL tiers: live, replica, backup/PITR history, CDC mirror (when enabled), rollups/matviews, audit log, registered `non_pii!` rows, trace-sink ingress schema, KMS attestation. Red path: a seeded plaintext copy in any tier must fail the oracle.
   - **Masked-impersonation bypass attempts**: CSV export, JSON API, webhook payload, log line, LiveView render, calculation output — every egress must show `••••`/absent for an ungranted session.
   - **Reveal-grant abuse**: self-approval (must be blocked by the DB CHECK and by policy), expired-grant reveal, renew-in-place attempt, grant-row tamper, approval by the requestor via a second account (collusion — documented residue + audit-visible).
   - **Aggregate differencing**: count-of-one cohort (must suppress), homogeneous k-cohort (l-diversity must suppress), two-query differencing (budget scaffold must account; full defense is the P6 posture track — the test documents current behavior honestly).
   - **Migration drills**: expand reversal via `down/0` in CI; quarterly PITR game-day against a production-sized Neon branch measured against RTO ≤ 2 h / detection-latency RPO.
4. **Phase gates**: every phase ends with an adversarial multi-subagent review (opus): parallel finders per dimension → independent verifiers per finding (refute-by-default) → synthesis gate. Confirmed findings become **fix tasks in that phase**; the gate re-runs until clean or explicitly waived by the operator.
5. **End-to-end dogfood** (Phase 5): the reference vertical runs the whole verifier suite fail-closed in CI exactly as §runs describes, and the guarantees are demonstrated against the running app, not fixtures.

---

## 7 · Phased plan

Conventions: every task row = `id | objective | inputs | deliverable | acceptance (testable) | verification | model | effort | deps | worktree?`. All phases assume the repo at `/Users/clank/Desktop/projects/samen` (Open Decision OD-1). "Gate" tasks use the find→verify→gate pattern from §6.4.

---

### PHASE 0 — Spikes: prove the load-bearing idioms

**Goal:** de-risk R1–R5 before any platform code exists. Each spike is a small standalone mix project under `spikes/` plus a written report (what worked, what didn't, the ADR it implies).
**Definition of done:** all six spikes green with red-path tests; ADR-001 (key hierarchy), ADR-002 (WORM anchor target, may defer), ADR-003 (AshCloak vs custom vault) drafted; the gate signs off go/no-go per idiom with fallback designs recorded for any no-go.

| id | objective | inputs | deliverable | acceptance | verification | model | effort | deps | worktree? |
|---|---|---|---|---|---|---|---|---|---|
| S0.1 | Repo scaffold: mix project layout, pinned deps (Elixir ≥1.18, Ash 3.x, AshPostgres, Phoenix/LiveView, Oban, Spark), CI skeleton, local Postgres, `spikes/` layout | this plan | compiling repo + CI running `mix test` | CI green on empty suite; deps resolve; versions recorded in README | CI run | sonnet | low | — | no |
| S0.2 | **Spike: abbrev storage transformer.** Spark DSL transformer on a `Samen.Resource` prototype: `abbrev: "com"` + `attribute :name` → storage `com_name`; codegen round-trip | doc §core code, §runs 1 | `spikes/s02_transformer/` + report | generated migration contains `com_name`; `Ash.read/create` work via `:name`; emitted SQL says `WHERE com_org_id` shape; **red path:** resource without `abbrev` fails compile with a clear diagnostic | `mix test` incl. red-path (assert compile raise) | opus | high | S0.1 | yes |
| S0.3 | **Spike: fragment single-table composition.** `Core.Person` fragment (attrs + pii section) folded via `use Samen.Resource, base: Core.Person`; two composed resources | doc §core `Core.Person`/`Lumen.Patient` block | `spikes/s03_fragments/` + report | each composed resource = ONE table (`pat_*`, `stf_*`); fragment has no table; `belongs_to :primary_provider, Staff` FK targets `stf_*`; generated DDL contains **no `INHERITS`**; fragment pii attrs inherit the composing resource's abbrev | `mix test` + DDL assertion | opus | high | S0.2 | yes |
| S0.4 | **Spike: catalog written in the migration transaction.** Codegen extension or `Samen.Migration` wrapper emitting `tam_table`/`fld_field` INSERTs atomically with DDL | doc §runs "BEGIN; ALTER…INSERT INTO fld_field…COMMIT" | `spikes/s04_catalog_tx/` + report + chosen mechanism | migrating adds column + catalog row in one tx (crash between = neither); rollback removes both; catalog matches `Ash.Resource.Info` | `mix test` incl. injected-crash test | opus | high | S0.2 | yes |
| S0.5 | **Spike: vault + envelope crypto + KMS behaviour + crypto-shred + `%Masked{}`.** Implement ADR-001's key hierarchy with a `Samen.Kms` behaviour (InMemory + file-backed stub simulating the external store); vault table, token FK, mask-by-default, `:reveal` chokepoint, shred | S0.8 ADR-001; doc §data token-only paragraph, §control masking | `spikes/s05_vault/` + report + ADR-003 (AshCloak verdict) | write PII → vault row ciphertext + token in domain row; default read = `%Masked{}` → `••••` in LiveView render, JSON, CSV, changeset round-trip; `:reveal` returns plaintext once; **shred:** destroy key → decrypt raises, oracle-style scan finds no decryptable bytes; **red paths:** simulated PITR restore of vault snapshot cannot decrypt (key store not in snapshot); accidental plaintext interpolation raises | `mix test` incl. red paths | opus | xhigh | S0.8 | yes |
| S0.6 | **Spike: verifier harness + `catalog_parity` v0.** Mix-task harness pattern (introspect → check → exit 1 + human diagnostic), proven on the easiest verifier | S0.4 | `spikes/s06_verify/` + report | parity both directions on the spike app; **red paths:** uncatalogued column fails; orphan `fld_field` row fails; exit codes correct | `mix test` driving the task | opus design / sonnet impl | medium | S0.4 | yes |
| S0.7 | **Spike: `pii_reads` AST feasibility.** AST walker over a toy corpus: vault-declared values flowing into `Logger`/span/sink calls; `:reveal`-scope awareness | doc §runs 4a + code NOTE | `spikes/s07_pii_reads/` + report w/ catch & false-positive rates | catches all seeded **direct** flows; does not flag `pii do` declaration sites; laundered flow documented as sink-schema territory (expected miss); false-positive rate < ~1 per 50 legit call sites on corpus | seeded-corpus test matrix | opus | xhigh | S0.1 | yes |
| S0.8 | **Threat model + key-hierarchy design (ADR-001).** Per-subject key: external, destructible, attestable, outside WAL/PITR, cheap at 10⁵–10⁷ subjects; KMS availability posture (fail-closed deny-recoverable); pseudonym keying (J2) rides same key | doc §data, §limits erasure + break-glass bullets; R1 | ADR-001 + tier map for the oracle | ADR names: store choice, wrap hierarchy, destruction semantics, attestation API, cost model, availability target, what PITR restore can/can't resurrect | adversarial review inside S0.9 | opus | xhigh | S0.1 | no |
| S0.9 | **GATE 0:** adversarial review of all spike reports + ADRs; go/no-go per idiom; fallback design for any no-go | all spike reports | gate report; fix/fallback tasks | every P0 risk (R1–R5) has either a green spike or an approved fallback; no unresolved contradiction with a doc passage | multi-agent find→verify→gate | opus | xhigh | S0.2–S0.8 | no |

**Workflow spec — Phase 0.** Shape: `S0.1` runs first (single agent), then a **pipeline** where `S0.8 → S0.5` is a dependent chain and `S0.2→S0.3/S0.4` chains, with `S0.7` fully parallel; each spike stage is followed immediately by its own verify agent (red-path auditor) without waiting for sibling spikes; a final **barrier** collects all reports for the gate panel (barrier justified: the gate needs cross-spike context). Spike agents get `isolation: 'worktree'` (they mutate the same repo). Per [[feedback_serialize_workflow_fanouts]], cap concurrency by batching thunks if session limits bite. Concrete script skeleton in §8.

---

### PHASE 1 — `samen_core`: the governed substrate kernel

**Goal:** production-grade base macro + catalog + PII vault + the five-verifier suite, all fail-closed, proven on a dogfood demo app.
**Definition of done:** a demo app using only `samen_core` passes the full CI gate from §runs 3 (`mix compile --warnings-as-errors && catalog_parity && prefixes && pii_reads && pii_classify && no_plaintext_pii` CI-mode); every verifier has red-path tests; crypto-shred proven against all tiers that exist so far; Gate 1 signed.

| id | objective | inputs | deliverable | acceptance | verification | model | effort | deps | worktree? |
|---|---|---|---|---|---|---|---|---|---|
| T1.1 | Productionize `Samen.Resource`: transformer, abbrev registry (permanent, collision-checked, committed registry file), injected id/org_id/timestamps, extension wiring | S0.2/S0.3 spikes + Gate-0 notes | `samen_core` lib modules + docs | spike acceptances hold under the prod API; registry rejects reuse/recycle; fragment `base:` works per S0.3 | unit + property tests (∀ names → prefixed) | opus design+impl | high | S0.9 | no |
| T1.2 | Catalog subsystem: `tam_table`/`fld_field` resources, migration-tx writes (S0.4 mechanism), committed `schema.dict.json` emitter, CI linter (B4) | S0.4 | catalog modules + `mix samen.catalog.dump` | parity by construction on the demo app; dict deterministic (stable ordering); linter fails on unknown `^[a-z]{3}_` reference in source | unit + red-path | sonnet (opus review) | medium | T1.1 | no |
| T1.3 | PII DSL: `pii do`/`pii_attribute`, composite types (FullName/Emails/Phones per Twenty spec), **mask-unknown-by-default** type classification registry (D9) | S0.5; Twenty type spec (as spec only) | `Samen.Pii` extension + `Samen.Type.*` | composite fields route by vault name; scalars carry `pii_` prefix; an unclassified custom type is treated as PII (masked) by default; red path: declaring a vault on a non-existent vault table fails compile | unit + property | opus design / sonnet impl | high | T1.1 | no |
| T1.4 | Vault: `pii_*` tables, token FKs, envelope encryption per ADR-001, `Samen.Kms` behaviour + production adapter (per ADR-001) + InMemory/dev adapter | S0.5, ADR-001 | vault runtime | write→token+ciphertext; per-subject DEK wrapped per ADR-001; key store external to app Postgres; KMS call is the only decrypt path | integration tests vs dev adapter + contract tests vs prod adapter | sonnet (opus review) | high | T1.3 | no |
| T1.5 | `%Masked{}` + single decrypt chokepoint + `:reveal` action | S0.5 | masking runtime | masked is the normal value across changeset/LiveView/JSON/CSV; exactly one module can produce plaintext; red path: any second decrypt path fails `pii_reads` | unit + adversarial egress matrix (§6.3 bypass suite, fixture-level) | opus | high | T1.4 | no |
| T1.6 | Reveal-grant model: `RevealRequest`, distinct-party approval, `CHECK (granted_by <> requestor_id)`, `expires_at` policy denial, same-tx Oban auto-revoke, no renew-in-place, hash-chain-ready audit rows | doc §control time-boxed paragraph | grant resources + policies + migration | self-approval blocked at DB AND policy layer; expired grant denies even with stale row; revoke job provably enqueued in the grant's tx; re-access requires fresh request | unit + property (clock) + red paths | opus design / sonnet impl | high | T1.5, T2.1* (Oban conventions can be stubbed with plain Oban) | no |
| T1.7 | Crypto-shred + SHREDDED sentinel + `non_pii!` registry & row-redaction path (D7/D8) | T1.4, ADR-001 | `Samen.Erasure` (shred orchestration) | shred destroys key via KMS adapter, writes sentinel, emits audit row; `non_pii!` columns get row-level redaction on erasure; both recorded for the oracle | integration + red path (post-shred decrypt raises) | opus | high | T1.4, T1.6 | no |
| T1.8a | Verifiers `catalog_parity` + `prefixes` (prod versions on the S0.6 harness) | S0.6 | mix tasks | doc-specified checks; exit ≠ 0 + actionable diagnostics | red-path fixture apps | sonnet | low | T1.2 | yes (fixture apps) |
| T1.8b | Verifier `pii_reads` (prod, per S0.7 report) | S0.7 | mix task | S0.7 acceptance on the real codebase; `:reveal`-scope aware; keys on declarations | red-path fixtures: direct leak fails; declaration site passes; laundered leak passes here but MUST fail J2's sink check (tested together in P2) | opus | xhigh | T1.5 | yes |
| T1.8c | Verifier `pii_classify` (heuristic scanner + review-gated `non_pii!` + catalog registration) | doc §llm backstop paragraph | mix task + override flow | flags seeded ssn/dob/mrn/cdl/email-shaped columns; `non_pii!` without second-reviewer metadata fails; accepted override lands in catalog | red-path fixtures incl. value-shape hits from seeds | opus design / sonnet impl | high | T1.2, T1.3 | yes |
| T1.8d | Verifier `no_plaintext_pii` **CI mode** (token-only-downstream over tiers existing so far: app-log sink, audit rows, catalog; asserts `db_statement: :disabled` config) | doc §runs oracle spec | mix task (CI mode) | passes on demo app; **red path:** seeded plaintext PII type in a projected surface fails | red-path fixtures | opus | high | T1.7 | yes |
| T1.9 | Demo dogfood app (`demo/`): a contact-manager slice using every T1 feature; property-based suites; the §runs CI gate wired end-to-end | all T1 | demo app + CI pipeline | full gate green; every red-path fixture red; coverage of samen_core ≥ 90% lines on core modules | CI | sonnet | medium | T1.8a–d | no |
| T1.10 | **GATE 1:** adversarial review — panel tries to (a) smuggle plaintext past each verifier, (b) find a masking egress leak, (c) break shred vs a simulated restore, (d) find doc-vs-implementation drift | T1.9 demo | gate report → in-phase fix tasks | zero confirmed P0 findings open; each finding either fixed or ADR'd | multi-agent find→verify→gate | opus | xhigh | T1.9 | no |

**Workflow spec — Phase 1.** Shape: **pipeline** over the dependency chains (T1.1→T1.2→…, T1.3→T1.4→T1.5→T1.6/T1.7), with the four verifier tasks T1.8a–d as a **parallel fan-out** once their deps clear (worktree isolation — they each add fixture apps). Subagents: `design:<component>` (opus, xhigh, schema: `{spec, acceptance[], api_sketch}`), `impl:<component>` (sonnet, medium, schema: `{files[], test_summary, ci_green: bool}`), `redpath:<verifier>` (sonnet, schema: `{fixtures[], all_fail_closed: bool}`), `review:<component>` (opus, xhigh, refute-by-default verdict). Gate: the §6.4 pattern — 4 finder lenses (verifier-evasion, egress-leak, shred-vs-restore, doc-drift) → 2 independent verifiers per finding → synthesis.

---

### PHASE 2 — Engine, event tier, resilience, PII-safe observability, the full oracle

**Goal:** Postgres-as-engine + the ops posture the doc stakes its single-substrate honesty on, plus observability that keeps the no-plaintext invariant, culminating in the full destruction oracle.
**Definition of done:** demo app runs jobs/cron/rollups; expand/contract tooling enforced; `no_plaintext_pii --subject --tiers all` passes post-shred on the demo app and fails on every seeded violation; first PITR game-day executed with measured numbers; Gate 2 signed.

| id | objective | inputs | deliverable | acceptance | verification | model | effort | deps | worktree? |
|---|---|---|---|---|---|---|---|---|---|
| T2.1 | Oban/AshOban conventions: same-tx enqueue helper, queue taxonomy + per-queue concurrency, cron, DLQ policy | doc §"Postgres as the engine"; §limits blast-radius | `Samen.Jobs` conventions + docs | enqueue provably same-tx (crash test); runaway-queue starvation test shows isolation | integration tests | opus design / sonnet impl | medium | T1.1 | no |
| T2.2 | `aud_event` append-only tier: monthly RANGE partitions, BRIN, append-only enforcement (no UPDATE/DELETE grants + trigger), partition-detach policy gated on erasure window | doc §data bullets | event tier + partition manager (Oban cron) | inserts route to right partition; UPDATE/DELETE denied; detach refuses while partition feeds an erasure-relevant rollup | integration + red path | sonnet (opus review) | medium | T2.1 | no |
| T2.3 | Rollups/matviews + AshOban `trigger :refresh_rollup` + **rebuild-or-exclude-on-erasure** | doc §data code block; §limits erasure (derived aggregates) | rollup framework + erasure hooks | dashboard query hits rollup, never raw; erasure with raw retained → rebuild without subject; erasure in archived window → suppress arm | integration + red path (pre-shred rollup must not resurrect subject) | opus design / sonnet impl | high | T2.2, T1.7 | no |
| T2.4 | Migration tooling: expand/contract helpers, `lock_timeout=5s`/`statement_timeout=15s` in DDL tx, carve-outs (CONCURRENTLY + chunked backfills outside tx), tested `down/0` convention, `contract_ready?` bake-window gate | doc §runs 2/2b | `Samen.Migration` helpers + CI check | contract migration refuses before bake window; timeout posture verified (blocking-lock test aborts fast; CONCURRENTLY build survives); every expand has passing `down/0` in CI | integration + drill tests | opus | high | T1.2 | no |
| T2.5 | PITR/reverse game-day #1: runbook + drill on a production-sized Neon branch; measure vs RPO ≤1 min steady / RTO ≤30 min forward-fix (target) / ≤2 h PITR | doc §runs 2b | runbook + measured drill report | drill executed; numbers recorded; gaps become fix tasks | drill evidence reviewed at gate | opus (runbook) + human-in-loop (drill) | high | T2.4 | no |
| T2.6 | OTel tracing: mount→Ash→policy→SQL (`db_statement: :disabled`)→reveal, Oban span propagation via job row; `:reveal` span attrs allow-listed (`subject_id, grant_id, reason`); sampled `auto_explain` server-side | doc §runs 4a | tracing integration | one request = one end-to-end trace across the job boundary; no SQL text/bind params in any span; reveal span carries only the three attrs | integration + red path (assert absent attrs) | sonnet (opus review) | medium | T2.1 | no |
| T2.7 | Wide events + **build-time sink schema allow-list** (bounded ID/token/enum/number only) + `actor_id` per-subject-keyed pseudonym `HMAC(subject_key, subject_id)` + sink TTL config | doc §runs 4b | wide-event emitter + schema check | seeded string field in a wide event fails the build; pseudonym unlinkable post-shred (key gone); the T1.8b "laundered leak" fixture is caught HERE | red-path + integration w/ T1.7 shred | opus design / sonnet impl | high | T2.6, T1.7 | no |
| T2.8 | Bounded-cardinality metrics + exemplars; BEAM introspection runbook (4c/4d) | doc §runs 4c/4d | metrics + runbook | no raw org/actor labels (CI label-lint); exemplar links trace | unit + lint | sonnet | low | T2.6 | no |
| T2.9 | **Destruction oracle, full**: `no_plaintext_pii --subject <uuid> --tiers all` — DB-tier content scan (live·replica·rollup·audit·registered_non_pii), backup/PITR-history scan, KMS destruction attestation; trace-sink ingress-class assertion; CDC tier stubbed until H4 | doc §runs oracle block (the whole spec); ADR-001 | oracle mix task + tier registry | post-shred run passes on demo; **red paths:** seeded decryptable ciphertext in any tier fails; key present in a simulated PITR branch fails; KMS attestation missing fails; unredacted `non_pii!` row fails | adversarial fixture matrix per tier | opus | xhigh | T1.7, T2.2, T2.3, T2.7 | no |
| T2.10 | **GATE 2:** adversarial review — shred-completeness across tiers, migration-drill evidence, observability leak hunt, blast-radius mitigations | all T2 | gate report → in-phase fixes | oracle red-path matrix fully red; drill numbers within targets or gap-tasked | find→verify→gate | opus | xhigh | T2.1–T2.9 | no |

**Workflow spec — Phase 2.** Shape: **pipeline** with two lanes (engine lane T2.1→T2.2→T2.3; ops lane T2.4→T2.5 ∥ obs lane T2.6→T2.7→T2.8) converging on T2.9 (barrier justified: the oracle needs every tier to exist). T2.5's live drill needs operator presence — schedule it as a flagged human-in-loop step, not an autonomous agent action. Gate roster as Phase 1 with lenses: tier-completeness, drill-evidence, sink-leak, queue-starvation.

---

### PHASE 3 — Universal scopes, malleability ladder, external surface

**Goal:** the inherited 80% as real Ash domains in the samen idioms; the ladder's tenant tiers; the governed public API/webhooks.
**Definition of done:** all seven scopes compile under the full verifier gate with seed data and per-scope test suites; Tier-0/1/2 work on the demo app; `/api/v1` + webhooks live with `api_contract` in CI; Gate 3 signed.

| id | objective | inputs | deliverable | acceptance | verification | model | effort | deps | worktree? |
|---|---|---|---|---|---|---|---|---|---|
| T3.1 | **Identity scope** (org·user🔒·membership·role·api_key·invitation🔒·audit) + the canonical policy patterns (org-scope, RBAC, `Ash.Scope` actor+org_id from membership) every other scope copies | doc §runs 1; scope table | Identity domain + policy library + scope-authoring guide (the template for the fan-out) | full CI gate green; policy tests (cross-org read denied, role matrix); user/invitation PII vaulted; audit rows emitted | unit + policy property tests | opus | xhigh | Gate 2 | no |
| T3.2–T3.7 | **Scope fan-out**: CRM, Billing, Marketing, CMS, Support, Primitives — each per the T3.1 guide; PII per the 🔒 map; Tier-0 config rows per scope; Billing = Stripe-mirror shape (customer/subscription/plan/price/invoice/payment/usage/entitlement) | T3.1 guide + doc scope table | six domains + seeds + tests | per scope: verifier gate green; 🔒 objects vault-routed; org-scope policy tests; Tier-0 rows seeded; opus review sign-off | per-scope suites + opus review | **sonnet fan-out**, opus per-scope review | medium each | T3.1 | **yes** (parallel mutation) |
| T3.8 | Tier-1 custom fields: `xxx_custom` jsonb + `tnt_field` metadata + validated-at-write + catalog rows for custom fields | doc §core Tier-1 bag; memory ladder | Tier-1 runtime | tenant defines field → validated writes; invalid shape rejected at write; custom fields catalogued; **contained**: no Tier-1 field can be a vault bypass (values classified, PII-shaped values flagged) | unit + red path | opus design / sonnet impl | high | T3.1 | no |
| T3.9 | Tier-2 custom objects (**minimal viable**, R11): `tnt_object`/`tnt_field`/`tnt_record`, org-scoped, catalogued; no workflow builder | memory (Twenty spec) | Tier-2 runtime | tenant defines object + fields, CRUD works, org-scoped, catalogued; one-way boundary documented (no FK from system tables into `tnt_record`) | unit + red path | opus design / sonnet impl | high | T3.8 | no |
| T3.10 | `Samen.Context` DSL: `alias_resource`, `reshape`/calculations (A4) — needed by Phase 5 | doc §core `Lumen.Context` block | context DSL | alias exposes kernel resource under vertical name; reshape calcs compile & catalog correctly; plumbing (vault/org/audit) unchanged underneath | unit tests on a toy context | opus | high | T3.1 | no |
| T3.11 | External API: AshJsonApi (+GraphQL optional, OD-6) `/api/v1`; **allowlist serialization** (default not-exposed; catalog names only; masked serializes `••••`; operator-plane vaulted fields absent without grant); two api_key classes (I2) | doc §scale external-surface section | API layer | unallowlisted field absent; storage names never appear in any payload; tenant key reads own-org PII per RBAC without grant; operator cross-tenant key masked | integration + adversarial payload matrix | opus design / sonnet impl | high | T3.1 | no |
| T3.12 | Verifier `api_contract` (C6): schema-diff vs committed v1 snapshot; fails on structural break | doc §scale versioning bullet | mix task + snapshot | red paths: removed field / narrowed type / dropped route / new required arg each fail; additive change passes | red-path fixtures | sonnet (opus review) | medium | T3.11 | yes |
| T3.13 | Webhooks: Oban delivery, at-least-once, capped backoff, DLQ, idempotency keys, HMAC+timestamp signing, allowlisted masked payloads | doc §scale webhook bullets | webhook subsystem | replay rejected by receiver-side verify helper; redelivery idempotent; DLQ after cap; payload passes the same allowlist as the API | integration + property (retry schedule) | sonnet (opus review) | medium | T2.1, T3.11 | no |
| T3.14 | **GATE 3:** adversarial review — scope-consistency sweep (idiom drift across the six fan-out scopes), Tier-1/2 containment attack, API leak hunt (storage-name/vault leakage), webhook replay | all T3 | gate report → in-phase fixes | zero P0; idiom drift fixed (this is where fan-out inconsistency dies) | find→verify→gate | opus | xhigh | T3.1–T3.13 | no |

**Workflow spec — Phase 3.** Shape: T3.1 single opus chain first (it authors the template); then **pipeline over the six scopes** — each scope: `impl:<scope>` (sonnet, worktree) → `review:<scope>` (opus, refute-by-default, schema `{idiom_violations[], pii_gaps[], verdict}`) → fix agent if needed; ladder + API lanes run parallel to the fan-out. **Serialize or batch the six-scope fan-out** (concurrency ≤ 2–3) per [[feedback_serialize_workflow_fanouts]]. Gate adds a dedicated cross-scope consistency lens (needs all scopes: barrier justified).

---

### PHASE 4 — Two-plane control plane

**Goal:** the doc's hero claim, built: masked impersonation, second-party reveal, token-blind aggregates, tamper-evident tenant-readable audit, break-glass, aggregate-privacy floors.
**Definition of done:** an operator can run support/billing/CRM over tenants with PII masked; every §control mechanism demonstrably enforced; the adversarial suite (§6.3) passes; Gate 4 (the heaviest) signed.

| id | objective | inputs | deliverable | acceptance | verification | model | effort | deps | worktree? |
|---|---|---|---|---|---|---|---|---|---|
| T4.1 | Operator plane domains + **masked impersonation**: session scoped to target org (different actor, same org_id policy), no reveal grant by default, short-TTL impersonation grant w/ reason-for-access, tenant-visible | §control lead; memory | impersonation runtime + operator UI slice | impersonating operator sees tenant's real UI with `••••`; TTL expiry ends session; reason recorded; tenant can list impersonations | integration + egress matrix | opus design / sonnet impl | xhigh | Gate 3 | no |
| T4.2 | **Token-blind aggregate actor**: named actor, own default-deny domain, no org_id, vault-excluded projection (no `pii_` columns exist), mutually exclusive with `:reveal`; `NoPiiColumns` verifier (C7) | §control two-paths block; memory CP-v2 (1) | aggregate domain + verifier | verifier fails on a seeded `pii_` column in the domain; actor cannot invoke `:reveal` (policy + test); MRR/queue rollups readable | red path + integration | opus | xhigh | T4.1, T2.3 | no |
| T4.3 | Hash-chained tenant-readable audit + **WORM anchor** (ADR-002: recommend S3 Object Lock): chain over token references + key-destroyable ciphertext; ops role cannot UPDATE/DELETE; oracle covers this tier | §control immutable-and-shreddable paragraph | audit chain + anchor job | chain verifies; tamper (edited row) detected; tenant read view works; post-shred: event survives, subject unrecoverable — oracle tier passes | red path (tamper + shred) | opus design / sonnet impl | high | T1.6, T2.9 | no |
| T4.4 | Break-glass: locally-durable deferred-anchor audit (R8 design resolved: persistent volume or dual-node local write), anchor reconciliation w/ gap detection, live-KMS-required decrypt, per-operator breadth budget + auto-suspend, degraded-mode monitoring | §limits break-glass bullet | break-glass runtime + runbook | control-plane-down drill: reveal completes w/ local audit, anchors on reconnect, gap tamper detected; KMS-down drill: reveal fails closed; budget breach auto-suspends | drill tests + red paths | opus | xhigh | T4.3 | no |
| T4.5 | Aggregate privacy floors: k-anonymity min-cohort + l-diversity suppression **enforced**; global/per-cohort query-budget **scaffold** (accounting + logging, enforcement thresholds configurable); DP/t-closeness explicitly deferred (T6.6) | §control ∴; §limits inference bullet | suppression layer + budget ledger | count-of-one suppressed; homogeneous k-cohort suppressed (l-div); budget ledger accounts per cohort not per actor; differencing test documents current behavior | adversarial queries + red paths | opus | xhigh | T4.2 | no |
| T4.6 | Adversarial suite as durable CI: impersonation bypass matrix, self-approval/collusion, expired/tampered grants, aggregate differencing, audit tamper | §6.3 | `test/adversarial/` suite | all attacks blocked or documented-residue with audit visibility; suite runs in CI | the suite itself | opus authors / sonnet expands | xhigh | T4.1–T4.5 | no |
| T4.7 | **GATE 4:** the heaviest gate — red-team panel (privacy, authz, crypto, audit-integrity lenses), 3–5-vote adversarial verify per finding | all T4 | gate report → in-phase fixes | zero confirmed P0/P1 open; residues match §limits exactly (no silent new ones) | find→verify→gate, widened panel | opus | xhigh | T4.6 | no |

**Workflow spec — Phase 4.** Shape: pipeline T4.1→T4.2→T4.5 and T4.3→T4.4, then T4.6 barrier (needs all surfaces). Gate 4 uses the **loop-until-dry** pattern (keep spawning finder rounds until 2 consecutive rounds find nothing new) — this is the phase where a missed finding is a breach-class defect in the finished product.

---

### PHASE 5 — Reference vertical: Driftwood (freight brokerage)

**Recommended pick: Driftwood** (OD-2). Rationale: it exercises the **hardest honest claim** — bounded-context translation (Company→Carrier/Shipper, Opportunity→Load, Activity untouched) and the billing **reshape** (invoice = carrier settlement: linehaul − advances − factoring; two-sided money) — plus real vaulted PII (`pii_drv_cdl_number`, driver identity) and FMCSA-style expiry gating, **without** dragging HIPAA compliance scope (Lumen) or settling for the easy additive case (PawChart).

**Goal:** one real SaaS end-to-end proving every guarantee in a running app.
**Definition of done:** Driftwood runs on Fly + Neon with tenant plane + operator plane live; full verifier gate in its CI exactly as §runs describes; crypto-shred game-day and PITR game-day executed against the real app with evidence; Gate 5 = ship-gate signed.

| id | objective | inputs | deliverable | acceptance | verification | model | effort | deps | worktree? |
|---|---|---|---|---|---|---|---|---|---|
| T5.1 | Domain design: Driftwood context map (kernel primitives → Carrier/Shipper/Load/Driver), settlement billing reshape spec, Tier usage plan (which customizations land on which rung) | doc §core Driftwood rows; T3.10 DSL | design doc + resource specs | every kernel noun mapped or explicitly unused; settlement math specified with worked examples; PII inventory (CDL, driver identity) vault-routed | opus adversarial design review | opus | xhigh | Gate 4 | no |
| T5.2 | Build the vertical: composed resources (`use Samen.Resource, base:`), `Driftwood.Context`, settlement billing, load/dispatch workflows (Oban), seeds | T5.1 spec | Driftwood app | full verifier gate green in Driftwood CI; settlement calcs match worked examples (property tests on the netting math); expiry gating blocks dispatch | unit + property + integration | sonnet fan-out (opus review) | high | T5.1 | yes |
| T5.3 | Tenant UI + operator plane live: broker dashboards (rollup-backed), support tickets, masked impersonation over a Driftwood tenant, reveal flow end-to-end | T5.2, T4.1 | running app (Fly + Neon) | an operator supports a tenant with `••••` PII; second-party reveal works; aggregate MRR view is token-blind | manual script + `/qa`-style pass + adversarial matrix rerun against the live app | sonnet impl / opus verify | high | T5.2 | no |
| T5.4 | **Crypto-shred game-day** on Driftwood: erase a real driver subject; run `no_plaintext_pii --subject --tiers all` against live·replica·rollup·audit·(CDC if enabled)·trace-sink·KMS; rollup rebuild-or-exclude exercised | T2.9 | game-day report | oracle passes on the real app; rollup arm exercised both ways; evidence archived | oracle run + gate review | opus (orchestrate) | xhigh | T5.3 | no |
| T5.5 | **PITR game-day #2** on a production-sized Driftwood branch: bad-contract scenario, forward-fix vs restore decision drill, RTO/RPO measured | T2.5 runbook | drill report | RTO ≤ 2 h restore path met; expand-reversal path rehearsed; runbook gaps fixed | drill evidence | opus + human-in-loop | high | T5.3 | no |
| T5.6 | **GATE 5 (SHIP gate):** full adversarial review of the running product + the doc-parity audit: every §runs/§control/§limits claim mapped to a passing test or a named honest residue | all T5 | ship report | claim→evidence table complete; no doc claim without evidence or an explicit downgrade note | find→verify→gate + doc-parity lens | opus | xhigh | T5.4, T5.5 | no |

**Workflow spec — Phase 5.** T5.1 single opus design + judge panel (3 independent approaches to the settlement model, scored, synthesized). T5.2 pipeline over resource groups (worktree). T5.4/T5.5 are evidence-producing orchestrations with human-in-loop flags. Gate 5 includes the **doc-parity audit** as its own finder lens — the plan's anti-invention mechanism, closing the loop opened in §2's inventory.

---

### PHASE 6 — Generalize: foundry packaging, reuse proof, deferred tracks

**Goal:** turn "one product on a substrate" into "a foundry," and burn down the deferred tracks.
**Definition of done:** a second-vertical thin slice reuses `samen_core` + scopes with measured delta-effort; LLM-grounding workflow documented and tested; generators exist; deferred tracks either shipped or explicitly parked with ADRs.

| id | objective | model | effort | deps |
|---|---|---|---|---|
| T6.1 | Extraction retro (Rule-of-Three notes): what Driftwood forced into core vs what stayed vertical; core-extraction ADRs | opus | high | Gate 5 |
| T6.2 | Second-vertical thin slice (PawChart: Patient composes Person, VaccineLot as Tier-2, plain subscriptions) — measure reuse: % inherited vs authored | sonnet (opus review) | medium | T6.1 |
| T6.3 | LLM-grounding workflow: `schema.dict.json` consumption guide, agent authoring guide (how an agent adds a resource and survives the gate), eval: seeded agent tasks must pass the verifier gate | opus design / sonnet impl | high | T6.1 |
| T6.4 | Generators/installer (`mix samen.new`, scope igniters) | sonnet | medium | T6.1 |
| T6.5 | Optional ClickHouse CDC path (H4): ClickPipes token-blind mirror, `ecto_ch` second repo, oracle `cdc_mirror` tier goes live, never-read-current lint | opus design / sonnet impl | high | T6.1 |
| T6.6 | Aggregate-privacy hardening track: global/per-cohort budget **enforcement**, DP noise posture, t-closeness — research-grade; stays honestly labeled posture-under-construction until proven | opus | xhigh | T4.5 |
| T6.7 | **GATE 6:** foundry-readiness review + refreshed risk register | opus | xhigh | T6.2–T6.6 |

---

## 8 · Phase-0/1 workflow script skeleton (copy-adaptable)

```javascript
export const meta = {
  name: 'samen-phase0-spikes',
  description: 'Prove the five load-bearing Samen idioms as isolated spikes with red-path tests, then gate',
  phases: [
    { title: 'Scaffold', detail: 'repo + CI + pinned deps' },
    { title: 'Design', detail: 'ADR-001 key hierarchy threat model' },
    { title: 'Spike', detail: 'transformer · fragments · catalog-tx · vault/KMS · verifier harness · pii_reads AST' },
    { title: 'Verify', detail: 'red-path auditor per spike' },
    { title: 'Gate', detail: 'adversarial go/no-go panel' },
  ],
}

const REPO = '/Users/clank/Desktop/projects/samen'
const DOC = '/Users/clank/Downloads/samen-foundry.html'
const PLAN = '/Users/clank/Downloads/samen-implementation-plan.md'

const SPIKE_SCHEMA = {
  type: 'object',
  required: ['spike_id', 'status', 'report_path', 'red_paths_failing_closed', 'findings'],
  properties: {
    spike_id: { type: 'string' },
    status: { enum: ['green', 'green_with_caveats', 'blocked'] },
    report_path: { type: 'string' },
    red_paths_failing_closed: { type: 'boolean' },
    findings: { type: 'array', items: { type: 'string' } },
    fallback_needed: { type: 'boolean' },
  },
}
const AUDIT_SCHEMA = {
  type: 'object',
  required: ['spike_id', 'verdict', 'issues'],
  properties: {
    spike_id: { type: 'string' },
    verdict: { enum: ['confirmed', 'refuted', 'partial'] },
    issues: { type: 'array', items: { type: 'string' } },
  },
}
const GATE_SCHEMA = {
  type: 'object',
  required: ['go_no_go', 'fix_tasks'],
  properties: {
    go_no_go: { type: 'object' },          // { s02: 'go' | 'no-go', ... }
    fix_tasks: { type: 'array', items: { type: 'string' } },
    fallback_designs: { type: 'array', items: { type: 'string' } },
  },
}

const ctx = (extra) => `You are building the Samen foundry (Elixir/Ash 3.x).
Source of truth: ${DOC} (read the relevant section). Plan + acceptance criteria: ${PLAN} (§7 Phase 0).
Repo: ${REPO}. Work ONLY under spikes/<your-spike>/ plus a report .md. ${extra}
Non-negotiable: ship red-path (must-fail) tests proving fail-closed behavior, per the plan's task row.`

phase('Scaffold')
const scaffold = await agent(
  ctx('Task S0.1: create the repo scaffold — mix project, pinned deps (record exact versions), CI running mix test, spikes/ dir. Deliver a compiling repo with green empty CI.'),
  { label: 'S0.1:scaffold', model: 'sonnet', effort: 'low', schema: SPIKE_SCHEMA }
)
if (!scaffold || scaffold.status === 'blocked') { log('scaffold blocked — stopping'); return { scaffold } }

phase('Design')
const adr1 = await agent(
  ctx(`Task S0.8: author ADR-001 — the per-subject external-KMS key hierarchy. Constraints from the doc (§limits erasure bullet, §data): key must be external to the app Postgres WAL/PITR surface, destructible with attestation, cheap at 10^5–10^7 subjects (one AWS CMK per subject is NOT viable at ~$1/mo each). Evaluate: wrapped per-subject DEKs in a dedicated no-backup store (DynamoDB PITR-off) vs HashiCorp Vault transit named keys. Cover: destruction semantics, attestation API, availability posture (fail-closed deny-recoverable), what a PITR restore can and cannot resurrect, and the J2 pseudonym HMAC keying. Write ADR to ${REPO}/docs/adr/001-key-hierarchy.md.`),
  { label: 'S0.8:ADR-001', effort: 'xhigh', schema: SPIKE_SCHEMA }   // inherits main model (opus-class)
)

phase('Spike')
// Chains: S0.2 → (S0.3 ∥ S0.4 ∥ S0.6-harness-after-S0.4); S0.8 → S0.5; S0.7 independent.
// pipeline(): no barrier — each chain's verify runs as soon as that chain lands.
const chains = [
  { id: 'transformer-chain', run: async () => {
      const s02 = await agent(ctx('Task S0.2: spike the abbrev storage transformer per the plan task row — Spark transformer, attribute :name → com_name storage, ash codegen round-trip, red path: missing abbrev fails compile.'),
        { label: 'S0.2:transformer', effort: 'high', isolation: 'worktree', phase: 'Spike', schema: SPIKE_SCHEMA })
      if (!s02 || s02.status === 'blocked') return [s02]
      const rest = await parallel([
        () => agent(ctx('Task S0.3: spike fragment single-table composition (base: Core.Person) per plan task row. Assert one table per composed resource, FK targets composed tables, DDL has no INHERITS. Build on the S0.2 transformer spike (read spikes/s02*).'),
          { label: 'S0.3:fragments', effort: 'high', isolation: 'worktree', phase: 'Spike', schema: SPIKE_SCHEMA }),
        () => agent(ctx('Task S0.4: spike catalog-in-migration-transaction per plan task row — tam_table/fld_field INSERTs atomic with DDL, rollback removes both, injected-crash test.'),
          { label: 'S0.4:catalog-tx', effort: 'high', isolation: 'worktree', phase: 'Spike', schema: SPIKE_SCHEMA }),
      ])
      const s04 = rest[1]
      const s06 = s04 && s04.status !== 'blocked'
        ? await agent(ctx('Task S0.6: spike the verifier harness + samen.verify.catalog_parity v0 per plan task row, on top of the S0.4 spike. Red paths: uncatalogued column fails; orphan fld_field row fails.'),
            { label: 'S0.6:verify-harness', model: 'sonnet', effort: 'medium', isolation: 'worktree', phase: 'Spike', schema: SPIKE_SCHEMA })
        : null
      return [s02, ...rest, s06]
    } },
  { id: 'vault-chain', run: async () => [await agent(
      ctx(`Task S0.5: spike the vault per plan task row and ADR-001 (read ${REPO}/docs/adr/001-key-hierarchy.md first): Samen.Kms behaviour + stub adapters, vault table + token FK, %Masked{} default render across changeset/LiveView/JSON/CSV, :reveal chokepoint, crypto-shred. Red paths: simulated PITR restore cannot decrypt; post-shred decrypt raises. Record the AshCloak-vs-custom-Cloak verdict as ADR-003.`),
      { label: 'S0.5:vault-kms', effort: 'xhigh', isolation: 'worktree', phase: 'Spike', schema: SPIKE_SCHEMA })] },
  { id: 'ast-chain', run: async () => [await agent(
      ctx('Task S0.7: spike pii_reads AST feasibility per plan task row — seeded corpus with direct leaks, declaration sites, laundered leaks; report catch/false-positive rates honestly.'),
      { label: 'S0.7:pii-reads-ast', effort: 'xhigh', isolation: 'worktree', phase: 'Spike', schema: SPIKE_SCHEMA })] },
]

const results = await pipeline(
  chains,
  (c) => c.run(),
  // per-chain verify: an independent red-path auditor per landed spike, no cross-chain barrier
  (spikes, chain) => parallel((spikes || []).filter(Boolean).map((s) => () =>
    agent(ctx(`Independently AUDIT spike ${s.spike_id} (report: ${s.report_path}). Re-run its tests. Try to REFUTE its claims: do the red-path tests actually fail closed? Does the mechanism match the doc passage cited in the plan? Default to refuted if uncertain.`),
      { label: `verify:${s.spike_id}`, effort: 'xhigh', phase: 'Verify', schema: AUDIT_SCHEMA })
      .then((v) => ({ spike: s, audit: v }))))
)

phase('Gate')
const flat = results.flat().filter(Boolean)
const gate = await agent(
  ctx(`GATE 0. Spike+audit results: ${JSON.stringify(flat.map(({ spike, audit }) => ({
    id: spike.spike_id, status: spike.status, red: spike.red_paths_failing_closed,
    verdict: audit && audit.verdict, issues: audit && audit.issues })))}.
Also read ADR-001. Decide go/no-go PER IDIOM (transformer, fragments, catalog-tx, vault/KMS, verifier-harness, pii_reads-AST). For any no-go or refuted audit, specify a concrete fallback design or fix task. A refuted red-path claim is an automatic no-go for that idiom.`),
  { label: 'gate:phase0', effort: 'xhigh', schema: GATE_SCHEMA }
)
return { adr1, spikes: flat, gate }
```

Adaptation notes for Phase 1+: keep `SPIKE_SCHEMA`→`IMPL_SCHEMA` (`{component, files, ci_green, red_paths}`), swap the Spike phase for a `pipeline(components, design → impl → redpath → review)`, and reuse the Gate agent verbatim with the phase's finder lenses in the prompt. Cap fan-out concurrency by batching `parallel` thunks in groups of 2–3 (session-limit guidance from project memory).

---

## 9 · Machine-readable task graph

```yaml
# samen task graph v1 — drive later sessions from this block
# model: opus|sonnet (opus = session main model in workflows; annotate via effort + prompt)
# verify: rp=red-path fixtures, pt=property tests, it=integration, drill=game-day evidence,
#         gate=adversarial multi-agent review, adr=design review
phases:
  - id: P0
    name: spikes
    gate: S0.9
    tasks:
      - {id: S0.1, deps: [],            model: sonnet, effort: low,   verify: [it],        worktree: false, obj: repo scaffold + CI + pinned deps}
      - {id: S0.2, deps: [S0.1],        model: opus,   effort: high,  verify: [rp],        worktree: true,  obj: abbrev transformer spike, risk: R2}
      - {id: S0.3, deps: [S0.2],        model: opus,   effort: high,  verify: [rp],        worktree: true,  obj: fragment single-table composition spike, risk: R3}
      - {id: S0.4, deps: [S0.2],        model: opus,   effort: high,  verify: [rp],        worktree: true,  obj: catalog-in-migration-tx spike, risk: R4}
      - {id: S0.5, deps: [S0.8],        model: opus,   effort: xhigh, verify: [rp],        worktree: true,  obj: vault+KMS+shred+Masked spike, risk: [R1, R6, R12]}
      - {id: S0.6, deps: [S0.4],        model: sonnet, effort: medium,verify: [rp],        worktree: true,  obj: verifier harness + catalog_parity v0}
      - {id: S0.7, deps: [S0.1],        model: opus,   effort: xhigh, verify: [rp],        worktree: true,  obj: pii_reads AST feasibility spike, risk: R5}
      - {id: S0.8, deps: [S0.1],        model: opus,   effort: xhigh, verify: [adr],       worktree: false, obj: ADR-001 key hierarchy threat model, risk: R1}
      - {id: S0.9, deps: [S0.2,S0.3,S0.4,S0.5,S0.6,S0.7,S0.8], model: opus, effort: xhigh, verify: [gate], worktree: false, obj: GATE 0 go/no-go per idiom}
  - id: P1
    name: samen_core
    gate: T1.10
    tasks:
      - {id: T1.1,  deps: [S0.9],       model: opus,   effort: high,  verify: [pt],        worktree: false, obj: Samen.Resource + transformer + abbrev registry}
      - {id: T1.2,  deps: [T1.1],       model: sonnet, effort: medium,verify: [rp],        worktree: false, obj: catalog + schema.dict.json + CI linter}
      - {id: T1.3,  deps: [T1.1],       model: opus,   effort: high,  verify: [pt, rp],    worktree: false, obj: pii DSL + composite types + mask-unknown-default}
      - {id: T1.4,  deps: [T1.3],       model: sonnet, effort: high,  verify: [it],        worktree: false, obj: vault + KMS adapters per ADR-001}
      - {id: T1.5,  deps: [T1.4],       model: opus,   effort: high,  verify: [rp],        worktree: false, obj: Masked type + decrypt chokepoint + reveal}
      - {id: T1.6,  deps: [T1.5],       model: opus,   effort: high,  verify: [pt, rp],    worktree: false, obj: reveal-grant model (2nd-party, expires_at, same-tx revoke)}
      - {id: T1.7,  deps: [T1.4, T1.6], model: opus,   effort: high,  verify: [rp],        worktree: false, obj: crypto-shred + sentinel + non_pii! registry}
      - {id: T1.8a, deps: [T1.2],       model: sonnet, effort: low,   verify: [rp],        worktree: true,  obj: verifiers catalog_parity + prefixes}
      - {id: T1.8b, deps: [T1.5],       model: opus,   effort: xhigh, verify: [rp],        worktree: true,  obj: verifier pii_reads (AST)}
      - {id: T1.8c, deps: [T1.2, T1.3], model: sonnet, effort: high,  verify: [rp],        worktree: true,  obj: verifier pii_classify + non_pii! review gate}
      - {id: T1.8d, deps: [T1.7],       model: opus,   effort: high,  verify: [rp],        worktree: true,  obj: verifier no_plaintext_pii CI mode}
      - {id: T1.9,  deps: [T1.8a, T1.8b, T1.8c, T1.8d], model: sonnet, effort: medium, verify: [it], worktree: false, obj: demo dogfood app + full CI gate}
      - {id: T1.10, deps: [T1.9],       model: opus,   effort: xhigh, verify: [gate],      worktree: false, obj: GATE 1}
  - id: P2
    name: engine-ops-observability-oracle
    gate: T2.10
    tasks:
      - {id: T2.1,  deps: [T1.10],       model: sonnet, effort: medium,verify: [it],       worktree: false, obj: Oban conventions + same-tx enqueue + queue isolation}
      - {id: T2.2,  deps: [T2.1],        model: sonnet, effort: medium,verify: [rp, it],   worktree: false, obj: aud_event partitioned append-only tier}
      - {id: T2.3,  deps: [T2.2, T1.7],  model: opus,   effort: high,  verify: [rp, it],   worktree: false, obj: rollups + rebuild-or-exclude-on-erasure}
      - {id: T2.4,  deps: [T1.10],       model: opus,   effort: high,  verify: [it, drill],worktree: false, obj: expand/contract tooling + timeouts + contract_ready?}
      - {id: T2.5,  deps: [T2.4],        model: opus,   effort: high,  verify: [drill],    worktree: false, obj: PITR game-day 1 (human-in-loop)}
      - {id: T2.6,  deps: [T2.1],        model: sonnet, effort: medium,verify: [rp, it],   worktree: false, obj: OTel tracing, db_statement disabled, reveal-span allowlist}
      - {id: T2.7,  deps: [T2.6, T1.7],  model: opus,   effort: high,  verify: [rp],       worktree: false, obj: wide events + sink schema check + keyed pseudonym}
      - {id: T2.8,  deps: [T2.6],        model: sonnet, effort: low,   verify: [it],       worktree: false, obj: bounded metrics + exemplars + BEAM runbook}
      - {id: T2.9,  deps: [T1.7, T2.2, T2.3, T2.7], model: opus, effort: xhigh, verify: [rp], worktree: false, obj: destruction oracle full (--subject --tiers all)}
      - {id: T2.10, deps: [T2.5, T2.8, T2.9], model: opus, effort: xhigh, verify: [gate], worktree: false, obj: GATE 2}
  - id: P3
    name: scopes-ladder-external
    gate: T3.14
    tasks:
      - {id: T3.1,  deps: [T2.10],       model: opus,   effort: xhigh, verify: [pt, it],   worktree: false, obj: Identity scope + policy library + scope guide}
      - {id: T3.2,  deps: [T3.1], model: sonnet, effort: medium, verify: [it], worktree: true, obj: CRM scope}
      - {id: T3.3,  deps: [T3.1], model: sonnet, effort: medium, verify: [it], worktree: true, obj: Billing scope (Stripe-mirror)}
      - {id: T3.4,  deps: [T3.1], model: sonnet, effort: medium, verify: [it], worktree: true, obj: Marketing scope}
      - {id: T3.5,  deps: [T3.1], model: sonnet, effort: medium, verify: [it], worktree: true, obj: CMS scope}
      - {id: T3.6,  deps: [T3.1], model: sonnet, effort: medium, verify: [it], worktree: true, obj: Support scope}
      - {id: T3.7,  deps: [T3.1], model: sonnet, effort: medium, verify: [it], worktree: true, obj: Primitives scope}
      - {id: T3.8,  deps: [T3.1],        model: opus,   effort: high,  verify: [rp],       worktree: false, obj: Tier-1 custom fields (jsonb + tnt_field)}
      - {id: T3.9,  deps: [T3.8],        model: opus,   effort: high,  verify: [rp],       worktree: false, obj: Tier-2 custom objects (minimal viable), risk: R11}
      - {id: T3.10, deps: [T3.1],        model: opus,   effort: high,  verify: [it],       worktree: false, obj: Samen.Context DSL (alias_resource, reshape)}
      - {id: T3.11, deps: [T3.1],        model: opus,   effort: high,  verify: [rp, it],   worktree: false, obj: public API + allowlist serialization + two key classes}
      - {id: T3.12, deps: [T3.11],       model: sonnet, effort: medium,verify: [rp],       worktree: true,  obj: verifier api_contract}
      - {id: T3.13, deps: [T2.1, T3.11], model: sonnet, effort: medium,verify: [pt, it],   worktree: false, obj: webhooks (HMAC, DLQ, idempotency)}
      - {id: T3.14, deps: [T3.2,T3.3,T3.4,T3.5,T3.6,T3.7,T3.9,T3.10,T3.12,T3.13], model: opus, effort: xhigh, verify: [gate], worktree: false, obj: GATE 3 incl. cross-scope idiom-drift lens}
  - id: P4
    name: control-plane
    gate: T4.7
    tasks:
      - {id: T4.1, deps: [T3.14],        model: opus,   effort: xhigh, verify: [it, rp],   worktree: false, obj: operator plane + masked impersonation}
      - {id: T4.2, deps: [T4.1, T2.3],   model: opus,   effort: xhigh, verify: [rp],       worktree: false, obj: token-blind aggregate actor + NoPiiColumns verifier}
      - {id: T4.3, deps: [T1.6, T2.9],   model: opus,   effort: high,  verify: [rp],       worktree: false, obj: hash-chained tenant-readable audit + WORM anchor (ADR-002)}
      - {id: T4.4, deps: [T4.3],         model: opus,   effort: xhigh, verify: [drill, rp],worktree: false, obj: break-glass deferred-anchor + breadth budget, risk: R8}
      - {id: T4.5, deps: [T4.2],         model: opus,   effort: xhigh, verify: [rp],       worktree: false, obj: k-anon + l-diversity floors + query-budget scaffold, risk: R7}
      - {id: T4.6, deps: [T4.1,T4.2,T4.3,T4.4,T4.5], model: opus, effort: xhigh, verify: [rp], worktree: false, obj: adversarial suite as durable CI}
      - {id: T4.7, deps: [T4.6],         model: opus,   effort: xhigh, verify: [gate],     worktree: false, obj: GATE 4 (loop-until-dry red team)}
  - id: P5
    name: driftwood-vertical
    gate: T5.6
    tasks:
      - {id: T5.1, deps: [T4.7],         model: opus,   effort: xhigh, verify: [adr],      worktree: false, obj: Driftwood context map + settlement spec (judge panel)}
      - {id: T5.2, deps: [T5.1],         model: sonnet, effort: high,  verify: [pt, it],   worktree: true,  obj: build the vertical}
      - {id: T5.3, deps: [T5.2],         model: sonnet, effort: high,  verify: [it],       worktree: false, obj: tenant UI + operator plane live on Fly/Neon}
      - {id: T5.4, deps: [T5.3],         model: opus,   effort: xhigh, verify: [drill],    worktree: false, obj: crypto-shred game-day (oracle vs live app)}
      - {id: T5.5, deps: [T5.3],         model: opus,   effort: high,  verify: [drill],    worktree: false, obj: PITR game-day 2 (human-in-loop)}
      - {id: T5.6, deps: [T5.4, T5.5],   model: opus,   effort: xhigh, verify: [gate],     worktree: false, obj: GATE 5 ship-gate + doc-parity audit}
  - id: P6
    name: generalize
    gate: T6.7
    tasks:
      - {id: T6.1, deps: [T5.6], model: opus,   effort: high,  verify: [adr],  worktree: false, obj: extraction retro (Rule of Three)}
      - {id: T6.2, deps: [T6.1], model: sonnet, effort: medium,verify: [it],   worktree: false, obj: PawChart thin slice — reuse measurement}
      - {id: T6.3, deps: [T6.1], model: opus,   effort: high,  verify: [it],   worktree: false, obj: LLM-grounding workflow + agent eval vs verifier gate}
      - {id: T6.4, deps: [T6.1], model: sonnet, effort: medium,verify: [it],   worktree: false, obj: generators / mix samen.new}
      - {id: T6.5, deps: [T6.1], model: opus,   effort: high,  verify: [rp],   worktree: false, obj: optional ClickHouse CDC + oracle cdc tier}
      - {id: T6.6, deps: [T4.5], model: opus,   effort: xhigh, verify: [rp],   worktree: false, obj: query-budget enforcement + DP posture (research track)}
      - {id: T6.7, deps: [T6.2,T6.3,T6.4,T6.5,T6.6], model: opus, effort: xhigh, verify: [gate], worktree: false, obj: GATE 6 foundry-readiness}
```

---

## 10 · Open decisions (each with a recommended default — none block Phase 0 except OD-3, resolved by S0.8)

| id | decision | recommended default | why / when it must be locked |
|---|---|---|---|
| OD-1 | Repo location & shape | `/Users/clank/Desktop/projects/samen`; single repo, `samen_core` as a path-dep library + `demo/` + `spikes/` + later `apps/driftwood`; NOT an umbrella | matches working dir; extraction to a hex-style lib can happen at P6. Lock at S0.1. |
| OD-2 | Reference vertical | **Driftwood (freight)** | exercises bounded-context + billing reshape + vaulted PII without HIPAA scope; PawChart too easy, Lumen drags compliance. Lock before T5.1. **The one I most want a human to confirm.** |
| OD-3 | KMS / key-store architecture | per-subject DEKs wrapped by a small set of KMS master keys; wrapped DEKs in a dedicated external store with backups/PITR disabled (DynamoDB PITR-off first choice; HashiCorp Vault transit the alternative); destruction = delete + attestation = store query | per-subject AWS CMKs cost ~$1/mo each — non-viable. This is S0.8/ADR-001's job; the default is the hypothesis it tests. |
| OD-4 | Encryption library | evaluate AshCloak; expect custom `Cloak.Vault`-per-subject wrapper (AshCloak assumes app-level keys) | resolved by S0.5 → ADR-003. |
| OD-5 | Dev/prod database | local Postgres (docker) for dev/CI; **Neon** for staging/prod and all PITR game-days | Neon branch-and-restore is load-bearing for K3 drills. Lock by T2.5. |
| OD-6 | Public API flavor | AshJsonApi only at first; AshGraphql behind OD when a consumer demands it | halves the C6 contract surface. Lock at T3.11. |
| OD-7 | WORM anchor target | S3 Object Lock (compliance mode) | cheapest true-WORM with an API the anchor job can drive. ADR-002 at T4.3. |
| OD-8 | Trace/event sink | Honeycomb (doc names Honeycomb/Tempo/Loki; pick one to build the ingress-schema check against) | any OTel sink works; the schema check is sink-agnostic. Lock at T2.7. |
| OD-9 | Deploy target | Fly.io (doc assumes it: rolling deploys, WireGuard clustering) | lock at T5.3. |
| OD-10 | Scope build depth in P3 | build all seven scopes in the fan-out, but Marketing + CMS to a thinner acceptance bar (resources + policies + catalog + Tier-0; workflows minimal) — Driftwood needs Identity/CRM/Billing/Support/Primitives deep | keeps "the 80% exists" true without gold-plating scopes the dogfood won't exercise; deepen in P6. |
| OD-11 | `non_pii!` second-reviewer mechanics for a solo builder | the review gate = a signed entry in the catalog registry requiring a separate approval identity (a second session/PR approval), never same-commit self-approval; honest residue documented | doc requires a second reviewer; a solo operator needs a defined stand-in. Lock at T1.8c. |

---

## 11 · Definition of done (whole plan)

1. **Every doc mechanism** in the §2 inventory is implemented, or explicitly parked with an ADR that names the downgrade (nothing silently dropped).
2. **The §runs CI gate runs fail-closed, verbatim**: `mix compile --warnings-as-errors && samen.verify.catalog_parity && prefixes && pii_reads && pii_classify && no_plaintext_pii` — and every verifier has red-path fixtures that fail it.
3. **The destruction oracle passes post-shred on a real app** (`--subject --tiers all`: DB scan + PITR-history scan + KMS attestation), and fails on every seeded violation, with the two carve-outs (trace-sink pseudonyms, `non_pii!` rows) handled exactly as the doc scopes them.
4. **The control plane's hero claim is demonstrated live**: masked impersonation, second-party time-boxed reveal, token-blind aggregates, tamper-evident tenant-readable audit — with the adversarial suite green in CI.
5. **Driftwood runs in production posture** (Fly + Neon), both planes, full gate in its own CI; crypto-shred and PITR game-days executed with archived evidence and measured RTO/RPO.
6. **A claim→evidence table** (Gate 5's doc-parity audit) maps every §runs/§control/§limits claim to a test, a drill artifact, or a named honest residue — the artifact you'd show the doc's imagined auditor.
7. **Reuse is measured**: the PawChart thin slice quantifies inherited-vs-authored, validating (or honestly falsifying) "build the 20%, inherit the 80%."
