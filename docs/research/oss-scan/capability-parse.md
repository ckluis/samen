# samen OSS scan — capability parse

Date: 2026-08-21. Inputs: `samen-digest.md`, `samen-oss-findings.html` (10 sections), `findings/*.md` (127 write-ups), the samen repo itself (`~/Desktop/projects/samen`, branch `saas-readiness-phase-1`), `spec/full-saas-readiness.md`, `_orch/plan/backlog.yaml` (T01–T160), `docs/adr/`.

Method: seven theme orchestrators (agent-runtime, ai-governance, identity-trust, billing-metering, delivery-egress, ops-data, product-platform), each verifying every candidate against its findings file AND against the repo by grep before proposing anything. Full per-theme detail (evidence file paths, per-candidate greps, complete discard ledgers) lives in `parse-work/*.md`; this document is the deduplicated, ranked synthesis.

Per operator override, this run ends in backlog conversion: the Part-4 shortlist has been appended to `~/Desktop/projects/samen/_orch/plan/backlog.yaml` as T161–T168 (uncommitted, for review).

---

## Part 0 — The audit finding that reframed the whole parse

**The assembled report — and in places the samen digest and samen's own gap register — systematically understate what samen already ships.** Every theme independently confirmed it. The stale claims caught and refuted by direct repo audit:

| Report/digest claim | Repo reality |
|---|---|
| "Stripe sync is a stub (`SyncAdapter.Stub`)" — G13's headline | Stub DELETED (`billing/provider.ex:24-30`); `SamenStripe.Provider` does real signed webhooks, checkout, portal, lifecycle sync w/ proration, metered usage reporting over injectable cassette transport. Only the live-key smoke lane is operator-gated. |
| "Adopt HMAC-digest show-once token storage" (Codex Pooler/CYFR cluster) | Already the invariant everywhere a bearer secret exists: emailed tokens, sessions, API keys, MCP tokens digest-only/show-once; fleet creds KMS-wrapped constant-time; webhook secrets vault-routed. |
| "No suppression-list logic on the send path" (Keila card) | Built (T28/T30/T114): `Delivery.Chokepoint` consults `dlv_suppression` fail-closed; bounce/complaint webhook ingestion populates it token-blind, idempotently, with DLQ. |
| "Fleet is push-only; a wedged heartbeat reads healthy" (Health card) | ADR-044 mode-A signed pull probe + cockpit-side `stale_after_s` staleness. Dead-man semantics shipped; only the public status page is missing. |
| "No cancellation / circuit breaker / checkpoint-resume / tool manifests in the agent loop" (sections 2–4) | All built: `run.ex`, `breaker.ex`, `kill.ex`, `tools.ex` (four-way narrowing, fail-closed), `write_proposal.ex` (args-digest binding). |
| "Metadata-only AI logging" as a new verifier | EG6 is a tested invariant (A1 no-text-in-logs test; T72 zero-`vt_*` pass criterion), not a posture to codify. |
| Plausible daily-salt visitor identity for analytics | Built stronger: `ProductEvent` has no identity column at all; `pae_actor_ref` is a per-subject HMAC pseudonym, crypto-shreddable. |
| "Revalidate plan on every Stripe webhook" (Azimutt) | Built stronger: `Reconciler` re-fetches the authoritative object on every verified event, never trusts the payload, with replay + out-of-order watermark gates Azimutt lacks. |
| Sequin's idempotency-key convention | Already samen's practice on every outbound retry path checked. |

**Doc-hygiene consequence (own action, no OSS source):** the G13 register line, WS-B spec preamble, the digest's delivery-pipeline description, and the stale "SKELETON" moduledoc in `samen_stripe/provider.ex:3` should be reworded so the next evaluation doesn't re-derive all of this (INV-6). Recorded in Part 5.

The inverse also happened: real defects the report did NOT name were found while auditing its claims (webhook-egress SSRF hole; automation live-load integrity bug; mutable usage ledger; KMS rotate designed-but-unimplemented). The best items in Part 1 came from grep, not from the report's headlines.

---

## Part 1 — Adopt candidates (ranked)

### Shortlist (converted to backlog, T161–T168)

**1. SSRF-proof single outbound-egress guard** — `Samen.Egress.Guard` (3-layer: literal private-range, resolve-at-fetch, pinned-IP connect) wired into the currently-unguarded `Samen.Webhook.DeliveryWorker` (posts to org-registered URLs via redirect-following `:httpc`) and the half-guarded automation webhook action, + DeliveryWorker hardening riders (payload cap, per-endpoint breaker, secret-rotation overlap, key-in-signed-body) + AST verifier. Sources: vutuv (MIT, near-portable), Baudrate/Tymeslot (AGPL patterns), Wanderer (MIT checklist). Mode: adapt. Effort M. The one live security defect the scan surfaced; no G-number — anchors ADR-039 §5.3 + B9/T19. `findings/078,062,059,097`; detail `parse-work/delivery-egress.md`.

**2. Automation run-definition pinning** — snapshot-per-run so a tenant edit never changes what an already-triggered/retrying run executes (`RunWorker` live-loads the workflow at fire time today, `run_worker.ex:94-106,198`) and historical Runs stay interpretable. Reuses shipped `versioned:` (T38/T119) machinery; kill-switch stays live-read; ADR-039 §13's undo rejection untouched (that was subject values). Source: Lightning (LGPL/GPL, patterns-only clean-room). Mode: adapt. Effort M. Data-integrity class. `findings/050`; detail `parse-work/product-platform.md`.

**3. Usage-metering capture substrate (`Samen.Billing.Meter`)** — the keyless half of G13 that's genuinely missing: reporting pipe exists end-to-end but nothing writes usage rows and the Usage blueprint is mutable with no idempotency identity (retried capture double-bills). Insert-only ledger + rebuild-from-source tallies + `within_limit?` quota joins + tenant usage panel with estimated receipts. Sources: Osmotic (BSD-2-Clause, pattern), Svärm receipts (FSL, pattern). Mode: adapt. Effort M. Explicitly NOT local rating/proration — mirror doctrine stands. `findings/108,030`; detail `parse-work/billing-metering.md`.

**4. KMS master-key rotation choreography** — ADR-001 §2.1 designs it ("rotated masters retained unwrap-only"), nothing implements it: `Samen.Kms` has no rotate/rewrap callback, `FileBacked` holds one `master.key`, and `secrets-rotation.md` §3 concedes the adapter can't do a dual-key transition. Key-ring + operator-initiated E3-gated rotate + chunked resumable re-wrap worker + retired-key-never-wraps red-path. Per-subject DEKs still never rotate (ADR-003). Sources: Logflare (Apache-2.0), Wanderer (MIT), Tymeslot (AGPL pattern). Mode: adapt. Effort M, trust-kernel adversarial. `findings/104,097,059`; detail `parse-work/ops-data.md`.

**5. Real `Storage.S3` + AetherS3 as keyless CI target** — the WS-E fail-honest skeleton (`files/storage/s3.ex` never stores a byte) has no backlog item; ADR-026 already ratified the design (SigV4 over `:httpc`, web-dep-free). AetherS3 (MIT) runs as a docker-compose fixture for a credential-free opt-in CI tier; MinIO fallback if API coverage falls short. Mode: import (fixture) + adapt (adapter code). Effort M (mechanical). `findings/098,055`; detail `parse-work/ops-data.md`.

**6. G11 public status page** — the last open G11 line. Public, rate-limited, token-blind samen_web surface + generator route over EXISTING fleet probe/staleness data (probing is built — do not rebuild); opt-in publish per app; masked uptime/incident history. Source: Health (AGPL, patterns-only; skip its SSE/Datastar transport). Mode: adapt. Effort M. `findings/103`; detail `parse-work/ops-data.md`.

**7. G24 i18n — ADR + first slice** — largest open end-user product gap; zero first-party gettext, USD/UTC hardcoded at cited blueprint lines. Seven codebases converge on ex_cldr+gettext+tz, but the ADR is genuinely load-bearing: samen's pinned ex_money 6.1.1 rides `localize`, not ex_cldr (mix.lock) — localize-first vs ex_cldr-first must be ruled. Accent's Langue core is the string import/export-chokepoint design ref. Full sweep phased per the decompose rule. Sources: Craftplan/nyght/Tymeslot/Nivose (AGPL evidence), vutuv/Torus (MIT), Accent (BSD-3); libraries permissive. Mode: import-libs-behind-adapt-ADR. Effort ADR+slice M, retrofit L phased. `findings/055,057,059,078,081,095,053`; detail `parse-work/product-platform.md`.

**8. Token-streaming chokepoint contract with per-delta re-scrub** — the one feature ADR-047 itself defers to "a future ADR", carrying BOTH §11 residuals (token streaming + live-progress PubSub). Six MIT/Apache projects prove the envelope/bounded-queue/pull-consumer plumbing is a solved zero-dep problem; the per-delta re-scrub through the masking chokepoint is samen's own work and the reason this is ADR-first. Ephemeral deltas never persisted (erasure envelope preserved). Sources: Lemon/Alloy/Cantrip (MIT), Nous/BeamWeaver/Sagents (Apache-2.0), Pixir (MIT). Mode: adapt. Effort L. `findings/044,046,034,036,047,024`; detail `parse-work/agent-runtime.md`.

### Next tier (real candidates, no slot this run — promote from here)

9. **`samen_oauth` OIDC-provider adapter package** (Boruta core, Apache-2.0, rare IMPORT; Operately's MCP-OAuth grant model as first consumer). Explicitly deferred gap, zero provider-side code in the repo. Held back on effort (L, ADR-first) + no current consumer pressure (static MCP tokens work). `parse-work/identity-trust.md`.
10. **AI spend governance at the chokepoint** (Glorbo/AlexClaw/OSA/Pepe, MIT/Apache): rates-as-data, tri-state `:ok/:alert/:stop`, declared tier routing — today budgets are counts, every call pays `claude-opus-5`. Becomes urgent the day live keys land; keyless CI blunts it now. `parse-work/ai-governance.md`.
11. **ESP send-path throttling** (Keila, AGPL clean-room): per-{org,provider} token buckets + Oban snooze; genuinely absent (ingress-only rate limiting today); cheap (sonnet). First promotion candidate when a vertical sends at volume. `parse-work/delivery-egress.md`.
12. **wax_ passkeys + credential-scoped step-up reauth** (vutuv MIT + AGPL patterns): zero WebAuthn code; no post-login fresh-auth gate on reveal/DSAR/shred/break-glass. `parse-work/identity-trust.md`.
13. **G19 DSAR self-serve export surface** (vutuv MIT + Plausible/Lightning patterns): kernel primitive built, zero web surface/zip machinery. `parse-work/product-platform.md`.
14. **Trajectory-based agent regression testing** (LangChain, Apache-2.0, adapt): golden tool-call sequences over the existing token-only Turn log. `parse-work/agent-runtime.md`.
15. **Billing-mirror staleness sentinel + fail-open/closed ADR-038 addendum** (Wanderer/Osmotic): webhook feed silently broken ⇒ mirrors drift forever; T151's entitled-forever edge is the recorded instance. `parse-work/billing-metering.md`.
16. **Version-pinned consent + approved-vs-actual reconciliation on E3** (CYFR/Codex Pooler, clean-room): approvals capture no definition hash. Complements #2 (which covers non-approval-gated runs). `parse-work/identity-trust.md`.
17. **Skills-as-data with progressive disclosure (G22)** (ZAQ clean-room + Long/Vibe MIT). `parse-work/ai-governance.md`.
18. **Decision-graph agent memory, ADR-first** (Loomkin/Ankole, patterns-only despite MIT — Jido-built). The one genuinely novel capability in the scan; not a named gap. `parse-work/ai-governance.md`.
19. **Agent-loop turn-guards pack** (Neoharness UNLICENSED clean-room + LangChain): duplicate-call guard, structured arg-errors, GenAI OTel, prompt caching. `parse-work/agent-runtime.md`.
20. **`mix samen.orch.tick`** (Symphony/Shep): claims-ledger bookkeeping over backlog.yaml; self-flagged weakest — never launches sessions, human gates unchanged. `parse-work/agent-runtime.md`.

---

## Part 2 — Transformed candidates (discarded skin → kept mechanism)

- **Keila** (Mailchimp-clone product) → send-path token-bucket throttling (#11); its suppression half samen already ships stronger.
- **vutuv** (fediverse LinkedIn) → `Vutuv.Ssrf` guard module (#1), versioned DSAR export registry (#13), passkey posture (#12), activity-log conventions (annotation).
- **Glorbo** (filesystem-as-truth "AI employees" org) → tri-state budget refusal + rates-as-data + `mix samen.doctor` preflight (#10, annotations).
- **Loomkin** (Jido dev-workspace) → decision-graph memory shape (#18); keeper full-fidelity offload rejected (breaks the erasure envelope).
- **Osmotic** (AI-gateway product) → insert-only idempotent usage ledger (#3); its local pricing table rejected for tenant money (mirror doctrine).
- **Wanderer** (EVE Online mapper) → fail-open/fail-closed billing-degrade question (#15), webhook-hardening checklist riders (#1), dual-key decrypt window (#4).
- **Health** (homelab uptime monitor) → the status-page feature only (#6); its probing/dead-man machinery samen already ships.
- **Lightning** (workflow-automation platform) → snapshot-per-run pinning (#2), streamed-zip DSAR shape (#13).
- **Plausible** (web analytics) → streamed-zip export machinery only (#13); its headline identity pattern already built stronger in samen.
- **Sagents/Lemon/Alloy/Nous/BeamWeaver/Pixir** (agent frameworks/products) → the streaming envelope/backpressure/canonical-ephemeral synthesis (#8).
- **CYFR** (WASM agent-permission system) → version-pinned consent + enforcement reconciliation (#16).
- **Codex Pooler** (account-pooling gateway) → per-key Observatory usage view (annotation on T84b/T155); everything else already built.
- **Camelot/Symphony/Shep** (software factories) → session-adoption/claims-ledger slice only (#20).
- **Accent** (translation-management product) → Langue format-abstraction core as the G24 import/export design ref (#7).
- **AetherS3** (distributed object store) → the runnable CI fixture (#5); its HRW/Khepri internals out of domain.
- **Wraft** (DocuSign alternative) → deferred blueprint designs (branded-PDF pipeline via future `samen_typst` adapter; counterparty e-sign on E3) — idea bank, not backlog.

## Part 3 — Explicit discards (where the value actually lives, and why samen can't capture it)

**Already built in samen (the report's systematic error — see Part 0):** real Stripe sync; webhook revalidation loop; HMAC/show-once token storage + `vault:` indirection; suppression + bounce ingestion; fleet pull-probe/dead-man; agent-loop cancellation/breaker/checkpoints/manifests/args-binding; metadata-only AI logging (EG6); Plausible visitor identity + drop taxonomy; Sequin idempotency convention; wide-event sink registry (behaviour + 3 adapters exist); aud_event partition lifecycle; per-dispatch egress attribution (Run.origin/depth/chain); ZAQ actor-never-from-params (structural, INV-2).

**Dependency-rejected (masking-chokepoint / INV-4 / ADR-037 lineage):** all eight agent frameworks (Alloy, BeamWeaver, Cantrip, Condukt, ElGraph, Legion, Lemon, Nous), all nine agent products (AlexClaw…ZAQ), Loomkin, LangChain, Sagents — raw-string provider paths, vendor/HTTP deps toward core, Jido/ReqLLM stacks. Patterns mined; libraries refused. stripity_stripe likewise (hand-built `samen_stripe` over `req` is deliberate).

**Value lives elsewhere / wrong problem:**
- Sequin watermark backfill + WAL slot processor — samen deliberately delegates CDC transport to ClickPipes/PeerDB; Broadway pipelines — a throughput problem samen doesn't have (study).
- Symphony full orchestrator service — unattended burn-down contradicts the deliberately human-gated adversarial process.
- Sandboxed LLM-authored code execution (Cantrip Dune, Legion Lua, Condukt microVMs) — samen has no code-execution tool and no roadmap line asking for one.
- Keycloak delegation / boruta-server-as-sidecar — outsourcing auth vs samen's in-chokepoint thesis; second stateful cluster for capability an imported lib provides.
- Bonfire Boundaries three-valued ACL — consumer sharing model; samen's SAT-solver OrgScope+PiiResolution composition is deliberate.
- Plural Console pull/reverse-tunnel fleet stance — ADR-044 settled it by operator ruling; validation only.
- libcluster as a backlog item — T90 proves Oban needs no BEAM clustering; PubSub clustering already planned (K4/T91); annotation only.
- New scope blueprints (nyght shifts, Tymeslot booking/availability, Craftplan light-ERP, Wraft doc-lifecycle, Operately check-ins) — all verified absent AND all deferred-until-a-vertical-demands-it; the foundry bar requires multi-vertical need.
- Mobilizon sanitize chokepoint — no consumer today (no tenant-authored raw HTML anywhere); becomes real with a rich-text CMS vertical.
- Loomkin keeper offload — full-fidelity context stashes outside the DEK envelope defeat crypto-shred.
- Pepe reversible PII redaction — the structural opposite of token-blind masking.
- Pepe tool-approval TTLs beyond "once" — auto-approval; regresses the attended-approval posture.
- Health synthetic-probe subsystem (DNS/TCP/SMTP raw sockets) — a monitoring product, not foundry substrate.
- Semaphore audit CSV/S3 export — composition of shipped pieces; schedule when a compliance customer asks.
- ServiceRadar — pure validation of the lean-kernel posture. Three codebases rejecting cloak-style encryption — pure validation of ADR-003.
- Neoharness anything-as-code — no LICENSE file (`license: null`) despite README's MIT claim; two surviving ideas kept strictly clean-room (#19).

## Part 4 — Closing shortlist (converted to backlog T161–T168)

1. T161 — SSRF-proof single egress guard (vutuv MIT + patterns; opus)
2. T162 — Automation run-definition pinning (Lightning patterns; opus)
3. T163 — Usage-metering capture substrate (Osmotic BSD-2; opus)
4. T164 — KMS master-key rotation choreography (Logflare/Wanderer/Tymeslot; opus)
5. T165 — Real Storage.S3 + AetherS3 keyless CI fixture (AetherS3 MIT; sonnet)
6. T166 — G11 public status page (Health AGPL patterns; opus)
7. T167 — G24 i18n ADR + first slice (7-codebase stack evidence + Accent; fable)
8. T168 — Token-streaming chokepoint ADR + build with per-delta re-scrub (6-project synthesis; fable)

Exact YAML in `_orch/plan/backlog.yaml` (working tree, uncommitted).

## Part 5 — Annotation recommendations (amendments to EXISTING items/docs; no new backlog entries)

**Doc-staleness corrections (INV-6 sweep, highest value):**
- G13 register line (`docs/saas-gap-roadmap.md:66`) + WS-B spec preamble (`spec/full-saas-readiness.md:71`) + digest: "Stripe sync is a stub" is stale post-T106/T108 — reword to "sync BUILT keyless (cassette-verified); live-key smoke + usage CAPTURE remain." Fix the stale "SKELETON" moduledoc in `samen_stripe/lib/samen_stripe/provider.ex:3`.
- Digest's delivery-pipeline description predates T28/T30/T114 (suppression/bounce ingestion built) and understates webhook-egress hardening (signing/idempotency/retry/DLQ built).

**Per existing T-id:**
- **T72** (red-team eval tier): add ingress-injection eval cases from AlexClaw's ContentSanitizer taxonomy (findings/000); fold in ControlKeel's findings→eval-candidate→human-gated-promotion loop (findings/018); add one EG6 POSITIVE shape assertion (terminal log line parses to expected keys).
- **T152** (keyless AI dogfood): embedder model/version column + `reembed_all` (vectors carry no version today — model swap silently mixes spaces); `mix samen.doctor` preflight (Glorbo, findings/003) as the fix for bare `{:error, :not_configured}`.
- **T155** (tenant AI UI) / **T84b** (cockpit): surface budget tri-state honestly if #10 lands; per-key Observatory usage read-scope over existing wide-event data (Codex Pooler pattern, findings/011).
- **T149/T155**: agent-run surface design refs — Hive "Flights" vocabulary (020), ElGraph ElTrace timeline (039), Sagents live-debugger (047), Shem forensic UI register (007).
- **T151** (lifecycle emails/dunning): state the nil-`period_end` guard as an instance of the fail-open/fail-closed policy (Wanderer framing, findings/097); test plan must assert lifecycle emails still pass `Chokepoint.send/2` (no bypass).
- **T25/B8** (usage reporting): if T163 lands, `UsageReporter` key derivation switches to the capture-side `idempotency_key` — one key end to end.
- **F7-P2-2 carry**: Jason-encodable entitlement summary (features + typed limits) exported through the catalog (Azimutt residue, findings/083).
- **T91** (Fly deploy BLOCK): evaluate libcluster_postgres alongside dns_cluster for PubSub clustering (findings/052); record that Oban needs no BEAM clustering (T90 proof).
- **T88/T92** (backup runbooks): GitBlixt restore-safety lines — envelope key shown once w/ off-server warning; restore REQUIRES carrying KMS key material (findings/085, doc content only).
- **T128**: partition-drop retention precedent noted for future volume (findings/052); compatible with `:delete`-class rows only, never `:shred`.
- **T44** (calendar/ICS): tokenized ICS feed URLs — per-user revocable capability token, vault-adjacent, audited, rate-limited (findings/074). S.
- **T115** (operator activity UI): vutuv conventions — declared per-kind detail-key vocabulary + build-time credential-shaped-key test + masked-at-write (findings/078). S.
- **T38/T119**: T162 is the next `versioned:` client family; reuse ADR-040 §6.2 governance verbatim.
- **T139** (sabotage harness wedged): new sabotage patches from T161–T164 sequence after T139 or regenerate together.
- **G28 register (`docs/saas-gap-roadmap.md:82`)**: warm-start design refs — Semaphore role naming/tiering (092), nyght role/permission table shape (057); note T146/T84a already shipped the enforcement spine.
- **ADR-037 line 647**: if #12 (passkeys) is promoted, the WebAuthn tier arrives first-party via wax_, closing the "wait for ash_authentication 5.0" trigger.
- **ADR-047 §11**: T168's ADR should consume BOTH residuals (token streaming + live-progress PubSub) so neither is re-litigated.

## Part 6 — second pass: promotions + concept mining

> Assembled by T31 from four upstream artifacts, cited inline: `T14` (workstream-1 audit,
> `/Users/clank/Desktop/projects/_orch/nodes/T14/work/w1-verdicts.md`), `T22`/`T23` (workstream-2
> concept rulings and repo-evidence, `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md`
> and `/Users/clank/Desktop/projects/_orch/nodes/T23/work/survivor-evidence.md`), `T30` (backlog
> append, `/Users/clank/Desktop/projects/_orch/nodes/T30/work/appended.yaml`), and `T32` (ranked
> next-tier list, `/Users/clank/Desktop/projects/_orch/nodes/T32/work/next-tier.md`). No verdict
> below is re-judged; every fact is cited to the node that ruled it.

### 6.1 Workstream 1 — per-candidate verdicts (the 12 held-back candidates, T169–T179 + #20)

Audited by `T14` (rung 3). Nine of the eleven already-filed entries (T169–T179) stand as written;
two stand with a noted correction; the twelfth candidate (#20) is **held, not promoted**. Source:
`/Users/clank/Desktop/projects/_orch/nodes/T14/work/w1-verdicts.md`, summary table (lines 566–582).

| id | capability | verdict |
|---|---|---|
| T169 | AI spend governance at the chokepoint | stands with a noted correction (below) |
| T170 | ESP send-path throttling | stands as written |
| T171 | wax_ passkeys + credential-scoped step-up reauth | stands with a noted correction (below) |
| T172 | G19 DSAR self-serve export surface | stands as written |
| T173 | trajectory-based agent regression testing | stands as written |
| T174 | billing-mirror trust boundary + staleness sentinel | stands as written |
| T175 | E3 version-pinned consent + approved-vs-actual reconciliation | stands as written |
| T176 | skills-as-data with progressive disclosure (G22) | stands as written |
| T177 | samen_oauth OAuth2/OIDC provider adapter package | stands as written |
| T178 | ADR-only decision-graph agent memory | stands as written |
| T179 | agent-loop turn-guards pack | stands as written |
| #20 | `mix samen.orch.tick` (Symphony/Shep claims-ledger bookkeeping) | **held, not promoted** |

**Correction on T169 (recorded, no edit made to the filed entry).** T169's license slot names only
Glorbo, AlexClaw, OSA and Pepe ("MIT/Apache-2.0"), but the entry's own title borrows CYFR's
per-tenant concurrency-cap pattern and cites `findings/012`; CYFR's auth/policy/audit/tenancy
subsystem, Sanctum, is FSL-1.1, which directive §4.1 requires to be marked "patterns-only
clean-room" in the license slot. Sibling entry T175, filed in the same batch, marks CYFR that way;
T169 does not. Nothing about the build changes — the concurrency rider was always a clean-room
reimplementation over Oban partitioning — only the licensing-hygiene marking is missing. Source:
`/Users/clank/Desktop/projects/_orch/nodes/T14/work/w1-verdicts.md`, Audit block 1.

**Correction on T171 (recorded, no edit made to the filed entry).** T171's license slot calls
Boruta "MIT"; Boruta is Apache-2.0 per `/Users/clank/Desktop/projects/samen-oss-scan/findings/100-boruta-server.md`
("Apache-2.0, by malach-it") and per sibling entry T177, filed in the same batch, which labels the
same project correctly. Both licenses are MIT-compatible so the plan and clean-room boundary are
unaffected, but the slot is factually wrong about a named source. Separately, the slot never states
`wax_`'s own license even though the entry's mode is "import wax_"; the first-pass evidence records
it as Apache-2.0 "re-verify at adoption," and directive §5's "Unclear license = incompatible until
verified" makes that re-verification a precondition of the import, not a footnote. Source:
`/Users/clank/Desktop/projects/_orch/nodes/T14/work/w1-verdicts.md`, Audit block 3.

**Candidate #20 — `mix samen.orch.tick` — held, not promoted.** Dedup, license (clean — Symphony
Apache-2.0, Shep MIT) and absence (T13 confirmed-absent) all clear, but the entry fails on two
independent grounds: no WS letter, G-number or ADR section anchor exists or can be invented for it
(directive §4.1's anchor requirement is "not optional"), and it fails the §5 foundry bar — a
`samen.orch.tick` task reads/writes samen's own gitignored `_orch/` dev-process state
(`/Users/clank/Desktop/projects/samen/.gitignore:30`), which no generated app inherits, so it is
"samen's private dev tooling wearing a foundry mix-task shape." Ruling (closing string): `hold`.
Per the done-criterion's if-and-only-if condition, no draft backlog entry was ever carried for it.
Source: `/Users/clank/Desktop/projects/_orch/nodes/T14/work/w1-verdicts.md`, Adjudication block
(lines 462–519).

### 6.2 Workstream 2 — concept-mining results

**Corpus read.** The whole `findings/000`–`findings/048` cluster plus `findings/051` (Sequin), read
for concepts only across three readers: `T20` (agent products / software factories, 117 concepts),
`T21` (agent frameworks / sandboxed-execution trio / Sequin, 60 concepts), `T21b` (findings/000–048
neighbours, 64 concepts) — 241 concepts total. Source:
`/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md`, lines 6–21.

**The dependency-level discard was not reopened.** All ~20 agent frameworks/products were rejected
on the masking-chokepoint failure (raw-string provider paths, vendor/HTTP deps reaching toward
core, Jido/ReqLLM lineage — INV-4, ADR-037). Nothing in this workstream reopens that; every survivor
below is a **clean-room pattern adaptation**, never a code import, per directive §3.2.

**Rulings.** `T22` (rung 3) ruled all 241 concepts: 31 `SURVIVES` (grouped into 13 items, S1–S13),
72 `REJECTED — premature` (real concepts, routed to the next-tier list, not a bar failure — never a
backlog item and never treated as a defect), and 138 `REJECTED` on one of four bars (bar 1 × 33,
bar 2 × 1, bar 3 × 94, bar 4 × 10). `T23` (rung 2) then ran repo-evidence checks against all 13
survivor items and withdrew three — S7, S8, S10 — each to `held — narrower than claimed` with an
evidenced remainder, never `dead`.

**The 13 survivor items, source and license per concept** (source: `T22` roll-up,
`/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md`, lines 502–523):

| item | capability | sources · license | MIT-compat | mode | tier |
|---|---|---|---|---|---|
| S1 | Context-compaction contract inside the ADR-046 erasure envelope | Ankole Apache-2.0 · OSA Apache-2.0 · Pepe MIT · Neoharness UNLICENSED (clean-room) · Alloy MIT · Condukt MIT · Sagents Apache-2.0 | permissive YES; Neoharness NO → clean-room | adapt | fable |
| S2 | Agent-loop hook/middleware seam (`{:block,:edit,:halt}`) | Alloy MIT | YES | adapt | opus |
| S3 | Untrusted-content sanitization at tool-result ingress | AlexClaw Apache-2.0 · Pepe MIT | YES | adapt | opus |
| S4 | Surface-scoped tool registries (MCP/operator/tenant/eval) | Condukt MIT (library) | YES | adapt | opus |
| S5 | Secrets-redaction lane distinct from `pii_*` masking | Condukt MIT (library) | YES | adapt | opus |
| S6 | `ctx[:actor]`-only tool identity + foundry-wide verifier | ZAQ AGPL-3.0 | NO → clean-room | adapt | sonnet |
| S7 | Mid-run cancellation (ETS abort registry) — **withdrawn, see below** | Vibe MIT · Neoharness UNLICENSED (clean-room) · Lemon MIT | MIT sources YES; Neoharness NO → clean-room | adapt | sonnet |
| S8 | Checkpoint-backed pause/resume for approval-gated runs — **withdrawn, see below** | BeamWeaver Apache-2.0 · ElGraph MIT · Legion MIT · Hive MPL-2.0 (clean-room) · Svärm FSL-1.1-MIT (clean-room) | permissive YES; MPL/FSL NO → clean-room | adapt (Hive: study) | opus |
| S9 | Embedding-model staleness stamp + incremental re-embed | AlexClaw Apache-2.0 · BeamWeaver Apache-2.0 | YES | adapt | sonnet |
| S10 | Watermark-coordinated backfill discipline — **withdrawn, see below** | Sequin MIT | YES | adapt | opus |
| S11 | AST denylist cross-audit of the raw-spawn lock (`apply/3`) | Legion MIT | YES | adapt | sonnet |
| S12 | Behaviour contract-test case kits per adapter | Lemon MIT | YES | adapt | sonnet |
| S13 | `mix samen.doctor` environment preflight, narrowed | Glorbo MIT-OR-Apache-2.0 · Agent Harness unlicensed (clean-room) | Glorbo YES; Agent Harness NO → clean-room | adapt | sonnet |

Every survivor whose MIT-compat column reads NO is marked "patterns-only clean-room" in its backlog
title per directive §4.1; none of the 13 items is `import` — all are `adapt` (S8's Hive leg is
`study`), matching directive §5's default.

**The three withdrawals (S7, S8, S10) — `held — narrower than claimed`, never `dead`.** `T23`'s
`## WITHDRAWN` rulings are **authoritative over T22's stale `SURVIVES` label** on these three
concepts, per the binding gate ruling; `T22`'s `concept-verdicts.md` still labels them `SURVIVES`
(documentation drift, accepted, not corrected in that file). Source for all three:
`/Users/clank/Desktop/projects/_orch/nodes/T23/work/survivor-evidence.md`, `## WITHDRAWN` section.

- **S7 — mid-run cancellation.** A durable, DB-persisted run-level cancel already ships
  (`Samen.AI.Agent.cancel/2`, `/Users/clank/Desktop/projects/samen/samen_core/lib/samen/ai/agent/run.ex:63-66`
  and `agent.ex:724-738` — the loop re-checks the cancel flag at every turn boundary and honors it).
  Narrowed remainder: a **sub-turn (per-tool-call) interruption** — an in-memory check consulted
  before each tool call within an in-progress turn, short-circuiting the remaining calls with
  synthetic results, instead of always letting the in-flight turn finish. No such mechanism exists
  anywhere in the repo.
- **S8 — checkpoint-backed pause/resume.** The run-level `awaiting_approval`/`park`/`resume`/
  `expire_due` state machine and a crash-recoverable turn cursor already ship
  (`/Users/clank/Desktop/projects/samen/samen_core/lib/samen/ai/agent/run.ex:60-136`), plus
  turn-row replay-idempotency (`turn.ex:1-16`). Narrowed remainder: **keyed memoization of the
  provider LLM completion itself**, so a crash-replay of an in-progress turn does not re-call the
  LLM — the repo states in its own moduledoc that "the provider call between the two checkpoints can
  genuinely repeat" while the turn row does not (`turn.ex:12-13`). This remainder still carries
  S1's bar-4 condition: any memoized completion must live inside the run subject's DEK envelope and
  register as a derived artifact under C-001-7's withdrawal-propagation rule; without that condition
  it fails bar 4 outright.
- **S10 — watermark-coordinated backfill discipline.** `Samen.Migration.ExpandContract.chunked_backfill/4`
  (`/Users/clank/Desktop/projects/samen/samen_core/lib/samen/migration/expand_contract.ex:278`)
  already ships a reusable, idempotent, chunked-scan UPDATE loop. Narrowed remainder: a **runtime**
  (non-migration) coordinated sweep for a **live** derived store — `chunked_backfill/4` hard-refuses
  outside a migration, its predicate can never re-process an already-populated row, it holds no
  watermark against concurrent writes, and it persists no cursor across a restart. **Per the binding
  gate ruling, this remainder does not rank ahead of S9** — it has no client until S9's re-embed
  sweep lands (T22's own text: "first client is the S9 re-embed sweep",
  `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:338`).

**UNVERIFIED note (does not block, stays in the record — CONTRACT §9).** `T20`'s verification probe
sampled 8 concept quotes across sections 000, 003, 006, 009, 019, 021, 024, 026 and downgraded two
to `UNVERIFIED`: **C-009-1** (findings/009-zaq.md) and **C-026-1** (findings/026-symphony.md) each
silently elide a parenthetical clause of real content words with no ellipsis marker, so the quotes
as originally written do not appear verbatim in their source findings files. Neither concept's
ruling changes — C-009-1 is `REJECTED — bar 3` (T22) and C-026-1 is `REJECTED — bar 4` (T22),
both independent of the elided clause's wording. Source:
`/Users/clank/Desktop/projects/_orch/verify/T20-verdict.json`, `unverified` array.

### 6.3 Appended IDs

`T30` (rung 1) appended **ten** entries, T180 through T189, to
`/Users/clank/Desktop/projects/samen/_orch/plan/backlog.yaml`, sourced from `T23`'s ten `DRAFT
ENTRIES` (S1, S2, S3, S4, S5, S6, S9, S11, S12, S13 — S7/S8/S10 excluded, being withdrawn, not
draft entries; candidate #20 excluded, being held, not promoted). Taken verbatim from
`/Users/clank/Desktop/projects/_orch/nodes/T30/work/appended.yaml`, whose only content change from
its source (per the prime's gate ruling 5) was fixing S6/T185's verify-task count from "21" to
"22" — the correction `T23`'s own S6 evidence block already stated.

| real id | source item | one-line title anchor |
|---|---|---|
| T180 | S1 | context-compaction contract inside the ADR-046 erasure envelope |
| T181 | S2 | agent-loop hook/middleware seam |
| T182 | S3 | untrusted-content sanitization at tool-result INGRESS |
| T183 | S4 | surface-scoped tool registries |
| T184 | S5 | secrets-redaction lane distinct from `pii_*` masking |
| T185 | S6 | `ctx[:actor]`-only tool identity + verifier tier (foundry-wide) |
| T186 | S9 | embedding-model staleness stamp + incremental re-embed pipeline |
| T187 | S11 | AST denylist cross-audit of the F-4 raw-spawn lock (`apply/3`) |
| T188 | S12 | behaviour contract-test case kit for adapter packages |
| T189 | S13 | `mix samen.doctor` environment preflight, NARROWED |

Verbatim appended YAML (source: `/Users/clank/Desktop/projects/_orch/nodes/T30/work/appended.yaml`,
all 10 lines, byte-identical to the live backlog's last 10 lines per T30's own diff check):

```yaml
- {id: T180, phase: 7, title: "OSS-SCAN (source: Ankole Apache-2.0 + OSA Apache-2.0 + Pepe MIT + Neoharness UNLICENSED patterns-only clean-room + Alloy MIT + Condukt MIT + Sagents Apache-2.0, mode: adapt): context-compaction contract inside the ADR-046 erasure envelope — re-scrub the summary through the chokepoint, dual-view (LLM-facing vs UI-facing) transcript, three-level overflow recovery, and a derived-artifact withdrawal-propagation rule so a shred invalidates matching summaries/memos; repo evidence: `context_cutoff`/`token_budget`/`context.window`/`overflow_recover` return zero hits in samen_core|samen_web (all 28 `compact` hits are CSV/UI helpers), nothing truncates or summarizes the loop's `:history` while budget exhaustion is terminal and never promotes a partial answer (agent.ex:114-122), ADR-047 §11's residual list names no compaction residual, ADR-046 has no derived-artifact rule; the §3.2a per-turn history re-scrub (chokepoint.ex:285) already ships and is the substrate to extend; findings/001+005+006+016+034+038+047; ADR-046/ADR-047 §11", tier: fable, blocked_by: [], adversarial: standard}
- {id: T181, phase: 7, title: "OSS-SCAN (source: Alloy, MIT, mode: adapt): agent-loop hook/middleware seam — an ordered chain (`:session_start`/`:before_completion`/`:after_compaction`/`:after_tool_request`/`:before_tool_call`/`:after_tool_execution`/`:on_error`) with a `{:block,reason}`/`{:edit,call}`/`{:halt,reason}` return contract, first-decision-wins, giving `samen_core`'s ADR-047 loop one declared policy seam instead of none; repo evidence: zero hits for any of the six hook names or the block/edit/halt contract in samen_core/lib or samen_web/lib; findings/034; ADR-047", tier: opus, blocked_by: [], adversarial: standard}
- {id: T182, phase: 7, title: "OSS-SCAN (source: AlexClaw Apache-2.0 + Pepe MIT, mode: adapt): untrusted-content sanitization at tool-result INGRESS — the missing direction of the ADR-047 chokepoint, which today only scrubs egress (PII masking outward, per ADR-047:399 and the EG2/EG4 renderers); repo evidence: chokepoint.ex/tool_result.ex/mcp.ex scrub only samen's own vault-routed fields on the way out and tool_result.ex exposes no sanitize entry point at all, no hit anywhere is prompt-injection/instruction-shaped-text/zero-width handling; the one shipped untrusted-content sanitizer, `Samen.Support.Inbound.Sanitize.plain_text/1` (sanitize.ex:32), is by its own moduledoc stored-XSS defense for a HEEx render sink and has zero callers under samen_core/lib/samen/ai — reuse its shape, it does not cover this; findings/000+006; ADR-047 §4.3", tier: opus, blocked_by: [], adversarial: standard}
- {id: T183, phase: 7, title: "OSS-SCAN (source: Condukt, MIT library, mode: adapt): surface-scoped tool registries — MCP server / operator plane / tenant plane / CI eval lane as first-class scopes each owning its own tool registry, structurally preventing a tool registered for one surface from being invoked on another; repo evidence: `Samen.Automation.Action.registry()` (agent.ex path) and `Samen.AI.Mcp`'s hardcoded four-tool set are two hand-rolled implementations with no shared registry/surface abstraction, zero hits for tool_registry/surface-scoped; findings/038; ADR-043 §7/§9", tier: opus, blocked_by: [], adversarial: standard}
- {id: T184, phase: 7, title: "OSS-SCAN (source: Condukt, MIT library, mode: adapt): secrets-redaction lane distinct from `pii_*` masking — a pattern-based chokepoint check for operator/app API keys, tokens, connection strings appearing incidentally in transcripts/tool output, separate from the declared-field `pii_*` vault-class taxonomy; repo evidence: zero hits for secret-pattern/free-text-scanner terms and no Logger `filter_parameters`; the two adjacent shipped facts are both narrower — `:pii_secret` (gen/post_templates.ex) is a declared-attribute generator example not wired into no_plaintext_pii.ex, and `redact_payload/1` (an @callback on the mailbox/delivery/enrichment/billing provider behaviours, provider.ex:107/149/73/124, identity pass-through by default) is a fixed-key `Map.drop` over inbound webhook envelopes that never runs on the AI plane; findings/038; ADR-046", tier: opus, blocked_by: [], adversarial: standard}
- {id: T185, phase: 7, title: "OSS-SCAN (source: ZAQ, AGPL-3.0 commercial dual-license, mode: adapt, patterns-only clean-room): `ctx[:actor]`-only tool identity as a structural rule + a verifier tier refusing any tool schema that declares an actor/org/tenant parameter, foundry-wide; repo evidence: the `ctx.actor` convention exists informally (agent/tools.ex:18) but none of samen's 22 `samen.verify.*` tasks checks tool-schema parameters for actor/org/tenant fields, and T177's near-identical rule is scoped inside its own OAuth-grant work, not foundry-wide; findings/009; ADR-043 §6.2/§7", tier: sonnet, blocked_by: [], adversarial: standard}
- {id: T186, phase: 7, title: "OSS-SCAN (source: AlexClaw Apache-2.0 + BeamWeaver Apache-2.0, mode: adapt): embedding-model staleness stamp + incremental re-embed pipeline — stamp each embedding row with the model identifier that produced it, detect drift on model upgrade, and batch re-embed only the stale rows; repo evidence: `samen_core/lib/samen/ai/embeddings.ex` carries no model/version field at all (grep for model|version returns zero hits), zero hits for stale_embedding/re-embed anywhere in samen_core; findings/000+036; WS-D D3", tier: sonnet, blocked_by: [], adversarial: standard}
- {id: T187, phase: 7, title: "OSS-SCAN (source: Legion, MIT, mode: adapt): AST denylist cross-audit of the existing F-4 raw-spawn lock for `apply/3` indirection — diff Legion's blocklist (defmodule/import/spawn/send/apply + module allowlisting) against samen.verify.agent_coverage's spawn_lock_violations/2 to close the gap where `apply(Samen.AI.Agent, :start, [...])` evades the direct-call/regex match; repo evidence: `samen.verify.agent_coverage.ex:160-177`'s AST branch and regex fallback both match only a direct `Agent.start/run` call, never an `apply/3` indirection; findings/042; ADR-047 §10a row 19/row 24", tier: sonnet, blocked_by: [], adversarial: standard}
- {id: T188, phase: 7, title: "OSS-SCAN (source: Lemon, MIT, mode: adapt): behaviour contract-test case kit for adapter packages — a shared `ExUnit.CaseTemplate` asserting `%MaskedPayload{}`-only acceptance and refusal semantics, generalized beyond the delivery-only `Samen.Delivery.ProviderConformanceCase` T27 (WS-C C1) built for ESP adapters, each adapter package taking one optional dep and raising a named compile-time error when absent; repo evidence: the only reusable cross-package case template (`samen_core/lib/samen/delivery/provider_conformance_case.ex`) is delivery/ESP-scoped (T27, a neighbour, WS-C) and its only external consumer is samen_postmark; the KMS family's contract suite (test/kms_conformance_test.exs) is a one-off `use ExUnit.Case` over a hardcoded @adapters list, and `Samen.AgentCase.assert_masked_only_payloads!/0` (agent_case.ex:211) covers the agent loop only — generalize these three, no general adapter-family kit exists; findings/044; WS-C / INV-4 (samen/ci.sh:126)", tier: sonnet, blocked_by: [], adversarial: standard}
- {id: T189, phase: 7, title: "OSS-SCAN (source: Glorbo MIT-OR-Apache-2.0 + Agent Harness unlicensed patterns-only clean-room, mode: adapt): `mix samen.doctor` environment preflight, NARROWED — the adapter-configuration walk + a config-only, behaviour-dispatched keystore-adapter readiness check (never a live vendor network probe, INV-4) + a single readiness table; the pgvector pre-migration check is explicitly OUT, already owned by T140 (backlog.yaml:148); repo evidence: no `mix samen.doctor`-named task exists (find over lib/mix/tasks returns empty), zero hits for readiness-table/adapter-configuration-walk terms, and the only in-repo precedent for the config-only keystore check is the single function `Samen.Kms.assert_prod_adapter_ready!/1` (kms.ex:169), not a foundry-owned task; findings/003+027; WS-L", tier: sonnet, blocked_by: [], adversarial: standard}
```

Source: `/Users/clank/Desktop/projects/_orch/nodes/T30/work/appended.yaml` and
`/Users/clank/Desktop/projects/_orch/nodes/T30/work/append-log.md`.

### 6.4 Updated ranked next-tier list

`T32` (rung 2) merged `T14`, `T22` and `T23` into one ranked list of everything that remains held —
76 entries across six bands, nearest-to-promotable first — plus a `DEAD, NOT HELD` accounting of
everything `T22` rejected on a bar rather than as `premature`. Embedded in full below. Source:
`/Users/clank/Desktop/projects/_orch/nodes/T32/work/next-tier.md`.

**Binding gate rulings T32 applied** (restated): S10's narrowed remainder does not rank ahead of
S9 (S9 is a promoted survivor, not itself held, so it is not a line in this list); T23's
`## WITHDRAWN` rulings on S7/S8/S10 are authoritative over T22's stale `SURVIVES` label on the same
concepts, so this list keys off T23 throughout.

#### HELD — ranked next-tier list

**Band 1 — nearest to promotable: dependency is a promoted/filed item, not a chartering decision, or no dependency at all.**

1. S7 remainder — sub-turn (per-tool-call) mid-run interruption. Held because the run-level cancel already ships; only the in-flight, before-each-tool-call check is missing, and nothing blocks building it. `/Users/clank/Desktop/projects/_orch/nodes/T23/work/survivor-evidence.md`.
2. S8 remainder — keyed memoization of the provider LLM completion for crash-replay. Held because the run-level state machine already ships; the remainder is conditioned on S1 landing (C-001-7's derived-artifact rule). `/Users/clank/Desktop/projects/_orch/nodes/T23/work/survivor-evidence.md`.
3. S10 remainder — watermark-coordinated backfill discipline for live derived stores. Held because `chunked_backfill/4` already ships the migration-time scan but has no watermark, cursor, or non-migration mode; per binding gate ruling, ranks behind S9 (its first client). `/Users/clank/Desktop/projects/_orch/nodes/T23/work/survivor-evidence.md`.
4. C-030-2 (Svärm) — held, premature: ROI metrics rank behind T169's cost dimension, which is already filed. `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:424`.
5. C-009-3 (ZAQ) — held, premature: `ROLES=`-gated supervision trees belong with the WS-L deploy recipe (T91), not ahead of it. `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:148`.
6. C-018-5 (ControlKeel) — held, premature: a hook-time verifier subset needs S2's runtime seam first; S2 is a promoted survivor. `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:170`.

**Band 2 — blocked on a specific, already-named increment (a promoted survivor not yet built, the v2 subagent/scheduling line T176 defers, or a not-yet-started ADR).**

7. C-001-5 (Ankole) — ranks directly below T178's decision-graph ADR. `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:87`.
8. C-000-5 (AlexClaw) — presupposes nested tool/subagent invocation, T176 v2. `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:77`.
9. C-024-5 (Pixir) — durable subagent timeouts presuppose subagents, T176 v2. `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:223`.
10. C-047-7 (Sagents) — child-to-parent interrupt escalation presupposes subagents, T176 v2. `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:333`.
11. C-016-2 (Neoharness) — presupposes agent-scheduled runs, T176 v2; trace-retention half rides S1. `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:399`.
12. C-019-6 (Genesis) — mid-run message injection is the increment after S8's durable pause/resume. `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:180`.
13. C-021-10 (Loomkin) — a diff-review component is polish on the built E3 surface. `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:203`.
14. C-024-4 (Pixir) — a materialized virtual-diff is UX on top of the built E3 draft shape. `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:222`.
15. C-044-4 (Lemon) — steering/follow-up queues rank with C-019-6, after S8. `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:314`.
16. C-047-6 (Sagents) — an `:edit` approval decision is polish on approvals shipping after S8. `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:332`.
17. C-032-3 (Agens) — LM-decided routing needs an ADR before it could be a build. `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:437`.

**Band 3 — blocked on infrastructure samen deliberately has not chartered yet: a code-execution/compute tool, a third-party MCP client consumer, live AI provider keys, or a multi-agent/unattended-run surface.**

18. C-042-3 (Legion) — the pure-Elixir Lua VM compute step, first among the sandbox cluster. `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:304`.
19. C-003-4 (Glorbo) — bwrap/`--cap-drop`/pasta isolation, no code-execution tool. `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:97`.
20. C-019-3 (Genesis) — systemd-run → bwrap → sandbox-exec chain, no code-execution tool. `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:177`.
21. C-037-1 (Cantrip) — port-isolated Dune sandbox, mined but no code-execution tool. `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:267`.
22. C-038-1 (Condukt) — in-memory→microVM→per-session-pod isolation ladder, no code-execution tool. `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:277`.
23. C-020-3 (Hive) — sandbox half, reader marked "watch, not adopt." `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:189`.
24. C-005-3 (OSA) — an Elixir MCP client, nothing consumes third-party MCP servers today. `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:112`.
25. C-021-9 (Loomkin) — consuming external MCP servers, no consumer, INV-4 forces an adapter package. `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:202`.
26. C-012-4 (CYFR) — MCP stdio→HTTP bridge, no third-party MCP consumer exists. `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:373`.
27. C-039-2 (ElGraph) — MCP client with sampling/elicitation, study-only. `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:287`.
28. C-005-4 (OSA) — deferred tool loading, no tool-count pressure exists yet. `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:113`.
29. C-018-6 (ControlKeel) — burn-rate breakers, AI plane keyless today (T152). `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:171`.
30. C-011-5 (Codex Pooler) — provider health/quota routing, AI plane keyless (T152). `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:366`.
31. C-016-7 (Neoharness) — fuse-style provider-egress breaker, T169's `:stop` is the first tripwire. `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:404`.
32. C-014-2 (JidoBuilder) — per-agent-template breaker granularity ranks with C-016-7/C-018-6. `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:384`.
33. C-005-6 (OSA) — durable goals with stall auto-pause, loop is request-scoped today. `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:115`.
34. C-006-3 (Pepe) — directed agent-to-agent ACLs need a multi-agent surface not built. `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:121`.
35. C-007-4 (Shem) — per-tool risk-tag manifests, "AI writes do not exist" today. `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:133`.
36. C-009-1 (ZAQ) — two-tier runtime reconciliation, no hot-patchable running runtime yet. `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:146`.

**Band 4 — debugging/replay affordance on top of value T173 already buys from the token-only Turn log; real, but purely additive.**

37. C-007-1 (Shem) — deterministic replay; T173 already buys the regression-pin value. `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:130`.
38. C-007-3 (Shem) — fork-at-turn debugging, same family as C-007-1. `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:132`.
39. C-036-3 (BeamWeaver) — checkpoint fork/time-travel eval primitive. `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:261`.
40. C-037-3 (Cantrip) — forkable loom replay, ranks with C-007-1. `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:269`.
41. C-039-1 (ElGraph) — thread forking from a past checkpoint. `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:286`.

**Band 5 — no demonstrated need, a hypothetical harm, or explicitly "no gap names it"; lowest promotion-readiness of the premature set.**

42. C-000-3 (AlexClaw) — parent/child semantic chunking, no truncation pressure evidenced. `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:75`.
43. C-000-7 (AlexClaw) — declarative `on_circuit_open` resilience policy, no gap. `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:79`.
44. C-001-8 (Ankole) — Oban Lifeline stale-lock rescue, no gap. `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:90`.
45. C-002-1 (Fermix) — compaction preserving memory/scheduled jobs presupposes T178 + T176 v2. `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:348`.
46. C-002-2 (Fermix) — memory/fact extraction ordering, no demonstrated failure. `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:349`.
47. C-002-3 (Fermix) — deterministic agent-loop benchmark tier, no gap. `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:350`.
48. C-002-5 (Fermix) — per-subsystem `/health/ready`, belongs with WS-L (T91); S13 covers the preflight half. `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:352`.
49. C-006-4 (Pepe) — one agent definition serving multiple channels, S4 answers this more safely. `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:122`.
50. C-007-2 (Shem) — offline-verifiable attestation bundles, anchors to no gap. `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:131`.
51. C-008-1 (Vibe) — multi-surface session attach, no second surface exists. `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:138`.
52. C-009-2 (ZAQ) — map/fan-out node types extend built E1/E2, no gap. `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:147`.
53. C-009-7 (ZAQ) — build-time DAG contract refusal, same family as C-038-6. `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:152`.
54. C-009-8 (ZAQ) — persist-before-deliver ordering, no demonstrated instance. `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:153`.
55. C-009-9 (ZAQ) — atom-safety guard, hypothetical harm. `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:154`.
56. C-010-3 (Buster Claw) — end-user "everything the agent changed" receipts feed. `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:358`.
57. C-015-3 (jido-conductor) — manifest-described run templates, T162 already pins run definitions. `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:390`.
58. C-017-3 (Camelot) — emitting `CLAUDE.md`/`.claude/skills` at generation time, no gap. `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:160`.
59. C-018-2 (ControlKeel) — trace-mining into eval candidates, no eval corpus yet. `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:167`.
60. C-019-7 (Genesis) — bounded grace turns refine S7's cancellation. `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:181`.
61. C-019-9 (Genesis) — disk-full-safe write boundary, SQLite-specific, samen is Postgres-only. `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:183`.
62. C-023-1 (Maestro) — `mix samen.gen.app --stack <preset>`, no gap names presets. `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:213`.
63. C-023-3 (Maestro) — fake-vs-live provider comparison runs, ranks with C-046-2. `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:215`.
64. C-025-3 (Shep) — "green means a named check reported," governs samen's own gate. `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:229`.
65. C-034-4 (Alloy) — `until_tool` termination, "draft is ready" already terminates through E3. `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:254`.
66. C-037-6 (Cantrip) — signed hot-load wards, matter only if ADR-044 payloads become executable. `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:272`.
67. C-037-7 (Cantrip) — wards as a declarative constraint list, ranks behind S2. `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:273`.
68. C-038-6 (Condukt) — compile-time JSON-Schema-typed tool operations, ranks with C-009-7. `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:282`.
69. C-040-3 (Jido Studio) — trending eval results, ranks behind an eval corpus that doesn't exist. `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:454`.
70. C-040-4 (Jido Studio) — arm-before-run two-step, no gap names it. `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:455`.
71. C-040-5 (Jido Studio) — presence-based viewer counts, low-value polish. `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:456`.
72. C-044-1 (Lemon) — stateless-Loop/stateful-Agent split, no demonstrated defect. `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:311`.
73. C-044-2 (Lemon) — deterministic multi-agent scenario arenas, inspiration-only. `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:312`.
74. C-046-2 (Nous) — declarative YAML eval suites, authoring ergonomics over T72's built tier. `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:320`.
75. C-047-5 (Sagents) — `until_tool` structured completion, ranks with C-034-4. `/Users/clank/Desktop/projects/_orch/nodes/T22/work/concept-verdicts.md:331`.

**Band 6 — structurally excluded, not merely waiting: fails the §5 foundry bar itself, so no amount of waiting promotes it absent a scope change.**

76. #20 — `mix samen.orch.tick` (claims-ledger bookkeeping over `backlog.yaml`). Held because it fails the §5 foundry bar (tools samen's own gitignored `_orch/` dev state, no generated app inherits it) and no WS/G/ADR anchor exists. Rank 20 (last) in Part 1's prior ordering, stays last here — nothing found in this second pass strengthens it. `/Users/clank/Desktop/projects/_orch/nodes/T14/work/w1-verdicts.md:462-519`.

#### DEAD, NOT HELD

**T23 withdrawals ruled `dead — already built`: none.** All three of T23's `## WITHDRAWN` blocks
(S7, S8, S10) are `held — narrower than claimed`, listed in Band 1 above, not dead.

**T22 bar-rejected concepts (138 total: bar 1 × 33, bar 2 × 1, bar 3 × 94, bar 4 × 10).** These are
not "premature" — T22 ruled them structurally excluded on a named bar, not merely not-yet-ready.
Full itemized list (each with source, ruling location and one-line ground) is embedded verbatim in
`/Users/clank/Desktop/projects/_orch/nodes/T32/work/next-tier.md` (`## DEAD, NOT HELD`, lines
158–320 of that file); the arithmetic is reproduced here as the section's own record:

- **Bar 1 — fails the foundry-substrate bar (33 concepts).** Dominant pattern: samen's own
  gitignored `_orch/` dev-loop and its coding-agent tooling (Glorbo's heartbeat ticks and reply-file
  IPC; Camelot's RunnerPool, Docker Swarm isolation, headless-planning contract, orphaned-session
  recovery; Shep's Port-supervised runners, worktree-per-task, live-CLI drop-in, verify-then-PR loop,
  tracker-as-database state; Symphony's workspace hooks, claim/run-attempt state machine, env-
  stripping, `WORKFLOW.md`, observability API, blocked-run surfacing, stall/continuation retry;
  Loopyard's containerized `_orch` sessions and pending-decision queue; Genesis's `git merge-tree`
  conflict prediction and worktree/branch reclaim; Conductor's per-issue workspace rule; Svärm's
  auto-retry-on-review-feedback; Maestro's per-run isolated workspaces; Pixir's checkpoint-status
  vocabulary) — none of it lands where a generated app inherits anything. Plus a handful of
  one-app-only features (Hive's Slack/GitHub/Grafana ingestion and business-domain taxonomy; OSA's
  workspace-trust for repo-local config; Vibe's CLI fuzzy-matching affordances) and two CDC-transport
  items samen deliberately delegated (Sequin's Broadway sink pipeline and logical-replication slot
  ownership).
- **Bar 2 — fails the MIT-clean bar (1 concept).** C-013-1 (Frontman) — the server's non-OSI
  `AI-SUPPLEMENTARY-TERMS.md` arguably forbids AI-mediated pattern extraction for a competing
  agent-orchestration product; unclear/non-OSI license is treated as incompatible until verified.
- **Bar 3 — duplicates occupied ground (94 concepts).** The largest bucket. Concentrated around
  already-filed T169–T179 (tier routing, cost attribution, budget tri-state, failover-deferred,
  concurrency caps duplicated ~15 times across AlexClaw/Glorbo/OSA/Pepe/CYFR/Genesis/Agens/Svärm),
  T178's decision-graph memory (Ankole's memory/RRF/citation concepts, Loomkin's routing/confidence
  cascade, Nous's RRF+decay), T176's skills-as-data and v2 self-scheduling note (Ankole, Long, Vibe,
  Codrift, Neoharness, ZAQ), T168's typed streaming envelope (Alloy, Pixir, BeamWeaver, Genesis,
  LangChain, Legion, Synapse, Nous, Sagents, LLMAgent, Cantrip, Avalon — ~13 hits), T175's
  definition-hash/reconciliation (ControlKeel, CYFR), and the built E1/E2/E3/E6/E7 automation and
  approvals engines (Jido, Agens, AgentForge, Avalon, Nous). Full per-concept citations at the T32
  path above.
- **Bar 4 — permanently discarded shape (10 concepts).** Reversible PII redaction (Pepe C-006-5);
  approval TTLs beyond "once"/auto-approve (Pepe C-006-7); full-fidelity context-offload keepers and
  their access/retrieval claims (Loomkin C-021-4/5/6/7); autonomous write→test→diagnose→fix cycles
  against "AI writes do not exist" (Loomkin C-021-11); continuous poll→claim→dispatch→reconcile
  unattended burn-down (Symphony C-026-1, named by the directive); `full_auto` mode auto-approval
  (Agent Harness C-027-1); tracker-polling claim-and-retry (Conductor C-029-1).

**Arithmetic (source: `/Users/clank/Desktop/projects/_orch/nodes/T32/work/next-tier.md`, lines
321–331).** HELD: 76 (3 T23 narrowed remainders + 72 T22 `premature` + 1 held workstream-1
candidate, #20). DEAD, NOT HELD: 138 (0 T23 `dead` + 138 T22 bar-rejected). 72 + 138 = 210 matches
T22's declared `REJECTED` total exactly; the 31 `SURVIVES` concepts are accounted for separately —
28 promoted unmodified via `T31`§6.3, 3 (S7/S8/S10) represented only by their T23-narrowed
remainders in Band 1 above, never under their original `SURVIVES` label.
