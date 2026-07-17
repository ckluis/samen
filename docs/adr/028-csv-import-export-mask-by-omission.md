# ADR-028 — CSV import/export: catalog-driven mapper, export as a first-class masking surface, import through the write chokepoint

- **Status:** Accepted (design; WS-E phase E3 implements).
- **Date:** 2026-07-16
- **Task:** WS-E / G15 — no import/export at any granularity. `Catalog.fields/1` makes a generic column mapper feasible. Export is "the classic mask-by-omission leak vector" (end-user.md G7) — the highest-risk new PII surface in WS-E. Build a catalog-driven CSV import/export, framework-first, with export masking as a NON-NEGOTIABLE red-path.
- **Deciders:** opus (WS-E design), grounded in `docs/gap-discovery/end-user.md` G7, the shipped `Samen.Catalog.fields/1` (runtime field enumeration), `Samen.Web.Reads.page!/3` (keyset pagination), and the vault `WriteGuard` / `PiiResolution` seams.

---

## 1 · Context

There is no CSV code anywhere in the tree. Two capabilities exist that make a GENERIC (not per-resource) mapper feasible: (a) `Catalog.fields/1` enumerates any resource's `{table, column, logical_name, type}` at runtime; (b) `Reads.page!/3` gives a keyset-bounded, org-scoped iteration path. The danger is asymmetric:

- **Export** is a mask-by-OMISSION leak vector. The naive implementation reads rows and writes columns — if it reads the raw domain row, a vaulted `vt_*` token (or worse, a plaintext field on the tenant plane serialized to an operator-plane download) leaks. Export must render EVERY cell through the same masking seam the UI does, per plane, or it becomes the plaintext bypass the whole framework exists to prevent.
- **Import** writes rows. It must route through the vault WRITE chokepoint (`WriteGuard` + `Vault.Change`) exactly as the UI create forms do — a bulk CSV import must not be a path that writes plaintext PII into a domain column bypassing the vault.

## 2 · Decision

**Five load-bearing decisions:**

1. **A generic catalog-driven mapper in `samen_web` (`Samen.Web.Csv`), not per-resource code.** Export/import operate over `Catalog.fields(resource)` — the operator/tenant maps CSV headers to catalogued logical field names; the mapper is one framework module every resource inherits. No per-vertical CSV code is authored.

2. **Export renders every cell through `Samen.Api.PiiResolution` on the actor's plane — export is a first-class masking surface, not a serializer.** The export pipeline is: `Reads.page!/3` (org-scoped, keyset) → for each row, project through `PiiResolution.resolve` on the request's plane → serialize the RESOLVED values (operator-without-grant ⇒ `••••` in the cell, tenant ⇒ plaintext of its own org, never a raw `vt_*` token, never a cross-plane plaintext). A vaulted field with no reveal grant exports as `••••`, IDENTICAL to what the UI shows that plane. This is the load-bearing decision: **the CSV cell and the pixel show the same masked value on the same plane** — export can never be a leak the UI wouldn't already permit. Red-pathed per plane.

3. **Import routes through the SAME governed Ash create/update actions the UI forms use — the write chokepoint, not a bulk-insert.** `Samen.Web.Csv.import/3` maps each CSV row to a changeset for the resource's governed create action and runs it through `Ash.create` — so `WriteGuard` (refuses operator-plane plaintext PII) and `Vault.Change` (encrypts PII → `vt_*`) apply per row exactly as they do for a single UI create. No `Repo.insert_all`, no raw-column write. A malformed/policy-violating row fails that row (fail-closed) with a per-row error report; the import is transactional-per-batch with an honest partial-failure summary. Bulk plaintext-PII import on the operator plane is refused row-by-row by the SAME guard the UI hits.

4. **Export is bounded and streamed, never an unbounded full-table read.** Export iterates `Reads.page!/3` page-by-page (keyset cursor), streaming rows to the CSV response — it inherits the `default_limit`/keyset discipline WS-A shipped, so an export of a huge table is a bounded stream, not a single unbounded `Ash.read!`. A very large export may be capped or backgrounded (bounded config); it never loads the whole table into memory or issues an unbounded query.

5. **Column allowlisting is deny-by-default and plane-aware.** The export mapper offers only catalogued, non-internal fields; vaulted fields are *offered but resolved* (so an operator export simply yields `••••` columns, not an error) — the masking does the gating, matching the JSON:API allowlist ethos (a field's presence in the CSV is governed; its VALUE is plane-resolved). Import rejects CSV columns that map to non-writable/system fields (`org_id`, abbrev-prefixed internal columns, `id`) — fail-closed on an unknown mapping.

## 3 · Rationale

- **Catalog-driven** turns "N per-resource CSV implementations" into one framework module — the catalog-as-data investment (WS-D) pays off directly here.
- **Export-through-PiiResolution** is the ONLY design that makes export provably not-a-leak: by rendering the identical resolved value the UI renders on that plane, export inherits the masking correctness the whole framework already proves, rather than re-deriving it. "Same value in cell and pixel" is a single-sentence invariant a red-path can pin.
- **Import-through-the-write-chokepoint** means bulk import is not a new PII write path — it's the existing governed create action run in a loop, so every vault/policy guarantee holds row-by-row with zero new trust surface.
- **Bounded streaming** reuses the shipped keyset discipline so export can't reintroduce the unbounded-read problem WS-A closed.

## 4 · Consequences

**Positive** — generic CSV import/export every vertical inherits at ≈0 LOC (adoption-unlock for B2B migration + backup); export is provably masked per-plane with a red-path; import inherits every write guarantee; bounded/streamed by construction.

**Negative / accepted** — CSV only (no xlsx; `NimbleCSV` is the single small dep, or hand-rolled RFC-4180 to stay dep-free — a design sub-decision). No column-transform/formula mapping (straight header→field map). Import dedupe is upsert-on-a-declared-key or create-only (bounded, not a full merge UI). Large exports may be capped/backgrounded (honest bound, not silent truncation).

**Neutral** — new `Samen.Web.Csv` module (import/export), a `/export` + `/import` framework route per mounted scope (via a `samen_csv_routes` macro), a per-row import error report struct, one small CSV dep or a hand-rolled parser (decided in E3).

## 5 · Red paths

- **RP-CSV-1 (AC-G15-2) export masking per plane (NON-NEGOTIABLE):** an operator-plane export of a resource with vaulted fields yields `••••` in those cells (never a `vt_*` token, never plaintext); a tenant-plane export of its own org yields plaintext; the cell value EQUALS the UI value on that plane. Sabotaging the export to read the raw row (bypassing PiiResolution) FAILS — this is THE mask-by-omission red-path.
- **RP-CSV-2 (AC-G15-3) import through the vault chokepoint:** a CSV row with a PII field imported on the tenant plane routes through `Vault.Change` (raw domain row holds `vt_*`, plaintext nowhere); the SAME import on the operator plane is refused row-by-row by `WriteGuard`. Sabotaging import to `insert_all` (bypassing the chokepoint) FAILS the vault-routing test.
- **RP-CSV-3 (AC-G15-4) export bounded:** export of a table larger than one page iterates keyset pages (never an unbounded `Ash.read!`); the query always carries a limit. Replacing the paged iteration with a raw full read FAILS the bounded-read probe.
- **RP-CSV-4 (AC-G15-5) import fail-closed on bad mapping:** a CSV column mapped to `org_id`/`id`/an internal abbrev column is rejected; a policy-violating row fails that row with an error, not a silent skip or a partial write. Allowing an import to set `org_id` (cross-org write) FAILS.
