# Gate-3 fixes — F3.6 (mandatory) + Housekeeping

**Date:** 2026-07-07
**Scope:** the one MANDATORY-IN-PHASE Gate-3 finding (F3.6) plus the Housekeeping item
from `docs/gate-3-report.md`. F3.5 and F3.7 are carry-to-P4 and NOT addressed here.

---

## F3.6 (MANDATORY) — webhook payload is now OPT-IN

### The finding

`Samen.Webhook.Payload.build_data/3` auto-published **all** `public?: true` attributes
minus storage-named minus PII — opt-OUT by pattern. This is the inverse of the vision
doc's opt-in mandate (`docs/samen-foundry.txt`, "The external surface"): "a resource's
columns are not auto-published to the API **or webhook surface** … a field absent from
that allowlist is absent from the payload by omission — the default is not-exposed." The
Tier-1 `custom` jsonb bag and `name`/`inserted_at`/`updated_at` were being auto-published.

### The fix

**Design choice: reuse the existing `show_fields` allowlist** (the AshJsonApi `json_api do
show_fields([…]) end` block), NOT a separate webhook-payload field declaration.

**Reasoning** (composes best with the T3.11 code):

1. `show_fields` is the SAME opt-in allowlist the public API surface already enforces
   (AshJsonApi filters the API payload through `show_field?`). Reusing it makes the
   webhook surface mirror the API surface field-for-field — they **cannot drift**.
2. `Samen.ApiContract.build_fields/1` already resolves `show_fields` defensively via
   `AshJsonApi.Resource.Info` (an OPTIONAL dep of samen_core — only host apps like `demo`
   carry it). The payload builder now uses the identical resolution path — one canonical
   allowlist source, no second declaration to keep in sync.
3. A dedicated webhook-payload declaration would let the two surfaces diverge silently —
   the exact drift Gate-3 F3.6 flagged. The doc's phrase "the json_api / webhook payload
   declaration names it" is satisfied by a SINGLE declaration (`json_api show_fields`).

**Behavior now** (`build_data/3`):

- A field is serialized ONLY IF its catalog name is on the resource's `show_fields`.
- A field absent from `show_fields` — INCLUDING the Tier-1 `custom` bag, `org_id`,
  `inserted_at`, `updated_at`, and any plaintext-at-rest column — is ABSENT by omission.
- A resource with no `show_fields` (or no AshJsonApi block) → EMPTY `data` map
  (fail-closed; nothing auto-published).
- Allowlisted PII still masks: `%Masked{}` → `"••••"`; nil/absent (operator-plane, no
  grant) → omitted; plaintext-in-PII-field → omitted (fail-closed). A defense-in-depth
  storage-name guard still drops any storage-named field that slips onto an allowlist.

### Files changed

| File | Change |
|---|---|
| `samen_core/lib/samen/webhook/payload.ex` | `build_data/3` now filters by the `show_fields` allowlist (new `allowlisted_fields/1`); moduledoc rewritten to describe the opt-in mechanism + the "why show_fields" rationale. |
| `samen_core/lib/samen/webhook.ex` | moduledoc delivery-guarantee bullet corrected to "opt-IN allowlisted masked payload (F3.6)". |
| `samen_core/test/webhook_payload_test.exs` | Rewritten: exercises the REAL `Payload.build/3` (no more inline re-implementation); in samen_core (no AshJsonApi) the allowlist is empty, so these 5 tests prove the FAIL-CLOSED path + encode + Masked encoder. Docstring corrected (no more "T3.11 allowlist enforcement" overclaim). |
| `demo/test/webhook_payload_allowlist_test.exs` | **New** — the F3.6 red paths against real Ash resources (`Demo.Crm.Contact`, the fixture below), where AshJsonApi + `show_fields` are loaded. 9 tests. |
| `demo/test/support/webhook_allowlist_fixture.ex` | **New** — `Demo.WebhookAllowlist.Widget`: a resource with a Tier-1 `:custom` bag AND a `show_fields([:id, :display_name])` allowlist that OMITS the bag, so the "custom bag absent" red path runs against a real resource. |
| `samen_core/priv/abbrev_registry.json` | Reserved abbrev `waw` for the fixture (the registry is permanent/collision-checked; the runtime-loaded registry is samen_core's `:code.priv_dir(:samen_core)`). |
| `samen_core/reports/T3.13.md` | Corrected the "T3.11 allowlist enforcement" overclaim → opt-IN; updated red-path table, new-files table, and status counts. |

### Red paths (F3.6) — all four required, all green

Against the real `Samen.Webhook.Payload.build/3` in `demo/test/webhook_payload_allowlist_test.exs`:

1. **A public non-PII field NOT on the allowlist is ABSENT** — `org_id` (Contact) and
   `internal_label` (fixture) are `public?: true` but off `show_fields` → absent. ✓
2. **The `custom` bag is ABSENT even when populated** — the fixture's `custom` bag is set
   to `%{"priority" => "high", "tenant_note" => "confidential"}` and does NOT appear. ✓
3. **An allowlisted field appears under its catalog name** — `display_name` (on
   `show_fields`) is present with its value (positive control → the "absent" assertions
   are non-vacuous). ✓
4. **Masked PII on the allowlist per plane rules** — allowlisted `full_name`/`emails`/`dob`
   as `%Masked{}` → `"••••"`; nil (operator-plane, no grant) → omitted; `include_masked:
   false` → omitted. ✓

Plus a fail-closed test: a resource with no `show_fields` (`Demo.Crm.Membership`) produces
an empty `data` map.

### Anti-tautology probe (HARD RULE 2)

Backed up `samen_core/lib/samen/webhook/payload.ex` to a project-local scratch dir OUTSIDE
`/tmp` (`.gate3_f36_scratch/`, since removed). **Sabotaged the allowlist filter**:
`allowlisted_fields/1` was rewritten to ignore `show_fields` and return ALL attribute names
(defeating opt-in → auto-publish everything). Re-ran `demo/test/webhook_payload_allowlist_test.exs`:

- **Red path (1) FLIPPED to FAILING** — the `internal_label` case failed (a public field
  off the allowlist appeared). (The `org_id` variant of RP1 stayed green because `org_id`
  is also caught by the defense-in-depth storage-name guard — confirming the belt works,
  while the `internal_label` case proves the ALLOWLIST itself is load-bearing.)
- **Red path (2) FLIPPED to FAILING** — the `custom` bag appeared.
- The fail-closed empty-data test also flipped to failing.
- The remaining 6 tests (positive controls + masking) stayed green.

Reverted from backup: `diff` identical, **0 `SABOTAGED` markers** in `lib/`, scratch dir
removed. **Result: the opt-in allowlist filter is a non-vacuous discriminator, not an
always-pass.**

---

## Housekeeping

1. **Removed stale scratch dirs** — `_probes/` (prior round's `org_scope.ex.bak` + a T3.6
   sabotage probe) and the empty `gate2_scratch/` deleted from the repo root.

2. **Webhook DeliveryWorker `unique` keys** — the Gate-3 note asked to align the `keys:`
   to the string form the moduledoc showed. **This is not possible:** Oban 2.23.0 rejects
   `keys: ["idempotency_key"]` at compile time (`ArgumentError: expected :keys to be a list
   of atoms`). The code's atom form `keys: [:idempotency_key]` is the ONLY valid form, so
   the correct alignment is the reverse: the **moduledoc was corrected** to show the atom
   form (and a note added that Oban requires atoms). No behavior change; the delivery test
   (`:idempotency_key in keys`) stays green.

---

## Verification

| Check | Before | After |
|---|---|---|
| root `bash ci.sh` | exit 0 (ALL PASSED) | exit 0 (ALL PASSED) |
| samen_core `mix test --warnings-as-errors` | 632 passed | **630 passed** (−2: payload test rework, 7→5; the 9 show_fields red paths moved to demo) |
| demo `mix test --warnings-as-errors` | 354 passed | **363 passed** (+9 F3.6 red paths) |
| samen_core intermittent flake | `Core.Ctx.Activity.create` (documented T3.13 timing flake) | unchanged — same pre-existing flake, unrelated to this fix (630/630 on deterministic seed 0; two clean full runs) |

### Caveats / honesty

- **The webhook surface is still not invoked by any host** (Gate-3's own MED rationale) —
  `Samen.Webhook.deliver/3` is a library entry point; no demo resource calls it. The fix
  hardens the load-bearing serialization boundary but does not change that no live payload
  is emitted today.
- **samen_core cannot host the show_fields red paths** — AshJsonApi is an optional dep and
  is NOT loaded in samen_core, so `AshJsonApi.Resource.Info.show_fields/1` is unavailable
  there and the allowlist resolves empty. The real red paths therefore live in `demo`
  (which carries AshJsonApi + real `show_fields` resources). The samen_core payload test
  now proves the fail-closed path instead. This is a genuine dep-boundary constraint, not
  a coverage gap: the demo tests exercise the exact production `build/3`.
- **Intermittent Activity flake** — the pre-existing `Core.Ctx.Activity.create` timing
  flake (documented in T3.13) still surfaces on some random seeds in the full samen_core
  run. It is unrelated to this fix (deterministic seed-0 runs and two of my full runs were
  clean at 630/630). Not introduced or worsened here.
- **F3.5 and F3.7 are NOT addressed** — they are Gate-3 carry-to-P4 items, out of scope
  for this mandatory-fix pass.
