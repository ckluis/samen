# ADR-015 — Default-deny CDC/aggregate classifier for freeform content columns

- **Status:** Accepted (design; WS-A phase A1 implements, G3 rider). Claim-integrity — must not wait past WS-A's gate.
- **Date:** 2026-07-09
- **Task:** Kernel DESIGN for WS-A/G3 — replace the name+type "provably non-PII" heuristic with a **default-deny mechanism**: freeform string/text/map/jsonb columns are EXCLUDED from the CDC/aggregate projection UNLESS explicitly allowlisted (vault-routed, or a verifier-backed `non_pii!` two-reviewer declaration). Includes the migration path for existing verticals.
- **Deciders:** opus (kernel layer), grounded in harden H-2 (the single biggest claim-vs-mechanism gap) and the WS-A non-negotiable ("an unlisted freeform field must be provably absent from the projection — red-path").
- **Builds on:**
  - `Samen.Cdc.Projection` (`cdc/projection.ex` — `classify/3` at `:140`, `scalar_kind/1`, `project/1`, `assert_no_plaintext!/2`).
  - `Samen.PiiClassify` (`pii_classify.ex` — the name/value heuristic, `@pii_name_tokens`, `flag_reasons/1`).
  - `Samen.NoPlaintextPii.Context.plaintext_pii_type?/1` (the type-level oracle).
  - `Samen.NonPii` registry (the two-reviewer `non_pii!` override, `cleared_by != reviewed_by`) and the `pii_classify --baseline schema.dict.json` verifier.
  - The vault (`pii_attribute` → `vt_*` token → mirrored as `:token`).
- **Supersedes / touches:** inverts the classifier default for freeform content types (opt-in flagging → opt-out clearance). `samen_web` untouched. Existing verticals' baselines shift (§4).

---

## 1 · Context — "mask-unknown-by-default" is true for types, not for string contents

`Projection.classify/3` (`projection.ex:140–146`) refuses a column ONLY when `Context.plaintext_pii_type?(type)` is true (a TYPE check) or it is vault-routed; **everything else falls through `scalar_kind/1` and is bucketed `:metadata` → mirrored** to the aggregate plane. `PiiClassify` (`pii_classify.ex:290–301`) flags a `:string` column ONLY if its NAME matches `@pii_name_tokens` OR a seed value is PII-shaped. So a benign-named freeform string with no seed value — `drv_notes`, `owner_bio`, a dispatcher comment — produces **empty reasons → not flagged, not vaulted, mirrored into ClickHouse as `:metadata`** (harden H-2). The miss mode is *silent*. The "provably non-PII" surface is a heuristic backstopped by a human allowlist, not a proof.

## 2 · Decision — default-deny for freeform content types

A physical column whose Ash type is **freeform** — `:string`, `:ci_string`, `:text`, `:map`, `:jsonb`, or any type NOT on the structural-safe allowlist — is classified `:plaintext_pii` and **EXCLUDED** from `Projection.project/1` UNLESS:

- **(a)** it is **vault-routed** (`pii_attribute`) → carries a `vt_*` token → classified `:token`, mirrored; OR
- **(b)** it is **explicitly cleared** via `Samen.NonPii.register/1` with distinct second-reviewer metadata (`cleared_by != reviewed_by`) → classified as a safe scalar, mirrored.

**Structural-safe types stay as-is:** bounded id (`:uuid`), enum (`:atom`/`one_of`), timestamp (`:date`/`:utc_datetime`), number (`:integer`/`:float`/`:decimal`), `:boolean` → `scalar_kind/1` buckets them `:bounded_id`/`:enum`/`:timestamp`/`:number` and they mirror. The change touches freeform content columns ONLY — it does not over-refuse IDs/enums/dates.

**Mechanism:** `classify/3` gains a third branch BEFORE `scalar_kind/1`:
```
cond do
  vault_routed?          -> :token
  plaintext_pii_type?    -> :plaintext_pii
  freeform_content_type? -> if non_pii_cleared?, do: scalar_kind(type), else: :plaintext_pii
  true                   -> scalar_kind(type)   # structural-safe
end
```
`PiiClassify` flips its default for freeform types from *flag-on-heuristic-hit* to *flag-unless-cleared* — the name/value heuristic becomes advisory (better error messages), not the gate.

**Invariant G3-1:** for a freeform column, `present in Projection.project/1` ⟺ (vault-routed ∨ `non_pii!`-cleared). No freeform column reaches the aggregate plane by benign naming.

## 3 · Red paths & anti-tautology
- **RP-G3-1 (the proof):** a `:string` column, no vault, no `non_pii!` → `:plaintext_pii`, provably ABSENT from `project/1`, and `assert_no_plaintext!(resource, [col])` RAISES. The test FAILS if the column ever appears in the projection (anti-tautology probe).
- **RP-G3-2:** the SAME column with a two-reviewer `non_pii!` clearance IS present as a safe scalar; with a `pii_attribute` IS present as `:token`. Proves the allowlist works and RP-G3-1 is non-vacuous.
- **RP-G3-3 (over-block guard):** a `:uuid`/`:atom`/`:utc_datetime`/`:integer`/`:boolean` column is NOT re-classified `:plaintext_pii` — structural-safe types still mirror.

## 4 · Migration path for existing verticals

Re-classifying freeform columns as `:plaintext_pii` will fail `pii_classify`/`no_plaintext_pii` and shrink the projection until each column is triaged. Sequenced, gate-able migration (phase A1, before any vertical-inheritance proof):

1. **Sweep:** `mix samen.audit.freeform_projection` lists every currently-`:metadata` freeform column across `demo`/`driftwood`/`pawchart` (the migration worklist).
2. **Triage each column:**
   - genuine PII → declare `pii_attribute` (vault-route) → mirrors as `:token`;
   - genuinely safe (e.g. a bounded status that should be an enum) → fix the type, OR add a two-reviewer `Samen.NonPii` registry entry with a written justification.
3. **Baseline shift:** regenerate `schema.dict.json` + the `pii_classify --baseline` invocation and the `sink_schema`/`no_plaintext_pii` snapshots in the migration commit — an EXPECTED delta, reviewed, not a break.
4. **Per-vertical gate:** each vertical's re-classification is a discrete gate-able step; `ci.sh` for that vertical must be green after triage.

## 5 · Consequences
- **+** The load-bearing "provably non-PII / excludes plaintext BY CONSTRUCTION" claim becomes a fail-closed mechanism; the H-2 silent-pass miss mode is eliminated.
- **+** A tenant typing a name into a freeform note no longer leaks it to the analytics tier by naming.
- **−** One-time triage cost across three verticals; some freeform columns must be vault-routed or two-reviewer-cleared. This is the intended forcing function.
- **−** Baseline/snapshot churn in the migration commit (expected, reviewed delta).
- **Deferred (WS-C):** a runtime value-shape scan on the CDC write path (belt-and-suspenders atop this compile-time default-deny).
