# Pre-PR whole-product dogfood + remediation

- **Date:** 2026-08-11 (pre-PR, `saas-readiness-phase-1`)
- **Purpose:** a PR-reviewer-facing summary of the whole-product adversarial dogfood run before
  this branch's PR, and everything it caused to be fixed. The raw evidence (walker transcripts,
  triage, verifier verdicts) lives in the gitignored `_orch/` workspace and does not travel with
  the PR — this doc is the tracked record of what was found, what shipped to close it, and how
  each fix was independently proven, so a reviewer doesn't have to reconstruct that from commit
  messages alone.
- **Base commit:** `056334f` ("SaaS-Readiness Phase 6 COMPLETE" — GREEN) is where the dogfood
  started. §1–§5 below record the state through `f54adb6` (the 7 pre-PR remediation batches plus
  6 post-PR cleanup items H1–H5, incl. H2b). **The branch head as of this revision is `359abe7`**
  — §6 (2026-08-11) records the four pre-merge commits that followed and supersedes the stale
  head/CVE claims that §5 carried.
- **Sources:** `_orch/dogfood/pre-pr/triage.md` (the 17 canonical findings + dispositions) and
  the verifier verdicts under `_orch/verify/` (`pp1-authn-gate-verdict.json`,
  `pp5-pp6-tenant-role-verdict.json`, `pp7-nav-reach-verdict.json`,
  `pp15-16-14-ai-honesty-verdict.json`, `pp2-pawchart-spine-verdict.json`,
  `pp4-clinic-surface-verdict.json`, `pp11-12-13-reveal-verdict.json`, `pp17-hygiene-verdict.json`,
  `pp13-approver-verdict.json`, `t159-name-scope-verdict.json`, `t159-switcher-verdict.json`,
  `h3-gen-scope-authn-verdict.json`). Every commit SHA and verdict cited below was cross-checked
  against `git log` and the JSON files it names.

---

## 1 · What the dogfood was

Eight independent persona walkers (W1–W8) each drove the **whole integrated product** —
not a single feature in isolation — across every tier/role combination the platform ships:
tenant owner/admin/member/viewer, operator (with and without reveal grants), unauthenticated,
and cross-org. Walkers exercised driftwood (the freight vertical, the working positive control
with a full identity spine) and pawchart (the vet-clinic vertical, at the time an unauthenticated
framework-parity demo). Findings were consolidated into one authoritative list, with severities
**re-adjudicated independently against the cited code** (not copied from walker labels) and
duplicates merged keeping the strongest evidence (a live repro over a code trace).

**Operator ruling: fix everything in-phase**, down to LOW severity, each fix independently
adversarially verified, before the PR.

## 2 · The 17 canonical findings, by severity

**BLOCKER 3 · HIGH 6 · MED 4 · LOW 4.**

| Sev | ID | One-line | Root cluster | Disposition |
|---|---|---|---|---|
| BLOCKER | PP-1 | Pawchart's entire tenant plane served unmasked cross-tenant PII to a fully unauthenticated caller (`?org=<uuid>`), live-reproduced via plain `curl` | A — framework tenant-auth fail-open | **FIXED** (Batch 1) |
| BLOCKER | PP-5 | Any member/viewer could subscribe the org to a paid plan / open the Stripe billing portal — billing writes had no role concept | B — synthetic tenant-plane role | **FIXED** (Batch 2) |
| BLOCKER | PP-7 | A fresh driftwood tenant finishing onboarding had zero nav-reachable path into the product | C — nav reachability | **FIXED** (Batch 3) |
| HIGH | PP-2 | Pawchart mounted no identity spine at all (no login/signup/verify/onboarding/settings) | A + pawchart posture | **FIXED** (Batch 5a — operator chose "adopt") |
| HIGH | PP-3 | The tenant-auth gate is 100% host-opt-in and fails OPEN on a missing `:authn` label; nothing enforced adoption | A (root of PP-1) | **FIXED** (Batch 1) |
| HIGH | PP-6 | `Settings.ApiKeysLive` "Revoke" was silently broken for every role, incl. owners/admins — used a hardcoded synthetic `:member` scope | B | **FIXED** (Batch 2) |
| HIGH | PP-8 | Settings (Profile/API keys/Security/Invitations) was a total nav island | C | **FIXED** (Batch 3) |
| HIGH | PP-9 | Automation (workflow builder) was a total nav island | C | **FIXED** (Batch 3) |
| HIGH | PP-15 | Operator support-desk AI draft rendered simulated output with no honest "SIMULATED" badge | E — AI honesty labeling | **FIXED** (Batch 4) |
| MED | PP-4 | Pawchart's own vertical domain (Patient/Pet) had no tenant-facing surface, only a masked operator view | — pawchart posture | **FIXED** (Batch 5b — operator chose "build") |
| MED | PP-10 | The freight "Operations" nav group vanished the instant a driftwood tenant left `/broker` | C | **FIXED** (Batch 3) |
| MED | PP-11 | The reveal-grant seam had no tenant plane — unmask events landed on the `__global__` operator chain, invisible to the tenant's ledger | D — reveal-grant accountability | **FIXED** (Batch 6) |
| MED | PP-16 | Tenant Support-draft surface + persisted draft carried no simulated provenance | E | **FIXED** (Batch 4) |
| LOW | PP-12 | Driftwood `reveal`/`request_reveal` handlers were session-independent, reading any `driver_id` across any org with `authorize?: false` | D | **FIXED** (Batch 6) |
| LOW | PP-13 | The reveal request→approve→unmask lifecycle couldn't complete live — no host wired an approver UI | D | **DEFERRED to Phase-7** at Batch 6, then **FIXED** post-PR (H1) |
| LOW | PP-14 | Operator `AnalyticsLive` authorized a cross-tenant aggregate AI read with a hand-built role-less tag, not the authenticated actor | E (defense-in-depth) | **FIXED** (Batch 4) |
| LOW | PP-17 | Driftwood Settings/Security "sessions" + "2FA enrollment" weren't opted in (`spine_sessions`/`spine_totp` both false) | — product-intent/config posture | **FIXED** (Batch 7 — operator chose "adopt") |

**Verdict at the time of triage: NOT READY** — 3 genuine BLOCKERs, all closed pre-PR. The
masking/honesty/PII-egress core held under adversarial reproduction throughout (every AI
chokepoint, fleet-wire, ESP, Stripe, and per-plane masking invariant); the failures were
concentrated in two structural root causes (framework tenant-auth fail-open; synthetic
tenant-plane role) plus nav reachability and one AI-honesty labeling miss.

## 3 · Remediation batches

Each batch is opus-authored (security-sensitive) or sonnet-authored (nav/UX/config), and every
batch was **independently adversarially verified by a separate verifier session that did not
write the fix**, against its own `_orch/verify/*.json` and the full `./ci.sh` root gate + sabotage
harness, both green before and after.

| Batch | Findings closed | Commit | Sabotage # | Verdict file | Result |
|---|---|---|---|---|---|
| 1 — AUTHN-GATE | PP-1 (BLOCKER), PP-3 (HIGH) | `3d660fc` | 169 (+ 17-f2 re-drift) | `pp1-authn-gate-verdict.json` | PASS |
| 2 — TENANT-ROLE | PP-5 (BLOCKER), PP-6 (HIGH) | `35afc04` | 170, 171 | `pp5-pp6-tenant-role-verdict.json` | PASS |
| 3 — NAV-REACHABILITY | PP-7 (BLOCKER), PP-8 (HIGH), PP-9 (HIGH), PP-10 (MED) | `8d2c2ec` | 172, 173 | `pp7-nav-reach-verdict.json` | PASS |
| 4 — AI-HONESTY | PP-15 (HIGH), PP-16 (MED), PP-14 (LOW) | `0bebea5` | 174–178 | `pp15-16-14-ai-honesty-verdict.json` | PASS |
| 5a — PAWCHART-SPINE | PP-2 (HIGH) + a Batch-2 `:identity_namespace` residual | `8aebc51` | 179, 180 | `pp2-pawchart-spine-verdict.json` | PASS |
| 5b — PAWCHART-CLINIC | PP-4 (MED) | `bc500ce` | 181, 182 | `pp4-clinic-surface-verdict.json` | PASS |
| 6 — REVEAL-ACCOUNTABILITY | PP-11 (MED), PP-12 (LOW) | `dc94ce1` | 183, 184 | `pp11-12-13-reveal-verdict.json` | PASS |
| 6 — REVEAL-ACCOUNTABILITY (deferral) | PP-13 (LOW) → deferred to Phase-7 | — | — | `pp11-12-13-reveal-verdict.json` (deferral confirmed) | PASS (fails closed) |
| 7 — CONFIG/HYGIENE | PP-17 (LOW) + `mount.ex` label-whitelist fix + framework-wide `:identity_namespace` guard | `78a6856` | 185, 186 (+ area 120) | `pp17-hygiene-verdict.json` | PASS |

**Tally at the end of the pre-PR phase: 16/17 findings fixed and independently verified PASS;
1/17 (PP-13) deliberately deferred as a not-yet-wired feature that fails closed (nil live blast
radius — no approve path meant no grant was ever minted through the product, so the mask always
held). The sabotage harness grew from 168 (pre-remediation baseline) to 186 across the 7 batches.**

## 4 · Two wins beyond the original 17 findings

1. **Pawchart became a complete authenticated reference implementation.** Batch 5a adopted the
   framework identity spine (login/signup/verify/onboarding/settings/2FA, real per-org role
   resolution) and Batch 5b authored the real Clinic (Patient/Pet) tenant surface with correct
   masking/org-scoping. Pawchart went from an unauthenticated demo shell to a second working
   vertical, not just a framework-parity stub.
2. **A latent framework label-whitelist fragility was found and fixed.** Batch 7 discovered that
   `samen_web/lib/samen/web/mount.ex`'s `@label_keys` whitelist was silently dropping
   legitimate-but-unrecognized framework mount labels (`identity_namespace`, `spine_totp`,
   `host_nav_extra`, `analytics_ask_resource`) on session round-trip. Fixed by enumerating the
   full, current label set; the whitelist governs KEY atomization only — it never trusts
   attacker-supplied VALUES, and still rejects any genuinely unknown key via
   `String.to_existing_atom`. Verified non-regressive by sabotage 120.

## 5 · Post-PR cleanup (H1–H5)

Three items surfaced by the pre-PR remediation but scoped out of it (a deferred feature and two
residual follow-ups explicitly flagged by their own verifiers as "do not block, file as
follow-up") were closed after the pre-PR phase, each independently gated and verified the same
way:

- **H1 — tenant reveal-approver surface** (commit `0f7c6dd`, verdict `pp13-approver-verdict.json`
  → PASS, sabotages 187–189). Completes the request→approve→unmask lifecycle PP-13 deferred: a
  new `Samen.Web.Settings.RevealApprovalsLive` at `/settings/reveal-approvals` where an authorized
  tenant approver sees pending operator reveal-requests for their org and approves or denies each.
  Distinct-party enforced at two policy layers plus a DB CHECK backstop (a requesting operator
  cannot self-approve); the approve-moment audit now lands on the tenant's own chain (not
  `__global__`); the surface renders metadata only, never a vault value or `vt_*` token.
- **H2 — account-level name scoping on `/operator/accounts`** (commit `b0d1c89`, T159, verdict
  `t159-name-scope-verdict.json` → PASS, sabotage 190). Closes a cross-tenant name leak: an
  operator scoped to `:none` (or a subset via `{:accounts, [...]}`) previously saw every tenant
  account's name and org-id in the accounts list regardless of scope. Fixed via mask-by-omission
  (out-of-scope rows render an opaque avatar + "not in your scope," never the name/org-id/deep
  links). The same verifier flagged a same-class residual in the shared operator sidebar
  switcher — filed as H2b rather than silently left open.
- **H2b — operator switcher name-scoping** (commit `1f9dff8`, verdict
  `t159-switcher-verdict.json` → PASS, sabotage 191). Closes the H2-adjacent leak: the
  "Act as a tenant →" switcher rendered on every operator surface was enumerating all account
  names + org-ids to a scoped-out operator independent of the T159 row-level fix, including a
  live `/session/org/<org_id>` act-as deep link — arguably worse than a passive name because it
  was an actionable affordance. `switcher_orgs/1` now filters through the same scope resolver;
  out-of-scope entries (and their deep links) are omitted entirely, with whole-page consistency
  confirmed (rows masked and switcher entries dropped together, page still renders opaque, not
  blank).
- **H3 — `gen.scope` emits authn wiring** (commit `7c7a318`, verdict
  `h3-gen-scope-authn-verdict.json` → PASS, sabotage 192). Framework-generator hardening so a
  *fresh* vertical is correct-by-default against the exact class of bug PP-1 was: `mix
  samen.gen.scope` now emits a failing-until-wired `tenant_authn_coverage_test.exs` into the
  generated app and prints the authn-wired router snippet (`labels: @current_org_labels`) instead
  of a bare mount, naming the leak it prevents. Proven end-to-end inside `./ci.sh`
  (`gen_post_probe.exs`): the guard is green on the pristine generated router, then a sabotage
  strips the label from the generated app's own billing mount and the guard fails non-vacuously
  (exit 2), then the router is restored and the guard is green again. Idempotent (a second
  `gen.scope` call never rewrites the guard file) and made no registry/schema change.
- **H4 — hygiene + this doc** (commit `e0b22da`). A `is_nil` guard on
  `security_live.ex`'s `credential_id_for/2` (silences a warning the PP-17 2FA path exercised, no
  behaviour change), a DRY of the one pure-duplicate Support-resource list in `gen/app.ex` into
  `@support_resources` (the other three sites pair each atom with independent data and stay
  literal), and this tracked reviewer doc. No new sabotage.
- **H5 — dependency CVE bumps** (commit `f54adb6`). Conservative in-major bumps clearing all
  three bundled advisories that printed on every gate run: ash 3.29.3 → 3.31.2 (keyset-cursor
  memory exhaustion + manage_relationship predicate injection), postgrex 0.22.2 → 0.22.4 (two SQL
  injection advisories), ymlr 5.1.5 → 5.1.6 (YAML newline injection). No major upgrade, no API
  migration; `mix hex.audit` clean for the three across every app. **Follow-up (CLOSED — see §6):**
  H5 left the pre-existing phoenix 1.8.8 (one HIGH + one MED, in `demo`) and phoenix_live_view
  1.2.5/1.2.6 advisories for their own session. That session is commit `02a426f` (Phase A below);
  they are **no longer open**.

**Sabotage harness total: 168 → 192** across the pre-PR batches (168 → 186) and the post-PR
cleanup (186 → 189 for H1, 189 → 190 for H2, 190 → 191 for H2b, 191 → 192 for H3; H4/H5 added
none). §6's pre-merge burn-down took it to **198**; §7's full-harden burn-down took it to **203**.

## 6 · Pre-merge burn-down (2026-08-11)

Everything above happened *before* the PR was reviewed. This section records what happened after,
and corrects the two claims §5 had gone stale on (the branch head, and the phoenix CVE).

**Branch head is now `359abe7`.** Four commits and one review, in order:

- **Phase A — dependency CVE advisories cleared** (`02a426f`, verdict
  `premerge-phaseA-phoenix-lv-cve-verdict.json` → PASS). Closes the follow-up H5 explicitly
  deferred: phoenix 1.8.8 → 1.8.9 in `demo` (EEF-CVE-2026-56811 HIGH + EEF-CVE-2026-56812 MED),
  phoenix_live_view → 1.2.9 across all four web apps (EEF-CVE-2026-58228 MED + EEF-CVE-2026-64941
  LOW, and it resolves the demo-1.2.5-vs-samen_web-1.2.6 skew), bandit 1.12.0 → 1.12.1 in the two
  verticals (EEF-CVE-2026-65623 HIGH), plus a websock_adapter ride-along. `mix.exs`/`mix.lock`
  only — zero source edits. `mix hex.audit` is now clean in all 17 mix projects.
- **Phase B — P18 + live doc-debt version sync** (`d3f4a7d`). A small docs/hygiene batch: the
  codemunch exploration convention reinforced in `driftwood/CLAUDE.md`, and live prose claiming
  current dependency versions re-synced to the enforced `mix.lock` pins (Ash 3.29.3 → 3.31.2 in
  `samen_core/README.md` + `index.html`). Dated historical snapshots were deliberately left
  unedited — they are honest records of what was true on their date.
- **The LUMINARY pre-merge review** — 39 experts across 5 panels (architecture, security,
  data/privacy, ops/reliability, API/DX/compliance) plus one independent adversarial confirmer,
  run over the *integrated* branch rather than per item. It found two classes the per-item
  verification and the persona dogfood structurally could not see: cross-feature auth-boundary
  flow, and config/deploy artifacts that no test boots. Reports live in the gitignored
  `_orch/luminary-premerge/`. **Honesty posture verdict: HOLDS** — the fail-honest adapter
  contract, T144 operator-only analytics, and the anti-overclaim posture were all audited
  directly and found sound; the findings are auth-boundary, config, erasure-completeness and
  deploy-template, not fabrication.
- **Phase D, B-SEC — the framework tenant-authn `on_mount` gate** (`3b251e3`, verdict
  `premerge-bsec-tenant-authz-verdict.json` → PASS, sabotages 193–196). Framework tenant
  LiveViews resolved org fail-closed in `mount/3` and then overwrote it with raw `params["org"]`
  in `handle_params/3` — which in LiveView 1.2.9 runs on the **initial dead render**, and no
  `on_mount` existed to preempt it. Confirmed live, 7/7 red paths, unauthenticated. Closed by a
  new `Samen.Web.TenantAuthz` (`on_mount {:require_tenant}`, attached by every tenant route macro
  — ≈0 authored LOC for a vertical) plus `CurrentOrg.reresolve/2`, which demotes `?org=` from an
  identity to a selector validated against the principal's pinned authorized set; the settings /
  2FA / onboarding param-identity legs and the `--live` generator templates were fixed in the same
  pass. The independent verifier built its own endpoint **and** drove the real driftwood/pawchart
  endpoints, and ran an anti-tautology pre-fix control proving the new helper is load-bearing.
  Strictly narrowing: armed hosts get stricter, disarmed hosts are byte-for-byte unchanged.
- **Phase D, B-OBAN — canonical Oban queue taxonomy + parity gate** (`359abe7`, verdict
  `premerge-boban-queue-drain-verdict.json` → PASS, sabotages 197–198). Workers enqueued into
  queues configured nowhere, so jobs sat `available` forever — including webhook ingress, which
  verified the signature, persisted, returned 200 to Stripe/Postmark, and never drained (DLQ
  replay re-enqueued into the same dead queue and reported success). The gate missed it because
  the taxonomy test asserted a hard-coded six-queue list that itself omitted `webhooks_in`. Closed
  by a canonical 9-queue `default_queue_config/0` + a config-time `Samen.Jobs.install_defaults/1`
  seam every host and both application templates now resolve through, plus a **non-vacuous**
  `mix samen.verify.oban_queues` parity verifier (worker queue ⊆ configured queue, fails closed on
  empty discovery) wired as a gate step in every host `ci.sh` and both generator ci templates.
  Demo also now starts Oban (it had declared a full config, cron included, and never started it).

**What remains, and the merge gate.** The two BLOCKERs are fixed and banked; the rest of the
review is filed as a durable decision record rather than a sprawling same-session fix:

> **[ADR-045 — LUMINARY pre-merge review dispositions](adr/ADR-045-premerge-review-dispositions.md)**

ADR-045 §2 carries the one item that **gates this merge and needs an operator decision**: the
tenant-authn gate — both the new `on_mount` hook and the pre-existing host `:browser` plug — is
conditioned on `:auth_required?`, which per ADR-031 defaults to **`false`** (a deliberate
dev-ergonomics posture) with no `config_env()` guard. Every shipped host commits or inherits that
default and none has a `prod.exs`/`runtime.exs` at all, and the generated-app config template emits
it too — so as shipped, an anonymous `GET /broker?org=<victim>` still returns another org's data,
and a fresh `mix samen.gen.app` deploys with an open tenant plane. This is **not a regression** (the
pre-fix tree was identically open when disarmed) and not a defect the B-SEC fix introduced — it
means the B-SEC remediation is only realized once a host arms. ADR-045 states the options honestly
and recommends **fail-secure by environment**. §4 of that ADR files every other unresolved finding
into four phases (gate integrity · deploy/runtime hardening · erasure completeness · residual role
derivation), and §5 names the two non-V-F1 items it would advise fixing before merge.

## 7 · Full-harden burn-down (2026-08-12)

ADR-045 §2 (V-F1) needed an operator decision; §5 named O2 and X1 as the two advised non-V-F1
merge-blockers. **The operator approved ADR-045 §2 Option A (arm the tenant-auth gate by default in
`:prod`, full-harden).** It plus the two advised items shipped as four gated commits (G1–G4), each
independently verified, sabotage harness **198 → 203**:

- **G1 — membership-role derivation** (`dc7b80d`, verdicts `premerge-g1-membership-role` +
  `premerge-g1-chat-delta` → PASS). Closes ADR-045 §4.4 **S1a** (four tenant write helpers stopped
  hardcoding `:admin`) and **S12** (generated `--live` templates now derive admin-rank from real
  `Identity.Membership`). Armed hosts now gate admin-rank writes on real org membership, not a
  posture flag — the item that makes "arm in prod" usable for an adopter.
- **G2 / V-F1 — prod-armed, fail-secure** (`9f14a61`, verdict `premerge-g2-prod-armed` → PASS).
  `Samen.Web.TenantGate` arms `:prod` **by default** with a **boot-refusal guard** (raises, naming
  the flag + fix, if a mount-bearing host boots unarmed in prod); dev/test byte-for-byte unchanged.
  Generator + deploy templates arm prod and wire `identity_namespace`, so a fresh `mix samen.gen.app`
  is fail-secure by default. **ADR-031's literal "Off by default" is amended in force** (ADR-045
  §2.5; the amendment note now lives on ADR-031's Status block).
- **G3 — pawchart `aud_chain`** (`98125e5`, verdict `premerge-g3-pawchart-audchain` → PASS).
  Closes ADR-045 §4.3 **O2** (pawchart had no `aud_chain` table — every append silently swallowed)
  and §4.2 **O7** (its migration read driftwood's config key). Adds the table via the shared
  `Samen.OperatorPlane.Migration` helper + a persist/immutability red-path; verifier fired raw
  UPDATE/DELETE and confirmed both P0001-rejected. Sabotage 202.
- **G4 — generated-nav** (`ead7a42`, gate GREEN). Closes ADR-045 §4.1 **X1**: generated landing nav
  is constrained to the surfaces actually mounted (no dead links / `NoRouteError` on first click),
  with a durable `gen_app_flagship_probe.exs` guard. Sabotage 203.

**Remaining backlog** lives in **ADR-045 §4** (now Accepted): Phase 2 deploy hardening (O4/O5/X6/O3,
the O9/O10 swallow, the runbook arming/KMS prose), Phase 3 erasure completeness (D1/D3/D4-T130/D5/D6),
the A2/X9 + A3 verifier floors, S13/S6/S14/S15/S16/S7 authz hardening, and the note-only items — all
honestly deferred as post-merge, none a live cross-tenant path on an armed host.

## 8 · Read next

- `_orch/dogfood/pre-pr/triage.md` (gitignored) — the full per-finding adjudication, root-cause
  clusters, and the pawchart-posture recommendation the operator decided against.
- `_orch/dogfood/pre-pr/pp13-approver-ui-deferral.md` (gitignored) — the original Phase-7
  deferral entry for what became H1.
- [risk-register-final.md](risk-register-final.md) — the earlier Gate-6 risk register this
  dogfood postdates; same "named, bounded residual, never silently dropped" discipline.
- [adr/ADR-045-premerge-review-dispositions.md](adr/ADR-045-premerge-review-dispositions.md) —
  the pre-merge review's decision record: the V-F1 merge gate and the four-phase backlog.
- `_orch/luminary-premerge/` + `_orch/verify/premerge-*.json` (gitignored) — the five panel
  reports, the synthesis/triage, and the three pre-merge verifier verdicts every claim in §6 is
  traceable to.
