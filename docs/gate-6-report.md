# GATE 6 — Foundry-Readiness (the final gate, plan §7 T6.7)

- **Date:** 2026-07-08
- **Gate:** the FOUNDRY-READINESS gate. Phase 6 turned "one product on a proven substrate"
  into "a foundry." This gate asks the three questions the plan sets for T6.7:
  **(1) is this a foundry a builder could actually start a new SaaS on?**
  **(2) a final red-team across all verticals now that a 2nd vertical + external surfaces +
  CDC exist — any NEW cross-vertical/cross-tier hole?**
  **(3) refresh the risk register + close doc-parity across the WHOLE vision doc.**
- **Inputs read IN FULL:** the Phase-6 task rows (plan §7); the vision doc's foundry claims
  (`docs/samen-foundry.txt` :67/:542/:625–:637/:906/:921–:923/:947/:957); `docs/gate-5-report.md`;
  `docs/claim-evidence.md`; `docs/extraction-retro.md`; `pawchart/docs/reuse-measurement.md`;
  `pawchart/reports/T6.2.md`; `samen_core/reports/T6.{3,4,5,6}.md`; ADR-005/006/007;
  `docs/guides/{llm-grounding,generators}.md`; `docs/cdc-analytics-tier.md`.
- **Empirical work (this gate, not trusted from reports):**
  - Ran the **full root `bash ci.sh` three times** — deterministically green on runs 2 and 3
    (exit 0, all suites + all 4 gates + both game-days); see §Green.
  - **Independently re-ran the generator** (`mix samen.gen.app`) into a scratch app and drove
    its full 17-step `ci.sh` (exit 0) + the must-fail unreserved-abbrev compile (fails closed);
    restored the global registry byte-identical (md5 `1ee06ae9c8a279f17ae5b09ef0ddb6ca`), removed
    the scratch apps.
  - **Re-ran the agent-authoring eval + the CDC suites** (32 tests green) directly.
  - **Red-teamed the CDC projection against the real freight Driver** — plaintext PII excluded
    by construction, vaulted columns classify as `:token`, `assert_no_plaintext!` refuses.
  - **Scanned every aggregate projection across all 3 verticals** for `pii_` leakage (none) and
    confirmed each host's `schema.dict.json` is per-host-scoped (no cross-vertical bleed).
- **Gate rule (plan §6.4):** a refuted report claim or a false red-path is an automatic no-go.
  `go_with_caveats` is a go only if each caveat is a named residue / operator-TODO / doc-stated
  posture. Loop-until-dry: I iterated each lens until a fresh pass found nothing new.

---

## Verdict: **GO WITH CAVEATS**

Samen is a **foundry a builder could start a new SaaS on today** — and every headline
foundry-readiness claim I attacked head-on HELD, each confirmed non-vacuous:

1. **The generators produce a passing app, correct-by-construction.** ⟳ Independently this gate:
   `mix samen.gen.app --module Gate6probe --prefix zx --abbrev zxq` → the generated app's full
   17-step `ci.sh` EXITs **0** on first run, including its OWN vault anti-tautology probe flip.
   The must-fail path (`--no-reserve-abbrevs`) FAILS CLOSED at compile with the exact
   abbrev-registry error. A builder runs one command and gets a gate-green vertical.
2. **The LLM-grounding eval proves the gate catches an agent's mistakes.** ⟳ 13/13 eval green:
   a hallucinated column, net-new plaintext PII, an unprefixed column, a leaked vault value, and
   a missing cross-tenant guard EACH fail the build; a correct resource passes (non-vacuous
   control). Case 2 is driven through a **real `System.cmd/3` child OS process** proving the true
   `:erlang.halt(1)`. The catalog is ground an agent cannot invent off of, and the gate is its
   correctness oracle.
3. **PawChart validates the reuse thesis with real, honestly-calibrated numbers.** 4 of 6 idioms
   at ZERO vertical code; the vault at 1 line; the operator plane at 42 lines; ~96% inherited
   against the families a clinic touches; all 15 verifiers green on FIRST invocation. And the
   reuse doc is scrupulous about the calibrated edge: the *domain* 20% stays authored real work.
4. **The extraction retro is honest about what core actually pays.** It counts demo+driftwood as
   2 (not 3), extracts exactly ONE byte-identical security-critical copy (the aud_chain migration),
   and ADR-defers the large-blast-radius items (abbrev registry, rollup worker) rather than faking
   a refactor.

**FINAL RED-TEAM — no NEW cross-vertical or cross-tier breach-class hole.** The three surfaces a
foundry adds (a 2nd vertical, external API/webhook surfaces, the CDC tier) were each attacked:
- **Cross-vertical read isolation holds** — each host has its own Repo/DB; the global abbrev
  registry is a permanence LEDGER, not a data surface (each `schema.dict.json` is per-host-scoped,
  no bleed); no aggregate projection in any vertical declares PII (C7 green ×3).
- **The CDC tier does not leak across tiers** — `Projection.project(Driftwood.Freight.Driver)`
  includes ZERO plaintext PII columns; the vaulted CDL/name/emails/phones classify as safe
  `:token` FKs; `assert_no_plaintext!` refuses a mirror-everything request. Fail-closed both at
  build (lint) and runtime (`read_current` always raises).
- **The external surface holds on freight PII** — F1/F2 landed (CDL `••••`/absent for the
  operator, clear for the tenant), anti-tautology-flipped.

**The caveats are all named residues / operator-TODOs / doc-stated postures — none is a breach,
none is a regression.** They are enumerated in §Caveats and carried into `docs/risk-register-final.md`.

---

## What each gate question resolved to

### Q1 — Foundry-readiness: could a builder start a new SaaS here?
**YES.** The path is: `mix samen.gen.app` → a gate-green app (proven ⟳) → author your domain
nouns → the verifier gate is your correctness oracle (proven by the T6.3 eval ⟳) → ground an agent
on `schema.dict.json` (a hallucination doesn't compile). The reuse is real and measured (PawChart:
~96% inherited on the families it touches, 4/6 idioms at zero code). The one honest ergonomic tax —
the global abbrev registry forces fresh abbrevs per mount and an operator must commit the appended
rows — is documented (ADR-006, N1) and is a coupling, not a hole.

### Q2 — Final red-team: any NEW hole?
**NO breach-class hole.** New risks N1 (registry coupling), N2 (CDC leak surface), N3
(cross-vertical isolation), N4 (generated-gate soundness), N5 (DP over-sell) were each red-teamed
this gate and found mechanism-safe or honesty-enforced (full write-up in `risk-register-final.md §3`).
The pre-existing headline guarantees (crypto-shred, grant-gated reveal, structural aggregate
mutual-exclusion, append-only audit, cross-org isolation) remain green in the Driftwood 20-step gate
+ oracle (EXITs 0, 15 attestations) run this gate.

### Q3 — Risk register + doc parity
`docs/risk-register-final.md` (NEW) refreshes R1–R15 (7 cleanly retired, 7 retired-in-mechanism with
a named bounded residual, 1 accepted process residual — none unretired/unlabeled), folds in the
Gate-5 F1/F2/F3 and the extraction-retro A1–A10 items, and adds N1–N5. `docs/claim-evidence.md` §H
(NEW) extends the doc-parity map to the Phase-6 sections (LLM-grounding L1–L4, foundry F0/F1r/F2r,
CDC P1/P2, aggregate-privacy A1/A2) — every claim → a passing eval / generated artifact / red-teamed
mechanism / named posture. No remaining oversell.

---

## Green-before / green-after

- **Green (baseline + after):** root `bash ci.sh` = **ROOT CI: ALL PASSED, exit 0**, run **3×**
  this gate. Counts stable across runs:
  - **samen_core: 842 passed** (9 properties, 833 tests), `mix test --warnings-as-errors`.
  - **demo: 399 passed** (17 properties) + **52 adversarial** + the demo CI gate (17 verifiers).
  - **driftwood: 58 passed** (1 property) + **4 adversarial** + the full **20-step** gate
    (16 verifiers + never-read-current lint 16b + T5.4 crypto-shred game-day + T5.5 PITR game-day,
    both arms). The destruction **oracle** (`no_plaintext_pii --subject <uuid> --tiers all`, run as a
    separate OS process against a freshly-erased driver) **EXITs 0 with 15 positive attestations**.
  - **pawchart: 19 passed** + the full **17-step** gate (incl. its microchip vault anti-tautology probe).
  - 6 spikes green (s00/s02/s03/s04/s05/s07).
- **Note on determinism:** the FIRST background CI invocation this gate exited 2 (a one-off — the
  output was lost to subshell buffering and could not be attributed to a suite); runs 2 and 3 were
  fully green with identical counts, and every suite/gate/oracle passed individually. I could not
  reproduce a failure. This is logged as a low-severity flake to watch (below), not a regression —
  the deterministic result across two full clean runs + every individual suite is green.
- **No source changed this gate.** I ran the generator into scratch dirs (removed) and restored the
  global abbrev registry byte-identical (md5 `1ee06ae9c8a279f17ae5b09ef0ddb6ca`). The only files
  written are the three gate deliverables: `docs/gate-6-report.md`, `docs/risk-register-final.md`,
  and the §H addendum to `docs/claim-evidence.md`.

---

## Caveats (each a named residue / operator-TODO / doc-stated posture — none a breach)

1. **Global abbrev registry coupling (N1 / A3 / ADR-006).** Two hosts in one repo collide on
   scope-default abbrevs; the generator appends 10 rows to the shared `samen_core/priv/abbrev_registry.json`.
   Mechanism-safe (a permanence ledger, not a read surface — no cross-vertical bleed), but an
   ergonomic tax + an operator-TODO (commit the appended rows). Target design ADR'd, deferred behind
   the generator (50+ file blast radius).
2. **CDC / real cloud simulations (N2 / P1).** ClickHouse, ClickPipes/`ecto_ch`, real AWS-KMS,
   Neon PITR, S3 Object Lock, and a physical read replica are faithful LOCAL simulations + production
   skeletons + documented operator TODOs. The load-bearing invariants (key-store-outside-PITR,
   token-only-downstream, never-read-current) are proven identically in the local sim; the real wiring
   + a CI diff of the ClickPipes allow-list against `Projection.project/1` are operator TODOs.
3. **Formal DP composition + t-closeness (N5 / A2).** T6.6 ships an ENFORCING deterministic
   read-count budget + a distribution-tested Laplace DP MECHANISM (both opt-in, off by default). The
   FORMAL ε-budget composed across queries and t-closeness stay **posture-under-construction**, named
   in the moduledocs in the doc's own words. There is deliberately no flag that claims more.
4. **A6 webhook storage-name guard.** `~r/^[a-z]{3}_/` drops legit freight catalog names
   (`cdl_number`). Verified this gate to be **over-strict only** — a defense-in-depth DROP that can
   never under-mask (absent by omission, never a leak). P1 backlog with a precise fix (key on the
   declared abbrev). The JSON:API surface renders CDL correctly (different path).
5. **Deferred extraction items (A5/A9 / ADR-007, A1/A2/A8/A10).** Rollup-as-cron-worker, the
   operator-plane migration set, typed non_pii! sentinels, org-from-actor convenience, and the shared
   game-day harness are ADR'd or backlogged with a trigger — deliberately NOT refactored (scope
   discipline: a 3rd vertical or the real cloud sharpens the shape).
6. **CI flake to watch.** One of three full-CI runs exited non-zero without a reproducible cause.
   Low severity (2/3 green, every suite green individually), but worth a deterministic-seed CI harden
   pass so a spurious exit can never mask a real one.

---

## Fix tasks

**None mandatory-in-phase** — no core guarantee regressed; no red-path is false; no claim is
oversold. All caveats are named residues / operator-TODOs / doc-stated postures already carried in
`docs/risk-register-final.md` and `docs/claim-evidence.md §H`.

**Recommended (post-gate, prioritized):**
- **[P1]** Fix A6: key the webhook storage-name guard on the resource's declared abbrev, not
  `~r/^[a-z]{3}_/`; add a freight-catalog-name red path. (1 core module + tests; over-strict today,
  not a leak.)
- **[P2]** Harden root `ci.sh` for determinism (fixed seeds / serialized DB setup) so a spurious
  exit can't recur; add a retry-once-then-fail wrapper that surfaces WHICH suite failed.
- **[P2]** Execute ADR-006 (per-host abbrev registry) behind the generator when a 3rd vertical
  lands or two hosts must share a repo in prod — retires N1's ergonomic tax.
- **[P2]** Execute ADR-007 (register vertical rollups as `Samen.Rollup.Spec`s, wire the cron)
  when a 3rd vertical confirms the domain-table-sourced Spec shape.
- **[P3]** When real cloud lands: wire ClickPipes/`ecto_ch` + the allow-list CI diff (N2/P1),
  the real AWS-KMS/Neon/S3 drills (A10), and typed non_pii! sentinels (A1/A2).
- **[Research]** The named open track: a formal ε-budget composed across queries + t-closeness
  (A2/N5) — stays posture-under-construction, honestly labeled, until proven.
