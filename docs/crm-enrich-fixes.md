# CRM enrichment — gate fix round (ADR-011)

**Date:** 2026-07-08
**Inputs:** `docs/gate-crm-enrich.md` (GO WITH CAVEATS — C1 mandatory, C2/C3 nice-to-have).
**Outcome:** all three fix tasks landed at the FRAMEWORK level (`samen_web`) or as vertical
proof (PawChart), every suite + ci.sh green before and after. `samen_core` code untouched
(only append-only abbrev-registry rows).

---

## FIX 1 (MANDATORY) — cold-start 500 on `/marketing/campaigns` + `/marketing/segments`

**Root cause (confirmed from the gate):** `Samen.Web.Mount.from_session/1 → atomize_labels/1
→ safe_label_key/1` called `String.to_existing_atom("crm_namespace")` on a deserialized label
key. The atom `:crm_namespace` was minted ONLY as a literal inside `LeadsLive`, so on a cold
BEAM it did not yet exist as an atom until `LeadsLive` had loaded — the first visitor to
campaigns/segments after a restart got a 500 (`ArgumentError` at `mount.ex:131`).

**Fix (framework, load-order-independent).** In
`samen_web/lib/samen/web/mount.ex`, made label-key atomization NOT depend on load order by
whitelisting the bounded, framework-owned label-key set as compile-time atom literals:

- Added `@label_keys` (a `~w(...)a` list of the 24 framework label keys — `crm_namespace`,
  `crm_path`, `crumb_root`, `title`, `glyph`, `operator_org_id`, `operator_title`,
  `operator_workspace`, `operator_glyph`, `aggregate_loader`, `otp_app`, `user_name`, … —
  collected by grepping every `Mount.label(…, :key, …)` / `%{key: …}` label site across
  `samen_web/lib` + host routers).
- `@label_key_strings` maps each key's string form → the atom. Because the atoms are literals
  in this ALWAYS-loaded module, they are resident in the atom table in ANY deserializing
  process, independent of which LiveView loaded first.
- `safe_label_key/1` now resolves a binary via the whitelist map first; an unknown key (never a
  framework label — i.e. cookie-injected garbage) still falls through to
  `String.to_existing_atom/1`, which REJECTS a never-compiled string rather than minting an
  atom from session input. So the security posture (no atom minting from cookies) is preserved.
- Exposed `Mount.label_keys/0` (used by the regression test to round-trip the full set).

**Verified live — 200 COLD on a fresh BEAM.** Booted Driftwood on a fresh port (4034), hit
campaigns + segments FIRST (before ever loading `/marketing/leads` — the exact order that
previously 500'd):

```
COLD  /marketing/campaigns  -> 200   (renders "Campaigns")
COLD  /marketing/segments   -> 200   (renders "Audience segments")
THEN  /marketing/leads      -> 200
```

Content-checked (not just status): the campaigns page renders `Campaigns`, segments renders
`Audience segments` — real renders, not error pages.

## FIX 2 (MANDATORY) — session round-trip regression test

New `samen_web/test/samen/web/marketing_session_roundtrip_test.exs` catches the cold-start
atom bug in CI. The established `render_live/3` harness assigns an already-built `%Mount{}` and
calls `load/*` directly — it NEVER calls the LiveView `mount/3`, so the crashing
`mount/3 → assign_mount → from_session → atomize_labels` path was uncovered. The new suite
drives that EXACT path:

- `CampaignsLive.mount/3` and `SegmentsLive.mount/3` (plus `LeadsLive.mount/3`) are called with
  a session built by `Mount.to_session/1` carrying `crm_namespace: Samen.WebTest.Crm` (mirroring
  how Driftwood wires the Marketing mount), asserting `{:ok, socket}` (a 200) and that the CRM
  namespace survived the round-trip.
- Two `Mount`-level unit tests assert the invariant directly: `from_session/1` resolves the
  `crm_namespace` key (and the FULL `Mount.label_keys/0` set) to ATOMS via the whitelist.

`samen_web`: **107 passed** (was 102 — 5 new tests), `--warnings-as-errors` clean.

## FIX 3 (NICE-TO-HAVE, C3) — PawChart: seed CRM activities + mount `:marketing`

Fully proves the outreach/consent surface reuse on the SECOND vertical (the gate's C3 flagged
`tl-empty` for the sampled clinic contact and no `:marketing` mount for PawChart).

- **CRM activity seeds** — `pawchart/lib/pawchart/seeds.ex`: `seed_crm_activities/2` (mirrors
  Driftwood) seeds 3 clinic-flavored activities per contact (call/email/note/meeting/task,
  completed). The inherited timeline now renders `tl-rail` (populated) instead of `tl-empty`.
- **Marketing mount** — the samen_core Marketing scope mounted for the clinic with ZERO
  PawChart LiveView code:
  - `pawchart/lib/pawchart/marketing.ex` — new `PawChart.Marketing` domain (`use
    Samen.Scopes.Marketing`, fresh `vm*` abbrevs `vmc/vmg/vms/vmt/vmn/vme/vmp`).
  - `samen_core/priv/abbrev_registry.json` — 7 append-only `vm*` rows (the ONLY sanctioned
    kernel change; append-only at the tail after the `wm*` block).
  - `pawchart/priv/repo/migrations/20260709120000_mount_marketing_scope.exs` — the `vm*` tables
    (copied+remapped from Driftwood's marketing migration; `pii_vms_email` vault column;
    Suppression created BEFORE Send; `catalog_sync` in the same tx).
  - `pawchart/config/config.exs` — `PawChart.Marketing` registered in both `ash_domains` lists.
  - `pawchart/lib/pawchart_web/router.ex` — `samen_module_routes(:marketing, PawChart.Marketing,
    …, labels: %{crm_namespace: PawChart.Crm})` (Leads lens over `PawChart.Crm.Person`).
  - `pawchart/schema.dict.json` — regenerated (31 tables, includes the vm* marketing tables).
  - `seed_marketing/1` in seeds — a clinic campaign + template + segment + 6 subscribers
    (emails vault-routed) + 1 suppression row, so the pages populate AND the suppression red
    path is demonstrable in the clinic dogfood.

**Verified live (PawChart, port 4042, fresh dev DB):**

```
/marketing/campaigns -> 200  (renders "Spring wellness referral drive")
/marketing/segments  -> 200  (renders "Referring vets" + "suppressed" flag)
/marketing/leads     -> 200
/crm/contacts/:id?tab=activity -> 200  (tl-rail populated; real activity subjects;
                                        log-activity-form composer present)
```

Tenant plane: the subscriber email renders in the CLEAR (`maya.singh@valleyanimal.example`) —
the org owns its contacts' PII, consistent with the framework masking posture (operator plane
stays `••••`, proven in the existing `samen_web` masking tests over the same LiveViews).

---

## Suites — GREEN before + after

- **samen_core:** `842 passed (833 tests, 9 properties)` under `--seed 0` (kernel green after
  the append-only abbrev rows; no kernel CODE change).
- **samen_web:** `107 passed`, `--warnings-as-errors` clean.
- **demo:** `403 passed (386 tests)`, `--warnings-as-errors` clean.
- **pawchart ci.sh:** **ALL 17 steps PASSED** — including catalog_parity / prefixes / migrations
  / same_org_fk / no_pii_columns over the NEW `vm*` marketing tables, schema.dict.json drift
  check, and the microchip anti-tautology probe (flip + revert).
- **driftwood ci.sh:** **ALL 20 steps PASSED** — including the verifier gate over the marketing
  tables and both PITR game-days + the red-path probe.

## Files touched

Framework (`samen_web`):
- `lib/samen/web/mount.ex` — whitelist label-key atomization (FIX 1) + `label_keys/0`.
- `test/samen/web/marketing_session_roundtrip_test.exs` — NEW (FIX 2).

Vertical proof (PawChart) + kernel data-file:
- `samen_core/priv/abbrev_registry.json` — 7 append-only `vm*` rows.
- `pawchart/lib/pawchart/marketing.ex` — NEW domain.
- `pawchart/priv/repo/migrations/20260709120000_mount_marketing_scope.exs` — NEW migration.
- `pawchart/config/config.exs` — register `PawChart.Marketing`.
- `pawchart/lib/pawchart_web/router.ex` — `:marketing` mount.
- `pawchart/lib/pawchart/seeds.ex` — `seed_crm_activities/2` + `seed_marketing/1`.
- `pawchart/schema.dict.json` — regenerated.
