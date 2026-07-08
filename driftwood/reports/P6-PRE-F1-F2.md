# P6 PRE — Gate-5 carries F1 + F2 landed on Driftwood (external surface + tenant-owner unmask)

- **Date:** 2026-07-07
- **Task:** Phase-6 PRE — burn down the two Gate-5 carry-to-P6 findings on the running
  Driftwood freight vertical:
  - **F1** — mount an AshJsonApi + webhook external surface over `Driftwood.Freight`
    (expose Driver + a `load.status` webhook through `/api/v1`); add freight-specific
    external-surface red paths; wire `api_contract` into `driftwood/ci.sh` with a committed
    `driftwood/api_contract.v1.json`.
  - **F2** — wire the tenant-plane `Samen.Api.PiiResolution` unmask into the broker-console
    reads so a TENANT sees its OWN driver CDL/name in clear per its RBAC (the doc's
    tenant-as-owner key class, no reveal grant), fixing the fail-safe over-masking; the
    operator plane stays masked.
- **Rule:** every guarantee ships a red-path (must-fail) test + an anti-tautology probe
  (project-local scratch, flip confirmed, reverted byte-identical). Keep root + driftwood
  `ci.sh` green; `mix test --warnings-as-errors` green.

---

## Green-before / green-after

- **Green-before:** `driftwood/ci.sh` = ALL PASSED (20 steps, exit 0). Root `bash ci.sh`
  came back with a single **pre-existing flake** in `samen_core`
  (`shred_key_material_test.exs:112` → `Vault.store_field` `{:error, :unavailable}` under a
  specific seed/interleaving — a KMS keystore availability race). It PASSES in isolation and
  on re-run (`samen_core` full suite = 768 passed), and is unrelated to this task (no
  `samen_core` code touched). Root CI green-after did NOT reproduce it (768 clean).
- **Green-after:** `driftwood/ci.sh` = ALL PASSED (exit 0). Root `bash ci.sh` = **ROOT CI:
  ALL PASSED** (exit 0): samen_core **768**, demo **399 + 48 gate**, driftwood **58 + 4
  adversarial** (was 47 + 4; +11 = 8 F1 + 3 F2 tests). `mix test --warnings-as-errors` green
  in every app; `mix compile --warnings-as-errors --force` clean in driftwood.

---

## F1 — external surface over freight

**Landed:**
- `Driftwood.Freight.Driver` — added `extensions: [AshJsonApi.Resource]`, a `json_api do
  show_fields([:id, :cdl_state, :cdl_expiry, :medical_card_expiry, :status, :eld_provider,
  :full_name, :cdl_number]) derive_filter?(false) routes … end` opt-in allowlist, and
  `preparations do prepare(Samen.Api.PiiResolution) end` (the two-key-class egress rule).
- `Driftwood.Freight.DispatchEvent` — `AshJsonApi.Resource` + a non-PII `show_fields`
  allowlist for the `load.status` webhook (status/dispatched_at/driver_id/load_id).
- `Driftwood.Freight.ApiKey` (abbrev **`dak`**) — the two-key-class credential
  (`token_digest` one-way digest `public?: false`, `plane`, `scopes`, `minter_role`,
  `minter_user_id`, `revoked_at`, injected `org_id`). Migration
  `priv/repo/migrations/20260708100000_freight_api_key.exs` creates `dak_api_key` +
  catalogs it in-tx (ADR-004). Registered in `samen_core/priv/abbrev_registry.json` +
  `driftwood/priv/abbrev_registry.json` (append-only; NO `samen_core` code changed).
- Web layer: `DriftwoodWeb.Api.{KeyAuthPlug, Router, Endpoint}` + a `forward("/api/v1",
  DriftwoodWeb.Api.Endpoint)` in `DriftwoodWeb.Router`. `Driftwood.Webhooks.{load_status,
  driver_updated}` emit via the shared `Samen.Webhook.Payload`.
- `api_contract.v1.json` regenerated (non-empty: Driver routes `/api/v1/drivers` +
  `/drivers/:id`, `cdl_number`/`full_name` as `Samen.Type.VaultField`); `ci.sh` step 13
  now diffs the real contract and fails on a structural break.

**Red paths (`test/api_external_surface_test.exs`, 8 tests, all green):**
1. OPERATOR JSON:API key — vaulted CDL ABSENT without a grant (never plaintext, never a
   `vt_` token, never the storage name `pii_drv_cdl_number`); PLAINTEXT with a live
   distinct-party grant (control).
2. Freight WEBHOOK — masked catalogued payload: `full_name` serializes `••••`, no
   plaintext CDL / vault token / storage-name key; `org_id` + the `custom` bag ABSENT
   (opt-in). `load.status` DispatchEvent payload is opt-in, catalog-named, non-PII; event
   type `load.status`, resource type `dispatch_event`.
3. TENANT JSON:API key — reads its OWN org's driver CDL + name in CLEAR (no grant); a
   cross-org tenant key sees zero foreign rows.
4. Actor-less request (no key) → zero rows (fail closed).

**Anti-tautology (project-local `.f1_scratch/`, removed):** forced `plane: :tenant` on
EVERY key in `KeyAuthPlug.build_actor/1` → the operator-absent red path FLIPPED to failing
(`operator key saw the vaulted CDL with no grant`, suite 7/8). Reverted; `key_auth_plug.ex`
md5 back to `257d987fb0f2e532c25d219eb5747f61` (byte-identical).

**Honest P6 finding (surfaced by the reference vertical):** `Samen.Webhook.Payload`'s
storage-name guard `~r/^[a-z]{3}_/` FALSE-POSITIVES on freight CATALOG names that begin
with a 3-letter token + underscore (`cdl_number`, `cdl_state`, `cdl_expiry`, `eld_provider`)
and silently DROPS them from the webhook body. This is OVER-STRICT (absent by omission,
never a leak) — the JSON:API surface (AshJsonApi serializer + `PiiResolution`, which does
NOT use this heuristic) renders CDL correctly. Flagged for the extraction retro (T6.1): the
webhook heuristic should key on the resource's declared storage prefix, not a blanket regex.
Not a `samen_core` code change in this task (never faked; the test asserts the fail-safe
absence + documents the finding inline).

---

## F2 — tenant-owner unmask in the broker console

**Landed:**
- `DriftwoodWeb.BrokerLive.broker_scope/1` — the tenant broker actor now carries
  `plane: :tenant` (+ a stable `:id`). OrgScope keys only on `org_id`, so isolation is
  unchanged.
- `Driftwood.Reads.driver_roster/1` — threads the scope through
  `Samen.Api.PiiResolution.resolve/4` (`repo: Driftwood.Repo`). On the `:tenant` plane the
  driver's own `full_name`/`cdl_number` are unmasked to PLAINTEXT through the single vault
  chokepoint; on the `:operator` plane (the impersonation scope's `plane: :operator` +
  `:impersonation` marker) the SAME resolver keeps them `%Masked{}` (`••••`). Fail-safe: a
  plane-less/org-less scope → default masked; a decrypt error → value stays masked.

**Red paths (`test/web_red_paths_test.exs` RED PATH 6, green):**
- a TENANT broker sees its OWN driver's CDL + name in CLEAR in the console (was `••••`);
- an OPERATOR impersonating the SAME org still sees `••••` (operator plane untouched);
- a CROSS-ORG tenant broker sees ZERO of the scenario org's drivers.
- `dogfood_walkthrough_test.exs` step 6 updated from the old over-masking assertion to the
  corrected tenant-owner-in-clear posture (operator step 7 still asserts `••••`).

**Anti-tautology (project-local `.f2_scratch/`, removed; reverted byte-identical, md5
`2abce259a1486d4b9ec001e0b85a2774`):**
- *tenant path:* made `resolve_pii/2` a no-op (never unmask) → the tenant-clear red path
  FLIPPED to failing (`tenant broker did not see its own driver's CDL in clear`, 8/9).
- *operator path:* forced `plane: :tenant` on every actor in `actor_of/1` → the
  operator-masked red paths (RED PATH 1/2 + the F2 operator test) FLIPPED to leaking
  `CDL-OK-` (6/9). Both reverted.

---

## Files touched

- `driftwood/lib/driftwood/freight.ex` (Driver json_api + PiiResolution prep; DispatchEvent
  json_api; new `Driftwood.Freight.ApiKey`; domain `AshJsonApi.Domain`)
- `driftwood/lib/driftwood/reads.ex` (F2 `resolve_pii`)
- `driftwood/lib/driftwood/webhooks.ex` (new)
- `driftwood/lib/driftwood_web/broker_live.ex` (`plane: :tenant`; moduledoc)
- `driftwood/lib/driftwood_web/router.ex` (`forward "/api/v1"`)
- `driftwood/lib/driftwood_web/api/{key_auth_plug,router,endpoint}.ex` (new)
- `driftwood/priv/repo/migrations/20260708100000_freight_api_key.exs` (new)
- `driftwood/api_contract.v1.json` (regenerated, non-empty)
- `driftwood/schema.dict.json` (regenerated: 12 tables incl. `dak_api_key`)
- `driftwood/priv/abbrev_registry.json` + `samen_core/priv/abbrev_registry.json`
  (append-only `dak` row; NO samen_core code)
- `driftwood/ci.sh` (step-13 comment)
- tests: `driftwood/test/api_external_surface_test.exs` (new),
  `driftwood/test/support/api_case.ex` (new), `driftwood/test/web_red_paths_test.exs`
  (RED PATH 6), `driftwood/test/dogfood_walkthrough_test.exs` (step 6 corrected)
- docs: `docs/claim-evidence.md` (E1–E4 + F1/F2 rows), `docs/gate-5-report.md` (fix-task status)
