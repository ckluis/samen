# GATE 5 — Phase-5 SHIP gate: red-team of the running Driftwood vertical + doc-parity audit (T5.6)

- **Date:** 2026-07-07
- **Gate:** the SHIP gate (plan §7 T5.6). "This is where the guarantees stop being claims"
  (plan §1). A full adversarial review of the **RUNNING** Driftwood freight-brokerage
  product across **PRIVACY / AUTHZ / CRYPTO-AUDIT** lenses, PLUS the **doc-parity audit** —
  the plan's anti-invention mechanism: every load-bearing claim in the vision doc's §runs /
  §control / §data / §external-surface / §honest-edges sections mapped to a passing test, a
  game-day artifact, or an explicitly-named honest residue.
- **Inputs read IN FULL:** `driftwood/reports/T5.1–T5.5.md`, `driftwood/docs/driftwood-design.md`
  (756 lines), the game-day artifacts (`priv/gameday/crypto_shred_gameday.exs`,
  `priv/gameday/pitr_gameday_sim.sh`, `priv/drills/pitr_drill.exs`), the whole Driftwood
  source (context/reads/reveal/aggregate/fmcsa-gate/web LiveViews), the substrate reveal
  grant + impersonation scope + audit chain, and the vision doc `docs/samen-foundry.txt`:
  the freight table (:425–:437, :556), §runs (:756–:790), §control "Running the business"
  (:880–:906), §data (:573–:637), §external-surface (:693–:730), §honest-edges (:937–:959).
- **Empirical work:** ran the full root `bash ci.sh` (green-before, exit 0) and the 20-step
  `driftwood/ci.sh`; booted the app on `localhost:4010` and curled every plane; ran **four
  live red-team probe scripts** against the dev DB (all in `/tmp` scratch, removed); ran a
  genuine **anti-tautology sabotage** on the reveal grant gate (flip confirmed, reverted).
- **Gate rule (plan §6.4):** a refuted report claim or a false red-path is an automatic
  no-go. `go_with_caveats` is a go **only if** each caveat is a named in-phase fix or a
  plan-sanctioned deferral. Loop-until-dry: I iterated each lens until a fresh pass found
  nothing new.

---

## Verdict: **GO WITH CAVEATS**

Driftwood is a real, shippable reference vertical that proves the substrate's guarantees on
a running freight product. **Every headline privacy/authz/crypto-audit guarantee I attacked
head-on HELD under adversarial probing on the live app**, and each was confirmed non-vacuous:

- **Cross-org isolation** — an operator impersonating org A reads ZERO org-B driver/load
  rows (OrgScope); control: it DOES see org A's own rows (live probe V1).
- **Masked impersonation** — every driver name + CDL renders `%Masked{}` / `••••` under the
  operator scope; no plaintext, no `vt_` token leaks (live probe V2; `web_red_paths_test`).
- **Grant-gated reveal** — an ungranted reveal denies; a distinct-party-approved grant
  reveals exactly one subject; self-approval is refused at the policy + DB `CHECK` layers
  (live probe V3; `web_red_paths_test` RP2).
- **Aggregate mutual-exclusion is STRUCTURAL** — the token-blind aggregate actor is refused
  by `Samen.Reveal.reveal/5` **before** any grant/vault check (`{:error,
  :aggregate_actor_denied}`, live probe V5); the aggregate projections carry no `pii_`
  columns (C7 verifier green).
- **k-anon suppression** — no cohort below k=2 leaks an unsuppressed count/MRR (live probe
  V4); the differencing-attack budget is honestly posture-under-construction (matches doc).
- **Audit chain is tamper-proof two ways** — the `aud_chain` table has a DB-level
  append-only trigger that **refuses a raw SQL `UPDATE`** (`aud_chain is append-only`), AND
  the hash chain detects any payload forgery (`verify_entries → {:error, {:hash_mismatch,
  0}}`) while verifying clean on the untampered list (live probe V9). Survives crypto-shred
  (T5.4 §6).
- **FMCSA gate + no error/settlement leak** — an expired/missing/shredded-CDL /
  out-of-service driver cannot be dispatched (no row written); the refusal error message
  carries **no plaintext CDL** (live probe V7); settlement reads carry no PII (V8).
- **Crypto-shred oracle** — `mix samen.verify.no_plaintext_pii --subject <uuid> --tiers all`
  run as a **separate OS process** against a real erased driver EXITS 0 with 15 positive
  attestations; both rollup arms exercised (T5.4).
- **PITR bad-contract drill** — production-sized (2400 settlements), both recovery arms,
  key-store exclusion proven (restore resurrects ciphertext, never the key) (T5.5).

**No P0/P1 breach-class hole was found** — no path reaches a driver's CDL/name in the clear
for an unauthorized party, no cross-org read, no cross-tenant re-identification below the
enforced floor, no audit forgery. The reveal capability is subject-scoped and second-party
gated exactly as the doc specifies; the fact that a grant does not *also* require an
impersonation session for the subject's org (live probe V3) is the doc's designed model
(the distinct-party approval is the gate), not a hole.

**Anti-tautology discipline verified independently (not just trusted from reports):** I
sabotaged the `OperatorReveal` grant gate (injected an always-approve checker) in a
project-local scratch backup and re-ran the "ungranted reveal denies" red path — it FLIPPED
to failing (`{:ok, "CDL-OK-7170"}` where `{:error, :denied}` was expected), proving the test
exercises the real gate. Reverted; the file is byte-identical to the original and the red
path passes again. Scratch dir removed.

The three findings below are **one availability defect (fixed in-phase)** and **two labeled
scope/posture residues** — none is a re-architecture, none is a breach.

---

## RE-GATE (2026-07-07) — post-fix-round re-verification

A bounded RE-SHIP-GATE pass after the mandatory F3 fix round. The directive: confirm the
prior mandatory fix landed (re-run its red path + sabotage-probe it), re-run the full
Driftwood suite + `driftwood/ci.sh` + adversarial matrix + oracle, re-boot the app, and
refresh the claim→evidence table for any newly-covered claim. **All done this session,
empirically, with a fresh anti-tautology flip.**

**F3 (the prior mandatory fix) — CONFIRMED LANDED and NON-VACUOUS:**
- The guarded `load/3` head (`when not is_binary(operator_id) or not is_binary(org_id) →
  denied/3`) + the `:operator_suspended` fail-closed arm are present in
  `lib/driftwood_web/operator_impersonation_live.ex` (md5 `9d08cb6211418176cea2e63cd577a3a0`,
  byte-identical to the fix-round record).
- **Red path re-run:** `web_red_paths_test.exs` RED PATH 5b (the nil/partial-param matrix
  `[{nil,nil},{nil,"some-org"},{"op-x",nil}]`) passes — file suite **6/6**.
- **Anti-tautology sabotage (this session, project-local `.gate5_reship_scratch/`, removed):**
  I deleted the guarded `load/3` head so the nil path falls through to
  `Impersonation.scope(nil, …)`. RP5b **FLIPPED to failing** with exactly the diagnosed crash
  — `FunctionClauseError` at `Samen.Impersonation.operator_id/1` (`impersonation.ex:130` ←
  `scope/3:87` ← `operator_impersonation_live.ex:57`); suite 6/6 → **5/6, 1 failed**. Reverted;
  md5 back to `9d08cb6211418176cea2e63cd577a3a0` (byte-identical); RP5b green again; scratch
  removed. The guard is proven real, not a tautology.
- **Live HTTP re-confirmation:** re-booted the app (`Running DriftwoodWeb.Endpoint with Bandit
  1.12.0 at 127.0.0.1:4010`); `curl /operator/impersonate` (session-less) → **HTTP 200** +
  exactly one "access denied", **zero** PII tokens (`CDL-OK-`/`CDL-EXP-`/`vt_`/`driver-row` all
  0). `/operator/aggregate` → HTTP 200, 0 PII, 7 aggregate-content matches. `/broker` → HTTP
  200 (no-org guidance state). **No 500/crash in the boot log across all curls.** App stopped.

**Full gate re-run (green-after):**
- `driftwood/ci.sh` — **ALL PASSED** (20 steps: 16 verifiers + default 47 + adversarial 4 +
  T5.4 crypto-shred game-day + T5.5 PITR game-day, both arms + red-path probe). The T5.4
  destruction **oracle** (`mix samen.verify.no_plaintext_pii --subject <uuid> --tiers all`) run
  as a separate OS process against a freshly-erased driver **EXITS 0 with 15 positive
  attestations**; both rollup arms (rebuild + suppress) exercised; every game-day red path
  flips the oracle; the game-day's built-in anti-tautology sabotage is caught-then-reverted.
- root `bash ci.sh` — **ROOT CI: ALL PASSED, exit 0.** Counts unchanged from the gate:
  samen_core **768** (9 props / 759), demo **399** (17 props) + demo CI gate **48**, Driftwood
  **47** (1 prop / 46) + **4** adversarial, all six spikes green. `mix test
  --warnings-as-errors` green in every app.

**Claim→evidence refresh:** claim **C2** (masked impersonation fail-closed by default) is
now covered by a stronger, independently-verified proof — the session-less/nil-param entry
also renders access-denied (live HTTP 200) rather than 500. The claim-evidence table's C2
row is refreshed accordingly (`docs/claim-evidence.md`). No other claim changed class; F1/F2
remain the same two labeled carry-to-P6 residues (neither is a breach).

**Re-gate verdict: GO WITH CAVEATS holds.** The one mandatory fix is landed, non-vacuous, and
live-verified; all suites + both CI gates are green; the only remaining items are the two
plan-sanctioned carry-to-P6 residues (F1 external surface, F2 tenant-plane over-masking).

---

## Findings

### F3 (FIXED IN-PHASE) — `/operator/impersonate` with no params 500'd instead of rendering the documented fail-closed "access denied" state

The `OperatorImpersonationLive` moduledoc claims the absent-session path "renders the
access-denied state, no data." **The running app 500'd instead:** `mount/3` → `load/3` with
`operator_id = nil` → `Samen.Impersonation.scope(nil, …)` → `Samen.Impersonation.operator_id/1`
raised `FunctionClauseError` (no nil clause). The in-suite RED PATH 5 passed only because it
fed an explicit `op.id`, never the nil path. **Verified live:** `curl /operator/impersonate`
→ HTTP 500. **No PII leak** (the 500 body is `Internal Server Error`; grepped for
CDL/name/`vt_` → nothing) — so this is availability/robustness, not disclosure. But it
contradicts a stated fail-closed contract on the operator-plane entry page.

**Fixed this session:** `load/3` now guards a non-binary operator_id/org_id (and handles
`{:error, :operator_suspended}`, which `for_session/3` can return and the old code would have
crashed on), routing all three to a shared `denied/3` access-denied assign. **Verified live:**
`curl /operator/impersonate` → HTTP **200** + "access denied", no PII in body. **Regression
test added** (`web_red_paths_test.exs` RED PATH 5b, nil/partial-param matrix). Driftwood
suite 46 → **47 passed**; `driftwood/ci.sh` + root `ci.sh` GREEN after the fix.

### F1 (CARRY-TO-P6) — the reference vertical mounts NO public API/webhook surface; the external-surface guarantees are proven only in `demo`, never on freight PII

The vision doc's §external-surface (:693–:730) is load-bearing: versioned AshJsonApi +
webhooks + two-key classes + allowlist serialization + `api_contract`. That machinery is
fully proven in **demo** (`demo/test/api_*.exs`, `webhook_payload_allowlist_test.exs`). **But
Driftwood — the vertical the plan says "is where the guarantees stop being claims" — mounts
no API:** `driftwood/api_contract.v1.json` has `"resources": []`, the `:api` router pipeline
is defined but unused. So there is **no test proving a driver's CDL is `••••` in a JSON-API
payload**, no test proving a **freight webhook emits a masked catalogued payload**, and no
test proving **tenant-key-reads-own-PII-in-clear** on a freight resource. Named as a residue
in `reports/T5.2.md` (framed as "deferred to T5.3"), but T5.3 also did not mount it. The
external-surface claims are **MET at the substrate level, UNPROVEN on the reference vertical.**
Carry-to-P6: mount an AshJsonApi over `Driftwood.Freight.Driver` + a `load.status` webhook and
add the CDL-masked-payload / tenant-plaintext / operator-absent red paths on freight.

### F2 (CARRY-TO-P6 / accept) — the tenant-owner-sees-own-PII-in-clear rule is inverted in Driftwood's tenant UI (fail-SAFE deviation)

Doc (:707): a tenant key "reads that PII per the tenant's own RBAC, with no operator reveal
grant involved." Demo proves it (`api_two_key_classes_test.exs`). **Driftwood's broker
console masks its OWN drivers' CDL/name (`••••`)** — `Driftwood.Reads` reads through Ash (→
`%Masked{}`) and the LiveView never invokes the tenant-plane `Samen.Api.PiiResolution` unmask
path. `test/cdl_vault_test.exs` confirms a normal Ash read returns `%Masked{}` for ALL scopes.
This is **fail-safe** (over-masking, never under-masking — no leak), named as a residue in
`reports/T5.3.md`. Low severity: a broker can't see its own driver's CDL without a reveal
grant. Carry-to-P6 (wire the tenant-plane unmask into the LiveView reads) or accept as a
stated stricter posture.

---

## Doc-parity audit

The full CLAIM → EVIDENCE table is at **`/Users/clank/Desktop/projects/samen/docs/claim-evidence.md`**.
It maps **every** load-bearing claim in §runs (R1–R8), §control (C1–C7), §data (D1–D6),
§external-surface (E1–E4), §honest-edges (H1–H6), and the Driftwood freight table (DW1–DW3)
to a passing Driftwood test, a game-day artifact, a substrate-inherited proof, or a named
residue. **No claim is left un-evidenced and un-labeled** except the two labeled residues
(F1 external surface, F2 tenant plaintext) and the fixed F3. The honest simulation seams
(Fly/Neon/AWS KMS = operator TODOs; CDC = opt-in Phase-6 power-up; PITR-history + replica
tiers = documented oracle seams; rollup refresh = fn not cron) are each carried faithfully
from the T5.* reports, never faked.

---

## Green-before / green-after

- **Green-before:** root `bash ci.sh` = **ALL PASSED** (exit 0): spikes + samen_core 768 +
  demo 399+48 + demo CI gate + the full 20-step Driftwood gate (16 verifiers + default +
  adversarial + T5.4 crypto-shred game-day + T5.5 PITR game-day, both arms + red-path probe).
- **Change landed:** F3 fix (`lib/driftwood_web/operator_impersonation_live.ex`) + its
  regression test (`test/web_red_paths_test.exs` RP5b). No `samen_core`/`demo` file touched;
  `schema.dict.json` unchanged.
- **Green-after:** root `bash ci.sh` = **ALL PASSED** (exit 0). Driftwood default suite **47
  passed** (1 property) + 4 adversarial; samen_core **768**, demo **399+48** unchanged.
  `mix test --warnings-as-errors` green in all three apps.

---

## Fix tasks

**Mandatory-in-phase (DONE this session):**
- ✅ **F3** — guard the session-less `/operator/impersonate` path; render access-denied not a
  500; regression test added; CI green.

**Carry-to-P6 — BOTH LANDED (P6 PRE, 2026-07-07; `driftwood/reports/P6-PRE-F1-F2.md`):**
- ✅ **F1 (LANDED)** — Driftwood mounts a versioned AshJsonApi + webhook surface over
  `Driftwood.Freight`: `/api/v1/drivers` (via `DriftwoodWeb.Api.{KeyAuthPlug,Router,
  Endpoint}` forwarded from `DriftwoodWeb.Router`), the `Driftwood.Freight.ApiKey` (abbrev
  `dak`) two-key-class credential, `Driftwood.Webhooks.{load_status,driver_updated}`, an
  opt-in `show_fields` allowlist on Driver/DispatchEvent, and a committed non-empty
  `api_contract.v1.json` wired into `ci.sh` step 13. Freight red paths in
  `test/api_external_surface_test.exs` (CDL never plaintext in a JSON:API operator payload;
  masked webhook payload; tenant-key own-PII-in-clear; operator-key absent-without-grant;
  actor-less → zero rows), anti-tautology-flipped. Surfaced an honest P6 finding: the
  `Samen.Webhook.Payload` storage-name heuristic false-positives on freight catalog names
  (`cdl_number`/`cdl_state`/`eld_provider`) and drops them (over-strict, not a leak).
- ✅ **F2 (LANDED)** — the broker scope carries `plane: :tenant`; `Driftwood.Reads.driver_
  roster/1` threads it through `Samen.Api.PiiResolution.resolve/4` so a tenant sees its OWN
  driver CDL/name IN CLEAR per its RBAC (no reveal grant); the operator impersonation plane
  stays `••••` through the same resolver. Red paths in `test/web_red_paths_test.exs` RED
  PATH 6 + `dogfood_walkthrough_test.exs` step 6, anti-tautology-flipped on both planes.
- **P6 extraction-retro carries (already flagged in the T5.* reports):** the abbrev registry
  is global-to-samen_core not per-host (T5.2); the `aud_chain` migration is not
  auto-generated when a host mounts the operator plane (T5.4); rollup refresh is a plain
  function not an AshOban cron worker (T5.3); the real Fly/Neon/AWS-KMS game-day drills and
  the PITR-history + physical-replica oracle tiers remain operator TODOs (T5.4/T5.5).
