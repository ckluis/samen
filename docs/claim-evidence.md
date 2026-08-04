# Driftwood — Claim → Evidence Doc-Parity Audit (Gate 5, T5.6)

**Purpose (the plan's anti-invention mechanism).** Every load-bearing claim in the
vision doc's **runs** ("How it actually runs"), **Running the business**, **data-tier**
("One Postgres is the whole stateful surface"), **external-surface** ("a versioned
public API and webhooks"), and **honest edges** sections is mapped to ONE of:

- **✅ TEST** — a passing Driftwood test / verifier (file + what it proves), OR
- **🎯 GAME-DAY** — a Driftwood game-day artifact (`driftwood/reports/T5.*.md`), OR
- **♻️ SUBSTRATE** — proven in the substrate (`samen_core` / `demo`) and inherited by
  Driftwood unchanged (cited because Driftwood mounts it verbatim), OR
- **🟡 RESIDUE** — an explicitly-named honest residue / operator-TODO (not faked), OR
- **🔴 FINDING** — a claim with NO evidence and NO honest-residue label (a Gate-5 finding).

Source doc: `/Users/clank/Desktop/projects/samen/docs/samen-foundry.txt` (line refs in
parens). Driftwood app: `/Users/clank/Desktop/projects/samen/driftwood/`.

Legend for verdicts: a claim is **MET** if a ✅/🎯 lands it on the *running Driftwood
app*; **MET (substrate)** if only ♻️; **CAVEAT** if 🟡; **GAP** if 🔴.

---

## A. "How it actually runs" (§runs, :756–:790)

| # | Claim (doc line) | Class | Driftwood evidence | Verdict |
|---|---|---|---|---|
| R1 | One BEAM release runs web, workers, cron; one Postgres is truth/queue/cron/history/audit/vault (:763) | ✅ TEST + 🎯 | App boots as one release: `lib/driftwood/application.ex` starts Repo + Oban + PubSub + Endpoint. Live boot log: `Running DriftwoodWeb.Endpoint with Bandit 1.12.0 at 127.0.0.1:4010`. One `Driftwood.Repo` backs domain rows, `oban_jobs`, `pii_vault`, `aud_event`, `aud_chain`, rollups (all in one DB — reports/T5.3.md, T5.4.md). | **MET** |
| R2 | Request lifecycle: LiveView `mount/3` holds an `Ash.Scope` (actor+org_id); every action runs the policy check + emits `WHERE com_org_id=$1`; transformer ran at compile time so the query says `com_name` not `name` (:769) | ✅ TEST | `lib/driftwood_web/broker_live.ex` mounts with `broker_scope/1` (`%Samen.Scope{}`); `Driftwood.Reads` reads through Ash → OrgScope. Cross-org isolation proven: `test/adversarial/driftwood_attack_matrix_test.exs` "attack 3" (org-A sees ZERO org-B rows) + `test/cross_org_test.exs`. Abbrev projection proven: `attack 2` reads raw `pii_drv_cdl_number` / `drv_id` (physical `drv_*` columns) directly. | **MET** |
| R3 | The vault sits beside the row: the row carries a token; plaintext only when a `:reveal` action runs (:769) | ✅ TEST | `test/cdl_vault_test.exs`: raw `pii_drv_cdl_number` is a `vt_` token; a normal Ash read returns `%Masked{}`; plaintext only via `:reveal_driver`. Re-confirmed live in my Gate-5 probe (V2: all name+cdl fields `%Masked{}` under the read path). | **MET** |
| R4 | Deploy & migrations: `mix release` one artifact; Fly rolling deploy; expand migration runs as a release command; expand/contract never edit-in-place; `contract_ready?` bake gate (:771) | ♻️ SUBSTRATE + 🟡 RESIDUE | Expand/contract + `down/0` + `contract_ready?` proven in `demo` (`migration_expand_contract_test.exs`) and enforced on Driftwood by CI step 7 `mix samen.verify.migrations` (every expand ships a tested `down/0`). **Fly rolling deploy is an operator TODO** (local Postgres here; `docs/driftwood-dogfood.md` deploy seam). | **MET (substrate)** + CAVEAT (Fly) |
| R5 | Migration safety posture: `lock_timeout=5s`/`statement_timeout=15s`; CIC + batched backfills run outside the txn; every expand ships a tested `down/0`; contract covered by PITR; RTO ≤ 30 min forward-fix / ≤ 2 h full PITR; bad-contract effective RPO = detection latency (:773) | 🎯 GAME-DAY | **T5.5 PITR game-day #2** on a **production-sized** Driftwood dataset (2400 settlements / 160 carriers / 4 tenants): reversible EXPAND + a deliberately BAD contract (`DROP COLUMN stl_advances_cents`) → detected by the settlement-integrity harness → BOTH arms run (i: `down/0` + forward-fix; ii: `pg_dump`→fresh DB→validate). Wall-clock within targets *in the local sim*. `driftwood/reports/T5.5.md`, `priv/gameday/pitr_gameday_sim.sh`, `test/pitr_gameday2_test.exs`. **The ≤30min/≤2h numbers are TARGETS pending the real Neon drill; `detection_ms` is a harness-runtime PROXY for monitoring-driven detection latency — stated honestly in the report.** | **MET (as local sim)** + CAVEAT (Neon numbers = operator TODO) |
| R6 | The build fails closed: catalog_parity, prefixes, pii_reads, pii_classify, no_plaintext_pii — AST/Spark-checked, not grepped; every step exits non-zero on a violation (:775, :790) | ✅ TEST | `driftwood/ci.sh` runs the FULL 16-verifier gate + the default/adversarial suites + both game-days (20 steps). Root `bash ci.sh` = ALL PASSED (verified this session, exit 0). Each verifier ships a red path in `samen_core` (♻️). | **MET** |
| R7 | Distributed tracing: `db_statement: :disabled`; the reveal path excluded from span attributes; `pii_reads` fails the build on a direct flow of a revealed/`pii_` value into a span/log/sink (:779) | ♻️ SUBSTRATE + 🟡 RESIDUE | `mix samen.verify.pii_reads` + `sink_schema` + `metric_labels` run GREEN in `driftwood/ci.sh` (steps 4/8/9) against Driftwood's resources. `db_statement: :disabled` is asserted by the C5 CI-mode oracle (`no_plaintext_pii`, step 6, green). **Driftwood does not itself call `OpentelemetryEcto.setup(..., db_statement: :disabled)` in config** (demo does: `demo/config/config.exs:141`); Driftwood has no live OTel exporter wired (boot log: "OTLP exporter module not found"). The invariant is verifier-enforced, but a live trace-scrub demonstration on freight data is an operator TODO. | **MET (verifier)** + CAVEAT (no live tracer wired) |
| R8 | Bounded-cardinality metrics (action/route/result/tenant-tier, never raw org_id/actor_id); audit is separate first-class `aud_event` rows (:785) | ✅ TEST + 🎯 | `mix samen.verify.metric_labels` green in `driftwood/ci.sh` step 9. Audit as first-class rows proven by the T5.4 game-day: dispatch/reveal/erasure events land on `aud_event` and are queried by `SELECT` (`reports/T5.4.md` §1, §6). | **MET** |

---

## B. "Running the business" — the two planes (§control, :880–:906, :98–:100)

| # | Claim (doc line) | Class | Driftwood evidence | Verdict |
|---|---|---|---|---|
| C1 | Product tenants use + control plane you run the business with are the SAME objects on the same substrate; operator CRM where accounts are tenant orgs (:888) | ✅ TEST | The operator planes read Driftwood's OWN freight tenants: `DriftwoodWeb.OperatorImpersonationLive` + `OperatorDashboardLive` over `Driftwood.Freight`/`Crm`. The masking seam is the SHARED `Driftwood.Reads` used by BOTH the broker console and the operator impersonation view (`lib/driftwood/reads.ex`). | **MET** |
| C2 | Masked impersonation: operator opens a tenant, sees its real UI, session carries NO reveal grant, PII renders `••••` by default (masking is the field type's normal value — no CSV/API/log path leaks by omission) (:888, :98) | ✅ TEST + LIVE PROBE | `test/web_red_paths_test.exs` RED PATH 1 (impersonation renders `••••`, refutes plaintext/`vt_`/name, with a non-vacuous control that the 2 real driver rows + FMCSA badges render). **RE-GATE (2026-07-07): the fail-closed contract is now proven on the session-less/nil-param entry too** — RED PATH 5b (F3 regression) drives `[{nil,nil},{nil,"some-org"},{"op-x",nil}]` → access-denied, no data, no crash; re-confirmed LIVE this session (`curl /operator/impersonate` → **HTTP 200** + "access denied", 0 PII tokens — was HTTP 500 pre-F3). Anti-tautology re-flipped this re-gate (delete the guard → `FunctionClauseError`; revert byte-identical). Re-confirmed LIVE in my Gate-5 probe V1/V2 (operator sees org-A's driver rows; all name+CDL fields `%Masked{}`). Masked-render anti-tautology recorded in `test/web_anti_tautology_probe.md`. | **MET** |
| C3 | Unmasking one subject is second-party: operator requests, a DISTINCT party approves, enforced in policy AND a DB `CHECK (granted_by <> requestor_id)`; written to a hash-chained, tenant-readable log the operator cannot edit (:890) | ✅ TEST + LIVE PROBE | `test/web_red_paths_test.exs` RED PATH 2 (ungranted → `{:error, :denied}`; distinct-party grant → `{:ok, "CDL-OK-…"}`; SELF-approval → `{:error, :self_approval}`). Grant model + DB `rvg_distinct_party` CHECK: `samen_core/lib/samen/reveal/grants.ex` (♻️, distinct-party re-checked on read: `active?/2`). Re-confirmed LIVE (Gate-5 probe V3: no-grant denies; distinct-party grant reveals). | **MET** |
| C4 | Cross-tenant views (MRR, queues) run on a separate token-blind actor whose resources have NO `pii_` columns at all. The two paths are mutually exclusive (:890, :898) | ✅ TEST + LIVE PROBE | `Driftwood.Aggregate.{LoadVolumeByLane,MrrByTier}` carry only lane/tier/counts/cents — no `pii_` (`lib/driftwood/aggregate.ex`). `mix samen.verify.no_pii_columns` (C7) green in `driftwood/ci.sh` step 15. Mutual exclusion is STRUCTURAL: `Samen.Reveal.reveal/5` refuses the aggregate actor BEFORE any grant/vault check — re-confirmed LIVE (Gate-5 probe V5: `{:error, :aggregate_actor_denied}`). `test/web_red_paths_test.exs` RED PATH 3 (aggregate DOM has no `••••`/`CDL`/name/`vt_`/driver_id; control: it DOES show the lane cohort + MRR). | **MET** |
| C5 | "Time-boxed" is a built mechanism: a grant row carries `expires_at` (minutes default); the `:reveal` policy denies the moment `now() > expires_at`; an Oban auto-revoke job scheduled in the SAME transaction; no renew-in-place (:892) | ♻️ SUBSTRATE | `samen_core/lib/samen/reveal/grants.ex`: `active?/2` deny-on-read on expiry (no dependence on the job), `approve/2` enqueues `AutoRevokeWorker` in the SAME `Ecto.Multi`, `attempt_extend/2` always `{:error, :no_renew_in_place}`. Driftwood configures `reveal_grant: Samen.Reveal.Grants` (`config/config.exs:63`) and drives it end-to-end (RED PATH 2). Substrate red paths in `samen_core`; Driftwood exercises the wired model. | **MET (substrate, wired + driven in Driftwood)** |
| C6 | Break-glass: a locally-durable, deferred-anchor, hash-chained record on the operator node's own disk (fsync'd), anchored into the WORM chain when the control plane returns; chain detects any gap or tamper (:951) | ♻️ SUBSTRATE + 🟡 RESIDUE | Break-glass deferred-anchor + reconciliation proven in `samen_core` (`break_glass/local_audit.ex`, `break_glass/reconciliation.ex`) and `demo` (`test/adversarial/break_glass_abuse_test.exs`). **Not exercised on a Driftwood-specific scenario** — no freight break-glass game-day. Inherited unchanged; a Driftwood break-glass drill is a carry-to-P6 item. | **MET (substrate)** + CAVEAT (no Driftwood-specific drill) |
| C7 | The hash-chained tenant-readable log is immutable AND crypto-shreddable (stores token references + key-destroyable ciphertext only) (:898) | ✅ LIVE PROBE + 🎯 | **Live Gate-5 forgery probe (V9):** the `aud_chain` table has a DB-level append-only trigger — a raw SQL `UPDATE` was REFUSED with `aud_chain is append-only: UPDATE and DELETE are not permitted`. The hash chain also detects an in-memory payload forgery (`verify_entries` → `{:error, {:hash_mismatch, 0}}`) and verifies clean on the untampered list (non-vacuous). **T5.4 game-day** proves the chain still VERIFIES post-shred and its entries carry no plaintext CDL/name (`reports/T5.4.md` §6). | **MET** |

---

## C. Data tier — "One Postgres is the whole stateful surface" (§data, :573–:637)

| # | Claim (doc line) | Class | Driftwood evidence | Verdict |
|---|---|---|---|---|
| D1 | Append-only, time-partitioned event/audit table; BRIN on time; rollups refreshed by AshOban; dashboards read the small summary, never a live scan (:587–:616) | ✅ TEST + 🟡 RESIDUE | The broker dashboard reads the `dbs_broker_summary` rollup (`lib/driftwood/broker_rollup.ex`), NEVER a raw scan — the LiveView reads `BrokerRollup.summary/2` (`broker_live.ex`). Aggregate reads `dag_/dtq_` projections. **The rollups are refreshed by plain functions the dogfood drives, NOT yet AshOban cron workers** — the same honest simplification demo made (`reports/T5.3.md` "honest residues"). BRIN/partitioning is a substrate posture on `aud_event` (♻️). | **MET (rollup-backed)** + CAVEAT (refresh is a fn, not a cron worker) |
| D2 | Token-only-downstream invariant: across live/replica/backup-PITR/CDC/rollup/audit tiers, personal data exists only as ciphertext or a vault-FK token (:637) | 🎯 GAME-DAY | **T5.4 crypto-shred game-day** seeds a real driver across EVERY tier (domain, vault, aud_event, driver-keyed rollup, oban args, aud_chain, non_pii!) then runs `mix samen.verify.no_plaintext_pii --subject <uuid> --tiers all` as a SEPARATE OS process → EXITS 0 with 15 positive attestations (`reports/T5.4.md`). CI step 19 regenerates + re-verifies on every run. | **MET** |
| D3 | Destroying one subject's external-KMS key makes their vault-tokenized PII undecryptable across live/replica/backup-PITR/CDC/rollup/audit at once — a key-destruction, not copy-chasing (:637) | 🎯 GAME-DAY | T5.4: `Samen.Erasure.shred/2` → KMS `:shredded` tombstone; post-shred the CDL reveal returns `{:error, :shredded}`, no vault row decrypts, the driver is unrecoverable across every scanned tier; both rollup arms (rebuild + suppress) exercised (`reports/T5.4.md` §2,4,5). Re-confirmed the CDL is unrecoverable cross-tier (§7 RED). | **MET** |
| D4 | The per-subject key is NOT a Postgres row — it lives in an external KMS outside the WAL/PITR surface; a PITR restore brings back ciphertext, never the key; `no_plaintext_pii` audits the key store + PITR history as tiers (:637) | 🎯 GAME-DAY + 🟡 RESIDUE | T5.4 oracle attests `kms_store_backups` (external store has PITR DISABLED) + `live` (no key column on `pii_vault`). **T5.5** proves it physically: the `pg_dump` restore resurrects the CDL **ciphertext** but, pointed at an empty key dir, `reveal` returns `{:error, :unavailable}`; the dump was grepped and contained no `master.key`/`.dek` (`reports/T5.5.md` §T5.5(c)). **The `pitr_history` tier is a documented SEAM** (no PITR-snapshot repos passed; a real Neon branch-restore is an operator TODO). The **replica** tier is `--replica none` (no physical replica here). **AWS KMS is simulated by `Samen.Kms.FileBacked`** — external to Postgres in both, so the load-bearing exclusion is identical. | **MET (as local sim)** + CAVEAT (PITR-history + replica + real KMS = operator TODOs) |
| D5 | Derived aggregates governed by minimum-cohort suppression + rebuild-or-exclude-on-erasure (an aggregate computed before a shred must not resurrect the erased subject) (:637, :947) | 🎯 GAME-DAY + ✅ LIVE PROBE | T5.4 exercises BOTH arms on a driver-keyed rollup `drl_driver_load_count`: REBUILD (raw retained → recompute driver-free → post-shred count = 0, no resurrection) and SUPPRESS (`raw_retained?: false` → `drl_suppressed=TRUE`) (`reports/T5.4.md` §5). Minimum-cohort (k=2) suppression re-confirmed LIVE (Gate-5 probe V4: no cohort below k leaks an unsuppressed count/MRR). | **MET** |
| D6 | CDC mirror carries token-blind rows; analytics inherits erasure for free; "never read a current value from the analytics tier" (:635, :637) | 🟡 RESIDUE | **CDC/ClickHouse is not enabled** in Driftwood (the doc's explicit opt-in power-up, default off). The T5.4 oracle attests `cdc_mirror` as a STUB ("CDC mirror not enabled … a real content scan + never-read-current lint lands with T6.5 — operator TODO"). Not faked; named as a Phase-6 power-up. | **CAVEAT (opt-in, not enabled — operator TODO)** |

---

## D. External surface — "a versioned public API and webhooks" (§external-surface, :693–:730)

| # | Claim (doc line) | Class | Driftwood evidence | Verdict |
|---|---|---|---|---|
| E1 | A B2B SaaS still ships a public API; `api_key`/`webhook` are inherited objects; the public API is AshJsonApi/AshGraphql over the SAME Ash resources the UI + operator plane use (:701) | ✅ TEST (F1 landed P6) | **F1 (Gate-5 carry) LANDED:** Driftwood now mounts a versioned public JSON:API over `Driftwood.Freight` — `DriftwoodWeb.Router` forwards `/api/v1` → `DriftwoodWeb.Api.Endpoint` (`KeyAuthPlug` → `AshJsonApi.Router` over the SAME Ash Driver resource the UI/operator plane use). `Driftwood.Freight.ApiKey` (abbrev `dak`) is the inherited two-key-class credential. `api_contract.v1.json` now pins the Driver routes (`/api/v1/drivers`, `/drivers/:id`); `ci.sh` step 13 fails on any structural break. `test/api_external_surface_test.exs` (8 tests). | **MET (F1 landed)** |
| E2 | Two key classes: a tenant key reads its OWN org's PII in CLEAR (no operator grant); an operator/cross-tenant key is masked-by-default, plaintext only under a live grant (:707) | ✅ TEST (F1+F2 landed P6) | **F1+F2 (Gate-5 carries) LANDED — both halves now realized on freight.** JSON:API (F1, `test/api_external_surface_test.exs`): a `:tenant` key reads its own org's driver CDL + name in CLEAR (no grant); a `:operator` key sees the vaulted CDL ABSENT without a grant, PLAINTEXT with a live distinct-party grant; a cross-org tenant key sees zero foreign rows. Broker CONSOLE (F2): the broker scope carries `plane: :tenant`; `Driftwood.Reads.driver_roster/1` threads it through `Samen.Api.PiiResolution.resolve/4` so the broker reads its OWN drivers' CDL/name in clear, while the OPERATOR impersonation scope (`plane: :operator`) keeps them `••••` — same resolver, opposite plane (`test/web_red_paths_test.exs` RED PATH 6, `dogfood_walkthrough_test.exs` step 6). Both anti-tautology-flipped (no-op resolver → tenant-clear fails; force-plane-tenant → operator-masked fails; reverted byte-identical). | **MET (F1+F2 landed)** |
| E3 | Serialization allowlist: columns not auto-published; a masked value serializes as `••••`; the payload exposes the catalog field name, never the physical storage name or vault; PII absent by omission is structural (:711) | ✅ TEST (F1 landed P6) | **F1 LANDED on freight.** The Driver `json_api do show_fields([…]) end` allowlist is opt-in (default not-exposed): `org_id` + the `custom` bag are ABSENT by omission (`api_external_surface_test.exs`). The `driver.updated` webhook (`Driftwood.Webhooks`) serializes the masked composite `full_name` as `••••`, never plaintext, never a `vt_` token, never a storage name; the `load.status` webhook over DispatchEvent is catalog-named, opt-in, non-PII. **Honest P6 finding (in the test):** `Samen.Webhook.Payload`'s storage-name heuristic `~r/^[a-z]{3}_/` false-positives on freight CATALOG names (`cdl_number`, `cdl_state`, `eld_provider`) and DROPS them from the webhook body — over-strict (absent, never a leak); the JSON:API surface (AshJsonApi serializer + PiiResolution) renders CDL correctly. | **MET (F1 landed) + honest P6 finding** |
| E4 | Inbound API runs the SAME org-scope + RBAC + reveal-grant checks; outbound webhooks emit the SAME masked, catalogued payloads; `api_contract` verifier fails on an un-versioned structural break (:707, :730) | ✅ TEST (F1 landed P6) | **F1 LANDED on freight.** Inbound: the JSON:API runs the Driver's OWN policy stack (OrgScope + the two-key-class plane rule) — a cross-org tenant key sees zero rows, an operator key is masked without a grant, an actor-less request sees zero rows (fail closed) (`api_external_surface_test.exs`). Outbound: `Driftwood.Webhooks.{load_status,driver_updated}` emit via the SAME `Samen.Webhook.Payload` (opt-in allowlist, `••••` masked PII, catalog names only). `api_contract --version v1` now diffs a NON-empty committed contract (Driver routes) so a structural break is caught (`ci.sh` step 13). | **MET (F1 landed)** |

---

## E. The honest edges (§limits, :937–:959)

| # | Claim / honest-edge (doc line) | Class | Driftwood evidence | Verdict |
|---|---|---|---|---|
| H1 | Token-blind ≠ inference-blind; k-anonymity is the floor; k-anon + l-diversity enforced TODAY; cross-query budget / DP is posture-under-construction, not a solved proof; per-actor accounting named as the wrong unit (:947, :906) | ✅ TEST + 🟡 RESIDUE | k=2/l=2 floors configured (`config/config.exs:83–84`) and enforced by `mix samen.verify.aggregate_privacy` (green, ci.sh step 16) + the read path (`Samen.Aggregate.read_all/2` → `%Suppressed{}`). Live Gate-5 probe V4: no cohort below k leaks. **T6.6 UPDATE (samen_core + demo):** the query budget is now **ENFORCING** (opt-in) — a per-cohort/global read budget DENIES (suppresses with `reason: :query_budget`) further reads once spent, keyed per-cohort so two colluding actors share ONE budget (`Samen.Aggregate.QueryBudget.check/2`; demo differencing suite proves the above-floor differencing residue is now BLOCKED when opted in). A calibrated Laplace **DP noise** layer (`Samen.Aggregate.Dp`, opt-in, configurable ε) exists and is distribution-tested. **STILL posture (named, not claimed):** the FORMAL DP composition guarantee (an ε-budget composed across queries) and t-closeness — the enforcing budget is a deterministic read-COUNT budget, NOT an ε-budget proof (`samen_core/reports/T6.6.md`). Both flags default OFF; Driftwood has not yet opted in (a vertical carry). | **MET (floor + enforcing budget) + honest DP posture** |
| H2 | "Can't log it ⇒ can't see it" is a real availability cost; routine reveal fails closed if the audit sink / control-plane DB is unreachable; the KMS gets its own availability posture; a KMS partition denies decrypts, never resurrects a key or exposes plaintext (:951) | 🎯 GAME-DAY + ♻️ | T5.5 proves KMS-unavailability fails CLOSED: an empty key dir → `reveal` returns `{:error, :unavailable}` (`reports/T5.5.md` §T5.5(c)). Fail-closed reveal on an unreachable grant/suspension table is ♻️ substrate (`suspended?/2` defaults to "suspended"; `for_session/3` denies). | **MET** |
| H3 | One substrate is one blast radius — engineered down (BEAM isolation, Oban SKIP LOCKED + per-queue limits, read replica, expand/contract + lock/statement_timeout + PITR with stated RPO/RTO) (:953) | 🎯 GAME-DAY + 🟡 RESIDUE | The bad-migration incident — "the highest-consequence incident we run" — is the T5.5 drill (both arms, production-sized, key-store exclusion). Oban is wired (`lib/driftwood/jobs/dispatch_worker.ex`, `AutoRevokeWorker`). **Read replica is not provisioned locally** (operator TODO); the drilled RTO numbers are local-sim floors, not the real Neon RTO (named honestly in `reports/T5.5.md`). | **MET (as local sim)** + CAVEAT |
| H4 | Erasure of a `non_pii!` plaintext-at-rest column is by row-level deletion/redaction (not key-shred); the destruction oracle includes the registered-non_pii! set in its tier list (:927) | 🎯 GAME-DAY | Driftwood registers `drv_cdl_state`/`drv_cdl_expiry` via reviewed `non_pii!` (distinct reviewers; `pii_classify` fails without it — `reports/T5.2.md` OR-2). T5.4 oracle attests `registered_non_pii` redacted post-shred (`cdl_state → [REDACTED_NON_PII]`, `cdl_expiry → 1970-01-01` sentinel) (`reports/T5.4.md` §4). | **MET** |
| H5 | The trace-sink pseudonym + `non_pii!` are the two key-shred carve-outs; the reveal-request `reason` free-text is a NON-shreddable plaintext channel (ADR-002 §2.5) with a fail-closed value-shape scan (:637, F4.3) | ✅ TEST + ♻️ | The reveal-request `reason` PII-shape scan fires in Driftwood: CI-log evidence this session ("Samen.PiiReasonScan: rejected a ssn-shaped / email-shaped reveal-request reason — Refusing the write"). The residue is named in `docs/adr/002-worm-anchor.md §2.5` (♻️). T5.4 oracle attests the trace-sink pseudonym goes unlinkable at shred (`reports/T5.4.md` §3). | **MET** |
| H6 | You inherit infrastructure, NOT a domain model; every non-trivial vertical re-identifies the core nouns (Company→Carrier/Shipper, Opportunity→Load, Activity→Encounter) and reshapes billing (settlement-netting) — bounded-context translations, not additive extensions (:556, :566, :959) | ✅ TEST | `Driftwood.Context` (`lib/driftwood/context.ex`): `alias_resource Company as: Carrier AND Shipper` (two aliases, one kernel Company), `Opportunity as: Load`, `Activity as: CheckCall`; `reshape Settlement` netting calcs. Proven by `test/context_aliases_test.exs` (both aliases resolve to `Driftwood.Crm.Company`) + `test/settlement_math_test.exs`. The anti-corruption REFUSAL is itself proven: an alias/reshape cannot add the FMCSA FK/validation, so dispatch is a vertical `DispatchEvent` resource (design §1.4, `reports/T5.2.md`). | **MET** |

---

## F. Driftwood-specific domain claims (the freight table, :425–:437, :556)

| # | Claim | Class | Driftwood evidence | Verdict |
|---|---|---|---|---|
| DW1 | `pii_drv_cdl_number text → vault`; `drv_cdl_state`/`drv_medical_card_expiry` core; `drv_carrier_id → company tbl`; `drv_eld_provider enum → Tier-0`; driver composes person (:425–:435) | ✅ TEST | `lib/driftwood/freight.ex` Driver composes `Samen.Fragments.CorePerson` + `pii_attribute :cdl_number vault: :pii_cdl` + non-PII cdl/medical + Tier-0 `eld_provider` + `belongs_to :carrier` → `cmp_company`. `test/cdl_vault_test.exs` (vault round-trip), `schema.dict.json` (11 tables). | **MET** |
| DW2 | FMCSA compliance demands encrypted CDL + hard expiry tracking before a driver can be legally dispatched (:437) | ✅ TEST + LIVE PROBE | `lib/driftwood/policy/fmcsa_dispatch_gate.ex` refuses expired-medical / missing-medical / expired-CDL / missing-CDL / shredded-CDL / out-of-service / terminated — writing NO row; a compliant driver dispatches. `test/fmcsa_dispatch_gate_test.exs` + `test/adversarial/driftwood_attack_matrix_test.exs`. The gate reads only expiry DATES + CDL-token PRESENCE (never decrypts — off the `pii_reads` path). Live Gate-5 probe V7: the FMCSA error message carries NO plaintext CDL. | **MET** |
| DW3 | Billing reshaped to settlements: invoice = carrier settlement (linehaul − advances − factoring); two-sided money (:556) | ✅ TEST + LIVE | `Driftwood.Context` `reshape Settlement`: `net_payable = max((linehaul+fuel+accessorial) − advances − factoring_fee − claims, 0)`, `carryover = max(-net_raw,0)`. `test/settlement_math_test.exs`: 4 worked examples to the cent + 200-run property vs an independent reference; OR-5 integer-division truncation pinned. Live (T5.3): $4800−$500−$156−$50 = $4494 net payable. Two-sided: AR = kernel Invoice, AP = Settlement. | **MET** |

---

## G. FINDINGS (claims with a gap or a deviation on the running Driftwood app)

### ✅ F1 (LANDED, P6) — Driftwood now mounts a versioned public API/webhook surface over freight; the external-surface guarantees are proven on freight PII

**RESOLVED (P6 PRE, this session).** Driftwood mounts a versioned public JSON:API +
webhooks over `Driftwood.Freight`:
- `DriftwoodWeb.Router` forwards `/api/v1` → `DriftwoodWeb.Api.Endpoint`
  (`KeyAuthPlug` → `AshJsonApi.Router`) over the Driver resource (`/api/v1/drivers`).
- `Driftwood.Freight.ApiKey` (abbrev `dak`, migration `20260708100000_freight_api_key.exs`,
  catalogued in-tx) is the two-key-class credential the auth resolver reads.
- The Driver carries a `json_api do show_fields([…]) end` opt-in allowlist +
  `Samen.Api.PiiResolution` prep; DispatchEvent carries a non-PII allowlist for the
  `load.status` webhook. `Driftwood.Webhooks.{load_status,driver_updated}` emit via the
  shared `Samen.Webhook.Payload`.
- The committed `api_contract.v1.json` pins the Driver routes/fields; `ci.sh` step 13
  fails on a structural break.
- Red paths (`test/api_external_surface_test.exs`, 8): CDL never plaintext in a JSON:API
  operator payload; masked webhook payload (`••••`, no storage names, opt-in); tenant key
  reads own-org CDL/name in clear; operator key CDL absent without a grant (plaintext with
  a live grant — control); actor-less request → zero rows. Anti-tautology: forcing every
  key to `plane: :tenant` flips the operator-absent path to leaking; reverted byte-identical.
- **Honest P6 finding surfaced:** `Samen.Webhook.Payload`'s storage-name heuristic
  `~r/^[a-z]{3}_/` false-positives on legitimate freight CATALOG names (`cdl_number`,
  `cdl_state`, `eld_provider`) and drops them from the webhook body — over-strict (absent,
  never a leak); flagged for the extraction retro (the heuristic should key on the
  resource's declared storage prefix, not a blanket regex).

### ✅ F2 (LANDED, P6) — The tenant-owner-sees-own-PII-in-clear rule is now realized in Driftwood's broker console

**RESOLVED (P6 PRE, this session).** The broker scope (`DriftwoodWeb.BrokerLive.broker_scope/1`)
now carries `plane: :tenant`, and `Driftwood.Reads.driver_roster/1` threads it through
`Samen.Api.PiiResolution.resolve/4` — the SAME resolver the F1 API egress uses. On the
`:tenant` plane the broker reads its OWN drivers' CDL number + name in CLEAR (no operator
reveal grant); the OPERATOR impersonation scope (`plane: :operator` + `:impersonation`
marker) keeps them `%Masked{}` (`••••`) through the same resolver — the operator plane is
untouched.
- Red paths (`test/web_red_paths_test.exs` RED PATH 6): tenant broker sees its own driver's
  CDL in clear; operator impersonating the same org still sees `••••`; a cross-org tenant
  broker sees zero foreign-org drivers. `dogfood_walkthrough_test.exs` step 6 updated to the
  corrected posture.
- Anti-tautology (both planes, project-local scratch, reverted byte-identical): a no-op
  resolver flips the tenant-clear path to failing; forcing every actor to `plane: :tenant`
  flips the operator-masked path to leaking.
- Fail-safe preserved: a plane-less/org-less scope resolves to the default masked posture;
  a decrypt error leaves the value masked (never a leak).

### ✅ F3 (FIXED IN-PHASE) — `/operator/impersonate` with no `operator_id`/`org_id` params used to 500 instead of rendering the documented "access denied" state (availability defect; no PII leak)

The `OperatorImpersonationLive` moduledoc claims: "an expired/absent session yields
`{:error, :session_inactive}` and the view renders the access-denied state, no data."
**But a request with no params/session (the default) crashes with a 500:** `mount/3` →
`load/3` with `operator_id = nil` → `Samen.Impersonation.scope(nil, …)` →
`Samen.Impersonation.operator_id(nil)` raises `FunctionClauseError` (no nil clause). The
LiveView only handles the `{:error, :session_inactive}` tuple, but `scope/3` **raises**
before returning it when the operator id is nil.
- **Verified live:** `curl http://localhost:4010/operator/impersonate` → **HTTP 500**; boot
  log shows the `FunctionClauseError`. `RED PATH 5` in `web_red_paths_test.exs` passes only
  because it feeds an explicit `op.id`, so it never exercises the nil path.
- **Impact:** **availability/robustness only — NO PII leak** (the 500 body is
  `Internal Server Error`; grepped for CDL/name/`vt_` → nothing). But it contradicts the
  moduledoc's fail-closed contract and would be a broken operator-plane entry page for any
  session-less/mis-configured request.
- **FIX LANDED (this Gate-5 session):** `OperatorImpersonationLive.load/3` now guards a
  non-binary `operator_id`/`org_id` and renders the access-denied state via a shared
  `denied/3` helper; it also handles the `{:error, :operator_suspended}` shape (which
  `for_session/3` can return and the old code would have crashed on). **Verified live:**
  `curl /operator/impersonate` → HTTP **200** + "access denied" (was 500), no PII in body.
  **Regression test added:** `test/web_red_paths_test.exs` RED PATH 5b (nil/partial-param
  matrix renders access-denied, never crashes). Driftwood suite: **47 passed** (was 46);
  `driftwood/ci.sh` + root `ci.sh` GREEN after the fix.
- **RE-GATE RE-CONFIRMED (2026-07-07):** F3 re-verified independently this session — the
  guard is present (md5 `9d08cb6211418176cea2e63cd577a3a0`), RP5b passes (6/6 in
  `web_red_paths_test.exs`), a fresh project-local sabotage (delete the guarded `load/3`
  head) **flipped RP5b to failing** with the exact `FunctionClauseError` at
  `Samen.Impersonation.operator_id/1`, reverted byte-identical, scratch removed. Live re-boot:
  `curl /operator/impersonate` → HTTP **200** + "access denied", 0 PII tokens. `driftwood/ci.sh`
  ALL PASSED + root `bash ci.sh` exit 0; oracle (`--tiers all`, separate OS process) EXITS 0
  with 15 attestations. The fix is landed, non-vacuous, and live-verified.

---

## H. Phase-6 doc-parity addendum (Gate 6, T6.7) — the foundry-readiness sections

The Gate-5 table above covers §runs / §control / §data / §external-surface / §limits on the
*running Driftwood app*. Gate 6 extends the map to the vision-doc sections the foundry itself
generalizes: **§llm** ("software an agent builds", :921–:923), the **foundry / Rule-of-Three**
framing (:67, :957), the **ClickHouse/CDC power-up** (:625–:637), and the **aggregate
output-privacy** posture (:906, :947). Each maps to a **passing test / eval**, a **generated
artifact**, a **named honest residue**, or an **operator-TODO** — never faked. Evidence
independently re-run this gate is marked ⟳.

| # | Claim (doc line) | Class | Evidence | Verdict |
|---|---|---|---|---|
| **L1** | "Samen removes the blank page. Every object and field is in the catalog, so the agent grounds on a known model." (:921) | ✅ TEST | `schema.dict.json` on all 4 hosts is a committed, resource-qualified, PII-flagged dict (`mix samen.catalog.dump`, T6.3); each host's `ci.sh` drift-check confirms committed == code ⟳. `docs/guides/llm-grounding.md` documents the two-name identity model + the authoring loop. | **MET** |
| **L2** | "a schema hallucination fails at compile time … a CI linter rejects any reference to a column that isn't catalogued — a hallucinated field doesn't compile" (:923) | ✅ TEST + real OS-exit proof | `agent_authoring_eval_test.exs` case 2 (T6.3): a hallucinated/uncatalogued column FAILS `catalog_parity` + `column_refs`, driven through a **real `System.cmd/3` child process** — `mix samen.verify.catalog_parity` EXITs **1** on the seeded column, **0** on the clean host (true `:erlang.halt(1)`). 13/13 eval green ⟳. | **MET** |
| **L3** | "net-new PII … attribute :ssn, :string … is caught by mix samen.verify.pii_classify before it merges, or requires an explicit audited non_pii! override" (:923) | ✅ TEST | Eval case 3: a net-new plaintext `attribute :ssn, :string` FAILS `pii_classify` (exit 1). Case 5: a vault value logged outside `:reveal` FAILS `pii_reads`. Case 4: an unprefixed column FAILS `prefixes`. Case 6: a `belongs_to` with no `SameOrgFk` FAILS `same_org_fk`. Case 1 (a correct resource) PASSES — the non-vacuous positive control. Anti-tautology (T6.3): sabotaging `pii_classify.check` flips ONLY case 3 to uncaught, reverted byte-identical. | **MET** |
| **L4** | The agent disambiguates by the resource-qualified catalog entry, not a bare field name; `pii` keyed on the vault DECLARATION not the `pii_` prefix (:923) | ✅ TEST | `catalog_test.exs` (+2, T6.3): the `pii` boolean keys on `Samen.Pii.Info.vault_routed_columns/1` — a composite `per_full_name`/`pat_full_name` (no `pii_` prefix) is correctly `pii:true`; an anti-vacuity guard asserts BOTH true and false appear. | **MET** |
| **F0** | "the core extracted by the Rule of Three … pays from the third product on — not a foundry you build before you've shipped one" (:67, :957) | ✅ TEST + 🟡 RESIDUE | `docs/extraction-retro.md` (T6.1) applies the counting rule HONESTLY (demo + driftwood = 2, not 3); ONE extraction where the copy was byte-identical + security-critical (A4 aud_chain → `Samen.OperatorPlane.Migration`, 10 red-path tests + anti-tautology ⟳); everything else ADR'd (006/007) or backlogged with a trigger. **RESIDUE (honest, matches the doc):** the inheritance is measured on 2 self-built hosts; a 3rd *independently-motivated* vertical would sharpen several abstractions (A3/A5). Named, not oversold. | **MET (honest)** |
| **F1r** | "build the 20%, inherit the 80%" — reuse thesis (:542) | ✅ MEASURED + calibrated | `pawchart/docs/reuse-measurement.md` (T6.2): **4 of 6 idioms at ZERO vertical code**; PII vault = 1 line; operator plane = 42 lines (one projection); ~96% inherited against the 4 families a clinic touches; **all 15 verifiers green on FIRST invocation** (zero verifier fixes) ⟳. **Calibrated honestly (the doc's own edge :542):** the *domain* 20% (the two nouns) stays authored real work — "you inherit INFRASTRUCTURE, not a domain model." | **MET (on the axis the doc claims)** |
| **F2r** | Generators / installer — a builder can start a new SaaS on the substrate (plan T6.4; foundry framing) | ✅ TEST (red-path re-run) | `mix samen.gen.app` (T6.4). **Re-run independently this gate ⟳:** `--module Gate6probe --prefix zx --abbrev zxq` → the generated app's full 17-step `ci.sh` EXITs **0** on first run (correct-by-construction, incl. its own vault anti-tautology probe flip); the `--no-reserve-abbrevs` variant FAILS CLOSED at compile: `abbrev "zyc" … is not in the abbrev registry … Abbrevs are permanent and must be reserved`. Registry restored byte-identical, scratch apps removed. **Operator-TODO:** committing a generated app means committing the appended global-registry rows (N1 / ADR-006). | **MET** |
| **P1** | "ClickHouse is a power-up, not a prerequisite … opt-in per product, default off … never read a 'current' value from the analytics tier" (:625, :635) | ✅ TEST + 🟡 RESIDUE | `Samen.Cdc` (T6.5): default OFF, pays nothing; `LocalPostgres` sim mirrors a token-blind projection into a second schema; `ClickHouse` skeleton (`ecto_ch`, config-flagged, fails closed unconnected); `read_current/3` ALWAYS raises + `mix samen.verify.never_read_current` AST lint (green/vacuous with the tier off ⟳). **RESIDUE:** real ClickPipes/`ecto_ch` wiring + a CI diff of the pipe allow-list are operator TODOs (`docs/cdc-analytics-tier.md`). | **MET (mechanism + sim)** + CAVEAT (real wiring = TODO) |
| **P2** | "The token-only-downstream invariant is what makes the mirror safe … the CDC mirror … carries vault tokens, not plaintext PII" (:637) | ✅ TEST (re-run on freight) | `Samen.Cdc.Projection` excludes plaintext PII BY CONSTRUCTION; the oracle `cdc_mirror` tier does a real schema+content scan when on (RP-A/RP-B/RP-C fail closed, 12 tests + anti-tautology flip ⟳). **Red-teamed this gate against the real freight Driver:** `project/1` includes ZERO plaintext_pii columns; the vaulted `pii_drv_cdl_number`/`drv_full_name`/`drv_emails`/`drv_phones` classify as `:token` (safe vt_ FKs); `assert_no_plaintext!(Driver, :all)` REFUSES the naive mirror-everything request. | **MET** |
| **A1** | "the aggregate plane enforces today a minimum-cohort and minimum-distinct floor (k-anonymity + l-diversity), and treats the cross-query / differencing defense … as posture under construction" (:906) | ✅ TEST + 🟡 RESIDUE | k=2 / l=2 floors enforced (fail-closed) — green across demo/driftwood/pawchart gates ⟳. **T6.6 promoted the query budget to ENFORCING** (opt-in): a per-COHORT/global read budget DENIES further reads once spent; two colluding actors on one cohort share ONE budget (the doc's "per-actor is the wrong unit" now an *enforced* outcome, `aggregate_differencing_test.exs` +4). **RESIDUE (named, matches doc):** the enforcing budget is a deterministic read-COUNT budget, NOT a formal ε-budget. | **MET (floor + enforcing budget)** |
| **A2** | "a differential-privacy posture (calibrated noise composed across queries) … posture under construction, not a solved proof … t-closeness on the same track … per-actor accounting as the wrong unit" (:906, :947) | 🟡 POSTURE (honest) | `Samen.Aggregate.Dp` (T6.6): a distribution-tested Laplace mechanism (opt-in, configurable ε; empirical mean ≈ 0, variance ≈ 2b² over 20k draws). **The moduledoc is scrupulously honest — a single ε-release is NOT a system-level guarantee; composition (the averaging attack) and t-closeness stay explicitly OPEN.** There is deliberately NO flag that flips on a "formal DP guarantee." This is the doc's posture, carried faithfully — NOT an oversell. | **MET (mechanism shipped, posture honestly labeled)** |

**No new oversell found.** Every Phase-6 claim maps to a runnable eval / generated artifact / red-teamed mechanism, with the two genuinely-open items (formal DP composition, t-closeness) named as posture-under-construction in exactly the doc's own words. The one place a builder must not be misled — the DP mechanism could imply a guarantee it lacks — is guarded by the moduledoc + the OFF-by-default flags + the A2 row above.

---

## I. Summary

- **Every load-bearing claim** in §runs / §control / §data / §external-surface / §limits
  (sections A–G) maps to a passing Driftwood test, a game-day artifact, a substrate-inherited
  proof, or a **named honest residue** — and the **Phase-6 foundry sections** (§llm,
  Rule-of-Three, CDC power-up, DP posture) are now mapped in **section H** (L1–L4, F0/F1r/F2r,
  P1/P2, A1/A2). **No claim is left un-evidenced and un-labeled.** F1/F2/F3 are all resolved.
- **On the RUNNING Driftwood app**, the core privacy/authz/crypto-audit guarantees HOLD
  under adversarial probing: cross-org isolation, masked impersonation, grant-gated reveal,
  structural aggregate mutual-exclusion, k-anon suppression, append-only tamper-evident
  audit chain (DB-trigger + hash-chain), FMCSA gate, and error-path/settlement no-leak — all
  re-confirmed live this session, with a genuine anti-tautology flip on the reveal grant gate.
- **Findings:** **F3** (impersonation no-session 500) was a real availability defect on a
  documented fail-closed path — **FIXED in-phase** with a regression test (no PII leak; the
  running product now honors its contract). **F1** (no freight API/webhook surface —
  external-surface guarantees proven only in `demo`, not on freight PII) is a labeled
  residue → **carry-to-P6** fix task. **F2** (tenant-owner sees own PII masked, inverting
  the two-key-classes rule) is a **fail-safe** deviation (over-masking) and a stated posture
  → carry-to-P6 or accept.

---

## J. Phase 1 (BATON) — WS-A identity spine + WS-H rich types (INV-6)

Added by the Phase-1 gate (T16, 2026-07-22). Everything below is **complete + verified** at
the authoritative full-root level: `./ci.sh` passed twice consecutively (`ROOT CI: ALL PASSED`,
seeds 611057/182579 and 201315/306140, zero re-rolls). Each claim cites its proof artifact
(INV-6: a claim without a proof artifact is not allowed). Honest scope: this is the identity
*spine* + rich types — billing, live email delivery, and AI features are later phases. The
one deliberately-deferred auth-hardening item (rate-limiting, T103) is named in row A-DEFER.

### WS-A — self-serve identity spine (generator-emitted, zero-hand-edit)

| Req | Claim | Class | Evidence | Verdict |
|---|---|---|---|---|
| A1 | Self-serve registration creates Org+User+Membership atomically, credential PII vaulted | ✅ TEST | `samen_core/test/auth/{blind_index,hasher}_test.exs`; gen-app flagship probe "signup (A1) created org+user+owner-membership atomically" (root `ci.sh`) | **MET** |
| A2 | Email verification token round-trips and is single-use | ✅ TEST | `samen_web/test/samen/web/auth/confirm_test.exs`; `samen_core/test/policy/verified_test.exs`; flagship "verify (A2) token round-tripped + is single-use" | **MET** |
| A3 | Password reset token loop (no account-existence timing oracle) | ✅ TEST | `samen_web/test/samen/web/auth/confirm_test.exs`; `samen_core/test/delivery_auth_mailer_test.exs` (fail-honest AuthMailer — `:blocked`, never fake `:delivered`) | **MET** |
| A4 | Session management: remember-me, listing, revocation, policy; deterministic org-cap eviction (oldest-first) | ✅ TEST | `samen_web/test/samen/web/auth/session_test.exs`; `samen_core/test/auth/device_label_test.exs` (usec `inserted_at` + `{inserted_at,id}` strict order — the T104 fix) | **MET** |
| A5 | Team invitation lifecycle: invite → accept → membership in the inviting org | ✅ TEST | `samen_web/test/samen/web/auth/invitation_test.exs`; flagship "invite (A5) accept landed a membership" | **MET** |
| A6 | OIDC login (Google reference; SAML seam) **honors TOTP** — federated login steps up through /2fa | ✅ TEST | `samen_web/test/samen/web/auth/oidc_test.exs`; **`samen_web/test/samen/web/auth/oidc_totp_stepup_test.exs`** (T100 red tests — closes an account-takeover 2FA-bypass; zero Session until second factor) | **MET** |
| A7 | TOTP 2FA + vaulted recovery codes; enrollment reachable over a **production HTTP route** | ✅ TEST + LIVE PROBE | `samen_web/test/samen/web/auth/totp_test.exs`; `router.ex:663` mounts `live(".../security/2fa", TotpEnrollLive)`; flagship `GET /settings/security/2fa → 200` | **MET** |
| A8 | Onboarding wizard scaffold (first-run seam) with honest `:not_configured` empty state | ✅ TEST | `samen_web/test/samen/web/auth/onboarding_test.exs`; flagship "A8 wizard offered + plan hook is the honest :not_configured empty state (INV-4)" | **MET** |
| A9 | `mix samen.gen.app` emits the full auth spine with zero hand-edits | ✅ TEST | `samen_core/test/gen_app_test.exs`; the gen-app flagship probe IS the AC-X-1 proof (permanent root `ci.sh` step) | **MET** |
| A10 | Auth events → notifications + audit/CDC; login-family taxonomy (login/login_failed/logout/session_revoked/sessions_revoked_all) | ✅ TEST | `samen_web/test/samen/web/auth/auth_events_test.exs` (T09); `samen_web/test/samen/web/auth/login_events_test.exs` (T101 — `subject_id` always set); `Samen.Notifications.Engine` wired on demo + generated hosts (`demo/config/config.exs:44`; flagship "engine wired, fan-out dispatched") | **MET** |
| A-DEFER | **Auth-surface rate-limiting + bounded `login_failed` audit (T103, ADR-035 §4.5 / ADR-037 §5.14)** | 🟡 RESIDUE | **Deliberately deferred to early Phase 2 behind T17's ingress-limit ADR.** The brute-force / credential-stuffing control is NOT yet wired — the identity spine is complete, its rate-limit hardening is not. Named so no claim implies the auth story is finished. | **DEFERRED (named)** |

### WS-H — rich-type foundation + vault-write validation

| Req | Claim | Class | Evidence | Verdict |
|---|---|---|---|---|
| H1 | `Samen.Type.Money` (ash_money/ex_money) + Opportunity/Price migration | ✅ TEST | `samen_core/test/type/money_test.exs`; `samen_web/test/samen/web/csv_money_test.exs` | **MET** |
| H2 | Scalar types Percent / Score / Duration / Priority | ✅ TEST | `samen_core/test/type/{percent,score,duration,priority}_test.exs` | **MET** |
| H3 | Contact scalar types URL / EmailAddress / PhoneNumber (cast + normalize) | ✅ TEST | `samen_core/test/type/{url,email_address,phone_number}_test.exs` | **MET** |
| H4 | Address composite type | ✅ TEST | `samen_core/test/type/address_test.exs`; migration `20260721180000_rich_types_address_dob.exs` | **MET** |
| H5 | `pii_address` / `pii_dob` vault classes | ✅ TEST | `samen_core/test/type/address_test.exs` + the rich-types-address-dob migration | **MET** |
| H6 | Custom-field types over the rich menu | ✅ TEST | `samen_core/test/custom_fields_rich_types_test.exs`; `samen_core/test/red_path_vault_scan_test.exs` | **MET** |
| H7 | `gen.resource` full type menu | ✅ TEST | `samen_core/test/gen_post_test.exs` (post-app generator probe D7a, root `ci.sh`) | **MET** |
| H-D3 | **Vault write path re-runs declared-type `cast_input` (ADR-036 D3)** — vaulted Email/Phone/URL validated + normalized on input; garbage refused, never echoed | ✅ TEST | `samen_core/test/vault/vault_cast_validation_test.exs` (T99). Scalar-only by design; composites are a documented ADR-036 §10 follow-up | **MET (scalar); composites deferred** |

**Security defects caught-and-fixed by adversarial verification (Phase 1):** OIDC account-takeover
2FA-bypass (T100), account-existence timing oracle (T03), vault write-validation gap (T99),
loose-prefix leak-detection under-check (T102), and the session-cap eviction ordering **production
bug** (T104). Each fixed in-phase with a RED-on-revert proof. Full accounting:
`_orch/tasks/T16/work/phase-1-report.md`.

---

## K. Phase 2 (BATON) — WS-B Stripe billing + WS-C ESP delivery + auth rate-limiting (INV-6)

Added by the Phase-2 gate (T31, 2026-07-23). Everything below is **complete + verified** at
the authoritative full-root level: `./ci.sh` passed **twice consecutively** (`ROOT CI: ALL
PASSED`, EXIT:0, zero re-rolls; INV-3 determinism), and the **INV-4 adapters-absent probe**
holds — with `samen_stripe/` + `samen_postmark/` + `samen_ses/` + `samen_resend/` all removed,
`samen_core` (1718 passed) and `samen_web` (935 passed) still go green, so core+web carry
**zero vendor deps**. Each claim cites its green test artifact **and the lane that produced it**.

**Honest scope / lanes.** Everything in CI runs on the **keyless lane**: billing dispatch is
proven against `Samen.Billing.FakeProvider` / `Fake*Mirror` (hermetic, call-recording) and the
`samen_stripe` adapter against **injected-transport cassettes** (lane-0, no network); ESP
delivery is proven against fixtures + injected capture transports. **Production persistence is
FAKE-backed in Phase 2** — the Ash-backed mirrors exist but their host wiring + `si_` item-ref
resolution is **deferred to T108** (see below). **No host wires a live provider** — every
generated app boots with billing/ESP **unconfigured** and honestly renders the
`:not_configured` empty state. Live lanes exist but are **documented-and-not-CI**:
`STRIPE_TEST_KEY` (Stripe test-mode), `SAMEN_POSTMARK_SMOKE=1` / `mix samen.smoke.postmark`
(real Postmark API), and `SAMEN_ESP_LIVE=1` / `mix samen.smoke.{ses,resend}` (real SES/Resend).

### WS-B — Stripe billing adapter (fail-honest, vendor-free core)

| Req | Claim | Class · Lane | Evidence | Verdict |
|---|---|---|---|---|
| B1 | Billing behaviour (`Samen.Billing.Provider`, ADR-038 §3.1) + honest `FakeProvider`; `samen_stripe` skeleton is fail-honest (unconfigured→`:not_configured`, unwired→`:not_implemented`, never a fake `:ok`); tautological `SyncAdapter`/`Stub` deleted | ✅ TEST · keyless | `samen_core/test/billing_provider_test.exs`; `samen_stripe/test/skeleton_test.exs` (84 passed, standalone); `samen_core/test/billing_vendor_free_test.exs` (INV-4 ratchet, closed to 0 by T106) | **MET** — `_orch/verify/T18-verdict.json` |
| B2 | Hosted checkout: org-scoped success/cancel URLs FORCED, metadata-only (no PII, INV-1 snapshot), reconcile via the T19 dispatch on a separate `:billing_checkout_mirror` slot | ✅ TEST · keyless | `samen_core/test/billing_checkout_test.exs`; `samen_web/test/samen/billing/checkout_reconcile_test.exs`; `samen_stripe/test/checkout_test.exs` | **MET** — `T20-verdict.json` |
| B3 | Subscription lifecycle sync: fetch-on-event convergence (never trusts payload), idempotent (`last_event_id`), **out-of-order stale events discarded** (`occurred_at` watermark, `:lt`→`:stale`) | ✅ TEST + 🧨 SABOTAGE · keyless | `samen_core/test/billing_reconciler_test.exs`; `samen_stripe/test/lifecycle_sync_test.exs`; **`scripts/sabotages/29-b3-subscription-ordering-guard-drop.patch`** flips the named out-of-order tests, reverts byte-exact | **MET** — `T21-verdict.json` |
| B4 | Invoice mirror + tax fields: tax **mirrored exactly**, never a fabricated `0` (nil/`[]` passed verbatim when the provider computed none) — proven adapter→mirror→UI | ✅ TEST · keyless | `samen_core/test/billing_invoice_test.exs`; `samen_web/test/samen/billing/invoice_reconcile_test.exs`; `samen_stripe/test/invoice_mirror_test.exs`; `docs/guides/stripe-tax.md` | **MET** — `T22-verdict.json` |
| B5 | Payment methods via **Stripe-hosted surfaces only** — no card fields; a base-wired `NoPanColumns` verifier+transformer **hard-aborts compile** on any PAN-shaped column | ✅ TEST + compile-time verifier · keyless | `samen_core/test/billing_payment_method_test.exs`; `samen_core/test/no_pan_columns_red_path_test.exs`; `samen_stripe/test/payment_method_test.exs`; `mix samen.verify.no_pan_columns` (in every app `ci.sh`) | **MET** — `T23-verdict.json` |
| B6 | Hosted invoice/receipt links, **gated OFF on the operator plane** (INV-2 masked-read `writable?/1`) — raw URLs/link text refuted on the operator render | ✅ TEST · keyless | `samen_web/test/samen/web/billing_invoice_tax_links_test.exs` (operator-plane refute-assertions) | **MET** — `T22-verdict.json` |
| B7 | Dunning: grace-until-period-end on `:invoice_payment_failed`, recover on `:invoice_paid`; **symmetric watermark guard** so a stale failure can't re-clip a recovered customer (the attempt-1 money bug, FIXED) | ✅ TEST · keyless | `samen_core/test/billing_dunning_test.exs` ("out-of-order guard" block, RED-on-revert); `samen_stripe/test/dunning_test.exs` | **MET (attempt 2)** — `T24-verdict.json` |
| B8 | Usage-based metered reporting: one idempotent batch, **never marks reported on `{:error,_}`** (no double-charge / no data-loss), fail-honest `configured?/1` gate before any HTTP | ✅ TEST · keyless | `samen_core/test/billing_usage_reporter_test.exs`; `samen_stripe/test/usage_test.exs` (HTTP-500 + `:econnrefused` both leave rows pending, retry reuses keys) | **MET** — `T25-verdict.json` |
| B9 | Webhook ingress security: signature **fail-closed** (no-sig/wrong-secret/body-swap/future-ts → 400, raw bytes preserved), replay DB-unique-index-arbitrated, oversize→413, DLQ + operator view, rate-limited | ✅ TEST + 🧨 SABOTAGE · keyless | `samen_web/test/samen/web/webhook_security_test.exs`; `samen_stripe/test/webhook_security_test.exs`; **`scripts/sabotages/25-b9-webhook-signature-bypass.patch`** neuters the constant-time compare → 2 named red-paths fail, revert byte-exact | **MET** — `T19-verdict.json` |
| B10 | Billing settings page: composes B2/B4/B5 verbatim; **honest `:not_configured` empty state** with **zero fake affordances** (no plan card / checkout button / `$0.00` when unwired), emitted by the generator with zero hand-edits | ✅ TEST + LIVE PROBE · keyless | `samen_web/test/samen/web/billing_settings_live_test.exs`; the gen-app flagship probe asserts `GET /billing/settings → 200` + the exact not-configured copy (root `ci.sh`) | **MET** — `T26-verdict.json` |

### WS-C — ESP delivery adapters (behaviour + conformance + three vendors)

| Req | Claim | Class · Lane | Evidence | Verdict |
|---|---|---|---|---|
| C1 | ESP `Samen.Delivery.Provider` behaviour + a **shared, non-vacuous conformance harness**, satisfied by **all THREE adapters** — Postmark (Basic-Auth), SES (SNS RSA + SigV4), Resend (Svix HMAC) (M1 ruling: one contract, three vendors) | ✅ TEST · keyless | Harness `samen_core/lib/samen/delivery/provider_conformance_case.ex` (self-test `.../delivery_provider_conformance_case_test.exs`, non-vacuity proven by a toy adapter); `samen_postmark/test/conformance_test.exs` (38), `samen_ses/test/conformance_test.exs` (48), `samen_resend/test/conformance_test.exs` (43); vendor-freeness `samen_core/test/delivery_vendor_free_test.exs` (postmark **+ SES + Resend distinctive-token bans, T31 #5**) | **MET** — `T27`/`T94`/`T95-verdict.json` |
| C2 | Outbound send has a **single chokepoint** (`Samen.Delivery.Chokepoint` is the sole caller of `deliver/2`); suppression fail-closed + uniform across all 4 families; no fake-ok | ✅ TEST · keyless | `samen_core/test/delivery/lifecycle_send_test.exs` (full-repo grep + anti-tautology twin) | **MET** — `T28-verdict.json` |
| C3 | PII-safe rendering: every PII field resolves **through `Samen.Api.PiiResolution` on the actor's plane**; payload whitelist is **fail-closed** (raises on `%Masked{}` / `vt_`); at-rest record is body-free; a **non-skippable deliver-leak conformance gate** binds every adapter | ✅ TEST + 🧨 SABOTAGE · keyless | `samen_core/test/delivery/pii_rendering_test.exs`; `samen_core/test/delivery/deliver_leak_gate_test.exs` (LeakyProvider caught / CleanProvider passes); **`scripts/sabotages/30-c3-payload-minimality-vault-token-leak.patch`** leaks `vault_token_ref` → minimality test flips, revert byte-exact | **MET (attempt 2)** — `T29-verdict.json` |
| C4 | Deliverability: bounce/complaint match a real send receipt → kernel `EmailEvent`/`Suppression` rows; a bounced address is **refused at the chokepoint**; open/click **default-OFF** behind an org flag + per-recipient consent | ✅ TEST · keyless | `samen_core/test/delivery/deliverability_test.exs` (provider-agnostic); adapter shape proofs `samen_{postmark,ses,resend}/test/deliverability_test.exs` | **MET** — `T30-verdict.json` |
| C8 | Notification digests: one masked send per due cadence (daily/weekly/off, per-user), timezone-aware (fixed-offset, no tzdata dep), time-travel tested, reuses the C3 masked-render 3-proof | ✅ TEST · keyless | `samen_core/test/delivery/digest_test.exs` | **MET** — `T30-verdict.json` |

### Cross-cutting Phase-2 hardening

| Req | Claim | Class · Lane | Evidence | Verdict |
|---|---|---|---|---|
| T103 | Auth-surface rate-limiting (the A-DEFER item from Phase 1): sign-in / 2FA / registration / reset limited via the shared `Samen.Web.RateLimit` seam (Hammer ETS); keys are **bidx/credential/IP, never plaintext email**; bounded `login_failed` audit (edge row, O(windows) not O(N)) | ✅ TEST · keyless | `samen_web/test/samen/web/auth/rate_limit_test.exs` (every bypass axis — IP-rotate, account-rotate, casing-split, 2FA-brute, missed-surface — reproduced and LIMITED) | **MET** — `T103-verdict.json` |
| T106 | INV-4 vendor-ref rename ratchet **24→0**: `stripe_*_id` blueprint attrs renamed to neutral `provider_*_ref` across blueprint + 6 host migrations + goldens; ADR-038-A records the 5 billing-persistence decisions T108 implements | ✅ TEST · keyless | `samen_core/test/billing_vendor_free_test.exs` (carve-out CLOSED to 0, floor kept refutable via a `count_occurrences` self-test); `docs/adr/ADR-038-A-billing-persistence-architecture.md` | **MET** — `T106-verdict.json` |

**Security defects caught-and-fixed by adversarial verification (Phase 2):** the T19 webhook
**metadata-redaction** leak (P2), the T29 **deliver-seam** goodwill hole (P1 — now enforced by a
non-skippable conformance gate), the T24 **dunning out-of-order** money bug (P1 — a stale failure
re-clipping a recovered customer's entitlement, fixed with a symmetric watermark guard), and the
SNS (T94) / Svix (T95) **signature-forgery** suites (all forgeries rejected). Plus the T23
**deadlock-and-recovery**: two orphaned `./ci.sh` process trees from a prior session were mutating
the shared registry + holding stale DB locks — killed, cleared, registry restored byte-exact.
Full accounting: `_orch/tasks/T31/work/gate-report.md`.

**Deferred (named, not vanished):** production Ash-backed billing mirrors + `si_` resolution
(**T108**, blocked on T106, gates at T49); durable `Samen.Identity.LoginFailure` resource
(**T109** — ETS count is restart-ephemeral, the durable audit edge rows survive; gates at T49);
`ci.sh` gen_app-probe interrupt-safety (**T107** — registry corruption on kill); and the T30
`Suppression`/`ProviderSelection`/`MarketingReceiptLookup` stores that ship **unwired into any
host `config.exs`** (fail-OPEN when unconfigured; nothing sends in prod — keyless). Lesser P2/P3
notes are enumerated in the gate report.

---

## L. Phase 3 (BATON) — WS-E lifecycle/automation + WS-F work objects + LiveView client (INV-6)

Added by the Phase-3 gate (T49, 2026-07-29). Everything below is **complete + verified** at the
authoritative full-root level: `./ci.sh` passed **twice consecutively** (`ROOT CI: ALL PASSED`,
EXIT:0, distinct seeds, zero re-rolls; INV-3 determinism). The two known/suspected flake surfaces
were watched and both stayed green — the demo `SubscriptionMovementLedgerTest` (root-caused +
fixed by T121) and `reveal_grant_property_test.exs` (the noisy `[warning] Missed notifications`
lines it emits are benign Ash runtime logging inside the test transaction, not a failing
assertion). Each claim cites its green artifact **and** its `_orch/verify/T*-verdict.json`.

**Honest scope.** Phase 3 delivers the automation engine, the lifecycle substrate (approvals /
soft-delete / audit-on-write / versioning), the WS-F work objects, and — per operator ruling R1a
(2026-07-27) — **reverses the no-JS/CSS-only posture** by wiring a real LiveView client (ADR-042).
Progressive enhancement is preserved: reads and the auth arc still work JS-off (Class-A floor).
Everything still runs on the **keyless lane** (no live billing/ESP/AI provider). The M5 CRM
Activity→Task migration is **destructive and executed** (the Activity table/resource is gone).

### WS-E — automation engine (ADR-039)

| Req | Claim | Class · Lane | Evidence | Verdict |
|---|---|---|---|---|
| E1 | Workflow/Automation resource + trigger/condition engine: event + schedule triggers, predicates keyed **only on NonPii-eligible attributes** (a PII-keyed predicate is refused, red + control); PII-leak oracle + kill-switch; runs on `ash_oban` | ✅ TEST · keyless | `samen_core/test/automation/*` (workflow/trigger/predicate); ADR-039 | **MET** — `T39-verdict.json` |
| E1-UI | Tenant-plane automation **builder LiveView** + `samen_automation_routes()` mounting at ≈0 host LOC; a workflow is authorable end-to-end via `phx-click` over the T113 client; only NonPii-eligible attributes offered as condition keys (INV-1) | ✅ TEST · keyless | `samen_web/test/samen/web/automation/*` builder tests; ADR-039 §12 / ADR-042 Class-B | **MET** — `T118-verdict.json` |
| E2 | Action library (8 actions) — one green test per action incl. email-via-C1 + webhook; escalate/reminder actions invoke the real T41 primitives (module probe, no stub) | ✅ TEST · keyless | `samen_core/test/automation/action_*` (per-action) | **MET** — `T40-verdict.json` |
| E4/E5 | Reminder scheduler + escalation primitive (+ SLA / dunning clients): reminder-at-T, escalation chain, SLA-breach + dunning invoke the primitive (client tests) | ✅ TEST · keyless | `samen_core/test/automation/{reminder,escalation}_*` | **MET** — `T41-verdict.json` |
| E8 | Automation observability: fired/skipped/failed run log, operator health view (token-blind), kill-switch (red + control) | ✅ TEST · keyless | `samen_core/test/automation/observability_*`; operator health view tests | **MET** — `T42-verdict.json` |

### WS-E — lifecycle substrate (ADR-040)

| Req | Claim | Class · Lane | Evidence | Verdict |
|---|---|---|---|---|
| E3 | Generalized approve/reject engine (ADR-040 §4): requester≠approver **DB CHECK** (red + control); any action can require approval (hook proven). Reveal grants are now an **engine client** — all existing reveal/grant tests stay green | ✅ TEST · keyless | `samen_core/test/{approvals,reveal_grants}_*`; DB-CHECK red-path | **MET** — `T34`/`T35-verdict.json` |
| E6 | Soft-delete **blueprint-wide** (ADR-040 §5) via `use Samen.Resource, archivable: true` on `ash_archival`: archive hides from default reads (red) + restore (green), policy-aware filters, crypto-shred path unchanged. Adopted across every scope — billing / cms / crm / marketing / primitives+chat / support — with composition-cascade + independent-restore honesty; retention integration + archived-count sweep | ✅ TEST + 🧨 SABOTAGE · keyless | `samen_core/test/lifecycle/*`; per-scope archival + leak-red tests (T37a–f); retention sweep (T37g); UI affordance + `gen --archivable` + catalog adoption probe (T37h) | **MET** — `T36`/`T37a-h-verdict.json` |
| E6-fix | `archived_at` is **microsecond** (`:utc_datetime_usec`), not second-granularity — closes the same-second cascade **mis-restore** (a child independently archived in the same wall-clock second as a cascade parent is no longer resurrected). Substrate-wide grep + regenerated host migrations + same-second regression test | ✅ TEST + 🧨 SABOTAGE · keyless | `samen_core/lib/samen/transformers/archivable_attribute.ex`; CMS Page▸Block same-second regression test (RED pre-fix) | **MET** — `T124-verdict.json` |
| E7 | Audit-on-write (ADR-040 §6): change-log records actor/diff/timestamp; hash-chain tests untouched-green; four audit tiers **disjoint**. **P7-F1 (impersonation)**: impersonation-context writes are the **mandatory first client** (not opt-in) — single/bulk create/update/**destroy**/destroy_permanently + archive/restore all emit an attributable, **value-free (INV-1)**, in-transaction fail-closed audit row; an impersonated write **without** an audit row is impossible | ✅ TEST + 🧨 SABOTAGE · keyless | `samen_core/test/audit/*`; impersonation-write red-path + bulk_destroy coverage; sabotage 33 (6 RED) | **MET** — `T38-verdict.json` (P7-F1 closed) |
| E7-ver | General `versioned` opt-in (ADR-040 §6.2) on `ash_paper_trail`: a `versioned true` pilot logs versions (control: non-opted resource writes none); vaulted-field diffs are **token-only** incl. `:snapshot` over a vault attribute (INV-1 red + sabotage twin); `store_action_inputs?` FALSE. CMS **ContentVersion retired** across demo/driftwood/pawchart (destructive pre-1.0 break, §6.5, zero-drop) | ✅ TEST + 🧨 SABOTAGE · keyless | `samen_core/test/audit/versioned_*`; ContentVersion-retirement migration; CHANGELOG | **MET** — `T119-verdict.json` |

### WS-F — work objects (canonical Task + calendar/docs/tag/location/vendor/lead)

| Req | Claim | Class · Lane | Evidence | Verdict |
|---|---|---|---|---|
| F1 | **Canonical Work Task + Project + Subtask** (ADR-041): Task schema matches the ADR field-for-field (`kind` mirrors the old Activity `type` enum; plain-atom `status`; self-referential `parent_id` subtree, cycle-refused). **M5 destructive migration EXECUTED** — the CRM `Activity` table + resource + catalog entry are **GONE**, CRM timelines/CDC ride the Task, multi-anchor timeline preserved in `custom.crm_refs`, zero data loss | ✅ TEST + 🧨 SABOTAGE · keyless | `samen_core/lib/samen/scopes/work/blueprint.ex`; `2026…_migrate_activity_to_task.exs` (all four hosts, `MigrateActivityToTask.up/0` via Ecto.Migrator); sabotage 34 | **MET** — `T43`/`T96`/`T97-verdict.json` (M5 confirmed) |
| F2 | **Calendar** scope: Event/Meeting + recurrence + ICS export; attendees vaulted (MaskingCase 3-proof); a valid `VCALENDAR` endpoint masked per plane | ✅ TEST · keyless | `samen_core/test/scopes/calendar/*`; ICS-export masking 3-proof | **MET** — `T44-verdict.json` |
| F3 | **Docs** scope: Doc + Note attachable via object-ref; PII-classified body vaulted; attach test on two host resources | ✅ TEST · keyless | `samen_core/test/scopes/docs/*` | **MET** — `T45-verdict.json` |
| F4 | **Tag** resource + polymorphic taggings; Ticket's bespoke `tags` array **migrated** onto the generic scope with an equivalence assert, old column dropped | ✅ TEST · keyless | `samen_core/test/scopes/tag/*`; Ticket tags-array migration | **MET** — `T46-verdict.json` |
| F5 | **Location** resource on the `Address` type; `pii_address` MaskingCase 3-proof | ✅ TEST · keyless | `samen_core/test/scopes/location/*` | **MET** — `T47-verdict.json` |
| F6/F7 | **Vendor** resource + **Sales Lead** with a conversion action; `lead ≠ subscriber` schema probe; convert → Contact/Opportunity | ✅ TEST · keyless | `samen_core/test/scopes/{vendor,lead}/*` | **MET** — `T48-verdict.json` |

### Client runtime — LiveView adoption (ADR-042, operator ruling R1a)

| Req | Claim | Class · Lane | Evidence | Verdict |
|---|---|---|---|---|
| UX-R1 | The shared root layout ships a **real LiveSocket/app.js bundle** inherited by every host + gen.app parity — a representative `phx-click` write (reveal / dispatch) now **mutates + re-renders browser-real** (headless Chromium). **Progressive enhancement preserved**: JS-off auth arc still completes (Class-A floor). Socket masking-leak probe clean (no `vt_`/plaintext to a no-grant operator); masking watch-list unmodified-green | ✅ BROWSER-REAL + 🧨 SABOTAGE · keyless | ADR-042; headless-browser regression (3 assets 200, liveSocket connect, `phx-click='reveal'` round-trip); sabotage 32 | **MET** — `T113-verdict.json` |

### Security defects caught-and-fixed by adversarial verification (Phase 3 — dogfood escalations)

Four dogfood-walk escalations were fixed **in-phase** and are closed by the gate:

| Esc | Defect (persona walk) | Fix + proof | Verdict |
|---|---|---|---|
| **P1-F1/F2** | **T110** — first-run auth arc was LiveView-only/browser-inert; the broken native-GET fallback **leaked the plaintext password into the URL query string** | Auth forms flip get→post; password moves to POST body (proven live, capture sink); onboarding + invite-accept work JS-off; regression red-on-old-form | **CLOSED** — `T110-verdict.json` |
| **P11-F3/F1/F2** | **T111** — a recipient `display_name` carrying `<script>` rendered **executable (stored-XSS)** in outbound HTML mail; AuthMailer never rendered content (empty verify/reset/invite emails); invite dispatch swallowed an `Ash.NotLoaded` crash as success | Template fields **html-escaped** to inert text; auth emails carry real working links; invite dispatch **fail-honest** (`{:error,_}`, never fake `{:ok}`) | **CLOSED** — `T111-verdict.json` |
| **P9-F1** | **T117** — generated-app **operator routes shipped with no prod auth gate**: a deployed app exposed `/operator/*` to anonymous visitors | Generator + `samen_operator_routes` macro emit a real prod-active `:authn` gate (dev/test no-op preserved): anonymous → 302/401 to login, authenticated operator → allowed; LiveView websocket back-door closed; sabotage-refutable | **CLOSED** — `T117-verdict.json` |
| **P7-F1** | **T38** — impersonation had session-level attribution but **per-mutation attribution was zero** (an impersonated tenant write left only a bare `updated_at`) | Impersonation-context writes are the mandatory first audit-on-write client incl. `bulk_destroy`; impersonated write without an audit row is impossible (red + control + sabotage) | **CLOSED** — `T38-verdict.json` |

### Infra hardening (INV-class, filed off Phase-3 incidents)

| Req | Claim | Class · Lane | Evidence | Verdict |
|---|---|---|---|---|
| T107 | `ci.sh` gen_app probes restore `abbrev_registry.json` **byte-exact on ALL exit paths** incl. SIGINT/SIGTERM (registry corruption on interrupt was observed 4+ times in Phase 2) | ✅ TEST · keyless | interrupt harness (SIGTERM mid-mutation → SHA-256 byte-exact, zero scratch); `ci.sh` `run_gen_probe` trap | **MET** — `T107-verdict.json` |
| T123 | Abbrev allocator `propose` checks the **union of ALL host namespaces** (not just own-host + flat global) — it can no longer hand back an abbrev already owned by a different host (root cause of the T44–T47 cross-host collisions + the T47 build-break). Refuses accidental cross-host different-owner reservation **at write time**; ADR-025 same-owner reuse preserved behind explicit opt-in | ✅ TEST + 🧨 SABOTAGE · keyless | RED-path proposer test + anti-tautology; sabotage 39; committed registry byte-untouched | **MET** — `T123-verdict.json` |
| T121 | The pre-existing flaky demo `SubscriptionMovementLedgerTest` root-caused at the ordering level (non-total `sort` tiebreak) and fixed with a **total-order** tiebreaker (occurred_at-usec + id belt), RED-on-revert guard — no retry/sleep/margin band-aid | ✅ TEST · keyless | `demo/test/…/subscription_movement_ledger_test.exs`; 450+ iterations 0-fail | **MET** — `T121-verdict.json` |

### Deferred / operator-scheduled (named, not vanished)

Per the T103/T107 naming precedent, the following are **honestly open** and NOT claimed done:

- **T108** — production Ash-backed billing mirrors + `si_` resolution: **DEFERRED until a live
  billing provider is actually wired** (operator ruling 2026-07-23). Under the keyless posture
  nothing sends in prod; the capability is proven against fakes (T106 / ADR-038-A). The T49→T108
  gate edge was removed by that ruling.
- **T114 / T115 / T116** — operator delivery/suppression surface, operator audit/activity UI over
  `aud_event` + T38 rows, and the plane-legibility system: operator-approved **additive** backlog,
  scheduled by the operator rather than auto-built (deliberately NOT gating T49).
- **T122** — rewire the T40 `add_tag` action onto the generic T46 Tag/Tagging: a functional
  **enhancement** (`add_tag` already degrades cleanly to `{:error, :no_tag_surface}` on a Ticket
  after T46 dropped the array column, not broken), non-gating.
- **T125** — reconcile E6 composition-cascade child-archivability posture across scopes (CMS blocks
  independent vs chat/support children cascade-locked): a **spec/product-semantics** reconciliation
  (each scope is internally correct; the lock is the safe over-restrictive direction, never a leak),
  non-gating — awaits an explicit operator posture decision (A/B/C).

Full accounting: `_orch/tasks/T49/work/gate-report.md`.

---

## M. Phase 4 (BATON) — WS-G views + WS-C comms (INV-6)

Added by the Phase-4 gate (T62, 2026-08-03). Everything below is **complete + verified** at the
authoritative full-root level: `./ci.sh` passed **twice consecutively** (`ROOT CI: ALL PASSED`,
EXIT:0, distinct seeds, zero re-rolls; INV-3 determinism). The Phase-3 `reveal_grant` clock-property
flake is **NOW FIXED** (T129 removed the mint-pipeline/Oban/wall-clock path from
`reveal_grant_property_test.exs`, so it no longer needs watching) — the one remaining watched flake
surface is the `samen_web` **RateLimitTest**. Each claim cites its green artifact **and** its
`_orch/verify/T*-verdict.json`.

**Honest scope.** Phase 4 delivers the WS-G reusable view kit (group-by primitive → kanban /
calendar / gantt / gallery+tree / map / charts+dashboard / clone / saved views) and the WS-C
comms surface (inbound-email→ticket / chat offline-escalation / chat attachments+masked search),
plus two infra hardenings. Everything still runs on the **keyless lane** (no live billing/ESP/AI
provider). **The G7 map (T55) has NO production adopter yet** — there is no geo-bearing resource
in any host (ADR-037 §5.10 REJECTs `ash_geo`/PostGIS for a zero-spec requirement; T47 Location
uses the H4 `Address` composite with no geometry column). The component + read are genuinely
**functional and framework-ready** — exercised against a REAL CRM `Person` resource with REAL DB
seeds (not mocks) — but the "framework-ready-awaiting-adopter" posture is stated so no row implies
a live geo product. Three deferred/latent follow-ups are **filed** (named, not vanished):
**T127** (`Samen.Web.Reads.page!/3` `authorize?:false`-drops-OrgScope hardening — safe today, all
current callers narrow explicitly; latent for a future caller), **T130** (`storage_key`
file-clone alias — re-tokenize/ref-count the file blob when file-level erasure lands), **T131**
(remove the global Google-Fonts `@import` from `samen_ui.css` — the framework's own no-external-CDN
invariant). All three are logged in `_orch/plan/backlog.yaml` (phase 4).

### WS-G — reusable view kit

| Req | Claim | Class · Lane | Evidence | Verdict |
|---|---|---|---|---|
| G4 | Generic `group_by!/3` read primitive: ordered group discovery + per-group **bounded** rows (`limit(cap+1)`) + **exact** per-group count aggregate; **org-scope is UNCONDITIONAL** — no `:authorize?` opt reaches any of the 3 reads (the attempt-1 cross-org bleed, where `authorize?:false` dropped OrgScope and leaked count cardinality, is **closed by construction**); a vault-routed group field is refused (`MaskedGroupKeyError`, no plaintext) | ✅ TEST + 🧨 SABOTAGE · keyless | `samen_web/test/samen/web/reads_group_by_test.exs` (6, incl. the "NO caller opt disables scoping" boundary test — RED on re-forwarding `:authorize?`, count 7 leak; restored byte-exact) | **MET (attempt 2)** — `T50-verdict.json` (page!/3 latent → T127) |
| G1 | Reusable `Samen.UI.board/1` kanban renders a `%Samen.Web.Board{}` as ordered columns (label + exact count + per-column-bounded cards + legible +N-more w/ optional `phx-click`); CRM `PipelineLive` is the first client and **re-implements no grouping/bounding/org-scoping** (delegates to G4). **Move genuinely deferred** (no raw `update` in the board path — only a governed seam, asserted). Opportunity **genuinely non-PII** (grep-confirmed no vault/`pii` block → no masking needed, real discriminator). No-JS floor + the load-more **second query re-scopes** (forged cross-org stage key → no rows) | ✅ TEST · keyless | `samen_web/test/.../crm_pipeline_board_test.exs` (ORG-SCOPE / LOAD-MORE org-scoped / BOUNDING / non-PII) + `board_component_test.exs` | **MET** — `T51-verdict.json` (framework-wide `:authn`-off dev `?org=` caveat, NOT a T51 defect — prod must run `:authn`) |
| G2 | Calendar view: client `?month=` **bounded** (garbage/5-digit-year/inverted → current month, no crash; a >62d or inverted window is structurally **unreachable** from client input); reads are **DB-windowed per day** (window filter + per-day equality + org-scope + per-cell `LIMIT` all pushed into SQL, not load-then-filter); per-cell cap + **exact** +N; org-scope holds (2-org, disjoint); `close_date` non-vaulted, a vaulted date facet refused; no-JS `<a href=?month=…>` GET prev/next | ✅ TEST · keyless | `samen_web/test/.../reads_calendar_test.exs` + `crm_calendar_test.exs` (12) | **MET** — `T52-verdict.json` |
| G3 | Gantt/timeline view: overlap predicate **boundary-correct** on all 7 positions; null-end / inverted-end **sane** (`max(width,0)`, point, clamped `left`, no negative width / no crash); **DB-bounded** (overlap predicate + `LIMIT cap+1` compiled into SQL; 200 out-of-window rows never loaded); `?from=` is a **fixed 28-day** forward window (no over-wide/inverted reachable; primitive-level >372d/inverted raise); per-lane cap + exact count; **vaulted axis refused** (`MaskedGroupKeyError`); single-lane **cross-org org-scoped** (sabotage-refutable) | ✅ TEST + 🧨 SABOTAGE · keyless | `reads_timeline_test.exs` (10) + `gantt_component_test.exs` (7) + `work_timeline_test.exs` (5); single-lane `authorize?:false` sabotage leaks count 8, restored byte-exact | **MET** — `T53-verdict.json` |
| G5+G6 | **Gallery** (keyset-bounded page walk, **non-PII opaque uuid** cursor via `:id` sort, MaskingCase **3-proof** render, org-scope refutable, forged `?after` cross-org matches nothing) + **Tree** (cycle-safe on self-parent / A↔B / long cycles — terminates fast, with **defense-in-depth** depth+node budgets as an independent guarantee; org-scope enforced + refutable at **EVERY level**; per-level cap + exact child count; vault parent-field refused) | ✅ TEST + 🧨 SABOTAGE · keyless | `gallery_component`/`tree_component`/`reads_tree`/`contacts_gallery`(`_masking`)/`task_tree` (36); cycle-check, org-scope, and plane-flip sabotages all restored byte-exact | **MET** — `T54-verdict.json` |
| G7 | Map view: self-contained **inline Natural-Earth SVG** basemap — **ZERO external host/CDN** in the rendered DOM (no `<script>`/remote `<img>`/`url()`); bring-your-tiles seam **fail-honest** (nil/blank/attribution-only/garbage → `{:error,:not_configured}`, no hardcoded host; host names its own `{z}/{x}/{y}`); `geo_markers!/2` **org-scoped** (unconditional, sabotage leaks a foreign site → restored); a **vaulted coordinate refused** (`MaskedCoordinateError`); label masking 3-proof; **DB-bounded** `limit(cap+1)` at query level (100k rows can't OOM the DOM). **HONEST: framework-ready, NO production adopter** — exercised against a real CRM `Person` resource with real seeds, not mocks | ✅ TEST + 🧨 SABOTAGE · keyless | `map_component_test.exs` (24, incl. "NO EXTERNAL CDN") + `geo_tiles_test.exs` + `reads_geo_test.exs`; org-scope + coord-refusal sabotages restored byte-exact | **MET (framework-ready, no adopter)** — `T55-verdict.json` (global Google-Fonts `@import`, pre-existing, not in map DOM → T131) |
| G8 | Tenant chart/dashboard components: measures are **DB-level** `Ash.count!/sum!/avg!` on an unset (`limit/offset/sort`) query; org-scope **unconditional** (no `:authorize?` opt); a vaulted **dimension OR measure** is refused (`MaskedGroupKeyError`/`MaskedMeasureError`) — the sole real PII guarantee. **HONEST: `:collapse_below` is NOT k-anonymity** — it folds small-cohort **labels** into an **arithmetic-remainder "Other"** tail for legibility only (a lone folded cohort is recoverable by subtraction); docs corrected to state "EXPLICITLY NOT k-anonymity" (the prior oversold `:min_cell` naming resolved) | ✅ TEST · keyless | `series.ex`/`dashboard_live.ex` aggregate tests; full `min_cell`→`collapse_below` rename grep-clean; docs-truthful re-check | **MET (attempt 2)** — `T56-verdict.json` |
| G9 | Duplicate/clone with vault re-tokenization: `Samen.Clone.clone/3` re-tokenizes vault PII into a **fresh per-subject DEK/tokens** (new PK ⇒ new subject_id ⇒ fresh `pii_vault` rows; feeds resolved plaintext, never a token); **independence proven BOTH directions through the REAL Erasure engine** (erase source → clone still resolves; erase clone → source still resolves; tokens differ, subjects disjoint); **no plaintext/token leak** to the caller (vault field returns `NotLoaded`); operator-without-grant refused at resolve, tenant control succeeds, operator-plane plaintext write blocked at `WriteGuard`; cross-org refused; audit row token-only | ✅ TEST + 🧨 SABOTAGE · keyless | `clone_test.exs` (10); `scripts/sabotages/43-g9-clone-token-sharing.patch` flips all 4 MUST_FAIL (cross-record bleed observed), reverts byte-exact | **MET** — `T57-verdict.json` (`storage_key` shallow file-alias, non-exploitable today → T130) |
| G10 | Saved views (per-user persisted list state): **per-user isolation** (real user id via `owner_scope/2`; `OwnerOnly` + `OrgScope` AND'd; another user in the same org gets `[]`/`:not_found`; owner-spoof create refused); **restore from an UNTRUSTED blob is safe** (`org_id` override ignored — scope re-applied from the actor; non-whitelisted fields dropped; **no dynamic atom creation**; injected SQL survives inert as a parameterized `contains`; oversized `page_size` clamped); a filter/sort ref to a **vaulted field is REFUSED at serialize** (`{:vaulted_field,_}`, no PII in the blob); masking **preserved on restore** (3-proof); all **10** view types round-trip | ✅ TEST + 🧨 SABOTAGE · keyless | `saved_views_test.exs` + `saved_views_masking_test.exs` (23); OwnerOnly/OrgScope/non_vaulted sabotages restored byte-exact; registry = one **sanctioned allocator-shaped** append (`wvs`), byte-exact | **MET** — `T58-verdict.json` |

### WS-C — comms surface

| Req | Claim | Class · Lane | Evidence | Verdict |
|---|---|---|---|---|
| C5 | Inbound-email → ticket: **`org_id` is un-spoofable** — a required `@enforce_keys` field on the host-supplied `Inbound.Config`, **never** derived from `To`/`From`/subject/`In-Reply-To`/plus-address; forged `In-Reply-To`/subject-token/plus-address (alone and combined at an org-B ticket) all open a **NEW ticket in the actor org**, never attach cross-org (sabotage dropping the org filter → cross-org FAIL, and a **3rd DB-level FK guard** also fires); **mail-loop prevention** (`Auto-Submitted`/`Precedence`/`X-Auto-Response-Suppress`/system-localparts/own-address suppress, case+whitespace-normalized, `max_inbound_per_thread` cap — 8-msg autoresponder loop → 0 tickets); stored-XSS **inert at rest** + HEEx-escaped; PII body + sender **vaulted** (3-proof); malformed/3MB-oversized **safe** (byte-capped, UTF-8-boundary-safe, no crash); **fail-honest** (unconfigured adapter → `:not_configured`, never a fabricated ticket); attachments via the `upload/3` chokepoint (`:quarantined`) | ✅ TEST + 🧨 SABOTAGE · keyless | `samen_core` inbound suites (23) + `demo` inbound test (11) + `samen_postmark` (8); cross-org-filter and `plain_text/1` sabotages restored byte-exact | **MET** — `T59-verdict.json` |
| C6 | Chat offline-escalation: the partial-unique dedupe index on `(org_id, external_id) WHERE external_id IS NOT NULL` **now travels with the framework for EVERY Support-Ticket adopter** — blueprint `custom_indexes` is the declarative single-source, the operator-mount gen template **emits it + a down-drop**, all **4 goldens carry it**, and the byte-golden parity test renders the template LIVE and matches (no drift); demo/driftwood/pawchart each ship a migration; **live-verified UNIQUE+PARTIAL on driftwood** (a raw-SQL duplicate REJECTED while two NULLs insert freely); **atomic** (TOCTOU race blocked); the escalation email is gated on the create-**winner**. **NOTE (honest): the index is now framework-emitted for every adopter** — the attempt-2 "only demo had it" gap is closed | ✅ TEST + 🧨 SABOTAGE · keyless | `support_chat_escalation_test.exs` (core 13 / demo gate 9) + `templates_parity_test.exs` (byte-golden + content-guard) + `driftwood/test/support_chat_escalation_index_test.exs`; parity-content and migration-disable sabotages restored byte-exact | **MET (attempt 3)** — `T60-verdict.json` |
| C7 | Chat attachments + masked search: the match oracle runs over the **plane-RESOLVED** value — an operator-without-grant body resolves to `%Masked{}` (structurally **unmatchable**, not a `vt_` string), and **present-vs-absent is indistinguishable** (secret-in-org vs clean-org both return `[]`, identical shape; searching the literal `vt_` also `[]`); the body is **NEVER tsvector-indexed** (`SearchIndexGuard` refuses a PII column — sabotage-refutable — ciphertext at rest, never a blind-index copy); search **org-scoped** (sabotage-refutable); bounded ≤200 keyset window (**perf, not security**); attachments via the `upload/3` chokepoint (`:quarantined` fail-closed, cross-org `[]`, direct `storage_key` mint refused); XSS-safe snippets + filenames | ✅ TEST + 🧨 SABOTAGE · keyless | `chat_search_masking_test.exs` (9) + `chat_attachments_test.exs` (7); index-guard, org-scope, and resolve-plane sabotages restored byte-exact | **MET** — `T61-verdict.json` |

### Infra hardening (INV-class, filed off Phase-4 verification)

| Req | Claim | Class · Lane | Evidence | Verdict |
|---|---|---|---|---|
| T128 | Prod `aud_event` partition **auto-roll cron**: the baseline defect is **real** — an audit write to a month with NO partition **RAISES** `Postgrex.Error` (silent prod audit-write loss); `ensure_upcoming_partitions/3` + the cron worker `perform/1` create the needed partition so the future-dated write **succeeds**; **idempotent + data-safe** (`CREATE TABLE IF NOT EXISTS … PARTITION OF` + `duplicate_table` rescue, **never DROP/DETACH** on the cron path, a seeded row survives a re-run); **GENERATED-APP PRODUCTION inheritance is REAL, not test-only** — a running Oban started with the generated-app prod-shaped config (`plugins:[Pruner]`) through `install_default_cron` registers `{"0 1 * * *", Samen.AuditEvent.PartitionManager}` in its **live Cron plugin**; tripwire sabotage-refutable | ✅ TEST + 🧨 SABOTAGE · keyless | `aud_event_test.exs` + `jobs_queue_taxonomy_test.exs` (40); removing the crontab entry flips 3 tests RED, `jobs.ex` restored byte-exact | **MET** — `T128-verdict.json` |
| T129 | `reveal_grant` flake **determinism fix**: `reveal_grant_property_test.exs` no longer calls the mint pipeline / Ash-engine / Oban / wall-clock path (the old `[warning] Missed notifications` source — a **test-env SQL-Sandbox artifact**, NOT a latent prod fragility); the two **security-load-bearing** clauses (clock-vs-expiry, requestor-binding) **remain refutable** (each sabotage flips the fixed test RED); the fix **GUTTED NOTHING** (coverage byte-identical to the original, proven by parity; the other 3 clauses have dedicated coverage elsewhere incl. the real `rvg_distinct_party` DB CHECK); determinism **empirically demonstrated** (0 failures across seeds 1..40 `--warnings-as-errors`, `--repeat-until-failure 80`). **Result: `reveal_grant` no longer needs watching** | ✅ TEST + 🧨 SABOTAGE · keyless | `reveal_grant_property_test.exs` + `rvg_check_probe_test.exs` (removed after); `grants.ex` restored byte-exact post-sabotage AND post-ci | **MET** — `T129-verdict.json` |

**Security defects caught-and-fixed by adversarial verification (Phase 4):** the **T50 attempt-1
cross-org group-by bleed** (`authorize?:false` dropped OrgScope on all 3 read paths — leaked count
cardinality `2+5=7`; closed **by construction** in attempt-2, page!/3's shared contract filed as
the T127 latent hardening); the **T60 attempt-2 framework-first gap** (the chat-escalation dedupe
index shipped only on `demo`, not on every adopter — closed in attempt-3 via the declarative
blueprint `custom_indexes` single-source + template emission + byte-golden parity); and the
**T56 oversold-naming** (`:min_cell` → `:collapse_below`, docs corrected to state it is NOT
k-anonymity). Each closed in-phase with a RED-on-revert / sabotage-refutable proof.

**Deferred / latent (named, not vanished)** — logged in `_orch/plan/backlog.yaml` (phase 4):

- **T127** — `Samen.Web.Reads.page!/3` lets `authorize?:false` drop OrgScope (policy-only isolation,
  no attribute multitenancy): **safe today** (all current `authorize?:false` callers pass an explicit
  scope-derived org filter), **latent** for any future caller — make the boundary safe-by-construction
  or loud. Same dev-posture class as the framework-wide `:authn`-off `?org=` caveat.
- **T130** — `Samen.Clone.clone/3` copies `storage_key` verbatim, so a clone + its source share one
  file blob (the same aliasing shape vault re-tokenization prevents, applied to files):
  **non-exploitable today** (the Erasure engine never touches files; no `Storage.delete` caller
  exists), documented as a deliberate shallow re-link. When file-level erasure lands, re-tokenize /
  duplicate / ref-count the blob so clone + source are independent on the file substrate too.
- **T131** — `samen_ui.css` carries a global Google-Fonts `@import` (a framework-wide external-CDN
  fetch on every page, pre-existing, **not** in the map component's DOM): contradicts the codebase's
  own no-external-CDN invariant. Self-host the font (vendor the woff2, like the Natural-Earth asset)
  or fall back to a system stack, and extend T55's no-CDN grep to the global stylesheet.

Plus the **G7 map (T55) framework-ready-no-adopter** posture above (no geo-bearing resource per
ADR-037 §5.10). Full accounting: the per-task `_orch/verify/T*-verdict.json` cited above +
`_orch/tasks/T62/status.json`.
