# Shared brief for theme orchestrators — samen OSS-scan capability parse

You are a THEME ORCHESTRATOR parsing one theme of a 127-project Elixir/BEAM OSS scan for **samen**, an Elixir/Ash/Phoenix "SaaS foundry" (repo: `~/Desktop/projects/samen`, MIT-licensed, github.com/ckluis/samen). Samen is a substrate for launching many SaaS products: `samen_core` (vault/masking/policy/audit/jobs/AI kernel — vendor-free, INV-4), `samen_web` (two-plane web framework, identity spine), vendor adapter packages (`samen_stripe`, `samen_anthropic`, ESP packages), generators (`mix samen.gen.app` emits a running app), ~20 `mix samen.verify.*` tiers, a 285-patch sabotage harness.

## Inputs (read in this order)
1. `~/Desktop/projects/samen-oss-scan/samen-digest.md` — what samen is + its open gaps (section 11 = gap register G-numbers, WS letters). READ THIS FULLY FIRST.
2. Your theme's report-section text files (listed in your task prompt) in `/private/tmp/claude-501/-Users-clank-Desktop-projects/430cc04b-14d8-46b6-a9cf-3098a4297ccb/scratchpad/` — plain-text conversions of the assembled report.
3. `~/Desktop/projects/samen-oss-scan/findings/*.md` — 127 per-project write-ups with relevance/verdict frontmatter. VERIFY every candidate against its findings file before including it (use sub-agent readers for bulk).
4. `~/Desktop/projects/samen/spec/full-saas-readiness.md` — master spec WS-A..WS-L.
5. `~/Desktop/projects/samen/_orch/plan/backlog.yaml` — 169 existing items T01..T160 (+T84a/b). A candidate duplicating an existing item must be recorded as an ANNOTATION recommendation, not a new item.
6. `~/Desktop/projects/samen/docs/` (ADRs) and actual samen code — when you claim "samen lacks X", GREP THE REPO before believing it. Cite file paths as evidence.

## The core discrimination rule
For every candidate ask: *where does the value actually live?* Keep infrastructure (multi-tenancy, auth/identity, job orchestration, realtime/sync, billing/metering, audit/observability, content pipelines, deploy/ops, OTP/Ash techniques, protocols serving a SaaS need). Discard product skins (front-ends over third-party data, consumer apps whose value is community/dataset, clones). TRANSFORM when a discarded skin hides a keepable mechanism — name the mechanism explicitly.

## The foundry bar (mandate for THIS run)
A pattern only earns a proposed backlog item if it helps the FOUNDRY: it must land in samen_core/samen_web/adapter-packages/generators as substrate every generated app inherits (or as foundry-owned mix tasks/verifier tiers). And it must not be already built, already planned (backlog/spec), or already refuted (ADRs — e.g. ADR-037 rejected ash_ai/Jido/ash_admin; ADR-003 rejected Cloak). Evidence required: for each adopt candidate, name the samen gap (G-number / WS / ADR / labeled TODO) and show repo evidence it is genuinely missing.

## License rule — samen must stay MIT-able
Record each source's license. MIT/Apache-2.0/BSD: importable. Copyleft (GPL/AGPL/LGPL) or non-OSS (BUSL, SSPL, FSL, Elastic, fair-source) or MISSING license: pattern-source ONLY (clean-room concept adaptation, never code translation). Unclear license = incompatible until verified.

## Mode marking (pattern over tech)
Mark every adopt candidate: **import** (take the library/dependency — only when it embodies hard-won complexity: crypto, protocol edge cases, production hardening), **adapt** (re-implement the pattern natively in Ash/Elixir — the default), **study** (learn from it, design our own). Remember INV-4: zero vendor/HTTP deps in samen_core; deps live in adapter packages only.

## Sub-agents
You may spawn sub-agent readers for bulk findings-file reading: model **sonnet**, at most 2-3 at a time, readers only EXTRACT and REPORT (license, verdict, concrete mechanisms, effort claims) — judgment stays with YOU. Do not let a reader write your deliverable.

## Deliverable
Write `~/Desktop/projects/samen-oss-scan/parse-work/<your-theme>.md` with exactly these sections:
1. **Adopt candidates** (ranked): capability name; the SaaS-foundry need it serves; source project(s) + findings-file refs (e.g. `findings/023-keila.md`); license + MIT verdict; mode import/adapt/study; what specifically to build; effort S/M/L; which samen gap/WS/ADR it maps to; repo evidence it is genuinely missing (file paths / grep results).
2. **Transformed candidates**: discarded skin → kept mechanism.
3. **Explicit discards**: notable rejections, one line each on where the value actually lives and why samen can't capture it.
4. **Annotation recommendations**: candidates that duplicate/amend an EXISTING backlog item — cite the T-id and say what to add to it.
5. **Proposed backlog items (0-4, draft)**: one-line YAML flow maps in exactly this shape:
   `- {id: TBD, phase: 7, title: "OSS-SCAN (source: <project>, <license>, mode: adapt): <capability> — <what to build and why the foundry needs it; findings ref + WS/gap>", tier: sonnet|opus|fable, blocked_by: [], adversarial: standard}`
   tier: sonnet = well-specified mechanical build; opus = design-led/framework-first; fable = ADR-level architecture decision only. Be selective — the cross-theme budget is 5-8 items total (hard cap 12), so only propose items you would defend.

Your final message: a compact summary of your file (top candidates, item count, key discards). Do not paste the whole file.
