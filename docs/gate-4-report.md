# GATE 4 — Phase-4 red-team of the two-plane control plane (T4.7)

- **Date:** 2026-07-07
- **Gate:** the heaviest gate in the plan (plan §7 T4.7; §6.4 loop-until-dry). A red-team
  pass over the finished control plane — masked impersonation (T4.1), the token-blind
  aggregate actor + `NoPiiColumns` C7 (T4.2), the hash-chained tenant-readable audit +
  WORM anchor (T4.3), break-glass deferred-anchor + breadth budget (T4.4), the
  k-anon/l-diversity floors + query-budget scaffold (T4.5), and the durable adversarial
  suite (T4.6). Four lenses: **PRIVACY**, **AUTHZ**, **CRYPTO/AUDIT-INTEGRITY**, **DOC PARITY**.
- **Inputs:** all `samen_core/reports/T4*.md` + `PRE-phase4.md`, ADR-002, `docs/gate-3-report.md`
  carries, `docs/plan.md` §7 PHASE 4, and the vision doc (`docs/samen-foundry.txt`) "Running the
  business" (:880–:906) IN FULL — the time-boxed-grant (:892), immutable-and-shreddable (:894),
  two-planes/two-operator-paths (:898), the ∴ block (:906) — plus "The honest edges" break-glass
  (:951) and token-blind/inference (:947) bullets. Plus direct inspection **and live execution** of
  the code (three empirical probes, all in project-local scratch, all removed).
- **Gate rule applied (plan §6.4):** a refuted report claim or a false red-path is an automatic
  no-go. `go_with_caveats` is a **go only if** each caveat is a named in-phase fix task or an
  explicit, plan-sanctioned deferral. This phase runs loop-until-dry: I iterated each lens until a
  fresh pass found nothing new.

---

## Verdict: **GO WITH CAVEATS**

Phase-4 is real, load-bearing, and — with the exceptions below — honestly reported. Every headline
guarantee I attacked head-on **held under adversarial probing plus my own non-vacuity sabotage
would-flip reasoning**: the impersonation mask renders `••••` through every egress with no grant; the
reveal grant binds the capability to the **requestor** gated on a **distinct approver** (the throwaway-
requestor self-serve collusion is closed, and `active?/2` re-checks `granted_by != requestor_id` on
read); the token-blind aggregate actor is structurally org-less and mutually exclusive with `:reveal`
in **both** directions; the hash chain detects edit/delete/gap and the WORM anchor catches a
wholesale rewrite; the chain survives crypto-shred (hash over tokens + a ciphertext **digest**); the
k-anon/l-diversity floors suppress count-of-one and homogeneous cohorts; break-glass fails closed when
the KMS is down and denies a suspended operator on the routine + impersonation-open + break-glass paths;
`plane` is server-side (no client forgery → no api_key→operator escalation); the query budget is
honestly a WARN-only scaffold matching the doc's "posture under construction."

**No P0/P1 breach-class hole was found** — no path reaches a subject's plaintext for an unauthorized
party, no cross-org read, no cross-tenant re-identification below the enforced floor. The three
confirmed findings are **integrity / accountability / honesty** gaps, all bounded, none re-architecture:

- **F4.1 (MANDATORY-IN-PHASE, MED)** — the reveal chokepoint does **not bind** the caller-supplied
  `subject_id` to the vaulted token's **actual** subject, so break-glass (and the direct reveal API)
  can decrypt subject A while the tamper-evident audit + breadth budget record subject B. An
  accountability-evasion, empirically confirmed.
- **F4.2 (carry-to-P5, LOW-MED)** — a suspended operator can still **use an already-open impersonation
  session** (the suspension gate is only on `open/1`, not on scope rebuild), contradicting the T4.4
  "every operator path denies while suspended" claim. No PII leaks (reveal stays blocked, data stays
  `••••`), so the residue is masked read access to the tenant's data **shape** until the session TTL.
- **F4.3 (carry-to-P5, LOW)** — a subject's plaintext PII typed into an **operator-authored reason**
  survives crypto-shred in `ach_detail` / `imp_reason` (plaintext, not key-destroyable ciphertext),
  a post-shred linkability residue the doc's "the audit log holds tokens only / who it was about
  becomes unrecoverable" claim overstates for the free-text metadata channel.

### Environment / gate results (run by me, not trusted from the reports)

| Check | Result |
|---|---|
| `samen_core` `mix test --warnings-as-errors` | **752 passed** (9 properties, 743 tests) |
| `demo` `mix test --warnings-as-errors` (default) | **399 passed** (17 properties, 382 tests), 48 excluded |
| `demo` `mix test --only adversarial --warnings-as-errors` | **48 passed**, 399 excluded |
| `demo` `MIX_ENV=test mix samen.verify.no_plaintext_pii` (oracle CI) | **OK — no violations** |
| root `bash ci.sh` (6 spikes + core + demo + 17-step demo gate) | **exit 0 — ROOT CI: ALL PASSED** |
| demo gate steps 1→17 (5 core verifiers + migrations + sink_schema + metric_labels + vault_declared_parity + tnt_catalog + tnt_boundary + api_contract + same_org_fk + no_pii_columns + aggregate_privacy + adversarial) | all PASSED, before AND after my probes |

Confirmed green **before** red-teaming and **after** (every probe was a fresh scratch test file, all
removed; no `lib/` file was mutated; `grep -rn SABOTAGED lib` == 0; the only "SABOTAGED" hit is a
pre-existing string literal in `webhook_signer_test.exs`).

---

## My empirical probes (HARD RULE 2 — sabotage/probe in a project-local scratch dir, confirm, revert, state)

All three probes were **new scratch test files** exercising the REAL kernel/demo code (not sabotage of
shipped logic — the findings are gaps in what the code *does not* do, so a would-flip sabotage does not
apply; instead each probe demonstrates the gap directly and I state the result). All were removed; the
suites are green; `.gate4_scratch/` deleted.

1. **F4.1 probe** (`demo/test/gate4_probe_bg_subject_test.exs`, removed): vaulted subject A's secret,
   built `%Masked{}` for A's token, called `BreakGlass.reveal(%{masked: A, subject_id: "subjectB-…"})`.
   **Result: `{:ok, %{plaintext: "alice-SECRET@a.test", local_entry: %{subject_id: "subjectB-1698"}}}`** —
   A's plaintext returned, the local audit entry records B, A is never named. Decoupled, confirmed.

2. **F4.2 probe** (`samen_core/test/gate4_probe_suspended_session_test.exs`, removed): opened a session,
   suspended the operator, confirmed `open/1` refuses (`{:error, :operator_suspended}`), then rebuilt the
   scope. **Result: `Scope.for_session/3` returned `{:ok, %Samen.Scope{…plane: :operator, impersonation:
   %{session_id: …}}}`** — a usable impersonation scope while suspended. Confirmed.

3. **F4.3 probe** (`samen_core/test/gate4_probe_reason_shred_test.exs`, removed): appended a chain entry
   whose `detail` = `"…reason=unlock dave.danger@victim.example … Dave Danger SSN 123-45-6789"`, shredded
   the subject, re-read `ach_detail` from the DB. **Result post-shred: the full plaintext PII string is
   still present in `ach_detail`** while `Kms.unwrap(subject) → {:error, :shredded}`. Confirmed.

---

## Lens 1 — PRIVACY (reach plaintext / re-identify a subject)

**No path to plaintext for an unauthorized party, and no re-identification below the enforced floor.**

### Held (I attacked, they held)

- **Impersonation egress matrix** — the impersonation scope carries NO reveal grant; `%Masked{}` renders
  `••••` through LiveView (`Phoenix.HTML.Safe`), JSON (`Jason.Encoder`), CSV/iodata, `to_string`/`inspect`,
  webhook payload, and error interpolation — by construction (the struct holds no plaintext). The T4.6
  category-1 matrix (10) exercises all of these on the real `Demo.Crm.Contact`; a live grant on top is the
  positive control that surfaces plaintext on the same paths.
- **Aggregate re-identification** — `MrrByTier` suppresses `mrr_cents` when `tenant_count < k`;
  `TicketQueueDepth` suppresses `depth` when `depth < k` (k-anon) OR `distinct_priorities < l` (l-diversity
  homogeneity, on the real sensitive dimension = ticket priority). `%Suppressed{}` carries only the reason +
  the observed **count** (never the withheld value) and renders `⊘` on every path (`String.Chars`, `Inspect`,
  `Jason.Encoder`). The dashboard `mrr/0` withholds a suppressed tier from the total (never zeroes/sums it —
  which would re-leak it). `Suppressed.observed` is a bounded count, not the sensitive value — consistent
  with the honest edge.
- **The complement/differencing residue is DOCUMENTED, not silent** — a differencing attack that stays
  ABOVE the k floor on both sides is NOT defended today (no cross-query suppression, no DP, no t-closeness);
  the ledger records it per-cohort and WARNs, but does not deny. T4.5/T4.6 state this exactly; it matches the
  doc's "posture under construction." The isolating count-of-one side IS suppressed (the k-anon floor).
- **PII-via-filter-inference over the aggregate plane** — closed: the aggregate resources are vault-excluded
  projections (C7-verified no `pii_` columns), so there is no plaintext column to binary-search.
- **Error/log leakage** — `%Masked{}`/`%Suppressed{}` never carry plaintext; storage names surface only in
  server logs, never client bodies (Gate-3 confirmed, unchanged).

### F4.3 (carry-to-P5, LOW) — operator-authored reason is a plaintext, **un-shreddable** channel

The impersonation `reason` and the reveal/erasure `detail` are operator-authored free-text stored as
**plaintext** in `imp_reason` and `ach_detail` (an allow-listed T2.2 metadata column) — NOT as per-subject
key-destroyable ciphertext. The `aud_chain`/`aud_event` oracle tiers scan **column name + type**, not
**values**, so a PII-shaped reason passes the gate, and crypto-shred (which destroys the DEK and seals vault
rows) does not touch it. **Confirmed live** (probe 3): a subject's name/email/SSN typed into a reason
survives shred verbatim in `ach_detail`, and is tenant-visible via `TenantView.for_org/2`.

This is a metadata-channel residue that requires **operator misuse** (putting subject PII into a free-text
justification), and the field is a documented allow-listed metadata channel — the same *class* as the
`non_pii!` carve-out. It is LOW severity (not a leak to an unauthorized party; scoped per-org). But the
doc's unqualified *"who it was about becomes unrecoverable"* is technically overstated for it. **Fix
(carry-to-P5):** either best-effort content-scan the reason for PII-shaped values at write (a `pii_classify`-
style flag, WARN-or-block per policy), OR name the operator-reason field explicitly as a non-shreddable
metadata channel in ADR-002 + the moduledocs (the honest-posture move, mirroring `non_pii!`). Preferred: the
honest naming now + a P6 content-scan track. This must not silently claim "unrecoverable" for a field the
shred does not reach.

---

## Lens 2 — AUTHZ (escalate)

**No privilege escalation to plaintext or cross-plane was found.** The escalations I tried and their outcomes:

### Held

- **operator→tenant-writes** — an impersonation scope is a NORMAL tenant scope with role `:member` (not
  owner/admin) and the TARGET org_id; `OrgScope` applies unchanged. Nothing elevates the role.
- **impersonation→reveal** — the impersonation scope carries no grant; `Reveal.reveal/5` consults the T1.6
  grant model keyed on the operator id, which denies without a live distinct-party grant. A live grant on
  top is the *intended* plaintext path (doc-sanctioned).
- **aggregate-actor→row-level** — the org-less aggregate actor filters to `expr(false)` on every tenant
  resource (zero rows) and is refused by `Reveal.reveal/5` structurally (`:aggregate_actor_denied`, first
  cond arm, before any grant/vault). Mutual exclusion is structural in both directions.
- **api_key→operator** — `plane` is read strictly from the server-side `key_row.plane`; a client cannot
  forge it. An operator API key gets the ABSENT posture (`%Ash.ForbiddenField{}`), NOT the impersonation
  `••••`-present posture (the `:impersonation` marker is set only by the server-side scope builder).
- **self-approval via API composition** — blocked at BOTH the policy layer (`{:error, :self_approval}`) and
  the DB CHECK (`rvg_distinct_party`), and `active?/2` re-checks `granted_by != requestor_id` on read. The
  requestor-bound capability closes the throwaway-requestor self-serve path. Two-account collusion is the
  doc's honest dual-control residue — ALLOWED by mechanics, its two ids ASSERTED VISIBLE in the tenant audit
  (T4.6 category 2). Matches the doc.
- **suspended-operator re-entry on the reveal paths** — `Grants.granted?/1` denies a suspended operator
  BEFORE the grant check; `Sessions.open/1` refuses; `BreakGlass.reveal/1` refuses. `suspended?/2` fails
  closed (`on_error: true`).

### F4.1 (MANDATORY-IN-PHASE, MED) — the reveal chokepoint does not bind subject_id to the token's real subject

`Samen.Vault.reveal(%Masked{token: token}, repo, _opts)` **ignores** the `subject_id` opt entirely and
decrypts by the vault row's OWN `subject_id`. So the caller-supplied `subject_id` — used for the break-glass
local audit, the T4.3 chain entry, AND the breadth budget's distinct-subject accounting — is **decoupled**
from the subject actually decrypted. **Confirmed live** (probe 1): `BreakGlass.reveal(%{masked: <A's token>,
subject_id: "B"})` returns **A's plaintext** while the audit + budget record **B**.

Consequences:
- **Accountability-evasion** — the tamper-evident, tenant-readable audit (the whole point of break-glass and
  the reveal log) attests to the *wrong subject*. The doc's *"captures who/what/**why** before the reveal is
  granted"* is defeated: the *what/who-about* is forgeable.
- **Breadth-budget evasion** — the auto-suspend triggers on N **distinct** subjects; an operator who always
  passes the same decoy `subject_id` never widens breadth and never trips the budget, defeating the T4.4
  abuse-response entirely.

Why MED not P0/P1: it requires the `:operator_break_glass` role (a small, reviewable set by convention), and
the operator was already authorized to break-glass *some* subject — it is an integrity/accountability defeat,
not a leak to an unauthorized party. But it breaks two load-bearing Phase-4 integrity properties, so it is
mandatory-in-phase. The routine egress path (`PiiResolution`) is NOT affected — there `subject_id = record.id`
and the masked field is on that same record, bound by construction; the gap is in the direct
`Vault.reveal`/`Reveal.reveal`/`BreakGlass.reveal` API where `masked` and `subject_id` are independent inputs
and break-glass has no grant gate to indirectly constrain the pairing.

**Fix (MANDATORY-IN-PHASE):** bind at the single chokepoint. When a `subject_id` opt is present,
`Samen.Vault.reveal/3` must assert `vault_row.subject_id == subject_id` and deny (`{:error, :subject_mismatch}`)
on mismatch. This closes break-glass and the routine direct API at once, at the one place plaintext is
produced. Add a red-path test: `BreakGlass.reveal` with a mismatched `subject_id` must DENY (not reveal), and
the routine `Reveal.reveal` with a grant for X but a masked token for Y must DENY. Anti-tautology: sabotage
the new binding check → the mismatch red path flips to revealing → revert.

### F4.2 (carry-to-P5, LOW-MED) — a suspended operator can still USE an already-open impersonation session

The suspension gate is on `Impersonation.Sessions.open/1` (refuses a NEW session) but NOT on
`Impersonation.Scope.for_session/3` (which only re-checks `active_session` = `closed_at IS NULL AND
expires_at > now`). **Confirmed live** (probe 2): after suspension, `open/1` refuses but `for_session/3`
still returns a usable `%Samen.Scope{plane: :operator, impersonation: %{…}}`.

This contradicts the T4.4 report + `Suspension` moduledoc claim that suspension denies **every** operator
path. Severity LOW-MED because **no PII leaks**: the impersonation scope shows `••••` by default, and the
reveal path is separately blocked for a suspended operator (`Grants.granted?/1`), so the suspended operator
gets only masked read access to the tenant's data **shape** (structure + non-PII fields) until the session's
minutes-scale TTL expires. It IS a real deviation from the stated invariant and an abuse-response gap.
**Fix (carry-to-P5):** add `Samen.OperatorPlane.Suspension.suspended?/2` to the per-request checks in
`Impersonation.Scope.for_session/3` (return `{:error, :operator_suspended}` when suspended), so a
suspension terminates live sessions on the next request, not just blocks new ones. A one-line check + a
red-path test (suspend mid-session → scope rebuild denies). Carry-to-P5 because it is a masked-shape residue,
not a plaintext breach — but it should land before the operator plane goes live against a real tenant (T5.3).

---

## Lens 3 — CRYPTO / AUDIT-INTEGRITY (forge, truncate, replay, post-shred linkability)

**The chain, anchor, and shred completeness held.** The integrity gaps found are F4.1 (subject-binding,
above — an audit-content forgery via the caller, not a chain-crypto break) and F4.3 (un-shreddable reason,
above).

### Held

- **Chain forge/truncate** — `verify_chain` recomputes `hash = SHA256(prior_hash <> canonical(payload))`
  and asserts dense gap-free seq from 0, genesis at seq 0, `prior_hash == prev.hash`, and stored-hash match.
  An edit → `:hash_mismatch`; a delete → `:seq_gap`/`:broken_link`. The canonical encoder is deterministic
  (sorted keys, explicit nulls, escaped strings) — injective over the bounded payload shapes it carries. The
  append-only `REVOKE UPDATE,DELETE` + trigger stop the app role from mutating a row.
- **Wholesale rewrite** — `verify_against_anchor` catches a rebuilt-from-scratch chain that internally
  `verify_chain`s clean, because the sealed head in the WORM store the attacker does not control does not
  match (`:anchor_divergence` / `:truncated_below_anchor`). The `LocalWorm` content-hash is honestly NOT a
  MAC (a party who controls the file can recompute it) — but ADR-002 §3.2 states this exactly: the anchor's
  job is to catch a DB-rewriter who does NOT also control the out-of-band store; the `S3ObjectLock`
  compliance-mode skeleton is the production "even root cannot delete it" seam (config-flagged, raises an
  operator TODO, never a faked pass). Faithful seam, honestly bounded.
- **Anchor replay** — a re-sealed OLD head cannot pass: `verify_against_anchor` requires the live head seq
  `>= sealed_seq` (the chain only grows), so replaying a lower sealed head is caught as
  `:truncated_below_anchor`. The seal-cadence window (events after the last seal, before detection) is the
  documented detection-latency residue (ADR-002 §3.3), bounded by the `*/5` cron.
- **Post-shred chain survival** — the hash commits to `ciphertext_sha256` (a digest), not the plaintext, so
  destroying the DEK leaves every hashed input unchanged: the chain STILL verifies while
  `ach_subject_ciphertext` becomes permanently undecryptable (`{:error, :shredded}`). "Immutable AND
  crypto-shreddable," both at once (T4.6 category 6, confirmed).
- **Break-glass local→central reconciliation** — `Reconciliation.reconcile/1` verifies the LOCAL chain FIRST
  and anchors NOTHING on a tampered/gapped file (`{:local_tamper, _}`); idempotent via a content-hash key.
  The local audit reuses the SAME canonicalizer, so a local entry and its central reconciliation hash
  identically.
- **KMS is not bypassable** — break-glass decrypts through the SAME single `Samen.Vault.reveal/3` →
  `Kms.adapter().unwrap` chokepoint; KMS down ⇒ `{:error, :unavailable}` (deny-recoverable), even with a
  fully writable local audit. No degraded path manufactures plaintext.
- **Post-shred linkability elsewhere in the control plane** — the impersonation session row is token-only
  (org_id/operator_id/reason; no subject ciphertext) and correctly survives shred unchanged; the reveal-grant
  rows carry a subject token, not plaintext. The one residue is F4.3 (the free-text reason), scoped above.

---

## Lens 4 — DOC PARITY ("Running the business" + ∴ + honest edges)

I checked every claim in :880–:906, :947, :951 against a passing test or a named posture. **Almost all are
enforced-and-tested or honestly-named-as-under-construction. Three claims are (mildly) oversold — the F4.1/
F4.2/F4.3 findings are precisely where an honest edge stopped being fully honest.**

| Doc claim (:line) | Status |
|---|---|
| ":888 personal data renders •••• by default … no CSV/API/log path leaks by omission" | **ENFORCED + tested** (T4.1 + T4.6 cat 1) |
| ":890 second-party … CHECK (granted_by <> requestor_id) … hash-chained, tenant-readable log the operator cannot edit" | **ENFORCED + tested** (policy + DB CHECK + `active?` re-check + append-only + chain) |
| ":890 cross-tenant views run on a token-blind actor with no pii_ columns … mutually exclusive" | **ENFORCED + tested** (C7 verifier+transformer, both-direction mutual exclusion) |
| ":892 'Time-boxed' … expires_at … deny the moment now() > expires_at … Oban auto-revoke same-tx … no renew-in-place" | **ENFORCED + tested** (deny-on-read, same-tx enqueue, `attempt_extend` always fails) |
| ":894 audit log never stores plaintext: token refs + key-destroyable ciphertext + hash chain … who it was about becomes unrecoverable … oracle asserts the audit log holds tokens only" | **MOSTLY — F4.3 caveat.** The chain columns are token/ciphertext-only and the oracle asserts it — BUT the oracle scans column name+type, not the **operator-authored reason VALUE**, which is a plaintext channel the shred does not reach. "Unrecoverable" is overstated for that field. |
| ":898 two operator paths, mutually exclusive; unmasking passes two gates" | **ENFORCED + tested** |
| ":906 ∴ k-anon + l-div enforced today; query budget + DP = posture under construction" | **MATCHED EXACTLY** — floors enforced, budget is WARN-only scaffold, DP/t-closeness named as T6.6 |
| ":947 per-actor accounting is the wrong unit; budget must be global/per-cohort" | **MATCHED** — ledger keyed by cohort, `count/2` ignores actor; collusion test proves it |
| ":951 break-glass writes who/what/why locally BEFORE the reveal … deferred anchor … KMS down ⇒ fail closed … no bypass" | **MOSTLY — F4.1 caveat.** The ordering, deferred anchor, KMS-down deny, and breadth budget are all real and tested — BUT the "who/what/why" (the *what/who-about*) is not bound to the decrypted subject, so it is forgeable, and the breadth budget is evadable. |
| ":951 'suspension is the response to abuse' … every reveal path denies while suspended | **MOSTLY — F4.2 caveat.** Denies on the reveal paths + `open/1`, but an already-open impersonation session stays usable (masked). |

The collusion residue (:890 dual-control), the local-write→anchor window and KMS-availability residue
(:951), and the differencing residue (:947) are all named honestly by T4.4/T4.5/T4.6 and match the doc — no
silent new residue there.

---

## Fix tasks

1. **[F4.1 · MANDATORY-IN-PHASE · MED]** Bind the reveal chokepoint to the token's real subject. In
   `Samen.Vault.reveal/3`, when a `subject_id` opt is present, assert it equals the loaded
   `VaultRow.subject_id` and deny `{:error, :subject_mismatch}` on mismatch (closing break-glass AND the
   routine direct API at the single plaintext chokepoint). Thread `subject_id` from `BreakGlass.reveal/1`
   (already has `req.subject_id`) and `Reveal.reveal/5` (already has `opts[:subject_id]`) into the vault
   call. Add red-path tests: `BreakGlass.reveal` with a mismatched `subject_id` DENIES (not reveals); the
   routine `Reveal.reveal` with a grant for X but a masked token for Y DENIES. Anti-tautology: sabotage the
   binding → the mismatch red path flips to revealing → revert. This restores the break-glass audit's
   *what/who-about* faithfulness and the breadth budget's distinct-subject integrity.

2. **[F4.2 · carry-to-P5 · LOW-MED]** Terminate live impersonation on suspension. Add
   `Samen.OperatorPlane.Suspension.suspended?(operator_id, repo: r)` to the per-request checks in
   `Samen.Impersonation.Scope.for_session/3` — return `{:error, :operator_suspended}` when suspended, so a
   suspension ends already-open sessions on the next request, matching the T4.4 "every operator path denies
   while suspended" claim. Red-path test: open a session, suspend mid-session, confirm the next scope rebuild
   denies. Carry-to-P5 (masked-shape residue, no plaintext leak) — but land it before T5.3 puts the operator
   plane live against a real tenant.

3. **[F4.3 · carry-to-P5 · LOW]** Make the operator-reason honest about shred. Either (preferred, cheap now)
   name the operator-authored `reason`/`detail` field explicitly as a **non-shreddable metadata channel** in
   ADR-002 §2.3 + the `Impersonation.Sessions` / `AuditChain` / `Reveal.Grants` moduledocs (mirroring the
   `non_pii!` honest carve-out), so "who it was about becomes unrecoverable" is stated with its true scope;
   AND/OR (P6 track) best-effort content-scan the reason for PII-shaped values at write (a `pii_classify`-
   style flag: WARN, or block on likely-PII, per policy). Do not leave the unqualified "unrecoverable" claim
   standing for a field the shred does not reach. Red-path/honesty test: assert the reason is documented as
   non-shreddable OR that a PII-shaped reason is flagged at write.

4. **[Housekeeping · LOW]** None required — no scratch residue remains (`.gate4_scratch/` removed, all three
   probe files deleted, `grep -rn SABOTAGED lib` == 0). Optional: fold the F4.1/F4.2 red paths into the
   durable `demo/test/adversarial/` suite (category 2 reveal-abuse + category 5 break-glass) once fixed, so
   the binding + suspension-termination invariants become gated regression tests.

---

## Gate decision

**GO WITH CAVEATS.** Phase-4 delivers the full two-plane control plane — masked impersonation, the
token-blind aggregate actor + C7, the hash-chained tenant-readable audit + WORM anchor, break-glass
deferred-anchor + breadth budget, and the k-anon/l-diversity floors + honest query-budget scaffold — all
fail-closed where the doc stakes a guarantee, with red-path tests, and the load-bearing PII-containment and
audit-integrity claims survived adversarial probing plus live empirical attack. **No P0/P1 breach-class hole
exists**: no unauthorized party reaches plaintext, no cross-org read, no re-identification below the enforced
floor, no forge/truncate/replay of the hash chain, and crypto-shred is complete across the control-plane
tiers. The one mandatory-in-phase fix (F4.1) is a real integrity gap — the reveal chokepoint doesn't bind the
audited/budgeted subject to the decrypted one, so break-glass accountability and the breadth budget are
forgeable — but it is a contained fix at the single vault chokepoint (a `subject_id` equality check + two red
paths), not re-architecture, and it does not leak PII to an unauthorized party. The two carry-to-P5 caveats
(F4.2 suspended-session reuse, masked-only; F4.3 un-shreddable operator reason, operator-misuse-dependent) are
bounded, honest, and natural to land before the operator plane goes live against a real tenant in P5. Proceed
to Phase 5 once F4.1 lands (the subject-binding check + red paths); F4.2 and F4.3 land in P5 before T5.3.

---

## RE-GATE (post-fix round) — 2026-07-07

Re-gate of the one mandatory-in-phase fix from this gate, **F4.1**. Confirmed landed by direct code
inspection, its three red paths re-run, an anti-tautology sabotage-probe of the binding (flip → revert),
full suites + adversarial + oracle re-run, and a brief re-attack of the four lenses.

### Verdict: **GO** (F4.1 landed and verified; F4.2/F4.3 remain the plan-sanctioned carry-to-P5)

### F4.1 — LANDED and VERIFIED (mandatory-in-phase)

The subject-bind is implemented at the single plaintext chokepoint and threaded from both accountability
callers, exactly as the fix task specified:

- **`Samen.Vault.reveal/3`** (`samen_core/lib/samen/vault.ex`) — `reveal_token/3` now takes the caller-
  asserted subject and calls `bind_subject/2` BEFORE `Kms.unwrap` / `do_decrypt`:
  `bind_subject(nil, _) → :ok` (raw internal callers e.g. oracle scans, unbound by design),
  `bind_subject(same, same) → :ok`, `bind_subject(_asserted, _real) → {:error, :subject_mismatch}`.
  The bind fires before the DEK is ever touched — no PII for the real subject is produced under a wrong
  subject's audit.
- **`Samen.BreakGlass.reveal/1`** (`samen_core/lib/samen/break_glass.ex:219`) threads
  `vault.reveal(req.masked, repo, subject_id: req.subject_id)`.
- **`Samen.Reveal.reveal/5`** (`samen_core/lib/samen/reveal.ex:165`) threads
  `vault_mod.reveal(masked, repo, Keyword.take(opts, [:subject_id]))`.

**Red paths landed (all three the fix task named), each with a positive control so the bind is not
always-deny:**
- `samen_core/test/vault_test.exs:356` — direct `Vault.reveal` with a mismatched `:subject_id` DENIES
  `:subject_mismatch` (+ matching-subject positive control at :346; + absent-subject raw-caller reveal at :375).
- `samen_core/test/break_glass_test.exs:190` — `BreakGlass.reveal` with a mismatched `subject_id` DENIES,
  no plaintext, no decoupled audit (+ matching-subject positive control at :213).
- `samen_core/test/reveal_grant_seam_test.exs:116` — routine `Reveal.reveal` with a grant approved for
  subject X but a masked token that is REALLY subject Y's DENIES `:subject_mismatch` against the REAL vault
  (+ real-subject positive control in the same test).

All three pass: `mix test test/vault_test.exs:356 test/break_glass_test.exs:190
test/reveal_grant_seam_test.exs:116` → **3 passed**.

**Anti-tautology sabotage-probe (HARD RULE 2).** Backed up `vault.ex` to `.regate4_scratch/`, sabotaged the
mismatch clause to `defp bind_subject(_asserted, _real), do: :ok` (defeat the bind). Re-ran the three red
paths → **all 3 FLIP to failing**: `BreakGlass.reveal(%{subject_id: B, masked: A's token})` returned
`{:ok, %{plaintext: "alice-SECRET@a.test", local_entry: %{subject_id: "subj-8452", …}}}` — A's plaintext
under B's local-audit entry, the exact F4.1 accountability-evasion, empirically reproduced. Reverted
(`diff` against the backup == clean), re-ran → **3 passed**; `.regate4_scratch/` removed;
`grep -rn SABOTAGED samen_core/lib demo/lib` == 0 (only pre-existing hit is the `webhook_signer_test.exs`
string literal, as before). The tests are non-vacuous.

### Suites + adversarial + oracle (re-run by me, after the probe/revert)

| Check | Result |
|---|---|
| `samen_core` `mix test --warnings-as-errors` | **758 passed** (9 properties, 749 tests) |
| `demo` `mix test --warnings-as-errors` (default) | **399 passed** (17 properties, 382 tests), 48 excluded |
| `demo` `mix test --only adversarial --warnings-as-errors` | **48 passed**, 399 excluded |
| `demo` `MIX_ENV=test mix samen.verify.no_plaintext_pii` (oracle) | **OK — no violations** |
| root `bash ci.sh` (spikes + core + demo + 17-step demo gate) | **exit 0 — ROOT CI: ALL PASSED** |

Green before the probe, green after the revert. `--warnings-as-errors` clean in both.

### Re-attack of the four lenses (brief)

- **AUTHZ.** The two direct-API paths where `masked` and `subject_id` are independent inputs
  (`BreakGlass.reveal`, `Reveal.reveal`) are now both bound at the vault. The routine egress path
  (`Samen.Api.PiiResolution.resolve/4`) calls `vault.reveal(masked, repo, [])` with NO `:subject_id` opt —
  verified SAFE: the `masked` value and the grant's `subject_id = record.id` both originate from the SAME
  `record` in one `Enum.reduce`, so the pairing is bound by construction and there is no independent
  caller-supplied subject to spoof (matches the F4.1 § analysis above). No new escalation.
- **CRYPTO/AUDIT-INTEGRITY.** The bind restores the break-glass audit's *what/who-about* faithfulness (a
  mismatch denies before any decrypt) and the breadth budget's distinct-subject integrity: an operator can
  no longer reveal a real subject while recording a decoy — the only way to a real reveal is to pass the
  token's TRUE subject, which correctly widens breadth. The residual over-count (a *denied* mismatched
  break-glass still writes one decoy ledger row at step 3 before the vault denies at step 5) can only make
  the budget trip SOONER — fail more conservatively, never more permissively. No integrity concern.
- **PRIVACY.** No new path to plaintext; the internal oracle-scan callers (`scan_no_plaintext`,
  `scan_pitr_key_absent`) use `reveal_token(token, repo)` with no asserted subject → `bind_subject(nil, _)`
  → `:ok`, so the destruction oracle is correctly unaffected (it scans by the row's own subject). Oracle
  re-run OK.
- **DOC PARITY.** The :951 break-glass "captures who/what/**why** before the reveal" is no longer forgeable
  in the *what/who-about* dimension — the caveat on that row is resolved. :890's "hash-chained, tenant-
  readable log the operator cannot edit" now attests to the correct subject.

### Remaining fix tasks (carry-to-P5, plan-sanctioned)

- **F4.2 (carry-to-P5, LOW-MED)** — a suspended operator can still USE an already-open impersonation
  session (suspension gate is on `Sessions.open/1`, not `Scope.for_session/3`). Masked-shape residue, no
  plaintext leak. Land before T5.3.
- **F4.3 (carry-to-P5, LOW)** — operator-authored `reason`/`detail` free-text is a plaintext, un-shreddable
  metadata channel; either name it explicitly as a non-shreddable channel (honest carve-out, cheap) or add
  a best-effort PII content-scan at write. Land before T5.3.

Both were explicitly classified carry-to-P5 in this gate and remain so; neither is a breach-class hole
(no unauthorized party reaches plaintext). **Phase 4 clears its gate: proceed to Phase 5.**
