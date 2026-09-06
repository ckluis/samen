---
project: Wraft
url: https://github.com/wraft/wraft
category: Business and Collaboration
relevance: medium
verdict: Active Elixir/Phoenix DLM platform; no code to lift (AGPL), but its content-type -> template -> engine -> branded-PDF pipeline and external-counterparty sign flow are the best blueprint yet for a deep samen docs scope.
---

# 060 — Wraft

## What the project is

Wraft is an open-source **Document Lifecycle Management (DLM)** platform — an "open-source alternative to DocuSign/PandaDoc" for producing structured business documents (letters, contracts, offer letters) at scale: generate from templates, route through approval flows, and sign. Actively maintained (~1,685 commits, v0.6.6, Elixir ~1.19, 161 stars), AGPL-3.0, with a hosted "Wraft Cloud" and Docker-based self-hosting.

Stack: **Elixir/Phoenix 1.7 backend** (`wraft_doc` / `wraft_doc_web`, JSON API + React frontend in a separate repo), Postgres, Oban + oban_web, Guardian JWT + api_keys, waffle/ex_aws-S3 storage, a **Rust NIF PDF analyzer** (rustler), **y_ex** (Yjs CRDT) for collaborative editing, ex_typesense search, fun_with_flags, backpex admin, cloak_ecto encryption, ex_audit, open_api_spex + bureaucrat, mjml/mjml_eex email templating, and recent AI additions (**jido_ai ~2.2, req_llm**, `ai_agents` + `token_engine` contexts).

Core product model: content is authored in **open formats (Markdown + JSON)**, strictly **separated from layout** — content types + data templates + reusable blocks/block_templates + frames feed layouts/themes, rendered to branded PDFs via typesetting engines (Typst/LaTeX topics on the repo). Domain contexts include: documents, content_types, blocks, layouts, frames, data_templates, forms, pipelines/logic_pipeline, comments, notifications, webhooks, organisation (multi-tenant), billing, **counter_parties** (external signing parties), vendors, action_log, system_backups, schedulers/workers.

## What samen could adopt

1. **Structured document-generation pipeline (content-type → data-template → layout/theme → engine → branded PDF)** — Wraft's central idea: documents as data (Markdown+JSON) with layout owned separately, compiled by a typesetting engine.
   - *Why it fits*: samen's `Samen.Scopes.docs`/cms are shallow; every vertical (driftwood freight BOLs/invoices, pawchart discharge summaries, dunning letters in G8) eventually needs branded generated PDFs. "Documents as catalog-described data" is exactly samen's catalog-as-data posture, and rendering is a natural fail-honest adapter (`samen_typst` package holding the engine dep, core stays vendor-free per INV-4). Typst specifically is a modern, fast, single-binary engine — far lighter than LaTeX/Pandoc.
   - *Effort*: **L** (new scope depth + one adapter package + generator support), with an **M**-sized first cut (one content type + Typst adapter + masked-field-aware render chokepoint).

2. **External-counterparty signature lifecycle (counter_parties + flows + verification)** — approval flows that extend beyond org members to external parties, with document state machine (draft → approved → sent → signed) and QR-code verification of authenticity (eqrcode).
   - *Why it fits*: samen already has the E3 approvals engine (requester ≠ approver at policy + DB-CHECK) and AshStateMachine; extending approvals to a vaulted external counterparty (their PII masked by default, sign token time-boxed like reveal grants) is a differentiated, on-brand extension — "governed signing" nobody else has. Also feeds G21/G8 lifecycle surfaces.
   - *Effort*: **L** (idea-level adoption; design as ADR first per decompose-cross-cutting rule).

3. **mjml_eex for transactional email templating** — MJML compiled to responsive HTML at the delivery chokepoint.
   - *Why it fits*: samen's `Samen.Delivery.Chokepoint` + ESP adapters send email but there's no branded-responsive-template story; mjml_eex is a small, self-contained lib that slots into an adapter package (not core) and keeps templates as data.
   - *Effort*: **S**.

4. **Reusable content blocks / block_templates / frames** — composable document fragments that adapt per business rules.
   - *Why it fits*: the natural schema for item 1's authoring model, and maps cleanly onto Ash resources + samen custom fields; also a good LLM-grounding target (AI drafts a block, E3 approves).
   - *Effort*: **M** (only meaningful bundled with item 1).

5. **OpenAPI spec emission (open_api_spex pattern, not necessarily the lib)** — Wraft publishes a typed OpenAPI contract; samen's JSON:API has `samen.verify.api_contract` but no exported spec artifact.
   - *Why it fits*: emitting OpenAPI from the catalog would strengthen G22 (agent-grounding packaging for external builders) and MCP tooling — catalog parity verifier can gate it.
   - *Effort*: **M**.

## What to ignore and why

- **Any code lifting**: Wraft is **AGPL-3.0**, samen is MIT — patterns and product ideas only, never source.
- **jido_ai / req_llm AI layer**: samen already evaluated and rejected Jido (`_orch/jido-eval-report.md`); generic LLM client libs bypass the token-blind `%MaskedPayload{}` chokepoint. Wraft is merely a data point that others reach for Jido.
- **cloak_ecto encryption**: samen's ADR-003 explicitly rejected Cloak-style field encryption in favor of the vault + per-subject KMS keys + crypto-shred; Wraft's approach is weaker (no shred story).
- **ex_audit**: mutable-by-comparison; samen's hash-chained, WORM-anchored, tenant-readable audit is strictly stronger.
- **backpex admin + fun_with_flags(+ui)**: samen deliberately builds a first-party operator plane (ash_admin rejected, ADR-037) and first-party feature_flags.
- **Rust NIF pdf_analyzer**: contradicts samen's no-NIF posture (simple_sat chosen precisely to avoid NIFs); if PDF introspection is ever needed, do it as an external-process adapter, fail-honest.
- **ex_typesense search**: samen intentionally standardized on Postgres tsvector (WS-E follow-on covers scale); adding a search sidecar breaks the local-Postgres-only ops story.
- **y_ex/Yjs collaborative editing**: impressive but a large realtime surface with PII-masking implications on every CRDT update; not worth it before the docs scope itself exists. Revisit only if item 1 ships and demands co-editing.
- **Guardian JWT / opus pipelines / scrivener / waffle**: samen has equivalents chosen for reasons (host-owned auth spine, Reactor, keyset pagination contract, Files chokepoint with quarantine).
