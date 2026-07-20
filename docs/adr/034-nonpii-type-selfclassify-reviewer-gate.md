# ADR-034 — The type-level `:non_pii` self-classification is reviewer-gated (two distinct parties)

- **Status:** Accepted.
- **Date:** 2026-07-20
- **Task:** Close the A1-gate carry INFO-1 (`docs/saas-gap-roadmap.md` WS-C): the type-level
  `:non_pii` self-classification was a **single-party escape hatch** out of the
  mask-unknown-by-default keystone.
- **Deciders:** engineering (foundry maintainer), grounded in the actual code of
  `Samen.Pii.Classification.classify/1` and the two-distinct-party invariant of
  `Samen.NonPii.register/1`.

---

## 1 · Context

`Samen.Pii.Classification.classify/1` is the classification oracle: every attribute type is
`:pii` (masked/vaulted) or `:non_pii` (plaintext), and the load-bearing rule is
**mask-unknown-by-default** — anything not provably non-PII is PII (D9; §limits keystone).

A type can self-classify by exporting `samen_pii_class/0`. Self-classifying `:pii` opts a type
*into* protection (safe). But self-classifying `:non_pii` opts a **whole type** *out* of
masking — every column of that type becomes plaintext, unmasked. Before this ADR, `classify/1`
honored that `:non_pii` self-classification with **no gate at all**: a host application could
define one custom Ash type exporting `def samen_pii_class, do: :non_pii` and silently make every
column of that type plaintext, decided by a **single party**.

That is an inconsistency with the column-level lever. Opting a single *column* out of masking
already requires a **two-distinct-party** clearance: `Samen.NonPii.register/1` fails closed on
`cleared_by == reviewed_by` ("the same distinct-party discipline the reveal grant uses"). So the
broader lever (a whole type) was *easier* to pull (one party) than the narrower one (one column,
two parties) — exactly backwards. The roadmap notes no kernel type or vertical uses type-level
`:non_pii` self-classification today (verified: the kernel composites `FullName/Emails/Phones`
and `VaultField` all self-classify `:pii`), so this is a latent hole, not an active leak — but a
latent single-party opt-out of masking is precisely the leak-by-omission risk the keystone exists
to prevent.

## 2 · Decision

**A type's `:non_pii` self-classification is honored ONLY behind a valid, two-distinct-party
clearance — otherwise it falls through to the mask-unknown-by-default PII result (fail-closed).**

1. A new sibling module `Samen.NonPii.TypeClearance` holds the clearance allowlist, mirroring
   `Samen.NonPii`'s distinct-party invariant. A clearance is **valid** for a module only when it
   names that exact `:type`, carries a non-blank `:cleared_by` and a non-blank `:reviewed_by`
   that are **distinct**, and a non-blank `:reason`. Any missing/blank key, a self-review, or a
   non-map entry is invalid → the type stays masked (fail-closed).
2. `classify/1`'s `:non_pii` self-class branch now returns `:non_pii` **only if**
   `Samen.NonPii.TypeClearance.cleared?(module)`; otherwise it falls through to `:pii`.
   `classified?/1` mirrors this — an ungoverned `:non_pii` self-class is treated exactly like an
   unknown type (not "explicitly classified"). Self-classifying `:pii` and the non-PII scalar
   primitive registry are **unchanged**.
3. The clearance is a **config allowlist**
   (`config :samen_core, :non_pii_type_clearances, [%{type: …, cleared_by: …, reviewed_by: …,
   reason: …}]`), **not** a DB read: `classify/1` is a hot, pure, compile-time-and-runtime
   function (the `pii_classify` verifier calls it while compiling; the read resolver calls it on
   every read), so the gate must be pure and cheap and must never hit the database. This differs
   deliberately from the DB-backed per-column `Samen.NonPii` registry, whose consumers (the
   erasure arm, the offline verifier) are not on the hot read path.

## 3 · Rationale

- **Symmetry with the column lever.** Opting a type out of masking is now exactly as hard as
  opting a column out: two distinct parties. No lever is a single-party bypass of the keystone.
- **Fail-closed in the safe direction.** An ungoverned or malformed `:non_pii` self-class is
  treated as PII (masked) — the same direction mask-unknown-by-default already picks. A mistake
  leaves data masked, never accidentally plain.
- **Zero behavior change for the existing tree.** No kernel type or vertical self-classifies
  `:non_pii` (only `:pii`), so the existing green suite is unaffected except for the tests that
  specifically exercised the now-governed behavior.
- **Config, not DB, keeps the oracle pure.** Preserves the compile-time `pii_classify` oracle
  and the per-read resolver's purity; no DB dependency added to a hot path.

## 4 · Rejected alternatives

- **Leave the type-level `:non_pii` self-class ungated.** Rejected — it is the single-party
  escape hatch this ADR exists to close.
- **Forbid type-level `:non_pii` self-classification entirely.** Rejected — a legitimately
  non-PII host type (e.g. an opaque enum token) should have a governed opt-out, matching the
  per-column `non_pii!` story. The gate is a review, not a ban.
- **Back the clearance with the DB (reuse `Samen.NonPii`).** Rejected — `classify/1` runs at
  compile time and on every read; a DB read there would break the verifier's purity and add a
  hot-path query. A config allowlist is pure and cheap.

## 5 · Consequences

**Positive.** The keystone now has no single-party bypass at either the type or the column level.
The seam is proven refutable by sabotage `scripts/sabotages/27-f7-nonpii-type-selfclassify-bypass.patch`
(drop the gate → the named RED tests flip).

**Negative / accepted.** A host that legitimately wants a plaintext custom type must add a
two-party clearance entry to config — one extra, deliberate step. This is the intended cost.

**Neutral.** No runtime data changes; no schema changes; the per-column `Samen.NonPii` registry
and the `pii_classify` verifier are untouched.
