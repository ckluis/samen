# ADR-025 — Abbrev registry + verifier host-partition (phased follow-on to ADR-023)

**Status:** Proposed (deferred) — filed per ADR-023 §2/§4 "decompose cross-cutting changes" bounded line.
**Relates to:** ADR-006 (Option B target), ADR-023 (allocator + namespaced schema — SHIPPED in WS-D D8).

## 1. Context

ADR-023 shipped, **bounded**, in WS-D D8:
- `mix samen.abbrev.reserve` — the allocator (deterministic `propose/3` + collision-checked
  `reserve!/4`), writing host-namespaced entries.
- The host-namespaced registry **schema** (`"hosts": {host => {abbrev => owner}}`) alongside the
  legacy flat `"abbrevs"` global cross-host net.
- The **read-compat shim**: `Samen.AbbrevRegistry.load/0` returns the flattened global view (union of
  the legacy map + every host namespace), so the compile-time verifier and every existing flat reader
  keep working **unchanged**. `Samen.AbbrevRegistry.{load_namespaced/1, owner/2, validate_host/4}`
  expose the host-scoped shape.
- `gen.app` / `gen.scope` / `gen.resource` reserve paths now route through the allocator into the
  app's host namespace (no hand-edit of `abbrev_registry.json`).

The committed registry (263 entries) is **byte-untouched** — no `"hosts"` key exists in-tree yet, so
the flattened view equals the legacy map exactly.

## 2. What is deferred here (the 50+ file partition ADR-006 §3 named)

Fully making the ownership ledger host-*aware end-to-end* (not just host-namespaced at write time):

1. **`Samen.Verifiers.AbbrevRegistry` host-partition.** The compile-time verifier currently reads the
   flattened global view via `AbbrevRegistry.load/0`. It is *correct today* because `"hosts"` is empty
   in-tree — every committed resource still resolves through the legacy global map. Once two hosts
   legitimately reuse a physical prefix (the whole point of Option B), the verifier must validate a
   resource against **its own host's namespace** (`validate_host/4`) rather than the flattened union,
   so a legitimate cross-host reuse compiles and an intra-host recycle still fails. This requires
   threading the owning host (otp_app) into the verifier's `dsl_state` read.
2. **Every flat reader.** `Samen.Resource` / `Samen.Extension` and any tooling reading `load/0` for
   ownership decisions (vs. mere presence) must move to the host-scoped API.
3. **One-time migration of the committed rows** into explicit host namespaces (currently they remain
   in the legacy global map — which is fine as the shared cross-host net, but Option B's "clean"
   end-state assigns each existing row to its owner's host).

## 3. Why deferred (not a gap)

Per ADR-023 §2 and the "decompose cross-cutting changes" memory: forcing the full partition into WS-D
would exceed a single phase. The bounded slice (allocator + schema + shim) already removes the
hand-edit tax and unblocks the generators; the flattened-view verifier is *correct* until a real
cross-host prefix reuse is committed. No vertical needs the partition today. This ADR is the explicit
record so the follow-on is tracked, not lost.

## 4. Trigger

Land ADR-025 when the **first legitimate cross-host prefix reuse** is committed (two hosts owning the
same 3-letter abbrev for distinct resources) — at that moment the flattened-view verifier would
false-positive a collision, and the host-partition becomes load-bearing rather than cosmetic.
