# Task PRE (Phase 4) — Gate-3 carries + hygiene

- **Date:** 2026-07-07
- **Scope:** the three Gate-3 carry items Phase 4 depends on:
  - **(a) F3.5** — SameOrgFk fail-closed verifier + wiring the unwired FKs.
  - **(b) F3.7** — close the API filter/sort side channel over de-allowlisted fields.
  - **(c) T3.13 flake** — root-cause + deflake the intermittent oracle-tier failure.
- **Result:** all three landed green. Root `bash ci.sh` = **exit 0 — ALL PASSED**
  (samen_core 637 pass, demo 366 pass, 14-step demo gate). Both suites green under
  `mix test --warnings-as-errors`. Anti-tautology probes run on (a) and (b), each
  flipped its guarantee's red path and was reverted clean (0 `SABOTAGED` markers).

---

## (a) F3.5 — SameOrgFk verifier + wiring

### The verifier

New fail-closed mix task **`mix samen.verify.same_org_fk`**
(`samen_core/lib/mix/tasks/samen.verify.same_org_fk.ex`). Turns the scope-authoring
guide §10 prose rule into a gated invariant: for every resource in every configured
Ash domain, it FAILS when the resource is **tenant-plane org-scoped** (has an
`org_id` attribute AND references `Samen.Policy.OrgScope` in a policy) and declares a
`belongs_to` — whose destination is *also* org-scoped (has an `org_id`) — that is NOT
covered by a `Samen.Policy.SameOrgFk` change.

Design decisions (the task left this "your call"):
- **Standalone task**, not folded into an existing verifier — it needs its own
  policy+change introspection and diagnostic; the other verifiers are
  column/catalog/DB scans. Follows the `Samen.Verifier.halt_if_violations/2` harness
  (`:erlang.halt(1)` fail-closed) and the `violations/1`-separated-from-`run/1`
  testability pattern the sibling `tnt_boundary` task uses.
- **Org-scoped-destination gate:** only requires the guard on FKs whose destination
  carries an `org_id`. `SameOrgFk` is a documented no-op against an org-less anchor
  (`:target_has_no_org_id`), so requiring it there would be a false positive — this
  mirrors the change's own semantics.
- **Coverage:** a bare `change Samen.Policy.SameOrgFk` (no `:relationships`) is `:all`
  coverage (the change's safe default); `{SameOrgFk, relationships: [...]}` covers the
  named FKs.

### Wiring — 21 FKs across 6 scopes (matches the gate's ~26 census)

Wired `change {Samen.Policy.SameOrgFk, relationships: [...]}` into the shared
blueprint macros (so every host inherits it):

| Scope | Resource → FKs wired |
|---|---|
| CRM | Person→[company]; Opportunity→[company, pipeline] |
| Marketing | Send→[subscriber, campaign, template]; EmailEvent→[send, subscriber]; Suppression→[subscriber] |
| CMS | Block→[page]; SeoMeta→[page, post] |
| Support | Ticket→[sla]; Csat→[ticket, agent] |
| Billing | Price→[plan]; Usage→[subscription]; Entitlement→[subscription, plan] |
| Identity | Membership→[user]; ApiKey→[membership] |

Marketing `Send` keeps its load-bearing inline suppression-time subscriber check; the
`SameOrgFk` change covers all three FKs uniformly (redundant-but-harmless on
`subscriber`) so the verifier passes by the same gated invariant every scope uses. A
live census (`SameOrgFk.violations()` over the demo's registered domains) returns
**zero** unwired FKs.

### SameOrgFk update-safety bug the wiring exposed (fixed)

Wiring `SameOrgFk` on `Identity.ApiKey` surfaced a latent bug: the change ran on
`revoke` (an update touching only `revoked_at`) and spuriously failed because
(1) `get_attribute(:org_id)` returns `%Ash.NotLoaded{}` on an update that doesn't
change org_id, and (2) it re-validated an FK not being written. Fixed in
`samen_core/lib/samen/policy/same_org_fk.ex`:
- `org_id_for/1` falls back to the persisted `changeset.data.org_id` when the
  changeset value is NotLoaded/nil.
- `fk_being_written?/2` narrows re-validation to FKs actually being written (always on
  create; on update only when `changing_attribute?`). A narrowing, never a widening —
  a same-org invariant established at write holds until the FK is rewritten. The F3.2
  create-time cross-org red paths still fail closed (confirmed live: 366 demo pass
  incl. the CRM cross-org-FK create red path).

### Tests + CI

- Red-path test: `samen_core/test/same_org_fk_verifier_test.exs` (7 tests) over
  fixture `samen_core/test/support/same_org_fk_fixture.ex` — an unguarded org-scoped
  `belongs_to` IS flagged (red path); a guarded one, a non-OrgScoped one, and the
  org-less-target case are NOT (positive controls). Fixture abbrevs `sfp/sfg/sfu/sfn`
  reserved in `priv/abbrev_registry.json`.
- Added as **step 14/14** in `demo/ci.sh`.

### Anti-tautology probe (F3.5)

Backed up `crm/blueprint.ex` to a project-local scratch dir, **removed the
Opportunity `SameOrgFk` change** (marked SABOTAGED), recompiled: `mix
samen.verify.same_org_fk` **flipped to exit 1** with 2 violations (Opportunity→company
+ →pipeline). Reverted from backup (diff identical, 0 SABOTAGED markers), removed the
scratch dir, re-ran → **exit 0**. Non-vacuous discriminator, confirmed.

---

## (b) F3.7 — filter/sort surface matches serialization surface

Set **`derive_filter?(false)`** in `Demo.Crm.Contact`'s `json_api` block
(`demo/lib/demo/crm.ex`). Before: `?filter[org_id]=…` (a public field kept OFF
`show_fields`) returned 200 and acted as a real predicate — a differencing side
channel over a de-allowlisted field. After: any `filter` param over a non-allowlisted
field is routed to an unused action argument and dropped — inert.

**Honest framework findings (documented in code + test):**
- **SORT** needs no flag: AshJsonApi's sort parser validates each `?sort=` field
  against `show_field?/2` and returns `InvalidSort` (**400**) for a non-allowlisted
  field — `?sort=org_id` is **already refused**. This is the "4xx red path" the task
  names, holding for sort.
- **Upstream bug noted:** `AshJsonApi.Resource.Info.derive_sort?/1` reads the mis-keyed
  option `:derive_sort` (not the DSL's `:derive_sort?`), so `derive_sort?(false)` is a
  no-op — but unnecessary, since show_fields already closes the sort surface. Left out
  and documented rather than shipped as a dead line.
- **FILTER** has no per-field validation, so `derive_filter?(false)` is the correct
  lever — it makes the filter value inert (proven by a two-value differencing probe:
  a would-miss and a would-hit filter return the SAME result set).

### Test + anti-tautology probe (F3.7)

`demo/test/api_filter_surface_test.exs` (3 tests): sort on a non-allowlisted field is
4xx (+ positive control that an allowlisted sort is 200); filter over a
non-allowlisted field is inert (differencing probe + non-empty-baseline positive
control). Probe: flipped `derive_filter?(false)` → `derive_filter?(true)` in a scratch
backup; the filter-inert test **flipped to failing** (miss=0, hit=1 — the field became
a live oracle). Reverted clean, scratch removed.

---

## (c) T3.13 flake — root-caused and deflaked (in our code)

The T3.13 report attributed an intermittent failure to `Core.Ctx.Activity.create`.
**That attribution was wrong.** Reproduced the flake (full samen_core suite, seed
1822): the actually-flaky module is **`Samen.NoPlaintextPii.Tiers.ObanJobsTest`**
(`test/oban_jobs_oracle_tier_test.exs`) — 3 tests failing with `got: []`. Two
independent bugs, both in our test code:

1. **Window race (intermittent half).** The module ran WITHOUT a sandbox — its
   `insert_test_job/3` committed straight to the shared `oban_jobs` table, and the
   oracle tier samples only the top-100-by-id rows **per queue** (`ORDER BY id DESC
   LIMIT 100` — a deliberate production seam). When concurrent async tests enqueued
   ≥100 higher-id `default`-queue jobs between the insert and the scan, the seeded row
   fell out of the window → `[]`.
   **Fix:** `Ecto.Adapters.SQL.Sandbox.checkout` + `{:shared, self()}` (the idiom
   `jobs_enqueue_in_tx_test.exs` uses). Inserts + scans run in the test's rolled-back
   transaction on the owned connection; the queue starts empty per test, the window
   deterministically contains the seeded row, and other tests' writes are invisible.

2. **Malformed jsonb (deterministic half, surfaced by the sandbox).**
   `insert_test_job` did `Jason.encode!(args)` then passed the STRING as `$2::jsonb`.
   Postgrex's jsonb extension JSON-encodes the Elixir term itself, so an
   already-encoded string was encoded a SECOND time — the column stored a jsonb STRING
   (`"{\"k\":…}"`), not an OBJECT. The tier reads `args::text` then `Jason.decode`s it
   → a bare string → empty arg map → the scan found NOTHING.
   **Fix:** pass the args **map** directly as the jsonb parameter (extension encodes it
   once). Verified: map-param stores `{"k": …}`; text-cast stored `"\"{\\\"k\\\":…}\""`.

3. **Anti-tautology test bug (surfaced once the tier actually ran).** The probe
   asserted the violation `detail` contains the literal plaintext email value — but the
   tier deliberately does NOT echo plaintext PII into a finding (it names the job id,
   arg key, and shape only). Rewrote the assertion to key on the PII job's id +
   `email-shaped` and to confirm the clean job's UUID arg produces NO violation (same
   key + worker across both jobs → proves discrimination on VALUE SHAPE).

**Result:** the module passes 11/11 deterministically; the full samen_core suite is
green across seeds 1822/100/137/911/424242 (previously 1822 flaked). No sleeps, no
quarantine — root cause was in our test helper + isolation, so it was fixed.

---

## Environment / gate results (run by me)

| Check | Result |
|---|---|
| root `bash ci.sh` | **exit 0 — ALL PASSED** (6 spikes + core + demo + 14-step demo gate) |
| `samen_core` `mix test --warnings-as-errors` | **637 passed** (9 properties, 628 tests) |
| `demo` `mix test --warnings-as-errors` | **366 passed** (17 properties, 349 tests) |
| `demo` `mix samen.verify.same_org_fk` | OK — no violations |
| F3.5 verifier red path (`same_org_fk_verifier_test.exs`) | 7 passed |
| F3.7 red path (`api_filter_surface_test.exs`) | 3 passed |
| deflaked module (`oban_jobs_oracle_tier_test.exs`) | 11 passed, 6× stress-run stable |

## Files changed / added

- **Added:** `samen_core/lib/mix/tasks/samen.verify.same_org_fk.ex`,
  `samen_core/test/same_org_fk_verifier_test.exs`,
  `samen_core/test/support/same_org_fk_fixture.ex`,
  `demo/test/api_filter_surface_test.exs`.
- **SameOrgFk wiring:** `samen_core/lib/samen/scopes/{crm,marketing,cms,support,
  billing,identity}/blueprint.ex`.
- **SameOrgFk update-safety fix:** `samen_core/lib/samen/policy/same_org_fk.ex`.
- **F3.7:** `demo/lib/demo/crm.ex` (`derive_filter?(false)` + rationale).
- **Deflake:** `samen_core/test/oban_jobs_oracle_tier_test.exs`.
- **Registry:** `samen_core/priv/abbrev_registry.json` (4 fixture abbrevs).
- **CI:** `demo/ci.sh` (step 14 = `same_org_fk`).
