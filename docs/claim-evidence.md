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
