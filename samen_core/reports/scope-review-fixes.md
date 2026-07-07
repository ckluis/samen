# Scope cross-scope review — mandatory fix round (T3.14 → fixes)

- **Date:** 2026-07-06
- **Scope:** the four mandatory fixes from the T3.14 cross-scope adversarial review
  (`reports/T3.14-crossscope-review.md`, verdict PARTIAL). One bounded pass.
- **Environment (re-run, not trusted):**
  - `samen_core` `mix test --warnings-as-errors`: **515 passed** (9 properties) — was 508, +7 (new C6 verifier test).
  - `demo` `mix test --warnings-as-errors`: **309 passed** (17 properties) — was 300, +9 (F3.1 + F3.2 red paths).
  - root `bash ci.sh`: **ALL PASSED** — the demo verifier gate is now **10 steps** (added
    step 10 `samen.verify.vault_declared_parity`).

---

## F3.1 — free-text-🔒 de-vault escapes the verifier gate → CLOSED

**Fix (both options landed):**

- **New verifier C6** `mix samen.verify.vault_declared_parity`
  (`samen_core/lib/mix/tasks/samen.verify.vault_declared_parity.ex`). It reads the
  **DB truth**: every physical column on a Samen-managed table whose name matches
  `^pii_[a-z]{3}_` (the scalar-vault storage shape `MaterializePii` emits) must have a
  matching declared `pii_attribute` route (`Samen.Pii.Info.vault_routed_columns/1`). A
  `pii_*` column left in the DB while the resource dropped its route is a fail-closed
  `de-vaulted PII column` violation — exactly the mismatch the T3.14 de-vault probe
  exploited (`pii_smg_body` in the DB, route gone, whole gate stayed green). Fail-closed
  on empty resource discovery (vacuous check must not pass). Wired into `demo/ci.sh` as
  step 10.
- **Doc downgrade.** scope-authoring guide §5 now states precisely that the gate enforces
  vault *consequences* (not the presence of a `pii do` declaration), that `pii_classify`
  does NOT guard a free-text 🔒 field whose logical name is not a heuristic token, and that
  the authoritative removal red paths are (a) the new C6 verifier and (b) the scope's
  `*_vault_routing_test.exs`. The Support blueprint moduledoc's over-claim ("fully enforced
  by pii_reads, no_plaintext_pii, and pii_classify") and the Primitives moduledoc were
  corrected to the same precise language.

**Red-path tests (de-vaulted body/secret is caught):**
- `samen_core/test/verify_vault_declared_parity_test.exs` (7 tests): unit + exit-code de-vault
  red paths, the route-dropped-column-still-in-DB mismatch, fail-closed-on-empty, allow-list.
- `demo/test/support_scope_vault_routing_test.exs`: de-vaulting `message.body`
  (`smg_message.pii_smg_body`) is caught.
- `demo/test/primitives_scope_vault_routing_test.exs`: de-vaulting `webhook.signing_secret`
  (`pwh_webhook.pii_pwh_signing_secret`) and `notification.rendered_body`
  (`pnt_notification.pii_pnt_rendered_body`) are caught.

**Anti-tautology probe (project-local scratch, reverted):** neutered `check/3` to return no
violations → the 3 verifier red-path tests (unit, exit-code, mismatch) flipped to FAILING while
green-path/control/allow-list stayed green. Reverted → 7/7 green.

## F3.2 — cross-org FK writes (foreign-org reach on WRITE) → CLOSED

**Fix:**

- **Marketing `Send.create_checked`** (`marketing/blueprint.ex`): a same-org FK check runs
  BEFORE the suppression query — it loads only the referenced subscriber's `org_id` (bounded
  UUID, no PII; via a bare repo query, NOT `Ash.read`, so OrgScope doesn't hide the foreign
  target) and refuses the send if it ≠ the send's org. An org-A actor can no longer enqueue a
  send to an org-B subscriber (which bypassed org B's suppression list).
- **Reusable `Samen.Policy.SameOrgFk` change** (`policy/same_org_fk.ex`), wired into the
  tenant-plane FK-bearing creates via a `changes` block: CRM `Activity`/`Attachment` (company,
  person, opportunity), Support `Message` (conversation, agent) / `Conversation` (ticket),
  Billing `Subscription` (customer, plan) / `Invoice` (customer, subscription) / `Payment`
  (invoice, customer). Same mechanism: read the target's org_id directly, refuse on mismatch.
- **Guide + template:** scope-authoring guide §3 documents the same-org-FK residue and adds the
  `change {Samen.Policy.SameOrgFk, …}` requirement to the checklist.

**Red-path tests (org-A row referencing an org-B FK refused):**
- `demo/test/marketing_scope_policy_matrix_test.exs`: org-A send → org-B subscriber refused
  (cross-org FK), + no send row created, + positive control (same-org send succeeds).
- `demo/test/crm_scope_policy_matrix_test.exs`: org-A activity → org-B person refused, +
  positive control.

**Anti-tautology probes (reverted):**
- Neutered `SameOrgFk.change` to a no-op → CRM cross-org red path flipped to FAILING
  (org-A→org-B activity succeeded), positive control stayed green. Reverted → green.
- Neutered the Marketing Send inline check (`subscriber_org_id = org_id`) → Marketing cross-org
  red path flipped to FAILING. Reverted → green.

## F3.3 — scalar-PII column-name prose drift → CORRECTED (docs only; runtime already canonical)

Corrected to the canonical `pii_<abbrev>_<name>` uniformly:
- Billing `bcu_pii_billing_name/email` → `pii_bcu_billing_name/email`
  (`billing/blueprint.ex` PII-map + inline comment + storage-discipline; `billing.ex` mount doc).
- Marketing `msu_pii_email` → `pii_msu_email` (`marketing/blueprint.ex` PII-map + storage
  discipline + inline comment; `marketing.ex` mount doc).
- Support `smg_pii_body` → `pii_smg_body` (`support/blueprint.ex` line-69 storage-discipline +
  inline comment, resolving the self-contradiction with the file's own PII-map table;
  `support.ex` mount doc `<abbrev>_pii_body` → `pii_<abbrev>_body`).
- Verified no remaining `[abbrev]_pii_` column drift in `lib/samen/scopes/`.

## F3.4 — CMS divergence from the split-read/split-write idiom → CORRECTED + DOCUMENTED

- **CMS `Block`** first policy changed from `action_type([:read, :create, :update, :destroy])`
  to `action_type(:read)` — matching the split-read-only/split-write idiom (the write
  action_types were redundant since Ash ANDs matching policies; not a hole, now clean).
- **CMS `Page`/`Post`** member-level content `:update` vs admin-gated `:publish`/`:archive`
  divergence is now an **explicit documented choice** in `Samen.Scopes.Cms.Blueprint`'s
  moduledoc and in scope-authoring guide §7 (content-edit vs Tier-0-transition split), rather
  than silent drift.

---

## Residues / seams (honest)

- `SameOrgFk` reads the target's org_id with a bare `repo.query` inside a `before_action`. It is
  read-committed against the same transaction; a concurrent org-change of the target between the
  check and commit is out of scope (org_id is effectively immutable in these scopes — no action
  updates it). Documented here, not silently assumed.
- C6 keys on the scalar-vault storage shape `^pii_[a-z]{3}_`. Composite PII (FullName/Emails/
  Phones) route by vault name with NO `pii_` prefix and are deliberately outside C6 — they remain
  covered by the per-scope vault-routing tests + C3/C5. This is stated in the C6 moduledoc.
- Broad `SameOrgFk` wiring covers the FK-bearing creates named in the review + the load-bearing
  Billing chain; Billing `Price`/`Usage`/`Entitlement` (config/derived rows referencing plan/
  subscription) were not wired this pass — same-org for those is lower-risk (no suppression-style
  bypass) and the reusable change + template note make adding them mechanical.
