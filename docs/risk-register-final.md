# Samen — Final Risk Register (Gate 6, T6.7)

- **Date:** 2026-07-08
- **Task:** plan §7 T6.7 (GATE 6) — refresh the plan's original risk register (R1–R15,
  plan §4) against everything built through Phases 0–6, fold in the accumulated gate
  residues (F1/F2/F3 from Gate 5, the extraction-retro A1–A10 items, and the honest
  postures named in the Phase-6 reports), and state for each: **retired / remains /
  new**.
- **Inputs:** plan §4 (R1–R15), `docs/gate-{0..5}-report.md`, `docs/extraction-retro.md`,
  `docs/claim-evidence.md`, ADR-001..007, and the Phase-6 reports
  (`samen_core/reports/T6.{3,4,5,6}.md`, `pawchart/reports/T6.2.md`).
- **Legend:** **RETIRED** = the retiring task landed and is proven (test / game-day /
  gate). **RESIDUAL** = mitigated to a named, bounded posture or operator-TODO — not a
  breach, honestly labeled. **NEW** = surfaced during the build, not in the original R1–R15.

---

## 1 · Original register R1–R15 — final disposition

| ID | Risk (abbreviated) | Sev | Final status | Evidence / residue |
|----|--------------------|-----|--------------|--------------------|
| **R1** | Per-subject external-KMS key design doesn't exist; a Postgres-row DEK breaks "restore brings back ciphertext, never the key" | P0 | **RETIRED (mechanism) · RESIDUAL (real cloud KMS)** | ADR-001 key hierarchy; `Samen.Kms` behaviour + `FileBacked` adapter (external to Postgres). Proven by the Driftwood T5.4 crypto-shred game-day (oracle EXITs 0, 15 attestations, key provably absent from every DB tier) + T5.5 PITR drill (restore resurrects ciphertext, `reveal → {:error, :unavailable}` with an empty key dir; dump grepped, no key material). **RESIDUAL:** real AWS-KMS / DynamoDB-PITR-off / HashiCorp-Vault wiring is an operator TODO; the load-bearing exclusion (key store outside the WAL/PITR surface) is identical in the local sim. |
| **R2** | Spark abbrev transformer fights AshPostgres codegen | P0 | **RETIRED** | S0.2 spike + `Samen.Resource` transformer; every column carries its abbrev (`com_`/`drv_`/`per_`/`own_`) across 4 hosts; `mix samen.verify.prefixes` green in every gate; `mix ash.codegen` round-trips. |
| **R3** | Fragment `base:` single-table composition unproven | P0 | **RETIRED** | S0.3 spike + `Samen.Fragments.CorePerson`; Driftwood Driver + PawChart Patient both compose it into ONE table, no `INHERITS`; FK targets composed tables. Proven again this gate: PawChart's Patient composes CorePerson with 0 vertical PII code. |
| **R4** | Catalog-in-migration-transaction has no native Ash hook | P0 | **RETIRED** | S0.4 spike + `Samen.Migration` / `catalog_sync`; `mix samen.verify.catalog_parity` green in every gate (both directions); `schema.dict.json` drift-check green on all 4 hosts. |
| **R5** | `pii_reads` AST verifier feasibility (false-positive walls / silent misses) | P0 | **RETIRED (bounded claim) · RESIDUAL (not a sound taint proof)** | S0.7 spike + `mix samen.verify.pii_reads` (direct-flow match) + the sink-schema allow-list backstop for laundered leaks. Green in every gate. **RESIDUAL (by design, doc-stated):** it is a dataflow match, NOT a sound taint proof; laundering is the sink-schema's job. The T6.3 agent-authoring eval case 5 proves it catches a direct `Logger.info(subject.rvp_emails)` leak outside `:reveal`. |
| **R6** | `%Masked{}` as the field's normal value vs Ash/LiveView/JSON/CSV machinery | P0 | **RETIRED** | S0.5 + the vault stack; masked renders `••••` across LiveView / JSON:API / webhooks / CSV / logs by omission. Re-proven this gate on freight (F1 API + F2 broker console) and PawChart (owner PII masked on the operator plane). |
| **R7** | Aggregate-plane inference (differencing, homogeneity); per-actor budgets don't compose vs collusion | P1 | **RETIRED (floors + enforcing budget) · RESIDUAL (formal DP composition, t-closeness)** | T4.5 k-anon + l-diversity floors (enforced today, fail-closed); **T6.6 promoted the query budget to ENFORCING** (opt-in per-cohort/global read budget that DENIES; keyed per-COHORT so two colluding actors share ONE budget — the doc's "per-actor is the wrong unit" now an *enforced* outcome) + a distribution-tested Laplace **DP noise mechanism** (opt-in). **RESIDUAL (named, not claimed solved):** the FORMAL ε-budget composed across queries and t-closeness stay posture-under-construction — the enforcing budget is a deterministic read-COUNT budget, not an ε-proof. This exactly matches the doc's own honest edge (:906, :947). |
| **R8** | Break-glass local-durable audit assumes a node disk that survives (Fly ephemeral) | P1 | **RETIRED (mechanism) · RESIDUAL (Fly volume)** | T4.4 break-glass deferred-anchor + reconciliation + gap detection + breadth budget/auto-suspend, proven in `samen_core` + `demo` (`break_glass_abuse_test`). **RESIDUAL:** a persistent-volume-per-operator-node deployment posture + a Driftwood-specific break-glass drill are operator/carry items (Gate-5 C6 CAVEAT). |
| **R9** | WORM anchor needs an out-of-band notary target | P2 | **RETIRED (mechanism) · RESIDUAL (S3 Object Lock)** | ADR-002; the hash-chained tenant-readable `aud_chain` with a DB-level append-only trigger (refuses raw UPDATE/DELETE) + hash-chain forgery detection — proven live at Gate 5 and by the extracted `Samen.OperatorPlane.Migration` red paths (T6.1). **RESIDUAL:** the real S3-Object-Lock compliance-mode anchor is an operator TODO; the deferred-anchor reconciliation is built. |
| **R10** | One-substrate blast radius (truth+queue+cron+audit+vault on one Postgres) | P1 | **RETIRED (as local sim) · RESIDUAL (read replica, real Neon RTO)** | Phase 2 (Oban queue isolation, expand/contract + lock/statement_timeout, PITR) + the T5.5 bad-migration game-day (production-sized, both recovery arms, key-store exclusion). **RESIDUAL:** no physical read replica locally; the drilled RTO/RPO numbers are local-sim floors, not the real Neon numbers (operator TODO). |
| **R11** | Tier-2 custom objects = re-implementing Twenty's metadata model (scope-creep magnet) | P1 | **RETIRED** | T3.9 minimal-viable `tnt_object`/`tnt_field`/`tnt_record`, org-scoped, catalogued, one-way boundary. Re-proven this gate: PawChart's Tier-2 VaccineLot via `define_object` with **0 vertical code** (`vaccine_lot_tier2_test.exs`). No workflow builder / UI designer crept in. |
| **R12** | Ecosystem/version drift (Ash 3.x, AshOban, AshCloak, OTel) | P1 | **RETIRED** | S0.1 pinned deps (Ash 3.29.3, ash_postgres 2.10.0, spark 2.7.2, oban 2.23.0); ADR-003 chose custom Cloak-per-subject over AshCloak (per-subject keys). All 4 hosts compile + gate green on the pinned set. |
| **R13** | Erasure residues: derived aggregates pre-shred; archived partitions | P1 | **RETIRED** | T2.3 rebuild-or-exclude-on-erasure; the T5.4 game-day exercises BOTH arms on a driver-keyed rollup (rebuild → count 0, no resurrection; suppress → `drl_suppressed=TRUE`). Oracle tier list includes rollups. |
| **R14** | Single-builder bandwidth / Elixir pond | P2 | **RESIDUAL (process, accepted)** | Mitigated by the workflow-driven, catalog-grounded, opus-designed/sonnet-executed build (this whole program). Not a code risk; an ongoing operational one. The foundry itself (T6.3 grounding + T6.4 generators) is the structural mitigation: a builder inherits the 80% instead of re-authoring it. |
| **R15** | Doc is a sales/vision artifact — some claims are positioning, not spec | P2 | **RETIRED (as a discipline)** | `docs/claim-evidence.md` maps every load-bearing claim to a test / game-day / substrate-inherited proof / named residue. Positioning claims (2M sockets, CFO math) were never lowered into code. This gate extends the map to the Phase-6 sections (LLM-grounding, generators, CDC, DP) — see §H of claim-evidence.md. |

**Score:** of the original 15, **R2/R3/R4/R6/R11/R12/R13** are cleanly RETIRED with running proof; **R1/R5/R7/R8/R9/R10/R15** are RETIRED-in-mechanism with a **named, bounded residual** (each a documented operator-TODO or a doc-stated posture, none a breach); **R14** stays an accepted process residual. **No original risk is unretired or unlabeled.**

---

## 2 · Accumulated gate residues folded in

### From Gate 5 (F1/F2/F3)
| Residue | Status |
|---------|--------|
| **F3** (operator/impersonate no-session 500) | **RETIRED** — fixed in-phase at Gate 5; re-verified (guard present, RP5b green, anti-tautology flip); availability defect, never a leak. |
| **F1** (reference vertical mounted no public API/webhook surface) | **RETIRED (P6 PRE)** — Driftwood now mounts `/api/v1` JSON:API + webhooks over freight; `api_external_surface_test.exs` (8) proves CDL never-plaintext on the operator key, masked webhook, tenant-key own-PII-clear, actor-less→zero-rows; anti-tautology-flipped. |
| **F2** (tenant-owner over-masking inverted the two-key rule) | **RETIRED (P6 PRE)** — broker scope carries `plane: :tenant`; `Driftwood.Reads.driver_roster/1` threads `Samen.Api.PiiResolution.resolve/4`; tenant reads own CDL/name in clear, operator plane stays `••••`; both planes anti-tautology-flipped. |

### From the extraction retro (A1–A10)
| Item | Status |
|------|--------|
| **A4** aud_chain migration byte-identical across 3 hosts | **RETIRED** — extracted to `Samen.OperatorPlane.Migration` (T6.1); 10 red-path tests + anti-tautology flip; the 3 hosts are now 4-line wrappers. |
| **A3** abbrev registry global-not-per-host | **RESIDUAL (ADR-006, DEFERRED)** — target design (per-host-namespaced owner) accepted but deferred behind the generator; 50+ file blast radius; interim rule (fresh abbrevs + append-only global registry) sanctioned. Re-confirmed by PawChart (fresh `own/pet/…`) and by the T6.4 generator (appends 10 rows to the global registry). |
| **A5** rollup refresh is a fn not a cron worker | **RESIDUAL (ADR-007, DEFERRED)** — the substrate HAS `Samen.Jobs.RollupRefreshWorker`; the gap is expressing vertical rollups as `Samen.Rollup.Spec`s; deferred until a 3rd vertical confirms the domain-table-sourced Spec shape. |
| **A6** webhook storage-name guard false-positives on freight catalog names | **RESIDUAL (P1 backlog, precise fix known)** — `~r/^[a-z]{3}_/` drops legit names (`cdl_number`); **over-strict (absent, never a leak)** — verified this gate: the guard is a defense-in-depth DROP, cannot under-mask. Fix: key on the resource's declared abbrev. |
| **A9** operator-plane migration set copy-pasted | **RESIDUAL (P1 backlog under ADR-005 + `mix samen.gen.operator_plane`)** — lower drift hazard than A4 (token-only/uncatalogued). |
| **A1/A2** `non_pii!` redaction sentinel is text-only (dictated a column type) | **RESIDUAL (P3 backlog)** — only 1 host hit it; contained + documented; fix = per-type redaction sentinels. |
| **A7** alias/reshape can't add auth/FK/validation | **NOT A RISK — designed boundary** (doc-stated; adding structure = write a native resource). |
| **A8** `org_id` not auto-derived on create | **RESIDUAL (P3, leave-vertical)** — a base-macro convenience is a footgun; kept explicit. |
| **A10** per-host game-day/drill scaffolding | **RESIDUAL (P4)** — meaningful only against real Fly/Neon/KMS; revisit with T6.5. |

---

## 3 · NEW risks surfaced by Phase 6 (a 2nd vertical + external surfaces + CDC)

| ID | New risk | Sev | Status / mitigation |
|----|----------|-----|---------------------|
| **N1** | **Global abbrev-registry coupling across verticals in one repo** — every host reads `samen_core/priv/abbrev_registry.json`; two hosts sharing the repo collide on scope-default abbrevs, and a generated app silently appends 10 rows to the shared registry. | P2 | **RESIDUAL — mechanism-safe, ergonomics-only.** Verified this gate: the registry is a permanence/collision LEDGER, not a data-access surface — each host's `schema.dict.json` contains ONLY its own resources (Demo/Driftwood/PawChart, no bleed), so there is **no cross-vertical read hole**. The cost is authoring friction (fresh abbrevs per mount) + an operator-TODO to commit the appended registry rows. Directed by ADR-006. |
| **N2** | **CDC analytics tier is a new cross-tier plaintext-leak surface** — a mis-scoped ClickPipes allow-list could mirror a plaintext PII column into ClickHouse (outside the key-reachable Postgres tiers in a naive design). | P1 | **RETIRED (mechanism) · RESIDUAL (real ClickPipes wiring).** T6.5: `Samen.Cdc.Projection` excludes plaintext PII BY CONSTRUCTION (mask-unknown-by-default classifier); `assert_no_plaintext!` RAISES on an explicitly-named plaintext column; the destruction-oracle `cdc_mirror` tier does a real schema+content scan when on; the never-read-current guard always raises + an AST lint. **Verified this gate against the real freight Driver:** `project/1` includes ZERO plaintext_pii columns; the vaulted CDL/name/emails/phones classify as `:token` (safe vt_ FKs); `assert_no_plaintext!(Driver, :all)` REFUSES. **RESIDUAL:** real ClickPipes/`ecto_ch` wiring + a CI diff of the pipe allow-list against `Projection.project/1` are operator TODOs (tier default off; honestly vacuous in CI). |
| **N3** | **Two verticals sharing the same substrate could cross-read via a shared operator plane or aggregate actor.** | P1 | **RETIRED.** Each vertical has its own Repo/DB; the operator plane + aggregate actor are per-host. C7 `no_pii_columns` green on all 3 verticals' projections; scanned this gate — no aggregate projection in demo/driftwood/pawchart declares a `pii_attribute`, vault, or PII relationship (only moduledoc mentions of the *absence*). No cross-vertical actor path exists. |
| **N4** | **Generated apps could ship a subtly-broken gate** (correct-by-construction is a strong claim). | P2 | **RETIRED.** T6.4 red paths, re-run independently this gate: `mix samen.gen.app --module Gate6probe --prefix zx --abbrev zxq` → the generated app's full 17-step `ci.sh` EXITs 0 on first run (incl. its own vault anti-tautology probe flip); the `--no-reserve-abbrevs` variant FAILS CLOSED at compile with the exact abbrev-registry error. |
| **N5** | **DP posture over-sell risk** — shipping a Laplace mechanism could imply a system-level DP guarantee the code does not have. | P2 | **RESIDUAL — honesty-enforced.** T6.6: both the budget-enforcement and DP flags default OFF; the `Samen.Aggregate.Dp` moduledoc spends more words on what a single ε-release does NOT guarantee (composition, the averaging attack) than on what it does; t-closeness named unimplemented; there is deliberately NO flag that flips on a "formal DP guarantee." The claim-evidence H1 row carries this exactly. |

---

## 4 · Bottom line

- **No P0/P1 breach-class risk is open.** Every original P0 (R1–R6) is retired in mechanism with running proof; the residuals on R1/R5/R7 are the doc's own stated honest edges (real cloud KMS, not-a-sound-taint-proof, formal DP composition), not gaps in the build.
- **The three NEW cross-cutting risks a foundry introduces** — global-registry coupling (N1), the CDC leak surface (N2), and cross-vertical isolation (N3) — were each red-teamed this gate and found **mechanism-safe**: no cross-vertical read hole, the CDC projection excludes plaintext PII on real freight data, and every aggregate projection is `pii_`-free.
- **The remaining residuals are all named, bounded, and either ADR'd or backlogged with a precise fix and a trigger** — none is a re-architecture, none is a breach.
