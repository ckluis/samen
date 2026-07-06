# GATE 2 — Phase-2 adversarial gate for `samen_core` (T2.10)

- **Date:** 2026-07-06
- **Gate:** Phase 2 adversarial review of the engine/event-tier/resilience/observability layer +
  the full destruction oracle (`no_plaintext_pii --subject --tiers all`). Five attack lenses:
  tier-completeness, drill-evidence, sink-leak, queue/blast-radius, doc-drift.
- **Inputs:** all `samen_core/reports/T2*.md` + `PRE.md`, `docs/plan.md` §7 Phase 2,
  `docs/gate-1-report.md` (carry-forward F2/F4/F5), the vision doc oracle block
  (`docs/samen-foundry.txt:573-637` "The data tier", `:756-872` "How it actually runs" incl. the
  `no_plaintext_pii` code block `:821-857`), the runbooks
  (`docs/runbooks/{pitr-gameday.md,beam-introspection.md}`), and direct inspection + execution of code.
- **Gate rule applied (plan §6.4):** a refuted report claim or a false red-path is an automatic no-go.
  `go_with_caveats` is a **go only if** each caveat is a named in-phase fix task or an explicit,
  plan-sanctioned deferral.

---

## Verdict: **GO WITH CAVEATS**

Phase-2 is real and honestly reported. Every headline guarantee I attacked held under adversarial
probing: the destruction oracle fails closed end-to-end (CLI `--subject --tiers all` exits 1 on a
never-shredded subject with 4 distinct fail-closed violations), the PITR simulation genuinely executes
both arms with measured wall-clock and proves key-store exclusion with a real seeded-then-denied subject,
the append-only `aud_event` trigger + REVOKE enforcement is live, queue starvation isolation is proven by
an ETS concurrency counter, and the `contract_ready?` bake gate and 5s lock-timeout posture are both
non-bypassable and live-verified. My own anti-tautology probe (below) confirmed the oracle's DB-content
check is a genuine discriminator, not a tautology.

**No P0/P1 breach-class hole was found.** Two genuine but bounded findings and three minor drift/wiring
gaps are the caveats — all are contained fixes or plan-sanctioned deferrals, none re-architecture.

### Environment / gate results (run by me, not trusted from reports)

| Check | Result |
|---|---|
| `samen_core` `mix test --warnings-as-errors` | **482 passed** (9 properties, 473 tests) |
| `samen_core` `mix compile --warnings-as-errors --force` | exit 0, warning-clean (after my probe revert) |
| `demo` `mix test --warnings-as-errors` | **46 passed** (3 properties, 43 tests) |
| root `bash ci.sh` | **exit 0** — ALL PASSED (spikes + core + demo 8-step gate) |
| oracle CLI `--subject <never-shredded> --tiers all` | **exit 1**, 4 fail-closed violations (real halt) |
| post-shred oracle suite (incl. `--include exit_code`) | **21 passed** |
| demo destruction-oracle E2E (`destruction_oracle_test.exs`) | **7 passed** |
| J2 laundered-leak suite (`wide_event_j2_laundered_test.exs`) | **4 passed** |
| PITR sim `bash pitr-gameday-sim.sh` | **exit 0** — both arms + key-store exclusion green |
| PITR red-path `--probe-corrupt` | **exit 0** — validation fails closed on corrupted restore |
| aud_event append-only + starvation isolation | **26 passed** |

---

## My anti-tautology probe (HARD RULE 2)

Backed up `db_content.ex` to a self-created scratch subdir OUTSIDE `/tmp`
(`.gate2_antitaut_scratch/`, since removed). Sabotaged `DbContent.live_findings/1` to emit a constant
`:pass` (ignore leaks). Re-ran `test/post_shred_oracle_test.exs`: **RP-1 (live-tier decryptable
ciphertext must be a violation) FLIPPED to FAILING** (20/21). Reverted from backup; confirmed 0
`SABOTAGED` occurrences and "STILL DECRYPT" restored; removed scratch dir; re-ran suite → **21/21 green**;
`mix compile --warnings-as-errors` clean. Result: **the oracle's live-content check is a non-vacuous
discriminator, not an always-pass tautology.**

---

## Lens 1 — Tier completeness

### F2.1 (carry-to-P3, LOW-MED) — `oban_jobs` (args/errors/meta) is a key-reachable DB tier the oracle does not scan

I enumerated every resting place for subject data and probed each against the oracle roster
(`Samen.NoPlaintextPii.{default_tiers,post_shred_tiers}/0`) and the DB-content scan
(`tiers/post_shred/db_content.ex`):

| Resting place | Scanned? | By |
|---|---|---|
| Domain rows / vault ciphertext | YES | `Vault.scan_no_plaintext/2` + wrong-key probe |
| `aud_event` (append-only) | YES | CI `AudEvent` schema tier + post-shred `audit` sub-check |
| Rollups / matviews | YES | CI `Rollup` tier + post-shred `rollup` arm (rebuild-or-exclude report) |
| Wide-event / span sinks | YES | J2 `Schema.violations` (build) + `TraceSink`/`TraceSinkIngress` tiers |
| `registered_non_pii!` columns | YES | post-shred `registered_non_pii` redaction probe |
| Catalog (`tam_table`/`fld_field`) | YES | `Catalog` tier |
| PITR-sim history | YES | `BackupPitr` (`pitr_repos:` seam) |
| KMS key store | YES | `KmsAttestation` + `scan_pitr_key_absent` |
| CDC mirror | STUB (fail-closed if configured) | `CdcMirror` |
| **`oban_jobs.args` / `.errors` / `.meta`** | **NO** | — (nothing scans it) |

`oban_jobs` lives in the same Postgres — it is key-reachable, and a failed job persists its `args` AND
its raised error (`errors` jsonb) durably. If a host app ever enqueues a job whose `args` carry a
plaintext PII value (or a worker raises an error whose message interpolates one), that value rests in a
DB tier **no oracle tier scans** — neither CI-mode nor post-shred.

**Why this is a caveat, not a no-go:**
- The doc's enumerated tier list (`:637`, `:821-857`) names CDC-mirror, rollups, matviews, app-logs, and
  `aud_event` — **it does not name `oban_jobs`**. So this is a boundary the doc did not stake, not a
  refuted claim.
- `samen_core`'s own job-enqueue sites are clean: I grepped every `enqueue_in_tx`/`Oban.insert`/`.new(%{`
  call in `lib/` — all carry only opaque IDs (`grant_id`, `record_id`, `order_id`). No Samen path puts
  plaintext PII into a job arg or error today. The risk is a **future host app** convention violation,
  the same class as "a host stuffs a name into a `non_pii!` column."
- The blast radius is bounded by crypto-shred discipline everywhere else: the *right* pattern (which
  Samen follows) is to enqueue a subject_id/token and let the worker reveal under a grant, never to pass
  plaintext in args.

**Fix (carry-to-P3):** add an `oban_jobs` CI tier that asserts job-arg *values* are token/opaque-ID/enum/
number-shaped (the same J2 shape guard, applied to `args`), and a post-shred tier that scans a subject's
job rows. At minimum, document `oban_jobs` in the tier map as an explicit token-only-args convention with
a lint. This is the natural companion to T3.13 (webhooks, which also enqueue payloads).

### Tier completeness that HELD (I tried, they held)

- **CDC mirror configured-but-unscanned** → fail-closed violation (`cdc_mirror.ex:66`), not a silent
  pass. Correct.
- **Undeclared replica in `--tiers all`** → fail-closed violation ("silence is not an all-clear",
  `db_content.ex:140`). `replica: :none` is a pass-with-seam-note; a real streaming replica is a
  documented operator TODO. Correct decomposition.
- **Wrong-key probe** routes through the single existing `do_decrypt/2` chokepoint — I confirmed the
  `Chokepoint` single-call-site invariant still holds (the T2.9 report flagged that it initially broke
  this and was fixed; `chokepoint_test` green). No second `Crypto.decrypt(` call site was added.
- **Post-shred tiers never return `[]`** — every tier emits a `:pass` or `:violation`; "I couldn't
  check" cannot masquerade as all-clear.

---

## Lens 2 — Drill evidence

**The PITR simulation is honest, not theater.** I re-ran `bash docs/runbooks/pitr-gameday-sim.sh`
(exit 0) and inspected `demo/priv/drills/pitr_drill.exs`:

- Both arms actually execute and are measured: detection ~0.72s, arm (i) reverse-expand + forward-fix
  ~0.72s (within the ≤30min forward-fix target), arm (ii) restore ~0.18s + validate ~0.70s = ~0.93s
  (within the ≤2h PITR target). Evidence regenerated to `pitr-gameday-evidence.json`.
- **Key-store exclusion is genuinely proven:** the drill seeds a REAL vault PII subject and asserts it
  DECRYPTS in the seed phase (`pitr_drill.exs:171`), then in the `keystore` phase points
  `SAMEN_KMS_KEY_DIR` at an EMPTY dir, confirms the ciphertext row survives the restore, and confirms
  `Vault.reveal` returns `{:error, :unavailable}` — with a RED-FLAG guard (`:297`) that fails loudly if a
  DB-only restore ever decrypts. Restore brings back useless ciphertext, never the key.
- **Red path fails closed:** `--probe-corrupt` drops the load-bearing column post-restore and the app
  validation exits 1 ("cnt_display_name column MISSING"); the orchestrator exits non-zero if a corrupted
  restore ever validates. Confirmed live.

**Honest caveats (correctly stated in the report/runbook, not hidden):** sub-second numbers are floors
proving runbook mechanics + the key-store invariant on a demo-shaped ~32KB DB, NOT production RTO
magnitude; detection here is harness runtime, not monitoring-driven latency; promote/cutover is
infra-level and not simulated. The real Neon branch-and-restore is a registered operator TODO (needs Neon
project + `NEON_API_KEY` + KMS reachability, quarterly). These are all faithfully documented simulation
seams — no faked pass.

---

## Lens 3 — Sink leak

### F2.2 (MANDATORY-IN-PHASE, MED) — the J2 *runtime value guard* only rejects whitespace; the report oversells "every bounded field"

The **schema-level** J2 guarantee is solid and load-bearing: `Samen.WideEvent.Schema` declares every
field as `:opaque_id | :token | :enum | :number`, and `mix samen.verify.sink_schema` (demo/ci.sh step
8/8) fails the build on any non-bounded field type — so **no free-string field exists** for a laundered
name to land in. I confirmed this holds (the build check + the `TraceSink`/`TraceSinkIngress` oracle
folds). That is the doc's real claim and it is honored.

**But** the T2.7 report claims J2 "REJECTS the exact laundered plaintext (`Alice Anders`) at every bounded
field." I probed the runtime value guard (`WideEvent.new/1` → `value_violation/4` →
`bounded_id_shape?/1`) directly and found it only rejects **whitespace-containing** values:

```
space-separated name in tenant_id  => rejected  (has a space)
single-word surname in tenant_id   => ACCEPTED  (value guard passed)
email in tenant_id (no whitespace) => ACCEPTED
email in actor_id token            => ACCEPTED
phone digits in tenant_id          => ACCEPTED
SSN "123-45-6789" in tenant_id     => ACCEPTED
atom-ized name in :action enum     => ACCEPTED  (is_atom passes)
```

The report's claim is true only for the SPECIFIC fixture `"Alice Anders"` (which contains a space). A
single-token PII value — a single-word name, an **email**, a **phone**, an **SSN** — passes the shape
guard if a host deliberately stuffs it into `tenant_id`/`actor_id`, and an atom-ized name passes the
`:action` open-enum `is_atom` check.

**Why this is MED, not a breach:** the doc itself calls this guard "a shape guard, not a taint proof —
the schema type is the real gate" (`wide_event.ex:259`), and the layered design (C3 AST for vault-declared
flows + J2 *schema* for laundered) does not claim to catch a value-level leak where a host manually types
a PII literal into an opaque-ID field. This is within the documented bound. The finding is that the
**report's prose overstates the runtime guard** — an auditor reading "rejects the exact laundered
plaintext at every bounded field" would over-trust it.

**Fix (mandatory-in-phase, small):** either (a) tighten `bounded_id_shape?/1` to reject email/phone/SSN
value shapes (reusing the C4 `pii_classify` value-shape heuristics — the code already exists), and reject
non-closed `:action` atoms whose printable form is name/email-shaped; OR (b) downgrade the T2.7 report
and the `TraceSinkIngress` moduledoc to state precisely that the runtime guard catches whitespace/type
shape only, and the *schema* (no free-string field) is the load-bearing J2 defense. (b) alone closes the
honesty gap; (a) is the stronger belt. I recommend (a)+(b) since the value-shape code is already written.

### Sink evasions that HELD

- **No free-string field in the schema** — build check rejects `:string`/`:map`/`:binary`/`:any` field
  types; an `:enum` with no closed `allowed:` fails. Verified.
- **Gate-1 F2 (grown C3 sink inventory)** — `:telemetry.execute`, `Sentry.*`, `File.write`, `send/2` are
  now modeled sinks in `pii_reads.ex` (12 sink references); C3 corpus holds 17/17 direct catch, 0 FP.
- **`:reveal` span attrs** allow-listed to exactly `{subject_id, grant_id, reason}` via
  `Map.take/2` before span creation (`tracer.ex`); a decrypted value is structurally excluded. T2.6
  red-path + sabotage probe confirmed non-vacuous.

---

## Lens 4 — Queue / blast-radius

All genuine:

- **Starvation isolation is real:** `jobs_starvation_isolation_test.exs` runs a REAL Oban supervisor
  with `slow_queue(limit=1)` + `fast_queue(limit=2)`; a fast job completes within 3s while slow_queue is
  saturated, and an **ETS concurrency counter** proves slow_queue never exceeds 1 concurrent. Not a
  timing-vibe test.
- **`contract_ready?` is not bypassable:** fail-closed on `{:no_expand_row}` (no bake clock at all) and
  `{:baking, elapsed, window}` until the window elapses; `contract_setup` raises unless `{:ready, _}`.
  The bake clock is a run-time `now()` row in `samen_migration_meta`, not the migration file's
  author-timestamp. Anti-tautology probe (report) confirmed the window is load-bearing.
- **Lock-timeout posture is protective under a held lock:** live test holds an ACCESS EXCLUSIVE lock 20s;
  the posture'd ALTER aborts with a `lock timeout` error in ~5.4s (traced), and the anti-tautology probe
  (`@lock_timeout "999s"`) proved the 5s value is genuinely the mechanism (sabotage made it run to the
  15s `statement_timeout` instead). Carve-outs (`CONCURRENTLY` + chunked backfill) correctly REQUIRE
  `@disable_ddl_transaction true` and are mutually exclusive with `catalog_sync` by construction.
- **Append-only `aud_event`:** belt-and-braces (REVOKE UPDATE/DELETE from the app role + BEFORE
  UPDATE/DELETE trigger). The T2.2 anti-tautology probe (trigger ON/OFF/RE-ON) confirmed the trigger is
  the enforcement, not vacuous. 26 tests green in my re-run.

**Documented simulation seam (honest):** single-node Oban limits are per-node; the `:erasure` queue
(limit 1) is not globally single-concurrent on a multi-node cluster — registered as an operator TODO
(Oban Pro global limits or a Postgres advisory lock in `Erasure.shred/2`). Correct for a library.

---

## Lens 5 — Doc drift + Gate-1 carry-forward

### Gate-1 carry-forwards — status

| Item | Status |
|---|---|
| **F1** (C3 fail-open on empty registry) — MANDATORY-IN-PHASE from Gate 1 | Landed in Phase-1 fixes (`gate1-fixes.md`); C3 now discovers from host `:app` `:ash_domains` and fails closed on an empty PII registry. Root ci.sh green. |
| **F2** (grow C3 sink inventory + J2 sink schema) | **LANDED** (T2.7): C3 models the 4 named sinks; J2 build check + `TraceSink` oracle fold shipped. |
| **F4** (post-shred oracle `--subject`/`--tiers` no longer raises) | **LANDED** (T2.9): the real oracle; CLI exits 1 fail-closed, verified live. |
| **F5** (committed `schema.dict.json` + CI drift check) | **LANDED** (PRE-b): `demo/schema.dict.json` committed (3 tables); demo/ci.sh step 1b regenerates + diffs (fails on drift); C4 uses it as `--baseline`. |

### F2.3 (carry-to-P3, LOW) — metric label-lint (T2.8) is not wired into any CI gate

`mix samen.verify.metric_labels` exists and is tested (catches seeded `org_id`/`actor_id`/`subject_id`
labels; anti-tautology probe in `metrics_label_lint_test.exs`), but I confirmed it is **not** invoked by
`demo/ci.sh` or root `ci.sh` (grep returned nothing). The T2.8 acceptance says "no raw org/actor labels
(CI label-lint)" — the *lint* exists but is not *gated*, so a raw-org_id label added by a host would not
be caught by CI today. The T2.8 report itself lists this as operator-TODO #1. **Fix (carry-to-P3):** add
`mix samen.verify.metric_labels` as a demo/ci.sh step (one line), same shape as the other verifier steps.

### F2.4 (housekeeping, LOW) — PRE-a scratch dirs live UNDER `/tmp`

`PRE.md` isolates the `column_refs` linter tests into `/tmp/samen_colrefs_test/<id>/`. The gate's hard
rule for *anti-tautology probes* is scratch OUTSIDE the `/tmp` root; this is test-isolation scaffolding,
not a probe, and the isolation goal (don't scan shared `/tmp`) is achieved. Minor inconsistency worth a
note; not a correctness issue.

### Doc-vs-implementation parity (verified against `docs/samen-foundry.txt:821-857`)

- CI-gate block (`compile && catalog_parity && prefixes && pii_reads && pii_classify &&
  no_plaintext_pii`) — implemented exactly; demo/ci.sh adds migrations + sink_schema steps (additive,
  correct). Root ci.sh green.
- Oracle 3-check decomposition (DB-content · backup/PITR-history · KMS-attestation) + ingress-class
  trace-sink + CDC stub — all present and correctly separated; `:absent == FAIL` positive-tombstone
  requirement honored (`KmsAttestation`).
- `db_statement: :disabled` asserted at BOTH config level AND live-handler level (`LogTelemetry` T2.6
  extension). `:reveal` span allow-list honored. `actor_id = HMAC(psk_S, subject_id)`,
  `psk_S = HKDF(DEK_S, "samen/obs-pseudonym/v1")` wired; unlinks post-shred (verified).
- Rebuild-or-exclude-on-erasure wired INTO `Erasure.shred/2` as an `Ecto.Multi` step; the report artifact
  `tiers["rollups"]` is exactly the seam the oracle's `rollup` sub-check consumes. Both arms tested.

No refuted doc claim found.

---

## Fix tasks

1. **[F2.2 · MANDATORY-IN-PHASE · MED]** Close the J2 runtime-value-guard honesty gap. Either tighten
   `Samen.WideEvent.bounded_id_shape?/1` to reject email/phone/SSN value shapes (reuse the C4
   `pii_classify` value-shape heuristics) and reject name/email-shaped `:action` atoms, AND/OR downgrade
   the T2.7 report + `TraceSinkIngress`/`WideEvent` moduledocs to state precisely that the runtime guard
   is whitespace/type-shape only and the *schema* (no free-string field) is the load-bearing J2 defense.
   Add a red-path test for a single-token PII value (email in `tenant_id`).

2. **[F2.3 · carry-to-P3 · LOW]** Wire `mix samen.verify.metric_labels` into `demo/ci.sh` (and the root
   gate) so the T2.8 "CI label-lint" acceptance is actually gated, not just tested.

3. **[F2.1 · carry-to-P3 · LOW-MED]** Add an `oban_jobs` tier to the oracle: a CI-mode token-only-args
   shape lint (job `args` values must be opaque-ID/token/enum/number) and a post-shred scan of a
   subject's job rows (args/errors/meta). Document `oban_jobs` in the tier map as an explicit
   token-only-args convention. Natural companion to T3.13 (webhook payloads).

4. **[F2.4 · housekeeping · LOW]** Move the PRE-a `column_refs` test-isolation scratch dirs out of the
   `/tmp` root (or note the exception), for consistency with the gate's scratch-dir rule.

---

## Gate decision

**GO WITH CAVEATS.** Phase-2 delivers the engine, append-only event tier, expand/contract migration
safety, PII-safe observability, and the full destruction oracle — all fail-closed, all with red-path
tests, and the load-bearing claims survived adversarial probing plus my own non-vacuity sabotage of the
oracle's DB-content check. The PITR drill is honest (both arms measured, key-store exclusion genuinely
proven, red path fails closed). Gate-1 carry-forwards F2/F4/F5 all landed. The one mandatory-in-phase fix
(F2.2) is a report-honesty + optional-belt tightening on the J2 runtime value guard — the *schema-level*
J2 defense (no free-string field) is intact and is what the doc actually stakes; the finding is that the
report's prose overstates the runtime guard. The remaining three caveats are a one-line CI wiring gap
(F2.3), a token-only-args tier that is a natural P3 companion (F2.1), and housekeeping (F2.4). None is
re-architecture. Proceed to Phase 3 once F2.2 lands (fix or honest downgrade).
