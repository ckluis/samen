# ADR-045 — LUMINARY pre-merge review dispositions: the tenant-gate prod default (V-F1) and the phased burn-down of what remains

- **Status:** **Accepted** — §2 (V-F1) was operator-approved as **Option A** and is now
  IMPLEMENTED + independently verified (commits `dc7b80d` G1, `9f14a61` G2; see §2). §4's phased
  backlog is Accepted as filed (it records dispositions, it authors no code); the items closed this
  session are marked with their SHAs in §4, the rest remain OPEN/post-merge. This ADR itself is
  docs-only per the standing decompose-cross-cutting-changes rule: it touches no source, no test, no
  sabotage, no abbrev-registry row, no `schema.dict.json` (the code lives in the G-phase commits it
  cites).
- **Date:** 2026-08-11 (filed) · **Accepted 2026-08-12** (Option A operator-approved + shipped)
- **Task:** Pre-merge disposition record for branch `saas-readiness-phase-1` (PR #1), after the
  LUMINARY 39-expert pre-merge review (5 panels + 1 independent adversarial confirmer) and the two
  BLOCKER fixes that review produced.
- **Deciders:** **the operator for §2** — Option A approved 2026-08-12 (it changes a posture ADR-031
  deliberately chose; the amendment to ADR-031 is now in force, see §2.5).
  §3–§5 recorded by the pre-merge disposition pass, grounded in: the five panel reports and
  `SYNTHESIS-triage.md` (`_orch/luminary-premerge/`, gitignored), the independent verifier verdict
  `_orch/verify/premerge-bsec-tenant-authz-verdict.json` (the source of V-F1), and a direct read of
  `Samen.Web.CurrentOrg` / `Samen.Web.TenantAuthz` / the three shipped host configs / the deploy
  templates.
- **Consumes (binding inputs):**
  - **ADR-031** — BYO-auth launch on-ramp. §2 is a challenge to ADR-031's *default*, not to its
    architecture; §2.2 states ADR-031's own reasoning before arguing with it.
  - **ADR-029 / ADR-010 §7.2** — auth is host-owned; the framework owns the seam, not the IdP.
    Nothing in §2 changes that.
  - **ADR-024** — the generated `--deploy` runtime is fail-closed on missing secrets. Phase 2
    (§4.2) is about the parts of that scaffold that are *not* yet fail-closed.
  - **ADR-035 §4.1** — the blind-index (`sys:bidx`) design D1 (§4.3) challenges.
  - **ADR-014 / ADR-026** — the fail-honest adapter contract, which the review re-verified sound.

---

## 1 · Context

PR #1 (branch `saas-readiness-phase-1`) had already passed per-item verification and an
eight-persona whole-product dogfood (`docs/pre-pr-dogfood-remediation.md`). The LUMINARY pre-merge
review was run as the last gate before merge, over the *integrated* branch rather than per item,
and found two classes those passes structurally could not see: cross-feature auth-boundary flow,
and config/deploy artifacts that no test boots.

**Two BLOCKERs were confirmed, fixed, independently verified, and banked:**

- **B-SEC** (commit `3b251e3`) — framework tenant LiveViews resolved org fail-closed in `mount/3`
  and then overwrote it with raw `params["org"]` in `handle_params/3`, which in LiveView 1.2.9 runs
  on the *initial dead render*; no `on_mount` existed to preempt it. Closed by
  `Samen.Web.TenantAuthz` (`on_mount {:require_tenant}`, attached by every tenant route macro) +
  `CurrentOrg.reresolve/2`, which demotes `?org=` from an identity to a selector validated against
  the principal's pinned authorized set. Independent opus verifier: **PASS** on its own endpoint
  *and* on the real driftwood/pawchart endpoints, with an anti-tautology pre-fix control proving
  the new helper is load-bearing.
- **B-OBAN** (commit `359abe7`) — workers enqueued into queues configured nowhere (silent
  no-drain, incl. webhook ingress that returned 200 to Stripe/Postmark). Closed by a canonical
  9-queue `default_queue_config/0` + `Samen.Jobs.install_defaults/1` + a **non-vacuous**
  `mix samen.verify.oban_queues` parity gate wired into every host `ci.sh` and both generator ci
  templates. Independent opus verifier: **PASS**.

This ADR exists because the *rest* of the review does not fit in a commit message. It records one
decision that must be made before merge (§2), the posture findings that are confirmed sound (§3),
and every remaining finding with an honest disposition and a fix sketch (§4), so the operator can
decide once and a future session can execute without re-deriving the review.

---

## 2 · The V-F1 decision — the tenant gate is dormant on every shipped host, and "disarmed" is the fail-OPEN default

> **RESOLVED 2026-08-12 — Option A operator-approved and IMPLEMENTED + independently verified.**
> The analysis below (§2.1–§2.5) stands as the record of the decision; §2.0 records the outcome.

### 2.0 · Outcome (2026-08-12) — Option A shipped, full-harden

The operator approved **Option A** (fail-secure by environment, full-harden). It is implemented and
independently verified across two banked commits, with the ADR-031 amendment now in force (§2.5):

- **`9f14a61` (G2 / V-F1)** — `Samen.Web.TenantGate` arms `:prod` **by default**, fail-secure, with
  a **boot-refusal guard** that raises (naming the flag and the fix) when a mount-bearing host comes
  up unarmed in `:prod`; dev/test defaults are byte-for-byte unchanged. The generator and deploy
  templates now **arm prod** and wire `identity_namespace`, so a fresh `mix samen.gen.app` is
  fail-secure by default rather than open by default. Independent verifier verdict:
  `_orch/verify/premerge-g2-prod-armed-verdict.json` → **PASS** (with the boot-refusal red path and
  an armed-host positive control).
- **`dc7b80d` (G1)** — membership-role derivation (closes the S1a + S12 residuals §2.4.2 named as A's
  collision risk): armed hosts derive admin-rank from real `Identity.Membership` rows instead of a
  hardcoded `:admin`/posture flag, so "arm in prod" is actually *usable* for an adopter. Verdicts:
  `_orch/verify/premerge-g1-membership-role-verdict.json` + `premerge-g1-chat-delta-verdict.json`
  → **PASS**.

The Option A scope note in §2.4 is satisfied by these two commits: (a) env-aware default + boot
refusal that names the flag → G2; (b) generator `config_exs_web.eex` + emitted prod/runtime posture
+ `identity_namespace` wiring → G2; (c) the red-path + positive control → G2 verifier; (d) sabotage
patch → the harness is now **203**; (e) the Phase-4 role derivation sequenced alongside → G1. The
`runbook` row in §4.2 (the operator-facing arming step / KMS / `aud_event_app_role`) remains OPEN as
Phase 2 deploy work — the *control* is armed by construction; the runbook prose is post-merge.

> **This was the real merge gate. It needed operator sign-off; nothing below it was a substitute.**

### 2.1 · The problem (mechanism, verified end-to-end)

The entire tenant-authn boundary — both the **new** `TenantAuthz` `on_mount` hook and the
**pre-existing** host `:browser` auth plug — is conditioned on one predicate:

```elixir
# samen_web/lib/samen/web/current_org.ex
def param_trust_disarmed?(mount) do
  case Samen.Web.Operator.otp_app(mount) do
    nil -> true
    otp_app -> not Application.get_env(otp_app, :auth_required?, false)
  end
end

def tenant_gate_armed?(mount), do: authn_required?(mount) or not param_trust_disarmed?(mount)
```

The `get_env` default is `false` — **disarmed**. There is no `config_env()`/`MIX_ENV` guard
anywhere, no boot-time warning, and no test asserting a prod-env arming. And every shipped host
takes that default:

| Host | Committed value | Prod config | Consequence as shipped |
|---|---|---|---|
| `driftwood` | `config :driftwood, auth_required?: false` (`config/config.exs:99`) | **no `prod.exs`, no `runtime.exs`** (`config/` is `config.exs`/`dev.exs`/`drill.exs`/`test.exs`) | anonymous `GET /broker?org=<victim>` → **200 with the victim org's vaulted CDL in the clear** |
| `pawchart` | `config :pawchart, auth_required?: false` (`config/config.exs:67`) | **no `prod.exs`, no `runtime.exs`** | anonymous `GET /clinic?org=<victim>` → **200 with the victim clinic's patient data** |
| `demo` | key never set → `get_env` default `false` | — | moot in practice: demo is API-only (zero `live_session`); its tenant authz is the API-key plug, which the security panel rated the exemplar |
| **a fresh `mix samen.gen.app`** | `config :<otp_app>, auth_required?: false` (`priv/templates/config_exs_web.eex:76`) | — | **an adopter who deploys without explicitly arming ships a fully open tenant plane** |

The independent verifier drove all of this end-to-end (`V-S4-disarmed`, `V-PC-disarmed`,
`V-POSTURE-disarmed`), including proving there is no prod posture to read at all: a
`Config.Reader.read!(env: :prod)` on driftwood *aborts* on the missing `config/prod.exs`.

Two things this is **not**, stated plainly so the decision is made on true facts:

- **Not a regression.** The pre-fix tree behaved identically when disarmed. B-SEC's fix is strictly
  narrowing: armed gets stricter, disarmed is byte-for-byte unchanged. The verifier's PASS is real.
- **Not a defect introduced by B-SEC.** It is the ADR-031 posture question, surfaced by the fix
  rather than created by it. B-SEC's remediation is simply *only realized once a host arms*.

What it **is**: the branch's entire tenant-authn boundary now hinges on one opt-in boolean that
defaults insecure, on a foundry whose thesis is *governed by construction*.

### 2.2 · What ADR-031 actually decided, and why (stated faithfully before arguing with it)

ADR-031 chose the disarmed default deliberately and for a reason it wrote down. Its own words:

> "Before F2, every tenant/shared LiveView resolved 'what org am I acting on?' through
> `Samen.Web.CurrentOrg.resolve/3`, whose FIRST resolution step trusts `params["org"]` — a raw
> `?org=<uuid>`. **In the local dogfood that is a feature (no login needed to demo). For a real
> launch it is an authentication hole.**"

> "**`CurrentOrg.resolve/3` gains a fail-closed prod path, opt-in per mount.** … **Off by default**
> — dev/test keep the query-param convenience unchanged, so demo/pawchart and every existing test
> are untouched."

> "**Opt-in, runtime-flippable** means the dogfood stays param-driven and every prior test is
> unaffected, while the SAME code proves both paths in one suite (`Application.put_env`)."

So ADR-031's rationale for disarmed-by-default is **dev/test ergonomics and non-disruption**: keep
the no-login dogfood working, keep every pre-existing test green, and prove both postures in one
suite by flipping an app env at runtime. It is *not* an argument that a production deployment
should be able to come up disarmed — ADR-031 names the query-param identity "an authentication
hole" for "a real launch" in its own Context, and its launch checklist names the swap. ADR-031
simply **never scoped an environment-aware default**: the flag it introduced is host-owned and
env-blind, and the reference host (driftwood) wires it as a plain `:app_env` label the operator is
expected to flip by hand.

That gap — not a bad decision, an unscoped one — is what V-F1 lands in.

### 2.3 · Options

**Option A — fail-secure by environment (RECOMMENDED).** `:auth_required?` defaults to **true**
in `:prod`, or (equivalently, and more visible) the app **raises at boot** when `config_env() ==
:prod` and a mount-bearing host is unarmed. Dev/test defaults are untouched.

- *For:* it is the only option where the wrong thing is the hard thing. It matches the posture the
  rest of this repo already takes everywhere else — `Samen.Files` quarantines fresh files
  (fail-closed), `Samen.Type.VaultField` refuses raw plaintext, the generated `runtime.exs`
  *raises* rather than boot half-secure on a missing secret (ADR-024). An env-aware default is
  strictly consistent with all three. It also makes an adopter's most likely failure — "I ran
  `gen.app` and deployed it" — safe by default rather than catastrophic by default.
- *Against (honest costs):*
  1. **It moves work onto the adopter at exactly the moment they deploy.** Arming requires a real
     `:authorized_orgs` seam (or spine `Membership` rows) *and* a login path; an adopter who armed
     accidentally gets a locked-out app, not a broken-open one. That is the right direction of
     failure but it is still a support burden, and the error message has to be excellent.
  2. **It collides with the Phase-4 role residual (§4.4).** An armed *generated* app today has no
     admin-rank writes at all — `ui_role/0` drops to `:member` when armed and no membership-derived
     role is wired yet (S12, honestly declared and verifier-confirmed). So "arm in prod" and
     "derive the real role" want to ship together, or A must ship with that gap named in the
     runbook.
  3. **No shipped host has a prod config file to put it in.** A is not one line: it needs either a
     framework-level env-aware default in `CurrentOrg`/`Samen.Jobs`-style config seam, or emitted
     `prod.exs`/`runtime.exs` postures for driftwood/pawchart and the generator.
  4. **It amends ADR-031's literal wording** ("Off by default", unqualified). See §2.5.

**Option B — keep the disarmed default, make it impossible to miss.** A loud, named boot-time
warning when `config_env() == :prod` and the flag is unset/false; a **mandatory arming step** in
`priv/templates/deploy_runbook.eex`'s "Operator TODO"; and a gate test asserting the prod-arming
path (so the warning itself cannot silently regress).

- *For:* zero behavior change, zero lock-out risk, cheapest, fully compatible with ADR-031 as
  written; the runbook already carries a `:authorized_orgs`-replacement warning to sit beside.
- *Against:* a warning in a log is not a control. It preserves a fail-open default in the one place
  the product's entire multi-tenancy claim rests, on a repo that elsewhere refuses to let a wrong
  configuration boot. It also leaves the published claim ("governed by construction") doing work
  the code does not do.

**Option C — status quo; document the sharp edge only.** Add the sharp edge to the runbook and to
this ADR's residual list; ship as-is.

- *For:* honest, and it is genuinely not a regression.
- *Against:* the branch would merge with a documented, fully-reachable, unauthenticated cross-tenant
  read on two shipped verticals and on every generated app. "Documented" does not make it safe, and
  the review's own security panel rated the underlying class BLOCKER.

### 2.4 · Recommendation

**Option A**, with B's runbook + warning work folded in as its user-facing half.

Reasoning, in order of weight:

1. **Direction of failure is the whole thesis.** Every other chokepoint in this codebase fails
   closed and is sabotage-tested for it. A tenant-authn gate that defaults open is the single
   inconsistency, and it sits on the highest-consequence boundary in the product.
2. **The adopter is the person A protects.** driftwood/pawchart are operated by the person who
   wrote them; a generated app is not. `config_exs_web.eex` shipping `auth_required?: false` means
   the foundry's *default output* is an open tenant plane. That is the finding that should decide
   this.
3. **A does not cost ADR-031 anything it argued for.** Dev and test stay disarmed; the dogfood
   stays param-driven; every existing test stays green; both postures still prove in one suite via
   `Application.put_env`. What changes is only the answer in `:prod`, an environment ADR-031 never
   ruled on.
4. **B is a real option, not a strawman** — it is the right call if the operator judges lock-out
   risk for existing deployments to outweigh open-by-default for new ones. It should then be
   adopted *with* the gate test, or it decays to C within one refactor.

**Scope note for whoever implements A:** it must land with (a) an env-aware default or boot refusal
that names the flag and the fix in its message, (b) the generator's `config_exs_web.eex` +
emitted prod/runtime posture, (c) a red-path test asserting that a `:prod`-configured unarmed host
refuses (with a positive control that an armed host serves), (d) a sabotage patch, and (e) the
Phase-4 role derivation sequenced alongside or explicitly named as a known gap in the runbook.

### 2.5 · Compatibility with ADR-031 — honest assessment

**Option A is compatible with ADR-031's *rationale* and amends its *literal default*.** ADR-031's
stated reasons for "off by default" are entirely about dev/test ergonomics and not disturbing
existing tests; A preserves both exactly. ADR-031 also already calls the query-param identity "an
authentication hole" for "a real launch," so A is arguing *for* ADR-031's own Context. But
ADR-031's Decision §2 says "Off by default" without qualifying by environment, and its Consequences
accept "opt-in, runtime-flippable" as the shape. A narrows that literal text. So: **not a
contradiction of intent, but a genuine amendment of the written default** — and it should be
recorded as an amendment to ADR-031 (an "Amended <date> — see ADR-045 §2" line, the ADR-044
precedent), not slipped in as an implementation detail.

> **In force (2026-08-12).** The amendment is now recorded on ADR-031 itself ("Amended 2026-08-12 by
> ADR-045 §2" in its Status block): the `:prod` default is **ARMED**, dev/test unchanged. ADR-031's
> dev-ergonomics rationale is preserved exactly (dev/test keep the query-param dogfood; every prior
> test stays green; both postures still prove in one suite); only the `:prod` answer changed.

### 2.6 · Sign-off

| | |
|---|---|
| **Decision required** | A / B / C |
| **Recommended** | **A** (with B's runbook + warning folded in) |
| **Operator** | **Approved — Option A (full-harden)** |
| **Date** | **2026-08-12** |
| **Outcome** | Shipped in `9f14a61` (G2/V-F1) + `dc7b80d` (G1); ADR-031 amended in force (§2.5); harness → 203. See §2.0 |

---

## 3 · What the review confirmed sound (recorded so it is not re-litigated)

- **The honesty posture HOLDS.** The fail-honest adapter contract (ADR-014/024/026), **T144**
  operator-only analytics with its pre-read platform-capability gate, the k-anonymity floors, and
  the anti-overclaim posture were all audited directly and found sound. The review's failures are
  auth-boundary, config, erasure-completeness, and deploy-template — **not fabrication**. The one
  claim found to overstate is a README line about pawchart's authored LOC (X5, §4.1), which is a
  doc defect, not a mechanism defect.
- **T130 (clone `storage_key` aliasing) is still blocked-safe.** Re-confirmed by the data/privacy
  panel: `Samen.Files.Storage.delete/2` is defined in both adapters and declared in the behaviour,
  and has **zero callers in any `lib/`** (only `test/files_storage_test.exs`). **Sequencing note:**
  that same fact is D4 — no code path ever deletes a file blob, so erasure does not reach stored
  bytes. **Fixing D4 makes T130 live.** They must be built and gated in the same task, never
  separately.
- **The two by-design reveal/switcher residuals are safe by direction, and one is safe for the
  wrong reason.** (a) Kernel `Reveal.Grants.approve/deny` are party-based only, as documented, and
  have no non-surface reachable path — sound at the kernel; their surface control was defeated by
  S1/S2 and is restored now that those are fixed. (b) The H2b switcher's `scope_of/2` over-masks as
  claimed, but *accidentally*: it passes an **org** id where a **principal** id is expected, and
  the resolver fails closed to `:none`. A host whose `:operator_authority` resolver returns a broad
  role for that org id would flip it to `:all` and enumerate every account name + org id. Not
  reachable on driftwood/pawchart today. **Harden post-merge** (thread the real principal through,
  or pin the reason in a comment) — filed at §4.4.
- **Carried unchanged:** **P17** (tenant-own-org analytics) remains a **product build-or-defer
  decision for the operator**, not a defect. Whatever is decided, it **must not weaken T144**: the
  gate refuses tenant actors *and* impersonation before any row is read, and any tenant-facing
  analytics surface has to be built as a separate, org-scoped path rather than by relaxing that
  gate. **T130** stays blocked-safe and blocked — see the D4 sequencing note above.

---

## 4 · The phased backlog — every remaining finding, with an honest disposition

Severity is the panel's. Dispositions are this ADR's. IDs map to `_orch/luminary-premerge/panel-*`
(gitignored; the IDs travel so a future session can find the evidence).

### 4.1 · Phase 1 — gate integrity and the adoption promise

The gates that are supposed to catch the next class of this, plus the first thing an adopter clicks.

| ID | Sev | One-line | Disposition | Fix sketch |
|---|---|---|---|---|
| **A2 / X9** | HIGH / MED | `samen.verify.pii_classify` and `samen.verify.api_contract` pass **vacuously on empty discovery**, while structurally identical siblings fail closed; `api_contract --update` will write an empty snapshot without complaint | **fix-before-merge** | Add a non-emptiness floor to both (exactly the shape `mix samen.verify.oban_queues` just shipped with in B-OBAN), plus a test asserting empty discovery **fails**, plus a sabotage |
| **X1** | HIGH | Generated `--modules` landing renders CRM/Support/Marketing/Automation nav links to routes the generated router never mounts → `NoRouteError` on the adopter's first click; the flagship probe prints "lists every mounted surface" while probing only the 5 selected labels | **CLOSED this session — `ead7a42` (G4)** | Generated landing nav is now constrained to the surfaces actually mounted (no dead links), with a durable probe guard in `gen_app_flagship_probe.exs`. Gate GREEN; sabotage added (harness → 203) |
| **A3** | HIGH | Generated apps run a **strictly weaker verifier gate** than the reference verticals: `no_pan_columns` is in neither `ci_sh.eex` nor `ci_sh_api.eex`; `column_refs` runs in no `.sh` at all | **fix-before-merge** (`no_pan_columns`) · **post-merge-phase-1** (`column_refs`) | Add the `no_pan_columns` step to both ci templates + the golden fixtures; decide separately whether `column_refs` is a real gate or dead code and either wire it everywhere or delete it |
| **A4** | MED | `Mount.@label_keys` whitelist has drifted — 7 used keys missing, 5 of them set by `samen_auth_routes` itself; the completeness test is tautological (it checks the list against itself) | **fix-before-merge** (add the keys) · **post-merge** (bind the sets) | Add the 7 keys; then make the test derive the used-key set from the router macros so it can actually fail |
| **X4 / X5 / X12** | MED | Doc-integrity cluster: README + `index.html` publish six stale/mutually contradictory verification counts (sabotages cited as 28/31, actually 198; ADR count; verifier count; gate-step count); README understates pawchart as "~191 authored lines" (actual `pawchart/lib` ≈ 3,938); "18-step gate" published in five places while the `--api` gate emits 19 | **fix-before-merge** (cheap, docs-only) | Recount from the filesystem and correct in one pass. **Claim-evidence parity is this repo's thesis — a stale count is the one defect class the product is least allowed to have** |
| **X11** | LOW | `docs/pre-pr-dogfood-remediation.md` stale at head (named `f54adb6`; carried the phoenix HIGH CVE as open after `02a426f` closed it) | **CLOSED by this pass** | Corrected in the same commit as this ADR |
| **A14 / A16 / X7 / X10** | LOW | Doc/ADR drift: kernel config tells hosts to wire `config :my_app, Oban` (nothing does); "263 entries" stale ×5; `CLAUDE.md` gate order ≠ `ci.sh`; `generators.md` documents neither `--web/--api/--deploy/--port/--headless` nor the web/API output tree (it describes the *headless* output while web+API are the defaults); "eight Billing abbrevs" vs the nine actually reserved | **post-merge-phase-1** | Mechanical doc corrections; the `generators.md` flag table is the one an adopter actually hits |

### 4.2 · Phase 2 — deploy and runtime hardening

Everything in the `--deploy` scaffold that a *boot* would find and no test does.

| ID | Sev | One-line | Disposition | Fix sketch |
|---|---|---|---|---|
| **O4** | HIGH | Every generated prod migration emits `REVOKE UPDATE, DELETE ON aud_chain FROM clank` — **a developer's local Postgres role** — because `priv/templates/m_aud_event.eex:5` defaults `@app_role` to `"clank"`; the first prod `release_command` aborts, and the deploy runbook never mentions the knob | **post-merge-phase-2** | Default the role to the migration's own connection role (or the repo's configured `:username`) instead of a hardcoded literal; if it cannot be derived, **raise a named error** rather than emit someone's laptop role; document the `:aud_event_app_role` knob in the runbook. Related: **O7 — CLOSED this session (`98125e5`, G3):** pawchart's aud-chain wiring was corrected alongside adding its `aud_chain` table (O2), so its own audit-role config key is now reachable. **O4 itself remains OPEN (Phase 2 deploy).** |
| **O5 / X6** | HIGH / MED | The generated `--deploy` `runtime.exs` sets `config :samen_core, :kms_adapter, Samen.Kms.AwsKmsDynamo` **and** `:aws_kms_dynamo_enabled, true` — and that adapter is a **raise-only skeleton** (`stub_delegate/2` raises whenever enabled; `backups_disabled?/0` and `key_material_present?/1` raise directly). The app boots green and then **every vault operation 500s**. The runbook's four-item "Operator TODO" omits it entirely | **post-merge-phase-2** | Do not select a raise-only adapter by default. Either emit the working `FileBacked`/explicit-choice posture with a named operator step, or keep the selection with `enabled: false` plus a fail-closed boot check that raises with the actual implementation checklist (the adapter's own moduledoc already lists the seven ADR-001 §8.2 obligations). Add it to the runbook's Operator TODO as **item 1** — it is the largest blocker there, and today it is absent. Honesty note: it fails **loudly**, so the fail-honest contract itself is intact — this is a scaffold-correctness bug, not an overclaim |
| **O3** | HIGH | The 15-minute audit-chain verify cron loads **every entry of every org** into memory, on the `maintenance: 1` queue it shares with the partition roll-forward | **post-merge-phase-2** | Bound the verify to a keyset window / per-org batch with a resume cursor; consider its own queue so a long verify cannot starve partition roll-forward |
| **runbook** | — | The deploy runbook's Operator TODO is incomplete against reality (O5/X6 above; the `:authorized_orgs` replacement warning exists but the **arming step** does not) | **post-merge-phase-2**, or **fix-before-merge if §2 lands as Option A or B** | One pass over `priv/templates/deploy_runbook.eex`: KMS adapter, `auth_required?` arming, `aud_event_app_role`, in that order of consequence |
| **O8 / O9** | MED | `Driftwood.Reads.driver_roster/1` is unbounded with per-row vault decrypt, called per `handle_params` (the boundedness lint's glob excludes the vertical trees); DSAR export returns `{:ok, bundle}` even when the "who exported what" audit record failed — a non-repudiation hole on a compliance surface | **post-merge-phase-2** | Add `limit`/keyset via `Samen.Web.Reads` and extend the lint's `source_files/0` to the verticals; make the DSAR audit write a hard precondition of returning the bundle |

### 4.3 · Phase 3 — erasure completeness (the unifying finding)

The data/privacy panel's central observation: `Samen.Erasure`'s moduledoc names **two** carve-outs
that key-shred does not reach and says both are "handled explicitly here." **There are at least
five.** Each is the same mechanism — a plaintext-or-linkable value living outside the per-subject
DEK envelope, therefore outside the reach of key destruction.

| ID | Sev | One-line | Disposition | Fix sketch |
|---|---|---|---|---|
| **D1** | HIGH | Crypto-shred leaves `email_bidx`, a keyed HMAC of the subject's email under `sys:bidx` — a **reserved subject `Kms.shred/1` refuses to destroy by design** — so an erased subject's email stays confirmable forever via an equality oracle over the enumerable email space | **operator-decision → post-merge-phase-3** (needs design; this is an **ADR-035 §4.1 amendment**, not a code tweak) | Cannot be fixed by nulling the column (`Credential.email_bidx` is `allow_nil?: false` and carries the global one-account-per-email unique invariant). Two coherent shapes: (a) destroy the `Credential`/`Invitation` rows as part of subject erasure, or (b) **re-key the blind index per subject** so shred unlinks it — precisely the pattern `Samen.Vault.pseudonym/1` already uses correctly, which is why the pseudonym carve-out *is* reached by shred and the blind index is not |
| **D3** | HIGH | `pii_declared: true` custom-bag values are plaintext PII in a `public?: true` `:map` column that `PiiResolution` never resolves — rendered **in the clear to operators** on CSV / JSON:API / UI-kit surfaces that claim per-plane masking, and no erasure path ever redacts them (`NonPii` redacts whole *columns*; there is no bag-key path) | **fix-before-merge IF reachable, else post-merge-phase-3** | **First action is a reachability check**, not a fix: grep whether any shipped resource declares a `pii_declared` bag field today. If yes it is an INV-1 gap on a live surface and rates merge-gating; if no it is a framework hazard awaiting its first adopter. Then: resolve bag keys through `PiiResolution` (or refuse `pii_declared` at the write chokepoint until routed), and add a `MaskingCase` three-proof for a bag field on at least one surface |
| **O2** | HIGH | **PawChart has no `aud_chain` table at all** — every audit-chain append fails, and the failure is swallowed. A shipped vertical mounting the operator plane has no tamper-evident chain | **CLOSED this session — `98125e5` (G3)** | Added the pawchart `aud_chain` migration wrapping the shared `Samen.OperatorPlane.Migration.create_aud_chain/1` helper (byte-identical adoption to driftwood/demo — append-only trigger, `UNIQUE(org,seq)`, `REVOKE UPDATE/DELETE`), plus `aud_chain_persist_test.exs` asserting appends **land**, hash-link, and verify. Independent verifier `_orch/verify/premerge-g3-pawchart-audchain-verdict.json` → **PASS** (raw UPDATE/DELETE both rejected P0001). Sabotage 202. **O9/O10 swallow remain OPEN (Phase 2)** — the table now exists so they no longer hide a live gap |
| **D4 / T130** | MED | No production path deletes a stored file blob; destroying/archiving/retention-sweeping a `File` row leaves raw, unencrypted bytes in storage indefinitely. Same fact that keeps T130 non-exploitable | **post-merge-phase-3, sequenced with T130** | Wire `Storage.delete/2` into the destroy/retention path **and** close T130's clone-aliasing in the same task, with a red-path proving a shredded subject's blob is gone and an aliased clone cannot resurrect it. **Never ship one without the other** |
| **D5** | MED | The framework's own automated erasure driver drops `:org_id`, so a retention-swept subject's erasure event lands on the reserved `"__global__"` chain — which `TenantView.for_org/2` refuses by design. The tenant's own chain never records the erasure of its own data subject | **post-merge-phase-3** | Thread `org_id` from the just-read row into `shred_opts` in `retention.ex`. Reachability: no shipped host configures a `:shred` retention spec today, so this is a framework defect awaiting first adopter |
| **D6** | MED | `Samen.Dsar.export_subject/2` applies **no org binding** and takes plane/grant as caller-asserted options with a plaintext default; the moduledoc's "NO cross-tenant leakage" claim is about *planes*, not *orgs* | **post-merge-phase-3** | Require an org predicate on both queries and check `grant?` against `Reveal.grant_checker/0` rather than trusting the caller. Reachability: no host wires DSAR to a route today — framework API hazard, not a live gap |
| **D2 / D7** | MED / LOW | `Samen.Policy.SameOrgFk` **refuses** a write whose FK targets an org-less row, contradicting its own inline comment *and* the verifier moduledoc (both say it passes) — a host following the scope-authoring guide's documented bare-`change` default breaks every create on such a resource. `Csv.compact/1` unwraps any struct via `Map.from_struct/1`, so a **nested** `%Samen.Masked{}` would serialize its `vt_*` token | **post-merge-phase-3** | D2: make code and docs agree (decide which is correct, then bind them with a test). D7: one clause — `compact(%Masked{} = m), do: m`. Both latent today (every `SameOrgFk` call site passes an explicit org-scoped `relationships:` list; no shipped resource nests a `%Masked{}`) |
| **new** | — | **The completeness verifier that would have caught D1+D3+D4 as one class** | **post-merge-phase-3** | A verifier over "every plaintext-or-derived column not covered by an erasure arm." The existing `pii_classify` baseline structurally cannot do this — `schema.dict.json` *grandfathers* pre-existing columns |

### 4.4 · Phase 4 — residual role derivation and authz hardening

Everything the B-SEC fix bounded but did not close. **All of these are intra-org or
over-denying** — the verifier confirmed no cross-tenant path survives on an armed host.

| ID | Sev | One-line | Disposition | Fix sketch |
|---|---|---|---|---|
| **S1a** (residual) | HIGH→intra-org | Four tenant write helpers still `Map.put(actor, :role, :admin)` unconditionally (`flags/reads.ex:76`, `support/kb_reads.ex:116`, `marketing/reads.ex:332`, `billing/reads.ex:304`+`:314`) — an ordinary member gets **admin-rank writes in their own org**. Verifier-confirmed genuinely intra-org only (`V-S1a-POSITIVE-CONTROL`) and unreachable across tenants post-fix | **CLOSED this session — `dc7b80d` (G1)** | Role is now derived from the resolved `Identity.Membership` instead of unconditionally elevating; red-paths refuse a `:viewer`/`:member` on the affected surfaces with a positive control for an actual admin. Verifier `_orch/verify/premerge-g1-membership-role-verdict.json` → **PASS** |
| **S12** (residual) | HIGH→fail-closed gap | Generated `--live` screens fail **closed** on armed hosts (via `reresolve/2`'s no-pin fallback), but `ui_role/0` is a **posture flag, not a membership read** — so an armed generated app has **no admin-rank writes at all** until a real membership role is wired | **CLOSED this session — `dc7b80d` (G1), sequenced with §2 Option A (G2)** | The `--live` templates now emit membership-derived role resolution, so an armed generated app has real admin-rank writes — this is the item that makes "arm in prod" usable for an adopter. Verifier `_orch/verify/premerge-g1-membership-role-verdict.json` (+ `premerge-g1-chat-delta-verdict.json`) → **PASS** |
| **S13** | HIGH | `Chat.ThreadLive` subscribes to the tenant thread topic **before** the gate, and neither `handle_info({:chat_message, …})` nor `handle_event("send", …)` re-consults `gate_socket/3` — an operator whose impersonation session expires mid-flight keeps streaming and can still post | **post-merge-phase-4** | Re-gate in both callbacks, the standard `operator/automation_health_live.ex:176-184` already states; subscribe **after** the gate |
| **S6 / S14** | MED | `SecurityLive.credential_id_for/2` does `Ash.read!(authorize?: false)` on a client-supplied `user_id` with no org scope and **no `# authz-scope:` justification** — a global user_id → credential_id oracle. `Operator.WebhookDlqLive` `replay`/`resolve` use a bare `repo.get` with no scope/actor and admit `:operator_readonly` (a read-only role getting a write) | **post-merge-phase-4** | Scope both to the session-derived actor; add the missing justification markers or remove the bypass |
| **S15** | MED | The `authorize?: false` lint is fooled by `Ash.Query.ensure_selected([:org_id])` (a *selection* counted as a *pin*) and **does not sweep the vertical trees at all** (79 + 47 + 26 unlinted sites) | **post-merge-phase-4** | Restrict pin detection to filter expressions; extend `source_files/0` to `driftwood/lib`, `pawchart/lib`, `demo/lib`. This is the lint that should have caught S6 |
| **S16 / S7** | LOW | Driftwood reveal handlers gate on cached assigns rather than re-running `gate_socket/3` (TOCTOU across session expiry / scope revocation; blast radius bounded by the downstream second-party grant). `GET /session/org/:org_id` is a state-changing CSRF-unprotected GET — an attacker page can flip a logged-in operator's current org via `<img src>` | **post-merge-phase-4** | Re-gate per handler; convert the org switch to a POST with CSRF (its "safe because the boundary is the actor-derivation step" defence rested on the premise S1 broke) |
| **S8 / S9 / S10** | INFO | The switcher over-mask holds **accidentally** via type confusion landing on a fail-closed `:none` (§3); kernel `Grants.approve/deny` sound with no non-surface reachable path; `Samen.Web.AuthGate` reads only the legacy `samen_current_user` key, never the spine token — a spine-only host's operator is bounced to `/login` (over-deny, a functional trap) | **note-only** · **S10: operator-decision** | S8: thread the real principal through `scope_of/2`, or pin the reason in a comment so a future refactor cannot silently flip it |
| **test gap** | — | No test in the repo drives a **connected** LiveView socket (`lazy_html` is not a dep) — the B-SEC suite and the verifier both used dead-render `get/2` + `live/2`-that-redirects. The dead render **is** the confirmed vector and the hook re-runs on the socket mount, but the connected live-nav/`push_patch` path is unproven by test | **post-merge-phase-4** | Add `lazy_html` as a test dep and drive one connected-socket red path |

### 4.5 · Note-only / operator-decision (recorded, not scheduled)

- **A5–A13, A16b** (framework-internal duplication and coupling): route macros that discard `kind`;
  `Plane.scope/2` reinvented in 3 host sites despite its docstring forbidding it; `DriftwoodWeb.Auth`
  ≡ `PawChartWeb.Auth` (48/48 lines); blanket `rescue _ -> []` in vertical reads (error →
  honest-looking empty); the template engine's ordered `String.replace` reduce with no
  leftover-placeholder assertion; `PageLimitClamp` byte-mirrored into demo; API-key digest
  hand-rolled 3× despite `TokenMint.digest/1`; verifier discovery predicates that `rescue _ ->
  false` (**fail-open in a gate** — the highest-value one of this group); verifier sprawl.
- **A15 / A17 / A18 / A19 / A20** (structure/posture): two unread mirror abbrev registries with no
  parity check; the kernel unconditionally starting `Kms.InMemory` though the default adapter is
  `FileBacked`; `Mount.@type t`'s `scope_kind` union missing 4 kinds; **A19 the abbrev registry as
  one global file with ADR-025's host partition still `Proposed (deferred)` — an
  operator-decision, and it is pre-publish shaped**; identical vertical endpoints with no
  `samen_endpoint` macro.
- **X2 / X3 / X8 / X13** (API surface): the generated `/api/v1` is bearer-authed with **no
  key-minting path** unless `--modules settings` (the seed prints a literal placeholder); a
  missing/invalid/revoked key yields **HTTP 200 + empty `data`**, never 401 — and the flagship
  probe codifies the 200 as a pass, inconsistent with the MCP surface in the same product;
  `Identity.ApiKey`'s `create: :*` makes `plane`/`minter_role` attacker-supplied inputs (not
  externally reachable today), which `AI.Analytics.platform_actor?/1` would compound if an
  API/MCP analytics tool is ever added.
- **O10 / O11 / O12 / D8** (accepted with note): reveal-ledger read error degrades to `[]`
  (indistinguishable from "no reveals ever occurred"); the tamper telemetry emits `org_id`
  metadata, a `forbidden_tag_keys/0` value the label-lint cannot see because it scans metric
  *definitions*, not `:telemetry.execute` metadata; `QueryBudget.check/2` fails open **as
  designed**; CDC deliberately mirrors `vt_*` tokens into the analytics tier (inert post-shred) —
  **audited sound, recorded so a future reviewer does not re-flag it**.

---

## 5 · What should block merge

**V-F1 (§2) was the only item this ADR asserts as a hard gate**, and it was a *decision* gate. **It
is now RESOLVED (2026-08-12):** the operator chose **Option A (full-harden)**, shipped in `9f14a61`
(G2) + `dc7b80d` (G1), with the ADR-031 amendment in force. The merge is no longer blocked on a human
decision.

**Two more were strongly advised in the same pre-merge phase — both are now CLOSED this session:**

- **O2 — CLOSED (`98125e5`, G3).** PawChart now has its `aud_chain` table (shared-helper migration +
  persist red-path); appends land, immutability verifier PASS.
- **X1 — CLOSED (`ead7a42`, G4).** Generated landing nav is constrained to mounted surfaces (no dead
  links) with a durable probe guard.

**A2/X9 and A3** are the next tier: they are gate-integrity, not user-facing, but a vacuous verifier
is precisely how the next B-SEC-class finding ships behind a green gate. Fix-before-merge if the
merge is not urgent; Phase 1 immediately after if it is.

**Everything else in §4 is honestly post-merge.** None of it is a live cross-tenant path on an armed
host, and saying otherwise to force urgency would be its own kind of overclaim.

---

## 6 · Consequences

**Positive** — the review's output survives the session that produced it: one decision the operator
can make in one place with the trade-offs stated honestly, and a phased backlog a future session can
execute item-by-item without re-reading five panel reports. The V-F1 framing is grounded in
ADR-031's *actual* reasoning, so the decision is made against the real prior decision rather than a
strawman of it. The residual list names what is *not* fixed, in the repo's standing "named, bounded
residual, never silently dropped" discipline.

**Negative / accepted** — this ADR fixes nothing. It is a decision record and a queue, and a queue
that is not executed decays into documentation of known debt. Phases 2–4 in particular contain two
design-level items (D1's ADR-035 amendment, D3's reachability question) that will each need their
own ADR or ADR amendment rather than a build task. And §2 deliberately blocks a merge on a human
decision — that is the point, but it is a cost.

**Neutral** — docs-only. No source, test, sabotage, registry, or schema-dict change. The ADR index
(`docs/adr/README.md`) gains a row for this ADR, and its stale total (part of finding X4) is
corrected in the same pass.

## 7 · See also

- **ADR-031** (`031-byo-auth-launch-onramp.md`) — the decision §2 challenges. If §2 lands as A or B,
  amend ADR-031 with a pointer here.
- **ADR-024** (`024-generated-deploy-fail-honest.md`) — the fail-closed boot posture Phase 2 (§4.2)
  measures the deploy scaffold against.
- **ADR-035 §4.1** (`ADR-035-identity-spine.md`) — the blind-index design D1 (§4.3) requires an
  amendment to.
- **ADR-005** (`005-operator-plane-migration-extraction.md`) — the shared `aud_chain` migration
  helper O2 (§4.3) should adopt rather than hand-copy.
- `docs/pre-pr-dogfood-remediation.md` — the tracked reviewer doc; its 2026-08-11 section records
  the pre-merge burn-down that produced this ADR.
- `samen_web/lib/samen/web/tenant_authz.ex` — the B-SEC gate whose *dormancy* is V-F1.
- `_orch/luminary-premerge/` + `_orch/verify/premerge-bsec-tenant-authz-verdict.json` (both
  gitignored) — the panel reports and the verifier verdict every ID above is traceable to.
