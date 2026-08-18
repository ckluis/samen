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

The committed registry's legacy global `"abbrevs"` map (263 entries) is **byte-untouched** — the
allocator only ever writes host namespaces. A `"hosts"` object now exists in-tree; at F7 landing it
carried five non-conflicting allocations (the F3 consent-ledger abbrevs — one per host: `demo`/`mce`,
`driftwood`/`fmv`, `pawchart`/`vmv`, `samen_core`/`sxv`, `samen_web`/`wmv`), each a distinct abbrev
reserved via the sanctioned allocator. Because every host abbrev resolves to exactly one owner across
all namespaces, the flattened view (then 263 + 5 = 268 entries) was **lossless** and the
flattened-view verifier was correct. **Current state (post-F7, count-checked live rather than
re-pinned here so this paragraph cannot go stale the way its F7 numbers did):** the allocator has
since reserved many more host-namespaced abbrevs across normal feature work; `mix run -e
"IO.inspect(Samen.AbbrevRegistry.load() |> map_size())"` against the committed registry reports the
current flattened total, `flatten_conflicts/1` against the committed file reports the current
conflict count — the invariant this ADR cares about is that the LATTER is always **zero**, not that
either total matches the F7 snapshot above. There is still **zero** cross-host abbrev reuse and
**zero** host-vs-global owner mismatch (reverified for this luminary doc-integrity pass: 263 legacy +
173 host-namespaced = 436 flattened entries, zero conflicts).

## 2. What is deferred here (the 50+ file partition ADR-006 §3 named)

Fully making the ownership ledger host-*aware end-to-end* (not just host-namespaced at write time):

1. **`Samen.Verifiers.AbbrevRegistry` host-partition.** The compile-time verifier currently reads the
   flattened global view via `AbbrevRegistry.load/0`. It is *correct today* because the flattening is
   **lossless** — `"hosts"` carries only non-conflicting allocations, so every committed resource still
   resolves to exactly one owner across all namespaces (a tripwire, below, now enforces this). Once two hosts
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

## 5. F7 slice shipped — the fail-closed flatten-conflict tripwire

The full 50+-file partition (§2) **remains deferred**. What shipped in F7 is the safe bounded slice
that makes the deferral *self-enforcing* rather than a silent latent risk:

- **`Samen.AbbrevRegistry.flatten_conflicts/1`** — a pure, cheap (single-pass, no IO), hot-path-safe
  guard that returns every abbrev owned by more than one namespace with *different* owners, i.e.
  exactly the condition under which the flattened view is ambiguous: (a) cross-host reuse (two hosts,
  same abbrev, distinct owners) or (b) a host-vs-global owner mismatch. Same-owner reuse is not a
  conflict (flattening stays lossless), so it is not reported.
- **`load/0`/`load/1` fail closed.** The flattened compat shim now calls `flatten_conflicts/1` and
  **raises** — with a message naming this ADR — when a conflict exists, instead of silently picking one
  owner. Because the compile-time verifier (`Samen.Verifiers.AbbrevRegistry`) loads through `load/0`,
  the build fails closed the day a real cross-host reuse lands, forcing the §2 partition to be
  implemented rather than false-positiving on the shadowed resource.
- **The allocator is unaffected.** The tripwire lives in the *flattened* read only. The allocator's
  host-aware path (`load_namespaced/1` → `validate_host/4`, and `reserve!/4`'s direct file read) never
  flattens, so it still reads and reserves a fresh non-conflicting abbrev normally. A lossy flattening
  is a flattened-view problem, not a namespaced-view problem.
- **No behavior change today.** The committed registry has zero flatten-conflicts (263 legacy-global
  entries plus the current set of host-namespaced allocations — 436 total as of this doc-integrity
  pass, up from 268 at F7 landing as normal feature work reserved more host abbrevs), so `load/0`
  returns the current flattened union unchanged and the whole suite + every gen probe stays green.

Proofs: `samen_core/test/abbrev_flatten_conflict_test.exs` (green: committed registry has zero
conflicts, load returns the union, allocator still reserves; red: synthetic cross-host reuse and
host-vs-global mismatch both report a conflict and make `load/0` raise; positive control: the same
registry minus the conflict does not raise). Sabotage:
`scripts/sabotages/28-f7-abbrev-flatten-conflict-tripwire.patch`.
