# ADR-037 — Ash-ecosystem adoption evaluation (operator directive M6)

- **Status:** Accepted (evaluation ADR; verdicts bind downstream ADRs T01/T11/T17/T32/T33/T55/T63/T81/T96).
- **Date:** 2026-07-21 (evaluation date; all package facts verified against hex.pm / hexdocs / GitHub on this date).
- **Task:** T98 — the operator's M6 ruling: a DEEP Ash-ecosystem evaluation BEFORE samen hand-builds
  what the ecosystem already ships. One ADOPT/REJECT verdict per package, each scored against the
  four mandatory criteria, each naming affected task ids (from `_orch/plan/backlog.yaml`) and the
  handoff revisions the verdict implies.
- **Deciders:** fable (T98 orchestrator), grounded in four commissioned research reports
  (`_orch/tasks/T98/work/research/group-{auth-admin,money-data,lifecycle-ai,workflow}.md` — current
  hex/hexdocs/GitHub data, not training priors), the live vault/verifier internals
  (`samen_core/lib/samen/type/vault_field.ex`, `samen_core/lib/samen/transformers/*`,
  `samen_core/lib/mix/tasks/samen.verify.*`), `spec/full-saas-readiness.md`, and the M1–M11 rulings.
- **Pinned stack:** `ash == 3.29.3`, `ash_postgres == 2.10.0`, `oban == 2.23.0` (plain Oban, no
  Pro), Phoenix LiveView, Postgres-only. Every constraint cited below was checked against these pins.

---

## 1 · Context

Samen's kernel was built hand-first: the PII vault (per-subject encryption, `vt_*` tokens,
`%Masked{}` reads, single `reveal/3` chokepoint, crypto-shred), the two-plane discipline, the
catalog, and a 17-task verifier suite that proves it all at every gate. The full-SaaS-readiness spec
now demands an identity spine (WS-A), rich types (WS-H), automation/lifecycle substrate (WS-E), an
AI plane (WS-D), and more — all territory where the Ash ecosystem ships first-party extensions. The
operator's M6 ruling (OVERRIDE + NEW DIRECTIVE) requires this evaluation to run FIRST, so the plan
neither hand-builds what a healthy package already provides, nor adopts a package that silently
weakens a masking claim.

Verdicts here are binding inputs: T01 (ADR-035, identity spine) consumes §5.1; T11 (ADR-036, rich
types + Money migration) consumes §5.2 and §5.11; T32/T33 (automation + lifecycle ADRs) consume
§5.3–§5.5 and §5.7–§5.9; T63 (AI-plane ADR) consumes §5.6; T55 consumes §5.10; T17 consumes §5.12;
T81/T96 inherit the cross-cutting constraints of §3.

## 2 · Evaluation criteria (per package, all four mandatory)

1. **C1 — Fit against INV-1 / the vault architecture.** No adoption may render or transmit
   plaintext PII without a reveal grant, on any plane, in any store the package introduces.
   > NOTE (operator): AshCloak is field encryption and is NOT a substitute for the vault/reveal-grant/two-plane architecture — any adoption must preserve samen's masking claims and the full verifier suite.
   Concretely: field-level encryption (AshCloak, `cloak_vault` options in other packages) is
   whole-app-keyed, not subject-keyed; it has no reveal-grant plane semantics, no per-subject
   crypto-shred, and no `%Masked{}` read face. Wherever a package offers "encryption" as its
   privacy answer, that answer is insufficient by operator ruling.
2. **C2 — INV-3 verifier compatibility.** Does the package's codegen/DSL keep `no_plaintext_pii`,
   `pii_reads`, `catalog_parity`, `tnt_boundary`, `prefixes`, `vault_declared_parity` et al.
   provable? (Mechanics in §3.)
3. **C3 — Maintenance / maturity.** Release cadence, Ash 3.x alignment against the exact pins,
   issue hygiene, bus factor.
4. **C4 — Migration cost vs hand-build cost**, in files touched and tasks reshaped.

Every verdict section below ends with explicit `INV-1:` and `INV-3:` statements (done-criterion 3).
No verdict in this ADR weakens a masking claim or removes a verifier tier; adoptions ADD
verifier/sabotage coverage per house rules.

## 3 · Cross-cutting integration constraints (what ANY adoption must clear)

These are the samen-specific mechanics that make "just add the dep" wrong. They apply to every
ADOPT below and are the standing checklist for future package evaluations.

1. **`catalog_parity` check 3 — no ghost resources.** Every `Ash.Resource.Info`-visible resource
   with an AshPostgres data layer must appear in `tam_table`. A package that ships or generates its
   own resources (auth Token, paper-trail Version resources, double-entry Account/Transfer/Balance)
   makes the gate fail until those resources are catalogued — which requires an abbrev allocation
   through the sanctioned allocator (`mix samen.abbrev.reserve`; registry is HANDS-OFF per ADR-023).
2. **`prefixes` verifier — every column on a Samen-managed table carries the resource abbrev.**
   Extension-injected attributes (`archived_at`, `state`, `hashed_password`) become physical columns.
   They must pass through `Samen.Transformers.AbbrevStorage`, which means **Spark transformer
   ordering is a first-class integration concern**: samen's transformer must be declared to run
   AFTER the adopted extension's attribute-adding transformers (the same `before?/after?` mechanism
   `MaterializePii` already uses against `AbbrevStorage`). An extension whose transformer runs after
   `AbbrevStorage` slips an unprefixed column past the transformer and is caught by the verifier —
   fail-closed, but the integration task must fix ordering, not allow-list the column.
3. **`pii_reads` scans `lib/` source.** Igniter-generated code lands in the host app's `lib/` and IS
   scanned (good). Dep code in `deps/` is NOT — so masking proofs for surfaces a dep renders must
   come from `Samen.MaskingCase` 3-proof tests (green/red/sabotage-twin), per the house watch-list
   discipline. Every ADOPT that touches a PII-bearing surface owes those tests in its implementing
   task.
4. **`no_plaintext_pii` CI mode asserts token-only over every projected tier.** Any new table that
   stores attribute values (version rows, event rows, job args) joins the projection roster. The
   structural ally: `Samen.Type.VaultField.dump_to_native/2` fails closed on plaintext, and
   `dump_to_embedded` (which serializers like AshPaperTrail call) defaults to `dump_to_native` —
   vault values leave the type layer as tokens or not at all.
5. **Fail-honest + INV-4 placement.** `samen_core` gains zero vendor deps; provider-client bundles
   (anything embedding OpenAI/Anthropic/Stripe API clients) live in first-party-but-separate
   packages behind core behaviours. Protocol libraries (assent, hammer) and data libraries
   (ex_money) are not vendor SDKs.
6. **Suites:** `--warnings-as-errors` (generated code must be warning-free), sabotage patches for
   every new gate claim, `./ci.sh` green at phase boundaries including the gen-app flagship probe —
   which means every ADOPT must also be wired into `mix samen.gen.app` output where the capability
   is substrate-level (INV-5).

## 4 · Verdict summary

| § | Package | Version (date) | Verdict | Primary consumers |
|---|---------|----------------|---------|-------------------|
| 5.1 | ash_authentication (+ _phoenix) | 4.14.1 (2026-06-15) / 2.17.2 | **REJECT** | T01–T10 |
| 5.2 | ash_money (+ ex_money 6) | 0.2.6 (2026-06-08) | **ADOPT** | T11, T12, T15 |
| 5.3 | ash_archival | 2.0.3 (2025-11-05) | **ADOPT** | T33, T36, T37 |
| 5.4 | ash_paper_trail | 0.6.0 (2026-06-08) | **ADOPT** | T33, T38 |
| 5.5 | ash_events | 0.7.0 (2026-03-29) | **REJECT** | T33, T38 |
| 5.6 | ash_ai | 0.7.3 (2026-07-21) | **REJECT** | T63–T72 |
| 5.7 | reactor | 1.0.2 (already transitive) | **ADOPT** | T32, T39, T40 |
| 5.8 | ash_state_machine | 0.2.13 | **ADOPT** (targeted) | T32, T33, T34, T39, T42 |
| 5.9 | ash_oban | 0.8.10 | **ADOPT** | T32, T39, T41, T42 |
| 5.10 | ash_geo | 0.3.0 (2024-07-31) | **REJECT** | T55, T47 |
| 5.11 | ash_csv | 0.9.8 | **REJECT** | T11, T15 |
| 5.12 | ash_double_entry | 1.0.18 (2026-07-13) | **REJECT** | T17, T21, T25 |
| 5.13 | ash_admin | 1.2.0 (2026-07-20) | **REJECT** | (operator plane stays first-party) |
| 5.14 | ash_rate_limiter | 1.0.0 (2026-02-11) | **ADOPT** (narrow) | T01, T19 |
| 5.15 | usage_rules | 1.2.6 (2026-04-13) | **ADOPT** (dev-only) | T16 (micro) |

---

## 5 · Per-package verdicts

### 5.1 ash_authentication 4.14.1 + ash_authentication_phoenix 2.17.2 — **REJECT**

Facts: team-alembic/ash-project; very active (5 open issues); stable 4.14.1 requires `ash ~> 3.7`
(fits). 4.x strategies: password, magic link, OAuth2/OIDC (via assent), API key. **TOTP/WebAuthn/
recovery codes/brute-force protection are 5.0-only, and 5.0 is still at rc.12 (2026-07-08) with
breaking changes in flight** (request actions become `:action`, iss/sub identity rework). The User
resource contract: `email :ci_string` (Postgres citext) with an identity, `hashed_password`;
built-in sign-in preparation filters on `identity_field` **equality — email must be a queryable
plaintext (citext) column**. Custom sign-in actions are permitted, so a blind-index lookup is
possible, but it is hand-rolled, not a config switch, and the add-ons (confirmation, password
reset, magic link, senders) all assume a readable `user.email`. Igniter generates
User/Token/AuthController/LiveUserAuth/routes into the host app.

- **C1 (INV-1/vault fit): FAIL.** Samen's `Identity.User` carries
  `pii_attribute(:emails, Samen.Type.Emails, vault: :pii_email)` — the email column holds a `vt_*`
  token, per-subject encrypted, crypto-shreddable, masked on the operator plane (traceability A1
  asserts exactly this). ash_authentication's identity model requires the inverse: plaintext citext
  email at rest, queryable by equality. Adopting it as designed reintroduces the exact column class
  the vault exists to eliminate; a shredded subject's login email would survive crypto-shred.
  Making it vault-compatible means replacing the sign-in preparation with a blind-index lookup AND
  replacing the identity-lookup preparation of every credential flow plus supplying custom senders —
  at which point samen is maintaining a fork of the package's core assumptions, not using the
  package.
- **C2 (INV-3): costly.** Token resource + citext extension + generated-into-`lib/` code all need
  catalog rows, abbrev allocations, and prefix-safe columns (§3.1–3.3); `hashed_password` and token
  `extra_data` join the `no_plaintext_pii` projection roster. All feasible, all labor — on top of C1.
- **C3 (maturity): excellent** — but the one capability WS-A needs that samen would least want to
  hand-build later (A7 TOTP) sits only in a release candidate; adopting 4.x now schedules a breaking
  5.0 migration mid-run.
- **C4 (migration vs hand-build):** Adoption reshapes T02–T10 around package integration plus a
  strategy fork; hand-build rides existing seams that already exist and are tested: the
  `Samen.Web.Auth` session seam (ADR-031), `Identity.User`/`Membership`/`ApiKey` resources, the
  vault write path, the delivery chokepoint for token emails (C2/C3), and the notification/audit
  spine for A10. The fork-everything adoption cost is at least comparable to hand-build cost, with
  an external breaking release on the critical path.

**Verdict: REJECT.** **This disposes of the WS-A hand-build question (T01/ADR-035 consumes this):
the identity spine is hand-built in `samen_web`/`samen_core` on the existing seams**, with a
blind-index (HMAC, non-reversible, org-independent-keyed) email-lookup column designed in ADR-035
so sign-in/reset/invite lookups never need plaintext email at rest. Two library notes for ADR-035
(libraries, not framework adoption; both are what ash_authentication itself uses or the ecosystem
standard): **assent** for A6 OIDC (T06) and **nimble_totp** for A7 (T07); password hashing choice
(bcrypt/argon2) is ADR-035's to make against the existing PBKDF2 reference.
- Affected tasks: T01 (binding branch), T02–T10 (shape unchanged — hand-build as planned).
- Required handoff revisions: none structural. T01 cites this section; T06/T07 gain the library
  notes via ADR-035, not via handoff edits.
- **INV-1:** preserved — email stays vaulted; no plaintext identity column is introduced.
- **INV-3:** preserved — no third-party resources enter the catalog; the spine extends the existing
  verifier surface (new tables catalogued through `mix samen.gen`/allocator as normal).

### 5.2 ash_money 0.2.6 (+ ex_money ~> 6.0, ex_money_sql ~> 2.0) — **ADOPT**

Facts: ash-project, 0 open issues, `ash ~> 3.0 and >= 3.0.15`, `ash_postgres ~> 2.0` (fits the
pins). Stores money as the Postgres composite `money_with_currency(char(3), numeric)` via
ex_money_sql; migrations via `AshMoney.AshPostgresExtension` in `installed_extensions` (also adds
`+`, `sum/min/max/avg` operator support in SQL); atomics and expr/aggregate support work; the
casting-bug backlog is closed. **Key 2026 fork: 0.2.6 requires ex_money 6 (2026-05), which dropped
the entire Cldr-backend requirement** — no `MyApp.Cldr` module, no locale-data compile step. ex_money
itself (kipcole9) is best-in-class and years-mature.

- **C1 (INV-1/vault fit): neutral-positive.** Money is not PII; no vault interaction. No masking
  claim is touched.
- **C2 (INV-3): provable.** The composite column is one physical column → one `fld_field` row
  (`catalog_parity` clean); samen names the attribute, so `prefixes` holds; `migrations` verifier
  must accept the extension's composite-type DDL — a verifier-fixture addition, not a weakening.
  Catalog dump / CSV round-trip / API contract learn one new type (T11's contract work either way).
- **C3 (maturity): good.** 0.2.x version number, but ash-project-maintained, quiet issue tracker,
  and the risky substrate (ex_money) is post-6.0 mature. The ex_money-6 cutover already happened —
  samen adopts on the far side of it.
- **C4 (migration vs hand-build): adoption clearly cheaper.** Hand-building `Samen.Type.Money`
  means reimplementing currency arithmetic, rounding, allocation, and SQL aggregation that
  ex_money/ash_money already prove. Files touched by adoption ≈ the same set H1 touches anyway
  (type module, two resource migrations, catalog/CSV/forms).

**Verdict: ADOPT.** `Samen.Type.Money` is defined in ADR-036 (T11) as a thin samen-owned wrapper
over `AshMoney.Types.Money` (samen name in the catalog/type-menu, package semantics underneath).
**This settles the H1 Money-migration strategy (M6; T11/ADR-036 consumes): pre-1.0 destructive
break, per the operator's confirmed default — one single data-copy migration per resource (CRM
`Opportunity.value_cents`+currency pair → one `money_with_currency` composite; Billing
`Price.unit_amount_cents` likewise), old paired columns dropped in the SAME migration, CHANGELOG
entry mandatory, no deprecation window.** AshMoney adoption implies exactly this shape: the
composite column replaces the pair; keeping both readable for a deprecation release would mean
double-writing a composite and a pair for zero consumers of the public repo's pre-1.0 schema.
- Affected tasks: T11 (ADR-036 designs on AshMoney), T12 (executes the migration above), T15
  (custom-field `money` type + gen.resource menu use the same type). T22/T26 read money fields
  post-T12 and absorb via T11's contracts.
- Required handoff revisions: none — T11's handoff already branches on this verdict; T12/T15
  inherit through ADR-036.
- **INV-1:** preserved — non-PII type; masking untouched.
- **INV-3:** preserved and extended — catalog/CSV/migrations verifiers gain money-type fixtures;
  gen-app probe gains the extension in `installed_extensions`.

### 5.3 ash_archival 2.0.3 — **ADOPT**

Facts: ash-project, 0 open issues/PRs, feature-complete-and-quiet (last release 2025-11-05, last
push 2026-07-01), sole dep `ash ~> 3.0 and >= 3.0.5`. Adds a private `archived_at`
(`utc_datetime_usec`, name/type configurable), filters every read for `is_nil(archived_at)` via a
preparation (or delegates to your `base_filter` with `base_filter? true`), turns destroys into
`soft?` updates, cascades via `archive_related` (silently — no notifications). Unarchive is the
documented excluded-read + `set_attribute(nil)` + `atomic_upgrade_with` pattern — **impossible on a
`base_filter` resource without a second resource on the same storage**. Upsert/identity semantics
via `identity ... where: expr(is_nil(archived_at))` + `identity_wheres_to_sql`. Known gotcha: the
preparation variant can leak archived rows through relationship loads/aggregates that bypass read
preparations; the airtight variant is `base_filter` — which then blocks unarchive.

- **C1 (INV-1/vault fit): clean.** `archived_at` is a non-PII timestamp; archived records keep
  their tokens vaulted; hard-delete + crypto-shred remain the terminal path exactly as E6 requires
  (`exclude_destroy_actions` keeps the real destroy for the retention/erasure path).
- **C2 (INV-3): provable with two integration duties.** (a) Transformer ordering so `archived_at`
  becomes an abbrev-prefixed column (§3.2); (b) partial-index SQL via `identity_wheres_to_sql` so
  `migrations`/`catalog_parity` stay coherent. The relationship/aggregate leak surface gets red
  tests (an archived record must NOT appear via relationship traversal) — new coverage, no tier
  removed. Retention sweep (existing) learns `archived_at` per E6.
- **C3 (maturity): high** — small, done, stable; the exact profile you want for substrate adoption.
- **C4 (migration vs hand-build): adoption cheaper and less subtle.** Hand-rolling default-filter
  injection across every blueprint reimplements this package's transformer, including the soft-destroy
  action rewrite — the leak-prone part. Files touched: blueprint macro + per-scope adoption sweep
  (T37) — the same sweep either way.

**Verdict: ADOPT.** E6 (soft delete/archive/restore) is implemented ON ash_archival. T33 (ADR)
fixes the mode: default is the **preparation variant + explicit unarchive actions + partial
identities** (restore is a hard E6 requirement, which rules out `base_filter` as the default);
resources with aggregate-sensitive archived semantics may opt into the documented base_filter+
companion-resource pattern per T33's judgment. Cascade (`archive_related`) usage must pair with
samen notifications where user-visible (package sends none).
- Affected tasks: T33 (design), T36 (core wiring via the extension, not hand-rolled), T37
  (substrate sweep + `identity_wheres_to_sql` + aggregate/relationship red tests + retention
  integration). T43–T48 adopt it via blueprint defaults; T96/T97 migration honors archived state.
- Required handoff revisions: none — T33/T36/T37 handoffs describe outcomes, not mechanisms; the
  ADR chain absorbs the how.
- **INV-1:** preserved — no plaintext surface introduced; crypto-shred/hard-delete path explicitly
  retained via excluded destroy actions.
- **INV-3:** preserved and extended — prefixes/catalog duties in-task; new red tests for the
  documented leak surface; sabotage patch flips the default-filter test.

### 5.4 ash_paper_trail 0.6.0 — **ADOPT**

Facts: ash-project, active (~15 open issues, monthly-to-quarterly cadence), `ash >= 3.5.43` (fits).
One auto-generated Version resource per tracked resource (added to the domain via
`AshPaperTrail.Domain`); `changes` is a jsonb map; `change_tracking_mode` `:snapshot` (default) /
`:changes_only` / `:full_diff` (**not atomic-safe** — returns `{:not_atomic, ...}`); versions are
created in after_action/after_batch hooks; `belongs_to_actor` (repeatable) attributes the actor;
multitenancy is inherited from the source resource. **Verified in source: the stored value per
attribute is `Ash.Type.dump_to_embedded(type, result_value)`, which defaults to
`dump_to_native/2`.** `sensitive_attributes` defaults to `:display`; `store_action_inputs?`
defaults to `false` (and auto-redacts sensitive inputs when on). `version_extensions` lets samen
apply its own extension to the generated Version resources; soft destroys (ash_archival) are the
package's own recommended answer to versioning deletes.

- **C1 (INV-1/vault fit): structurally sound — and this is the decisive fact.** Samen's
  `VaultField` does not override `dump_to_embedded`, so version rows receive
  `dump_to_native(value)`: a `vt_*` token for vault attributes, or **fail-closed `:error` if
  plaintext ever reached the type layer** — version rows hold tokens by construction, the same
  token-only-downstream invariant as every other tier. Guard duties: (a) `store_action_inputs?`
  stays `false` forever on samen resources — action INPUTS at create time are pre-vault plaintext,
  and while samen's `pii_attribute`s are `sensitive?: true` (auto-redacted), the posture is
  belt-and-braces off; (b) T38 adds an explicit red test asserting a version row of a vault
  attribute contains the token, never plaintext, plus the sabotage twin; (c) `sensitive_attributes`
  set to `:ignore` for any non-vault sensitive attribute a resource declares.
- **C2 (INV-3): provable with the §3 duties.** Version resources are real AshPostgres resources →
  abbrev allocation + `tam_table`/`fld_field` registration, satisfied by passing samen's extension
  through `version_extensions` so `AbbrevStorage` + catalog machinery run on them; the jsonb
  `changes` column rides the existing freeform-projection audit machinery
  (`mix samen.audit.freeform_projection`). `no_plaintext_pii` projection roster gains the version
  tables. `:full_diff` requires `require_atomic? false` — T33 chooses `:changes_only` (diff keys +
  new values, atomic-safe) as the default mode and documents the trade against `:full_diff`.
- **C3 (maturity): adequate.** 0.6.x but ash-project, steady cadence, wide use (~239k downloads);
  composite-PK support landed 0.6.0.
- **C4 (migration vs hand-build): adoption cheaper.** E7 hand-build means designing a per-resource
  version schema, after-action capture (incl. bulk paths), actor attribution, and tenancy
  inheritance — all of which the package already does, with the vault interplay proven safe above.
  The governance hash-chain stays untouched and PII/governance-scoped (E7 is explicitly distinct);
  CMS ContentVersion becomes a client per spec.

**Verdict: ADOPT** for E7 audit-on-write, as a substrate opt-in per blueprint.
- Affected tasks: T33 (design: mode choice, opt-in surface, version-resource governance), T38
  (implementation + ContentVersion client + the token-only red/sabotage tests).
- Required handoff revisions: none — absorbed by T33/T38 as written.
- **INV-1:** preserved — version tiers are token-only by the type's dump face; inputs storage off;
  proofs and sabotage twin required in T38.
- **INV-3:** preserved and extended — version resources fully catalogued/prefixed via
  `version_extensions`; `no_plaintext_pii` roster grows; no tier removed.

### 5.5 ash_events 0.7.0 — **REJECT**

Facts: ash-project but effectively one-main-author, youngest and smallest of the group (~43k
downloads, 14 months old); `ash ~> 3.5` + hard deps `ash_postgres ~> 2.0` AND `bcrypt_elixir ~> 3.0`
(the latter verified unused under `lib/` in the hex tarball — a packaging smell that still forces a
NIF into the tree). Centralized event log; action-wrapper transformer replaces create/update/destroy
implementations; Postgres advisory-lock serialization; per event it persists **`data` = the original
action input params** plus auto-captured `changed_attributes` — **plaintext jsonb by default, with
opt-in whole-log encryption via `cloak_vault`**. Replay wipes state (`clear_records_for_replay`) and
re-runs events with all lifecycle hooks skipped.

- **C1 (INV-1/vault fit): FAIL, twice.** (a) Action inputs at create/update time are pre-vault
  plaintext PII; the event log stores them verbatim, with no per-attribute redaction facility. (b)
  The package's only mitigation is `cloak_vault` — precisely the field-encryption-is-not-a-vault
  pattern the operator note in §2 rules out: app-keyed, no reveal-grant planes, and a shredded
  subject's plaintext inputs remain decryptable in the event log, breaking the crypto-shred/DSAR
  claim (`no_plaintext_pii --subject --tiers all` would fail honestly).
- **C2 (INV-3): conflicting.** Replay's wipe-and-rebuild contradicts the governance hash-chain's
  append-only tamper-evidence and the CDC stream's semantics; action-wrapper replacement of every
  write action sits ON the same chokepoints `Samen.Pii.WriteGuard`/`Vault.Change` govern — a
  second framework claiming the write path.
- **C3 (maturity): lowest of the roster** — pre-1.0, single primary author, dep hygiene smell.
- **C4:** No spec requirement asks for event sourcing/replay. E7's need (actor, diff, timestamp) is
  met by ash_paper_trail (§5.4); system-event audit is already the `aud` tier; row-level change
  capture is already CDC.

**Verdict: REJECT.** Samen's audit story remains: governance hash-chain (tamper-evidence) + CDC
(row deltas) + AshPaperTrail (per-resource business audit, §5.4).
- Affected tasks: T33/T38 proceed without it; no reshape.
- Required handoff revisions: none.
- **INV-1:** preserved by rejection — a plaintext-inputs event store never enters the substrate.
- **INV-3:** preserved — no write-path wrapper contends with the governed chokepoints; hash-chain
  and CDC verifier claims stand.

### 5.6 ash_ai 0.7.3 — **REJECT** (for the WS-D kernel; mined for patterns)

Facts: ash-project's most active repo (0.7.3 released 2026-07-21 — evaluation day; 184 stars;
monthly 0.x churn, breaking LangChain→ReqLLM cutover at 0.6.0). Required deps: **`req_llm ~> 1.7`
(a multi-provider LLM client — OpenAI/Anthropic/Google), `ash_json_api`, `open_api_spex`**. Ships:
tools DSL exposing Ash actions to LLMs (through real Ash authorization, public-attribute-limited —
but `load:` can pull **private** attributes into responses), prompt-backed actions (EEx prompts,
structured output), MCP dev + production servers (auth via ash_authentication api-key strategy or
OAuth2.1 add-on; sessions unshipped), pgvector vectorization (vector columns on the resource;
default `:after_action` strategy self-described "incredibly slow, not recommended for production";
`:ash_oban`/`:manual` for real use), experimental chat generator (Tailwind/DaisyUI assumptions).

- **C1 (INV-1/vault fit): mixed.** Genuinely good: tools execute through Ash authorization with an
  actor, and any vault field read through them returns `%Masked{}` structurally. But D2's contract
  is stronger than "policies apply": ONE prompt chokepoint, catalog-grounded, plane-resolved, with a
  verifier tier proving no `pii_*` plaintext can enter a prompt without a grant. ash_ai has no
  chokepoint concept — prompt-backed actions take arbitrary EEx; `load:` reaches private
  attributes; nothing forces prompt assembly through a maskable path. The chokepoint and the
  `ai_prompt_masking` verifier must be samen-owned either way.
- **C2 (INV-3): FAIL on placement.** `req_llm` is a bundle of vendor API clients; the tools DSL
  lives on core domains/resources, so adoption puts provider-client code INTO `samen_core` —
  against INV-4 and the operator's "no vendor SDKs in core", and it drags `ash_json_api` +
  `open_api_spex` into the kernel as hard deps. The D1 contract (core behaviour + `samen_anthropic`
  as a separate package, core gate green with the adapter absent) is structurally incompatible with
  ash_ai's dependency shape.
- **C3 (maturity): active but churning** — 0.x with breaking mid-stream cutovers; its MCP auth
  story leans on ash_authentication (rejected §5.1).
- **C4:** Adoption still leaves D2 (chokepoint + verifier), D8 (eval/red-team CI tier), and the
  INV-4 provider split to build — the hard parts. What it would save (tool plumbing, MCP protocol
  handling, vectorization wiring) is real but implementable against its source as reference.

**Verdict: REJECT** for the D1/D2 kernel. Binding notes for T63 (ADR): (a) **mine `AshAi.Mcp`**
(protocol version 2025-03-26, router shape, api-key plug seam) as the reference for the T69 D4 MCP
server; (b) adopt its **pgvector shape** (vector columns on the resource, oban-strategy async
embedding, HNSW via `custom_statements`) for T67 — consistent with ash_oban ADOPT (§5.9); (c)
re-evaluate ash_ai post-1.0 as a candidate host for the tool-exposure layer once samen's chokepoint
exists.
- Affected tasks: T63–T72 proceed per plan; no reshape.
- Required handoff revisions: none — T63 is the consuming ADR and cites this section.
- **INV-1:** preserved — the masking chokepoint + `ai_prompt_masking` verifier are samen-built
  (T64/T65), not delegated to a package without chokepoint semantics.
- **INV-3:** preserved — core stays vendor-client-free; the new AI verifier tier is added, none
  removed.

### 5.7 reactor 1.0.2 — **ADOPT**

Facts: 1.0.0 landed 2026-01-25 (one breaking change), patches since; ash-project (Harton); 0 open
issues. **Already a transitive dependency of ash 3.29.3 (`~> 1.0`) — adoption adds zero new deps.**
Saga semantics (`run/3` + `compensate/4` + `undo/4`, retries/backoff, whole-reactor undo);
DAG-driven async with `max_concurrency`/`async?: false`; middleware with telemetry.
**`Reactor.Builder` verified in 1.0.2**: programmatic reactor construction from external data at
runtime is documented and endorsed — DB-stored tenant automation rules can compile to executable
reactors. `Ash.Reactor` ships inside ash itself (version-locked): create/update/destroy/read/
action/bulk/transaction steps, `undo_action` semantics.

- **C1 (INV-1): clean.** Execution machinery; steps act through governed Ash actions with the
  workflow's actor; no storage, no rendering surface. E1's non-PII-keyed condition rule (flag-engine
  precedent, ADR-020) is a samen-side constraint on rule *definitions*, unaffected by the executor.
- **C2 (INV-3): clean.** No resources, no columns, no codegen into `lib/`. Run-log/observability
  rows (E8) are samen resources regardless.
- **C3 (maturity): high** — post-1.0, active, and load-bearing inside ash itself.
- **C4:** Hand-building a compensating, concurrency-aware DAG executor for E1/E2 runs would be
  rebuilding a library the kernel already links. Zero-dep adoption is strictly cheaper.

**Verdict: ADOPT.** T32 (automation ADR) designs E1 rule execution as runtime-built reactors
(`Reactor.Builder`) whose steps are `Ash.Reactor`-style governed actions; E2's action library
defines compensation per action (notify/email/webhook are at-least-once with no-op undo; record
mutations use `undo_action` where reversal is meaningful). Trigger/condition evaluation stays the
pure flag-engine-precedent evaluator; Reactor is the execution layer.
- Affected tasks: T32 (design), T39 (rule→reactor compilation), T40 (per-action compensation).
- Required handoff revisions: none — absorbed by T32.
- **INV-1:** preserved — actions execute through governed chokepoints; no new PII surface.
- **INV-3:** preserved — no verifier surface changes; E8 observability adds coverage.

### 5.8 ash_state_machine 0.2.13 — **ADOPT** (targeted: new state-bearing resources only)

Facts: ash-project, 0 open issues, active pushes through 2026-06/07, `ash >= 3.4.66` (fits); 3
years on the 0.2.x line at ~5 releases/yr — stable-but-0.x. Auto `:state` atom attribute
(configurable), action-keyed transition table enforced via the `transition_state` change
(`NoMatchingTransition` on violation), `possible_next_states`, Mermaid chart mix task.

- **C1 (INV-1): clean.** States are non-PII atoms; no storage/rendering surface beyond one column.
- **C2 (INV-3): one duty.** The injected `state` attribute must come out abbrev-prefixed
  (transformer ordering, §3.2) and catalogued — same duty as ash_archival, same mechanism.
- **C3 (maturity): adequate** — long-stable API, maintained, small blast radius.
- **C4:** Hand-enforcing transition tables per resource is exactly the subtle-bug surface
  (unguarded status writes) this eliminates; the Mermaid charts feed docs for free. Cheap adoption,
  but a substrate-wide RETROFIT of existing status-bearing resources (Ticket, Subscription, dunning)
  would be a >10-file cross-cutting sweep with no spec line demanding it — explicitly out of scope.

**Verdict: ADOPT, targeted.** New state-bearing resources introduced by this plan use it: the E3
approvals engine (T34 — pending/approved/rejected with requester≠approver invariants riding
alongside), automation run lifecycle (T39/T42), invitation lifecycle if ADR-035 elects it (T05,
optional). Existing resources are NOT retrofitted this run; a post-1.0 ADR may schedule that sweep.
- Affected tasks: T32, T33 (ADR design of state models), T34, T39, T42; T05 optionally via ADR-035.
- Required handoff revisions: none — absorbed by T32/T33 ADRs.
- **INV-1:** preserved — non-PII state column only.
- **INV-3:** preserved — prefix/catalog duties in-task; transition red tests (illegal transition
  refused + legal transition positive control) are new coverage.

### 5.9 ash_oban 0.8.10 — **ADOPT**

Facts: ash-project, 0 open issues, hot cadence (0.4→0.8 in 12 months), `ash >= 3.8.0` +
`oban ~> 2.20` (fits). **No Oban Pro dependency — triggers AND scheduled actions fully work on
plain Oban** (only chunk/batch processing is Pro-gated). Triggers: periodic scan for records
matching a predicate → enqueue per-record work; scheduled actions for cron-shaped generic actions.
Integration duties verified: default queue `{short_name}_{trigger_name}` must be added to Oban
config (wrapped via `AshOban.config/2`); a trigger schedules every minute unless `scheduler_cron`
is set (or `false`); default `max_attempts 1`; actor persisted via an `AshOban.ActorPersister`
behaviour you implement (serialized as plaintext JSON into job args); multitenancy via
`list_tenants` or `use_tenant_from_record?`.

- **C1 (INV-1): clean with one stated rule.** Job args are a persisted plaintext tier →
  **the samen `ActorPersister` serializes ID-only, non-PII actor references** (org id, user id,
  plane — samen actors are already bounded ids by construction), never actor structs. A red test
  asserts no vault token and no plaintext PII in `oban_jobs.args` for ash_oban-enqueued work; the
  existing sink-schema discipline extends to job args.
- **C2 (INV-3): clean.** No resources/columns of its own (`oban_jobs` is existing infra); DSL-level
  triggers on samen resources; predicates are ordinary Ash filters over governed attributes.
- **C3 (maturity): good** — active, plain-Oban-complete, ash-project.
- **C4:** Samen already runs 17 hand-rolled Oban workers; the scan-and-enqueue pattern E1 schedule
  triggers, E4 reminders, and E5 escalation deadlines all need is exactly what triggers provide.
  Hand-building a per-rule scheduler + per-record enqueue sweep duplicates the package.

**Verdict: ADOPT** for WS-E automation scheduling: E1 schedule triggers, E4 reminder due-scans, E5
escalation deadline-scans, E8 run health. Config discipline per §3.6: every trigger declares
`scheduler_cron` explicitly (no accidental every-minute defaults), queues registered through
`AshOban.config/2`, `max_attempts` set per job class. Existing hand workers are not migrated this
run.
- Affected tasks: T32 (design), T39, T41, T42.
- Required handoff revisions: none — absorbed by T32.
- **INV-1:** preserved — ID-only actor persistence rule + job-args red test added.
- **INV-3:** preserved — sink-schema coverage extends to job args; no tier removed.

### 5.10 ash_geo 0.3.0 — **REJECT**

Facts: community package (single maintainer, bcksl), last release 2024-07-31, last commit
2024-11-25, ~7 open issues/PRs — **effectively dormant**; pins `geo ~> 3.5` while the maintained
ecosystem path is geo 4.1.0 + geo_postgis 3.7.1 (felt org); provides Geo types + `st_*` expression
wrappers + Topo validations. ash_postgres has no built-in PostGIS types.

- **C1 (INV-1):** n/a-to-clean (geometry is not PII; address PII is H4's vault class, untouched).
- **C2 (INV-3): poor.** PostGIS becomes an `installed_extensions` requirement for every generated
  app + CI + gen-app probes — infra surface for a capability the operator ruled OPTIONAL (M4:
  Natural Earth SVG + bring-your-tiles seam; spatial queries not required for the map view).
- **C3 (maturity): FAIL** — dormant, stale dependency pin, bus factor 1.
- **C4:** Zero spec requirement demands spatial queries. Cost of adoption (PostGIS everywhere,
  dormant dep) buys nothing T55 needs.

**Verdict: REJECT.** T55 proceeds per M4 (server-side SVG, deterministic pin projection, tiles
seam). The documented extension seam for verticals that DO need spatial: geo 4.x + geo_postgis +
`installed_extensions ["postgis"]` + a small custom `Ash.Type` (`storage_type :geometry`) with
`fragment`-based `ST_*` queries — recorded here as the recipe, deliberately not built.
- Affected tasks: T55, T47 — both proceed unchanged (T47's Location uses the H4 Address composite,
  no geometry column).
- Required handoff revisions: none — T55's handoff already cites this verdict slot (G7
  traceability).
- **INV-1:** preserved — untouched.
- **INV-3:** preserved — no new required extension enters CI or the gen-app probe.

### 5.11 ash_csv 0.9.8 — **REJECT**

Facts (verified): ash_csv is a **CSV-file-backed Ash DATA LAYER** — resources whose storage IS a
CSV file — not an import/export helper. One release in ~23 months (NimbleCSV swap, 2026-04);
near-dormant.

- **C1 (INV-1): category error → FAIL if misused.** Samen's CSV layer (`Samen.Web.Csv`, ADR-028) is
  a first-class MASKING surface: every cell resolves through `Samen.Api.PiiResolution` on the
  actor's plane, keyset-bounded, mask-by-omission. A CSV data layer has nothing to do with that
  requirement and would bypass Postgres, the vault, and policies if ever used for real data.
- **C2 (INV-3): n/a** — a data layer swap has no verifier story because it has no place here at all.
- **C3 (maturity): poor** — one release in ~23 months, near-dormant.
- **C4:** zero spec requirement; the ADR-028 layer already exists and is gate-tested — nothing to
  save, everything to risk.

**Verdict: REJECT.** `Samen.Web.Csv` remains the only CSV import/export path; H7's type round-trip
work extends it (T11 contracts, T15 implementation).
- Affected tasks: T11, T15 — proceed on the existing layer.
- Required handoff revisions: none.
- **INV-1:** preserved — the masked CSV chokepoint stays sole.
- **INV-3:** preserved — no data-layer change.

### 5.12 ash_double_entry 1.0.18 — **REJECT** (no requirement; revisit trigger recorded)

Facts: ash-project, 0 open issues, active (2026-07-13), `ash >= 3.5.4`, hard-deps ash_money +
ex_money_sql (compatible with §5.2). Three extensions applied to your own Account/Transfer/Balance
resources; per-transfer balance rows with recalculation on backdating; `lock_accounts` FOR UPDATE;
multi-tenancy DIY (docs silent).

- **C1 (INV-1): clean** (amounts are non-PII).
- **C2 (INV-3): payable but real** — three new resources × abbrev/catalog/tenancy duties (§3.1–3.2),
  tenancy discipline hand-assured.
- **C3 (maturity): good** — 1.0.x, maintained.
- **C4: FAIL on requirement.** No WS-B line needs an internal double-entry ledger: Stripe is the
  authoritative money-mover (B2–B8 mirror it); MRR movement analytics are already served by the
  ADR-017 subscription-movement ledger; usage billing (B8) reports to Stripe rather than settling
  internally. Adopting would add unowned resources with no consumer.

**Verdict: REJECT** for this run. **Revisit trigger (recorded for T17's ADR):** if a
wallet/credits/prepaid-balance feature ever becomes a requirement, ash_double_entry + the §5.2
AshMoney adoption is the designated candidate — do not hand-build a ledger then.
- Affected tasks: T17, T21, T25 — proceed unchanged.
- Required handoff revisions: none.
- **INV-1:** preserved — untouched.
- **INV-3:** preserved — untouched.

### 5.13 ash_admin 1.2.0 — **REJECT**

Facts: ash-project, active (1.2.0 on 2026-07-20; dark-mode rework 2026-04), LiveView super-admin
requiring LiveView ~> 1.1-rc. Docs verbatim: *"There is no builtin security for your AshAdmin
(except your app's normal policies)"* — it runs read actions and renders returned field values
directly; route protection and actor derivation are the host's problem.

- **C1 (INV-1): FAIL as an operator plane.** Samen's operator plane is two-plane
  masked-by-construction: operator surfaces are token-blind or masked with per-plane 3-proof tests
  (INV-2), reveal only through granted `Samen.Api.PiiResolution`. ash_admin has no plane concept;
  vault fields would render as `%Masked{}` structs by luck of the type, but non-vault sensitive
  data, arbitrary action invocation (including governed actions with a super-actor), and the
  absence of plane-differentiated rendering make it un-provable under the masking watch-list
  discipline. Its escape hatch is "your policies" — samen's bar is masked BY CONSTRUCTION plus
  refutable tests per surface.
- **C2 (INV-3):** every mounted surface would need MaskingCase 3-proofs samen cannot write against
  a generic renderer it doesn't control; LiveView ~> 1.1-rc is also ahead of the pinned stack.
- **C3:** healthy package — irrelevant given C1.
- **C4:** The operator plane (ADR-010) already exists, gated and tested; adopting a second admin
  surface adds risk and zero required capability.

**Verdict: REJECT.** The first-party operator plane remains the only operator surface.
- Affected tasks: none — no planned task mounts a generic admin.
- Required handoff revisions: none.
- **INV-1:** preserved — no unmasked-by-construction surface enters any plane.
- **INV-3:** preserved — INV-2 verifier claims (no_pii_columns, tnt_boundary, aggregate_privacy)
  keep their current surface area.

### 5.14 ash_rate_limiter 1.0.0 — **ADOPT** (narrow: auth + webhook ingress)

Facts: ash-project, post-1.0 (2026-02-11; an accidental 2.0.0 was published and retired — pin
`== 1.0.0`/`~> 1.0.0` explicitly), young (18 stars). Spark DSL for per-action rate limits
(`rate_limit` block; Change/Preparation hooks; custom key functions), Hammer ~> 7.0 backend
(pluggable; deterministic test backend included), `LimitExceeded` implements `Plug.Exception` → 429.

- **C1 (INV-1): clean with one stated rule.** Rate-limit KEYS are a telemetry-adjacent tier —
  **keys must be non-PII by construction** (org id, user id, IP, or the ADR-035 blind-index hash —
  never plaintext email). Stated as a design rule for ADR-035/T19; red test on key composition.
- **C2 (INV-3): clean.** No resources/columns; DSL hooks on actions; Hammer's ETS backend adds no
  storage tier (a Postgres backend, if ever chosen, would be registered infra like oban_jobs).
- **C3 (maturity): young but credible** — ash-project-maintained, post-1.0 with the 2.0.0 mishap
  retired, pluggable + testable. Blast radius is small (two chokepoints), which is what makes young
  acceptable here.
- **C4:** Hand-building sliding-window limiting (and its test determinism) for A1–A4 brute-force
  protection and B9 webhook ingress is solved-problem work; the package's action-level DSL matches
  where samen wants the limits (governed actions), and 4.x-auth's absence of built-in brute-force
  protection (§5.1) makes this the natural complement to the hand-built spine.

**Verdict: ADOPT, narrow scope:** auth-surface actions (sign-in, registration, token
request/verify — designed in ADR-035) and webhook ingress (T19). Not a substrate-wide default this
run.
- Affected tasks: T01 (ADR-035 designs auth throttling on it), T19 (webhook ingress limits).
- Required handoff revisions: none — T01/T17-chain ADRs absorb; T19's B9 criteria already demand
  replay/ingress protection, this names the mechanism.
- **INV-1:** preserved — non-PII key rule + red test; no PII enters limiter state.
- **INV-3:** preserved — deterministic test backend keeps CI hermetic; 429 paths get red/positive
  tests.

### 5.15 usage_rules 1.2.6 — **ADOPT** (dev-only tooling)

Facts: ash-project, 2026-04-13, `mix usage_rules.sync` aggregates dependency-shipped
`usage-rules.md` files into AGENTS.md/CLAUDE.md (+ docs search tasks); `only: [:dev]`, zero runtime
footprint, no ash dependency.

- **C1 (INV-1): n/a** — never compiled into any release, no runtime, no data.
- **C2 (INV-3): n/a** — no verifier surface. One duty: the synced block lands in the repo CLAUDE.md
  as a MARKED, tool-managed section that must not dilute the house conventions above it.
- **C3: fine** — maintained, trivial surface.
- **C4: near-zero cost, real benefit** — this repo is built by serialized agents; syncing
  ash/ash_postgres/oban (and each newly adopted package's) usage rules into the agent context is
  the "encode knowledge as infra" house pattern applied to dependency knowledge.

**Verdict: ADOPT**, dev-only, root-level: add `{:usage_rules, "~> 1.2", only: [:dev]}` and run
`mix usage_rules.sync` for ash, ash_postgres, oban, and every package this ADR adopts, as part of
the Phase-1 gate's docs sync.
- Affected tasks: T16 (phase-1 gate: one added step — the only handoff needing a (one-line)
  planner touch, see §7).
- Required handoff revisions: T16 gains "run usage_rules sync per ADR-037 §5.15" in its INV-6 docs
  sync step.
- **INV-1:** untouched — dev-only, no runtime, no data.
- **INV-3:** untouched — no verifier surface; the synced CLAUDE.md block is tool-managed and marked.

---

## 6 · Bound dispositions (cross-references)

- **WS-A hand-build question — DISPOSED in §5.1:** AshAuthentication REJECT; the identity spine is
  hand-built on existing seams with a blind-index email lookup; assent (OIDC) and nimble_totp (2FA)
  are ADR-035's designated protocol libraries. T01/ADR-035 consumes §5.1 as its binding branch.
- **H1 Money-migration strategy — SETTLED in §5.2:** AshMoney ADOPT; pre-1.0 destructive break; one
  data-copy migration per resource (Opportunity, Price), paired columns dropped in the same
  migration, CHANGELOG mandatory. T11/ADR-036 consumes §5.2.

## 7 · Consequences

1. **Adopted (8):** ash_money, ash_archival, ash_paper_trail, reactor, ash_state_machine,
   ash_oban, ash_rate_limiter (narrow), usage_rules (dev-only). **Rejected (7):**
   ash_authentication, ash_events, ash_ai, ash_geo, ash_csv, ash_double_entry, ash_admin.
2. No verdict weakens a masking claim or removes a verifier tier; every ADOPT adds coverage
   (transition red tests, version-token proofs, job-args sink checks, aggregate-leak red tests,
   limiter red tests) and owes sabotage twins per house rules.
3. **Task-graph impact: no restructuring required.** Every ADOPT/REJECT is absorbed by the
   downstream ADR task that was already scheduled to consume it (T01, T11, T17, T32, T33, T63).
   The single handoff-text touch is T16 (§5.15, one line). The feared T02–T10 reshape (an
   AshAuthentication ADOPT) does not occur.
4. Dependency additions land inside the owning implementation tasks (T12/T36/T38/T39/T41/T19 et
   al.), each with its §3 duties (abbrev/catalog/prefix ordering, projection-roster updates,
   MaskingCase proofs) as in-task done-criteria via their ADRs.
5. Re-evaluation triggers recorded: ash_authentication 5.0 final (TOTP/WebAuthn tier) — for a
   post-1.0 auth revisit, not this run; ash_ai post-1.0 once samen's chokepoint exists (§5.6);
   ash_double_entry if a credits/wallet requirement appears (§5.12).

## 8 · References

- Research reports (full package facts, URLs, version tables):
  `_orch/tasks/T98/work/research/group-auth-admin.md`, `group-money-data.md`,
  `group-lifecycle-ai.md`, `group-workflow.md`.
- Verdict/affected-task digest for the planner: `_orch/tasks/T98/work/summary.md`.
- Grounding internals: `samen_core/lib/samen/type/vault_field.ex` (three faces, fail-closed dump),
  `samen_core/lib/samen/transformers/{abbrev_storage,materialize_pii}.ex` (ordering precedent),
  `samen_core/lib/mix/tasks/samen.verify.{no_plaintext_pii,pii_reads,catalog_parity,prefixes}.ex`,
  `samen_web/lib/samen/web/csv.ex` (ADR-028 masking surface), ADR-010/017/020/029/031.
- Rulings: `_orch/plan/spec-questions.md` M4/M6; `spec/full-saas-readiness.md` INV-1..INV-6.
