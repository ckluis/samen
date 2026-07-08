# Task 012c — Mount the cross-plane chat in Driftwood (both planes) + wire the identity model UI

- **Status:** Shipped, all suites green + the full driftwood `ci.sh` (20 steps) ALL PASSED.
  `samen_core` UNTOUCHED (842). Builds on Task 012a (`Samen.Web.ObjectRef` unfurl) and 012b
  (the framework cross-plane chat model + LiveViews).
- **What this task added:** (1) the driftwood mount was already wired for both planes — verified
  it renders + delivers realtime + masks per viewer LIVE; (2) the 3-state identity model's WRITE
  side (the tenant-wide setting + the initiator opt-in) was MISSING a visible UI — built it
  FRAMEWORK-level in `samen_web` so every vertical inherits it, not driftwood-local; (3) fixed a
  stale `driftwood/schema.dict.json` (the chat scope had been mounted + migrated but the catalog
  dict was never regenerated, so `ci.sh` step 1b was red).

---

## Chat routes (both planes, the SAME LiveViews)

Mounted in `driftwood/lib/driftwood_web/router.ex` via two `samen_chat_routes` one-liners:

| Route | Plane | Who |
|---|---|---|
| `/chat?org=<uuid>` | tenant | the Blue Ridge inbox — thread list + **the identity-disclosure setting** + **new-conversation form** |
| `/chat/:id?org=<uuid>` | tenant | the realtime room — bodies + identities CLEAR |
| `/operator/desk-chat?org=<uuid>` | operator | the SaaS-desk inbox — the SAME thread list (cross-plane), read-only (no settings/new-conversation) |
| `/operator/desk-chat/:id?org=<uuid>` | operator | the SAME room — bodies + identities `••••` |

Seeded thread `a6ea36fc-…` ("Rate confirmation for load BR-4471") on org `b1112d00-…-001`,
whose message pastes BOTH a `samen:crm.person:<id>` AND a `samen:freight.driver:<id>` ref, so the
crown-jewel unfurl is demonstrable on both sides (`Driftwood.Seeds.seed_chat/1`).

---

## Framework additions (level-up — every vertical inherits)

The task's item (c) — "wire the tenant-wide setting into a visible tenant setting + the initiator
opt-in on new-conversation" — was built at framework level in `samen_web`, NOT driftwood-local:

| Module | Added |
|---|---|
| `Samen.Web.Chat` | `start_conversation/3` (thread + initiator participant; `share_identity` → `:initiator_opt_in` + `identity_shared: true`), `disclosure_setting?/2` (read the org flag), `set_disclosure_setting/3` (upsert the per-org `ChatDisclosureSetting`; builds a same-org ADMIN tenant scope for the admin-gated write, still org-scope-confined; tenant-only by construction). |
| `Samen.Web.Chat.ThreadsLive` | the inbox now renders (TENANT plane only) an **Identity-disclosure-to-support** toggle (state 3) + a **New conversation** form with a **"Share MY identity … (initiator opt-in)"** checkbox (state 2). `handle_event "toggle_disclosure"` / `"new_conversation"` — both guarded to the tenant plane (a masked operator inbox can neither flip a setting nor open a conversation). |
| `samen_ui.css` | `.chat-settings/.chat-switch/.chat-new/.chat-flash` (append only). |

The 3-state model's WRITE side now lives in ONE place at framework level: the setting drives
`:tenant_wide`; the initiator opt-in drives `:initiator_opt_in`; absent either, the masked floor.
(012b already shipped the READ precedence in `Chat.Identity.disclosed?/3`.)

---

## LIVE verification (booted PORT=4035, `/healthz` → 200, seeded via `mix driftwood.seed`)

### Crown jewel — per-viewer unfurl masking on the SAME objects (LIVE)
Same thread + same pasted refs, rendered on both planes:
- **Tenant** (`/chat/:id`): CONTACT card "Dana Whitfield" + real title/email/phone; DRIVER card
  "Dana Compliant" (CDL-OK-963, TX, samsara, available); roster "Dana Whitfield" clear. **0 masks**,
  no `vt_`. Screenshot `/tmp/chat_tenant.png`.
- **Operator desk** (`/operator/desk-chat/:id`): the SAME cards — name/email/phone/CDL all `••••`
  (7 mask sentinels); non-PII fields (CDL state `TX`, ELD `samsara`, the "available" pill) still
  render; the person/driver plaintext is ABSENT; no `vt_`/`pii_` leak; safe handle
  `blueridge-dispatch` renders. Screenshot `/tmp/chat_operator.png`.

### Realtime cross-plane delivery (LIVE, real DB + Ash + PiiResolution)
A tenant `post_message` (pasting the driver ref) broadcast an **id-only** envelope
(keys `[:thread_id, :participant_id, :sender_party, :refs, :message_id]`, `has_body? = false`);
the OPERATOR subscriber received it and re-read per its plane → `OPERATOR_BODY = #Masked<••••>` and
the driver card `title = #Masked<••••>`; the SAME message re-read on the tenant plane →
`TENANT_BODY = "…driver samen:freight.driver:…"` (clear) and the card `title = "Dana Compliant"`.
Same broadcast, same object, per-viewer masking survives the realtime path — no plaintext transits
PubSub.

### The 3-state identity model (LIVE)
- **State 1 (masked floor):** the seeded `:masked` thread — operator roster shows the tenant
  participant `data-identity-masked="true"` (`••••`), tenant shows `"false"` (clear). The SaaS
  staffer sees the tenant participant MASKED BY DEFAULT.
- **State 3 (tenant-wide):** with the setting ON, a NEW conversation snapshotted
  `disclosure_mode = :tenant_wide` (live-verified, then reset).
- **State 2 (initiator opt-in):** a `start_conversation` with `share_identity: true` snapshotted
  `:initiator_opt_in` and stamped the initiator participant `identity_shared = true` (live-verified,
  then reset).

### The identity-model UI (LIVE)
- **Tenant inbox** renders the disclosure-setting card + new-conversation form + both opt-in
  controls. Screenshot `/tmp/chat_inbox.png`; the toggle's DB write path verified live
  (`{:ok, _}` + read-back `true`).
- **Operator inbox** renders NEITHER control (only the shared thread list) — a masked operator
  cannot flip a setting or open a tenant conversation.

---

## Suite status (green before AND after)

- `samen_core`: **842 passed** — UNTOUCHED (no code change, no abbrev append this task).
- `samen_web`: **162 passed** (154 baseline + **8 new** `chat_identity_write_test.exs`),
  `mix compile --warnings-as-errors` clean.
- `driftwood`: **89 passed** + full `ci.sh` **20/20 ALL PASSED** (incl. schema.dict drift,
  all 15 catalog/PII/boundary verifiers, api-contract v1, adversarial matrix, T5.4 crypto-shred
  game-day, T5.5 PITR game-day #2 both arms + red-path probe).
- `demo`: **403 passed**.
- `pawchart`: **35 passed** (inherits the framework change cleanly).

### New framework test — `chat_identity_write_test.exs` (8, all pass)
The WRITE side of the 3-state model (012b tested the READ precedence): `set_disclosure_setting`
persists + snapshots `:tenant_wide` on NEW threads; admin-gated (a masked operator event is a
no-op); `start_conversation` with opt-in stamps `:initiator_opt_in` + `identity_shared`; without
opt-in falls to the masked floor; the inbox `toggle_disclosure`/`new_conversation` events run
tenant-plane only; the tenant inbox renders the controls and the operator inbox does not.

## Files changed
- `samen_web/lib/samen/web/chat.ex` — `start_conversation/3`, `disclosure_setting?/2`,
  `set_disclosure_setting/3` + `admin_tenant_scope/1`.
- `samen_web/lib/samen/web/chat/threads_live.ex` — the two inbox events + the identity-controls
  render (tenant-plane gated).
- `samen_web/priv/static/assets/samen_ui.css` — `.chat-settings/.chat-switch/.chat-new/.chat-flash`.
- `samen_web/test/samen/web/chat_identity_write_test.exs` — NEW (8 tests).
- `driftwood/schema.dict.json` — regenerated to include the mounted chat scope
  (`dct_/dcp_/dcm_/dcd_` tables); this is what un-blocked `ci.sh` step 1b.
