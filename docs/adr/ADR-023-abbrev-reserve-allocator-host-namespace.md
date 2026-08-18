# ADR-023 — `mix samen.abbrev.reserve` allocator + host-namespaced registry schema (implementing ADR-006 Option B, bounded)

**Status:** Accepted (WS-D design, 2026-07-14)
**Context workstream:** WS-D "Builder Joy" (G4 / builder-dx.md G9)
**Relates to:** ADR-006 (abbrev-registry-scoping) — this ADR is the sanctioned implementation of
its deferred Option B.

## 1. Context

Every scope/resource must reserve a permanent 3-letter abbrev in the ONE global
`samen_core/priv/abbrev_registry.json`, and the builder must **commit that mutation alongside their
vertical** (which lives in a sibling repo depending only on samen_core). ADR-006 named this the
"ergonomic tax + operator-TODO" residue and **already adopted Option B — per-host-namespaced
ownership in one registry file — as the TARGET, explicitly deferred behind the T6.4 generator**
(ADR-006 §4). WS-D is that generator work.

The invariant ADR-006 protects is **permanence + collision-safety**: an abbrev, once owned, is
"one owner forever, never recycled." Crucially, per-host namespacing does **not** violate this — it
makes permanence *host-scoped* (demo's `cmp` and driftwood's `cmp` become distinct, legitimately-owned
entries), which is precisely what the shared-global file over-constrains. The physical 3-letter
column prefix is **unchanged**; only the ownership ledger's scope changes.

Today the generator's `reserve_abbrevs!/2` (`app.ex:203-223`) appends flat `abbrev → owner_module`
rows to the global file with a cross-owner collision check. The human still hand-edits the file when
authoring a scope/resource outside the whole-app generator (scope-authoring §10 checklist item).

## 2. Decision

**Ship `mix samen.abbrev.reserve` as the single allocator the generators call, writing a
host-namespaced registry schema, while keeping the global cross-host collision net as a safety
layer. Do NOT force the full registry+verifier host-partition into WS-D if it exceeds one phase.**

Concretely:
- **`mix samen.abbrev.reserve --host <otp_app> --abbrev <abc> --owner <Module.Path>`** allocates +
  commits an entry append-only. It is idempotent (same host+abbrev+owner is a no-op), fail-closed on
  cross-owner collision **within a host namespace** (permanence), and still checks the global
  cross-host net (two hosts sharing physical infrastructure cannot silently clash).
- **Registry schema** gains host namespacing: entries key on `(host, abbrev) → owner` (the ADR-006
  Option-B target). The existing flat rows are migrated to a default/legacy host namespace so nothing
  breaks; `Samen.AbbrevRegistry.load/0` and the compile-time verifier read the namespaced shape with
  a flat-compat fallback.
- **`samen.gen.scope` / `samen.gen.resource` call the allocator** — the human never hand-edits
  `abbrev_registry.json`. The `samen.gen.app` reserve path routes through the same allocator.
- **Bounded scope (the decompose rule).** If fully partitioning the verifier
  (`Samen.Verifiers.AbbrevRegistry`) + every reader to be host-aware exceeds a single phase (ADR-006
  §3 calls Option B a "50+ file change"), WS-D lands the **allocator + the namespaced schema it
  writes + a read-compat shim**, and files the remaining verifier-partition as a phased follow-on
  ADR. WS-D does not block on the full partition.

## 3. Consequences

**Positive.** The builder authors a scope/resource without reaching into samen_core's tree by hand —
the generator allocates. Parallel builders in sibling repos stop racing for global abbrevs (their
namespaces are distinct). ADR-006's target is realized without violating permanence. The physical
storage contract (3-letter column prefix) is untouched.

**Negative / accepted.** The registry schema changes shape (namespaced), so `Samen.AbbrevRegistry`,
the verifier, and the generator's reserve path all touch it — mitigated by a flat-compat fallback and
a one-time migration of existing rows. Two migration surfaces (the JSON schema + reader code) must
stay in sync, guarded by a round-trip test.

**Neutral.** The global cross-host collision net remains — the one safety Option C would have
forfeited — so hosts sharing infrastructure are still protected.

## 4. Alternatives considered

- **Keep the flat global file + only add the allocator (no namespacing).** Rejected as the target,
  accepted as the *fallback floor* if namespacing over-runs a phase: the allocator alone already
  removes the hand-edit tax, but leaves the cross-repo global-file coupling ADR-006 wants gone.
- **Registry file per host (ADR-006 Option C).** Rejected (per ADR-006) — forfeits the cross-host
  collision net that catches genuine clashes when hosts share physical infra.
- **Recycle/rename abbrevs to reduce pressure.** Rejected — violates the absolute "one owner forever"
  rule; permanence is load-bearing for column prefixes projected into CDC/logs/catalog.
