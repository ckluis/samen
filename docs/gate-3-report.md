# GATE 3 — Phase-3 adversarial gate for `samen_core` (T3.14)

- **Date:** 2026-07-07
- **Gate:** Phase 3 adversarial review of the universal scopes (Identity + CRM/Billing/
  Marketing/CMS/Support/Primitives), the malleability ladder (Tier-0/1/2/3), and the
  external surface (public API + webhooks + `api_contract` verifier). Five attack lenses:
  cross-scope consistency, Tier-1/2 containment, API leak, webhook replay/forgery, doc parity.
- **Inputs:** all `samen_core/reports/T3*.md` + the scope-review + re-review reports, ADR-004,
  the scope-authoring guide, `docs/plan.md` §7 Phase 3, `docs/gate-2-report.md` carries, and the
  vision doc (`docs/samen-foundry.txt`) "The inherited 80%" (:309), "The proof — one base, many
  shapes" (:357), "The external surface" (:693), the malleability ladder (:93). Plus direct
  inspection + execution of code.
- **Gate rule applied (plan §6.4):** a refuted report claim or a false red-path is an automatic
  no-go. `go_with_caveats` is a **go only if** each caveat is a named in-phase fix task or an
  explicit, plan-sanctioned deferral.

---

## Verdict: **GO WITH CAVEATS**

Phase-3 is real and honestly reported. The seven universal scopes fully cover the vision doc's
object table; the malleability ladder is present on all four rungs; the external surface (versioned
API, two key classes, HMAC-signed webhooks, `api_contract` structural-break verifier) is built and
fail-closed; and the Gate-2 carries (F2.1 `oban_jobs` tier, F2.3 `metric_labels` CI wiring) landed.
Every headline PII-containment guarantee I attacked held: the operator-plane mask is a non-vacuous
discriminator (my sabotage flipped its red path), a tenant cannot read across the org boundary even
by explicitly filtering on `org_id`, filter-inference on vaulted fields is closed by construction
(the physical column is a vault token, not the plaintext), the Tier-1 containment rule and Tier-2
one-way boundary are structurally sealed, and the webhook HMAC/timestamp scheme rejects tampered
bodies and stale replays.

**No P0/P1 breach-class hole was found.** The one MANDATORY-IN-PHASE finding is a genuine
containment gap on a *not-yet-invoked* surface (the webhook payload serializer auto-publishes fields
rather than honoring the opt-in allowlist the doc mandates for **both** API and webhook surfaces).
The remaining caveats are cross-scope idiom drift and defense-in-depth notes — all bounded, none
re-architecture.

### Environment / gate results (run by me, not trusted from reports)

| Check | Result |
|---|---|
| `samen_core` `mix test --warnings-as-errors` | **632 passed** (9 properties, 623 tests) |
| `samen_core` `mix compile --warnings-as-errors --force` | exit 0, warning-clean (after my probe revert) |
| `demo` `mix test --warnings-as-errors` | **354 passed** (17 properties, 337 tests) |
| `demo` `MIX_ENV=test mix compile --warnings-as-errors --force` | exit 0, warning-clean |
| root `bash ci.sh` | **exit 0 — ALL PASSED** (6 spikes + core + demo + 13-step demo gate) |
| demo gate steps 1→13 (5 core verifiers + migrations + sink_schema + metric_labels + vault_declared_parity + tnt_catalog + tnt_boundary + api_contract) | all PASSED |

---

## My anti-tautology probe (HARD RULE 2)

Backed up `samen_core/lib/samen/api/pii_resolution.ex` to a self-created project-local scratch dir
OUTSIDE `/tmp` (`.gate3_antitaut_scratch/`, since removed). **Sabotaged the operator branch** of
`resolve_field/8` to reveal plaintext with NO grant check (the operator-plane mask bypass). Re-ran
`demo/test/api_two_key_classes_test.exs`: **the operator-absent red path FLIPPED to FAILING**
("operator key saw a vaulted field with no grant" — `full_name` appeared) while the tenant-clear
positive control and the other 5 tests stayed green (6/7). Reverted from backup (`diff` identical,
0 `SABOTAGED` markers), removed the scratch dir, re-ran → warnings-clean compile + 354 demo pass.
**Result: the operator-plane mask is a non-vacuous discriminator, not an always-pass.** (Additional
empirical probes below in Lens 3 were run in the demo test dir and removed.)

---

## Lens 1 — Cross-scope consistency (with the ladder + API landed on top)

### F3.5 (carry-to-P4, LOW-MED) — the `SameOrgFk` same-org-FK idiom is applied inconsistently, and nothing enforces it fail-closed

The F3.2 fix (scope-review) established `change {Samen.Policy.SameOrgFk, relationships: […]}` as a
**mandatory template item** — the scope-authoring guide checklist §10 says it belongs on "**every**
resource with a `belongs_to` FK." I tallied the actual wiring across all seven blueprints:

| Scope | `belongs_to` count | `SameOrgFk` wires |
|---|---|---|
| billing | 10 | 3 |
| crm | 9 | 2 |
| support | 6 | 2 |
| marketing | 6 | 0 (Send has a separate **inline** same-org check — the load-bearing case) |
| cms | 3 | 0 |
| identity | 2 | 0 |
| primitives | 0 | 0 |

The re-review named only CMS `Block`/`SeoMeta`; the drift is in fact **broader** — CRM `Person`/
`Opportunity`, Marketing `EmailEvent`/`Suppression`/`Send`(non-subscriber FKs), Support `CSAT`,
Billing `Price`/`Usage`/`Entitlement`, and Identity `Membership`/`ApiKey` all carry a `belongs_to`
with no `SameOrgFk` change. There is **no verifier** that enforces the rule, so the guide-vs-code
drift is silent (I grepped `lib/mix/tasks` + `lib/samen/verifiers` — nothing checks it).

**Why this is a caveat, not a breach:** the F3.2 review already established that a cross-org FK write
is **NOT a PII-read breach** — `Samen.Policy.OrgScope`'s read-filter still makes foreign-org rows
invisible (I re-confirmed live: a tenant filtering `?filter[org_id]=<other-org>` gets `data_count=0`).
The one FK write with real impact — Marketing `Send` → foreign subscriber (a suppression-list bypass)
— IS closed, via the inline check in `create_checked` (I confirmed it present). The residue is
cross-tenant *referential pollution* (dangling FKs) with no PII read and no suppression bypass.

**Fix (carry-to-P4):** this matters most in Phase 4 when the operator plane's cross-tenant reach goes
live. Either (a) wire `SameOrgFk` on the remaining tenant-plane `belongs_to` FKs per the guide, or
(b) — stronger — add a Spark verifier / mix task that fails closed when a tenant-plane org-scoped
resource declares a `belongs_to` with no matching `SameOrgFk` change (turning the guide rule into a
gated invariant, the same move F3.1 made for de-vaulting). (b) is the durable fix; the drift recurs
without it. Add a red-path test per remaining scope (only CRM + Marketing have cross-org-FK red paths
today — a Support/Billing regression would go uncaught, matching re-review residue #2).

### Cross-scope idioms that HELD (I checked, they held)

- **Object coverage** — all seven scopes define every object in the doc's scope table (Identity 6 +
  audit; CRM 6; Billing 8; Marketing 7; CMS 7; Support 7; Primitives 5 + audit). No missing noun.
- **PII routing / vault** — the `pii do` + `%Masked{}` default + `vault_declared_parity` (C6, F3.1)
  are consistent across scopes; the scalar-PII column name `pii_<abbrev>_<name>` prose drift (F3.3)
  is corrected (grep confirms no `[abbrev]_pii_` prose remains).
- **Audit-rides-`aud_event`** — no scope defines its own `aud_*` table (ADR-004 §5 honored;
  the ladder's `Samen.Context` also contributes writers only, per T3.10).
- **CMS split-policy divergence** (F3.4) — the member-edit / admin-publish split is an explicitly
  documented intentional choice in the blueprint moduledoc + guide §7, not silent drift.

---

## Lens 2 — Tier-1/2 containment (escape the jsonb zone)

**The containment held under every probe I ran.** The one-way boundary and the sealed-bag design are
structural, not heuristic:

- **PII smuggling past the value-shape gate** — Tier-1 `classify_containment/2` rejects a PII-shaped
  *string* on a non-`pii_declared` field (fail-closed default). A nested map/list value is rejected
  earlier by `type_ok?` (the bounded scalar types don't accept structures). **Documented seam I
  confirmed:** the shape check only guards `is_binary/1`, so a numeric-typed PII value (e.g. a 9-digit
  SSN in an `:integer` field) passes — but this is exactly the `Samen.PiiValueShape` "heuristic, not a
  taint proof" bound the doc and the T3.8 report already stake ("System is provable; tenant is
  best-effort"). Not a new hole.
- **Reach system tables from `tnt_record`** — no path. `tnr_refs` are validated OPAQUE IDs (not Ash
  relationships, not FKs); the compile-time `Samen.Verifiers.TntBoundary` fails the build if any
  system resource declares a relationship whose destination is `Samen.CustomObjects.Record`, and the
  whole-app `mix samen.verify.tnt_boundary` sweep (demo gate step 12) asserts no FK targets a
  tenant-regime table in either direction. The T3.9 report's probe 3 (a `use Samen.Resource` offender
  fails compile) is genuine; the sweep is green in my root-CI run.
- **Custom field name influences a policy/query (injection via field names)** — no. `tnt_field_name`
  is stored and used only as a jsonb bag *key string*; it never becomes an atom (except
  `String.to_existing_atom` on the bounded `tnt_type`, whose values are all pre-existing atoms from a
  closed set), never a SQL identifier, never an evaluated expression. A field named `'; DROP TABLE`
  is inert data.
- **The one-way boundary is structurally sealed** — the single physical `tnt_record` table keyed by
  object (no runtime DDL), plus fail-closed validated-at-write, plus the no-FK-either-direction scan.

---

## Lens 3 — API leak

### F3.6 (MANDATORY-IN-PHASE, MED) — the webhook payload serializer auto-publishes fields (opt-OUT), violating the doc's opt-IN allowlist mandate for the webhook surface

The doc (`:711`) is explicit that the allowlist is the load-bearing control on **both** surfaces:
"a resource's columns are not auto-published to the API **or webhook surface**. Each field is an
explicit opt-in into the public allowlist (the json_api / **webhook payload declaration** names it);
a field absent from that allowlist is absent from the payload by omission — the default is
not-exposed."

The **API** honors this: `Demo.Crm.Contact` declares `show_fields([…])` and AshJsonApi filters every
field through `show_field?` (I confirmed a non-allowlisted public field like `org_id` and the
plaintext `notes` column are ABSENT from the payload). But the **webhook** does NOT. `Samen.Webhook.
Payload.build_data/3` iterates **all** `public?: true` attributes and includes each unless it looks
like a storage name (3-letter-abbrev prefix / `pii_`) or is a declared PII attribute. That is
**opt-out by pattern**, the exact inversion of the doc's opt-in mandate.

**Proven empirically** (probe against the real `SamenCore.Support.CustomFields.Widget` resource,
removed after):

```
widget public attributes:  [:name, :custom, :id, :org_id, :inserted_at, :updated_at]
webhook data map (auto-published): %{"custom" => …, "id" => …, "inserted_at" => …,
                                     "name" => …, "updated_at" => …}
```

The **`custom` Tier-1 jsonb bag was auto-published verbatim into the webhook payload** — including
any field a tenant declared `pii_declared: true` (accepted plaintext-in-bag). `org_id` was excluded
only incidentally (its `org_` prefix matches the storage-name regex). A host attribute that is
`public?: true`, not PII-declared, and not 3-letter-prefixed will silently appear on the outbound
contract — the "newly added storage column never silently appears" property the doc stakes is
**false for the webhook surface**.

**Why this is MED and not a P0/P1 breach:** `Samen.Webhook.deliver/3` is a library entry point — **no
host resource calls it today** (I grepped `demo/lib` + `samen_core/lib`; only the module's own
plumbing references it). So no live payload leaks now. But the payload builder is the **load-bearing
serialization boundary** for the webhook surface, and it (a) contradicts the doc's explicit "webhook
surface" opt-in claim, (b) diverges from the sibling API surface it is supposed to mirror, and (c) the
T3.13 report + `Samen.Webhook.Payload` moduledoc + the payload test's own docstring all claim "T3.11
allowlist enforcement" — an over-claim, since the mechanism is opt-out, not the T3.11 opt-in
allowlist. No test guards the opt-in property (the test only checks storage-named + non-public
exclusion), so the leak is uncaught.

**Fix (MANDATORY-IN-PHASE):** make the webhook payload honor an explicit opt-in allowlist — either
reuse the resource's `show_fields` (the AshJsonApi allowlist) or add a dedicated webhook-payload
field declaration; a field absent from it is absent from the payload. Add a red-path test: a
`public?: true` non-PII field NOT on the allowlist (and specifically the `custom` Tier-1 bag) must be
ABSENT from the webhook payload. At minimum, if the opt-in switch is deferred, downgrade the T3.13
report + `Samen.Webhook.Payload` moduledoc + the payload test docstring to state precisely that the
webhook serializer is opt-out-by-pattern (public-minus-storage-minus-PII), NOT the T3.11 opt-in
allowlist — and file the opt-in switch as a P4 item. The opt-in switch is strongly preferred: this is
the doc's explicitly-staked "webhook surface" property.

### F3.7 (carry-to-P4, LOW) — `derive_filter?`/`derive_sort?` default to true; a non-allowlisted public field is filterable/sortable even though absent from the payload

AshJsonApi's `derive_filter?` and `derive_sort?` default to `true`, and `Demo.Crm.Contact`'s
`json_api` block does not set them false. I confirmed live that `?filter[org_id]=…` (a public field
NOT in `show_fields`) returns **200** (the allowlist governs *serialization*, not the *filter/sort
surface*). This is not a disclosure of the field's value in the body (the allowlist still omits it),
and the OrgScope FilterCheck defends the load-bearing case (a cross-org `?filter[org_id]=<other>`
returns zero rows — confirmed). But a field a host keeps off `show_fields` for sensitivity reasons can
still be used as a **filter/sort predicate**, a side channel the doc's allowlist claim doesn't
address. **Fix (carry-to-P4):** default `derive_filter?: false`/`derive_sort?: false` on the
scope/API resources (or restrict the filter/sort surface to the allowlisted fields) so the filter
surface matches the serialization surface. Low severity — no value leaks and OrgScope defends
cross-org.

### API leaks that HELD (I tried, they held)

- **Storage-name / vault-structure leakage through errors** — a client filtering on a storage name
  (`?filter[pii_cnt_dob]=…`) gets a generic `{"code":"something_went_wrong"}` 400; the storage name
  (`No such field pii_cnt_dob`) appears only in the **server log**, never the client body. Fail-safe.
- **Operator-key mask via filter-inference on a vaulted field** — CLOSED by construction: filtering on
  a vault-routed field (`?filter[dob]=…`) returns 400 because the physical column holds a vault token,
  not the plaintext value — there is no plaintext to match, so no hit/miss binary-search channel.
- **Storage names in the serialized body** — the API regex sweep (T3.11) + the `show_field?` filter
  never emit `cnt_*`/`pii_*`/`vt_*`; masked PII serializes `••••`; operator-without-grant is absent
  (`%Ash.ForbiddenField{}`), proven non-vacuous by my sabotage above.
- **Contract snapshot leakage** — `api_contract.v1.json` records catalog field names + AshJsonApi
  types + routes; no storage names or vault routing (I inspected the snapshot format via T3.12).

---

## Lens 4 — Webhook replay / forgery

**All genuine; the HMAC/timestamp scheme held.** I re-read `Samen.Webhook.{Signer,DeliveryWorker}`
and cross-checked against the T3.13 anti-tautology probe:

- **Forgery / tampering** — `verify/4` recomputes `HMAC-SHA256(secret, "<ts>.<body>")` and
  constant-time compares (`secure_compare/2`, XOR-accumulate). The T3.13 probe (neuter
  `secure_compare` → constant `true`) flipped the tampered-body + wrong-secret tests to failing —
  the HMAC gate is the load-bearing check, not a tautology.
- **Replay** — `check_timestamp/2` rejects a timestamp outside the ±tolerance window (default 300s)
  **and** rejects future-dated timestamps (`age >= 0`, so a forged far-future ts that would never
  expire is refused), independent of the HMAC result. The T3.13 probe confirmed the stale-ts tests
  still pass even with the HMAC gate bypassed (the two checks are independent). Within-window replay
  is the documented Stripe-model bound — receiver-side event dedup is the idempotency key's job.
- **Idempotency-key race / DLQ poison** — the outbound job uses `unique: [fields: [:args], keys:
  [:idempotency_key], period: 86_400]`; a redelivery of the same event within 24h is a no-op insert.
  DLQ is Oban's built-in `:discarded` state after `max_attempts: 20` (capped exponential backoff);
  `{:discard, …}` is returned for a shredded/deleted endpoint (org erasure) so a poisoned job doesn't
  retry forever. The signing secret is revealed from the vault **at delivery time only** (never in
  job args — the F2.1 token-only-args convention), and the body is frozen at enqueue (no TOCTOU).
- **F2.1 `oban_jobs` tier** — landed in `default_tiers/0`; CI-mode shape-lints job arg values and
  post-shred scans a subject's `args/errors/meta`. Documented in the tier map. (Sampling-not-
  exhaustive seam honestly noted in the T3.13 report.)

**Minor note (not a finding):** the delivery worker's `unique` option uses `keys: [:idempotency_key]`
(an atom) while the moduledoc/report show `["idempotency_key]"` (a string); Oban resolves both
against the JSON args, and since a redelivery's full args are identical the dedup holds regardless.
No behavior gap — worth a one-line consistency touch when F3.6 is addressed.

---

## Lens 5 — Doc parity + Gate-2 carry-forward

### Gate-2 carry-forwards — status

| Item | Status |
|---|---|
| **F2.1** (`oban_jobs` token-only-args oracle tier) — carried to P3 | **LANDED** (T3.13): `ObanJobs` in `default_tiers/0`, CI + post-shred modes, tier-map documented, red paths + anti-tautology in `oban_jobs_oracle_tier_test.exs`. |
| **F2.3** (wire `metric_labels` into CI) — carried to P3 | **LANDED**: `mix samen.verify.metric_labels` is demo/ci.sh step 9 (3 references). |
| **F2.2** (J2 runtime-value-guard honesty) — mandatory-in-Gate-2 | Landed in Gate-2 fixes; not re-litigated here (Phase-2 surface). |

### Doc-vs-implementation parity (verified against the vision doc)

- **"The inherited 80%" scope table (:309)** — all seven scopes present with every object; 🔒 objects
  (user, invitation, person, customer, subscriber, message, agent, notification, webhook) vault-routed;
  operator plane deferred to P4 (correct — the objects exist, the operator paths are T4.x).
- **"The proof — one base, many shapes" (:357)** — the blueprint packaging (ADR-004) lets a host
  inherit a scope without a per-host fork; the demo mounts all seven; single-table composition + no
  `INHERITS` held since Phase 0/1.
- **The malleability ladder (:93)** — all four rungs present: Tier-0 config rows (14 scope refs),
  Tier-1 custom fields (T3.8), Tier-2 custom objects (T3.9), Tier-3 `Samen.Context` (T3.10). The top
  rung is a context boundary, as the doc states.
- **"The external surface" (:693)** — versioned `/api/v1` (✓), schema-diff `api_contract` structural
  break test (✓ C6, semantic breaks correctly out-of-scope), two key classes with plane-scoped
  masking (✓), Oban-backed at-least-once webhooks with capped backoff + DLQ + per-event idempotency +
  HMAC body+timestamp (✓). The **one parity break** is the serialization boundary: the doc stakes an
  opt-in allowlist for the **webhook** surface too, but the webhook serializer is opt-out (F3.6).

### Housekeeping (LOW) — leftover scratch dirs from prior rounds

`_probes/` (contains `org_scope.ex.bak` + a T3.6 sabotage probe script, dated Jul 6 — a prior round's
residue, not mine) and an empty `gate2_scratch/` remain at the repo root. My own gate-3 probe scratch
(`.gate3_antitaut_scratch/`) and demo probe test files were removed and verified clean (0 `SABOTAGED`
markers in `lib/`). Recommend deleting the stale `_probes/` + `gate2_scratch/` for hygiene.

---

## Fix tasks

1. **[F3.6 · MANDATORY-IN-PHASE · MED]** Make `Samen.Webhook.Payload` honor an explicit opt-in
   allowlist (reuse `show_fields` or add a webhook-payload field declaration) so a field absent from
   the allowlist — including the Tier-1 `custom` bag — is ABSENT from the webhook payload, matching the
   doc's "webhook surface … default is not-exposed" mandate and the sibling API surface. Add a
   red-path test (a public non-PII field NOT on the allowlist, and the `custom` bag, must be absent).
   If the switch is deferred, downgrade the T3.13 report + `Payload`/test docstrings to state precisely
   that the webhook serializer is opt-out-by-pattern (not the T3.11 opt-in allowlist) and file the
   switch as a P4 item — but the opt-in switch is strongly preferred (it is a doc-staked property).

2. **[F3.5 · carry-to-P4 · LOW-MED]** Close the `SameOrgFk` cross-scope drift. Preferred: add a
   verifier that fails closed when a tenant-plane org-scoped resource declares a `belongs_to` with no
   matching `SameOrgFk` change (turns the guide rule into a gated invariant). Otherwise wire
   `SameOrgFk` on the remaining `belongs_to` FKs (CMS Block/SeoMeta, CRM Person/Opportunity, Marketing
   non-Send FKs, Support CSAT, Billing Price/Usage/Entitlement, Identity Membership/ApiKey) and add a
   cross-org-FK red-path test per scope. Matters most when the operator plane's cross-tenant reach goes
   live in P4. Not a PII breach today (OrgScope read-filter holds; the load-bearing Marketing
   suppression bypass is closed by the inline check).

3. **[F3.7 · carry-to-P4 · LOW]** Default `derive_filter?: false`/`derive_sort?: false` (or restrict
   the filter/sort surface to allowlisted fields) so the API's filter/sort surface matches its
   serialization surface — a field kept off `show_fields` should not be usable as a filter/sort
   predicate. No value leaks today (allowlist omits the field from the body; OrgScope defends
   cross-org), so low severity.

4. **[Housekeeping · LOW]** Remove the stale `_probes/` and `gate2_scratch/` scratch dirs left by
   prior rounds; optionally align the webhook worker's `unique` `keys:` to the string form shown in
   its own moduledoc (no behavior change).

---

## Gate decision

**GO WITH CAVEATS.** Phase-3 delivers the seven universal scopes (full doc-table coverage), the
four-rung malleability ladder, and the external surface — all fail-closed where the doc stakes a
guarantee, with red-path tests, and the load-bearing PII-containment claims survived adversarial
probing plus my own non-vacuity sabotage of the operator-plane mask. Gate-2 carries F2.1 and F2.3
landed. The one mandatory-in-phase fix (F3.6) is a real containment gap on the webhook serialization
boundary — but on a surface no host invokes yet, and the sibling API surface already implements the
correct opt-in allowlist, so it is a contained fix (wire the allowlist + a red-path test) plus a
report/doc honesty downgrade, not re-architecture. The remaining caveats (F3.5 cross-scope
`SameOrgFk` drift, F3.7 filter/sort surface, housekeeping) are bounded, honest, and mostly P4-natural
(they bite when the operator plane goes cross-tenant). Proceed to Phase 4 once F3.6 lands (opt-in
switch or an honest downgrade + a filed P4 item).
