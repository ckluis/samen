# ADR-027 — Search engine: kernel `Search.query/2` over the non-PII tsvector, registry-gated, org-scoped, ⌘K in samen_web

- **Status:** Accepted (design; WS-E phase E4 implements).
- **Date:** 2026-07-16
- **Task:** WS-E / G9 — the `SearchIndex` registry (`psh`) + `search_index_guard.ex` (forbids indexing PII columns) + real `pfl_search_vector` tsvector columns all exist, but there is NO `search/2` helper, NO `:search` action, NO ⌘K palette, NO search box. Build the engine over the existing non-PII foundation, framework-first, PII-safe by construction.
- **Deciders:** opus (WS-E design), grounded in `docs/gap-discovery/end-user.md` G2, `docs/gap-discovery/harden-existing.md` H-10, the shipped `SearchIndexGuard` (which already red-paths PII-column indexing), and ADR-020's kernel-engine / web-UI split precedent.

---

## 1 · Context

The **hard, differentiated part of search is already done**: `SearchIndexGuard.assert_no_pii_column/2` refuses to register a vault-routed column into a tsvector index (T3.7 red path), and resources carry a real `pfl_search_vector` column. What is missing is the entire user-facing engine: a query helper, a result-ranking pass, the ⌘K palette, and the per-list search box. The `Samen.UI.sidebar/1` even has a `:search` slot placeholder that nothing feeds.

The question is: (a) where the query engine lives; (b) how it stays PII-safe at QUERY time (indexing is already guarded — but a query could still leak by returning a masked field in the result row); (c) how results are org-scoped and ranked; (d) how the ⌘K palette mounts framework-first.

## 2 · Decision

**Four load-bearing decisions:**

1. **The query engine is KERNEL (`Samen.Search.query/2`), the ⌘K palette + box are `samen_web`.** Mirrors ADR-020 (flag engine) exactly: `query(scope, term, opts)` is a pure-ish Ash-read builder over governed data needed by every plane and by API/worker paths — kernel. It reads the `SearchIndex` registry to discover which `(resource, vector_column)` pairs are searchable for the actor's org, builds a `websearch_to_tsquery`/`plainto_tsquery` filter against each registered `vector_column`, ranks by `ts_rank`, and returns a bounded, org-scoped, plane-resolved result set. The palette UI is web-only.

2. **PII-safety is enforced at BOTH ends and the query end is the new guarantee.** Index-time is already guarded (`SearchIndexGuard`). WS-E adds the QUERY-time guarantee: `Search.query/2` only ever filters against a **registered** `vector_column` (never an arbitrary column), and every result row is projected through `Samen.Api.PiiResolution` before returning — so a match on a non-PII field returns a row whose PII fields are masked/omitted per plane (operator-without-grant sees `••••`). The result payload is an allowlist of the registered searchable field + a small set of non-PII display fields per resource (declared in the registry `metadata`), NOT the whole row. A masked value can never be a search *match* (the guard prevents PII in the index) AND can never leak as a *display* field (PiiResolution projects it). This is the rare masking-*reduces*-risk case end-user.md G2 flags — made explicit and red-pathed.

3. **Results are org-scoped by construction, reusing the shipped bounded-reads path.** `Search.query/2` composes the tsquery filter INTO the same `Samen.Web.Reads`-style org-scoped, keyset-bounded Ash read the lists use (`OrgScope` policy applies; `limit` always present) — a search can never return cross-org rows and can never be an unbounded read. The engine returns at most N ranked results per resource (bounded config), fail-closed on an unregistered/ambiguous term.

4. **The ⌘K palette mounts via a new `samen_search_routes`/`Samen.UI.command_palette` framework component; the per-list box fills the existing `:search` slot.** The palette is a single framework LiveComponent (keyboard-triggered, debounced, calls `Search.query/2`, renders masked-safe result rows through the kit) that every vertical mounts with one macro call — zero authored search LiveViews. The per-list search box wires the sidebar `:search` slot (already present) to the same engine scoped to the current resource. Verticals inherit both at ≈0 LOC.

## 3 · Rationale

- **Kernel engine / web palette** matches ADR-020 and keeps the kernel web-dep-free; every caller (⌘K, per-list box, future API search) shares one query path.
- **Query-time projection through PiiResolution** closes the one gap index-time guarding leaves: even though PII can't be *indexed*, a naive result row could still ship a masked field's plaintext to the wrong plane — projecting every result row makes that impossible, and "search results" joins the six-surface masking watch-list with a real per-plane test.
- **Registered-column-only filtering** means the query can never target an unguarded column — the index guard and the query guard reference the SAME registry, so a column absent from the registry is unsearchable, not silently searchable.
- **Reusing bounded-reads** inherits org-scoping + keyset bounding for free — search cannot become the unbounded/cross-org read that JSON:API was before WS-A.

## 4 · Consequences

**Positive** — a real ⌘K + per-list search every vertical inherits at ≈0 LOC; PII-safe at index AND query time with a per-plane red-path; the `:search` slot placeholder finally has an engine; the `File.search_vector` from ADR-026 becomes searchable; ranked, org-scoped, bounded by construction.

**Negative / accepted** — Postgres FTS only (no vector/semantic search; adequate for the object-lookup use case, and dependency-free). `tsvector` population requires a DB trigger or an update hook per searchable resource — WS-E ships the trigger for the framework-owned searchable columns (File, and any registry-registered field) and documents the pattern; retrofitting every existing resource's tsvector is bounded to the ones registered. Ranking is `ts_rank` (lexical), not learned relevance.

**Neutral** — new `Samen.Search` module (kernel), a `Samen.UI.command_palette` LiveComponent + `samen_search_routes` macro (samen_web), a tsvector-populate trigger migration for searchable columns, per-resource registry `metadata.display_fields` (bounded non-PII allowlist).

## 5 · Red paths

- **RP-SE-1 (AC-G9-2) registered-column-only:** `Search.query/2` filters ONLY against columns present in the `SearchIndex` registry for the org; a term cannot target an unregistered/PII column. Sabotaging the engine to filter an arbitrary column FAILS the test (and the index guard's PII refusal stays green).
- **RP-SE-2 (AC-G9-3) result masking per plane:** an operator-plane search whose result row has a vaulted field renders that field `••••` (or omitted); a tenant-plane search of its own org sees plaintext. Sabotaging the result projection (returning the raw row) FAILS the per-plane test — this is the search entry on the masking watch-list.
- **RP-SE-3 (AC-G9-4) org-scoped + bounded:** a search from org A never returns org B rows; the result set is always `limit`-bounded (reuses `Reads`). Removing the `OrgScope` filter or the limit FAILS.
- **RP-SE-4 (AC-G9-5) fail-closed on empty/ambiguous:** an empty term or an unregistered resource returns `[]`, never a full-table dump. Defaulting to "match all" FAILS.
