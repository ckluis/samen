# Task 012b — Cross-plane realtime chat (ADR-012 Stage B/C/D, the flagship)

- **Status:** Shipped, all suites green. `samen_core` code UNTOUCHED (842 tests pass; only the
  sanctioned abbrev-registry data append). Builds on Task 012a (the shipped `Samen.Web.ObjectRef`
  unfurl capability — chat is its first CONSUMER, not its owner).
- **Scope:** the realtime CROSS-PLANE chat model + LiveViews + the 3-state identity model, all
  framework-level in `samen_web`, so ANY vertical inherits chat + object unfurl + the identity
  model by mounting one scope + one macro. The driftwood vertical only PROVES it.

---

## What shipped (framework-level in `samen_web`)

| Module | Role |
|---|---|
| `Samen.Scopes.Chat` (+ `.Blueprint`) | the library-authored blueprint (ADR-004 shape) materializing `ChatThread`/`ChatParticipant`/`ChatMessage`/`ChatDisclosureSetting` in the host namespace. Hosted in `samen_web` (not `samen_core`) — chat is a framework-WEB capability; the hard rule keeps `samen_core` code untouched. Each resource is a normal `use Samen.Resource` (the untouched kernel), so it inherits vault routing + PII verifiers + `OrgScope` + `SameOrgFk` + catalog by construction. |
| `Samen.Web.Chat` | the context: `scope/2`, `create_thread/3` (disclosure snapshot), `add_participant/3`, `post_message/4` (parse refs → persist+vault → broadcast id-only), `envelope/1`, `read_broadcast/3`, `resolve_cards/3`. |
| `Samen.Web.Chat.Reads` | the read layer — every PII field resolved through `PiiResolution` per the scope's plane (the CRM/Support reads pattern; NEVER unwraps a `%Masked{}`). |
| `Samen.Web.Chat.Identity` | the 3-state `disclosed?/3` precedence + the per-participant plane-choice resolve (`resolve_participant/4`). |
| `Samen.Web.Chat.PubSub` | `topic/1`, `server/1` (`:pubsub` mount label), `subscribe/2`, `broadcast_message/3` (id-only envelope). |
| `Samen.Web.Chat.Presence` | `use Phoenix.Presence`; non-PII meta (`meta/2` — handle only, never a name). |
| `Samen.Web.Chat.ThreadsLive` | the inbox (`/chat`). |
| `Samen.Web.Chat.ThreadLive` | the realtime room (`/chat/:id`) — subscribe on mount, broadcast on send, `handle_info` re-read per plane, inline unfurl cards, roster, composer. |
| `Samen.Web.Chat.Components` | `<.chat_message>`, `<.presence_roster>`, `<.identity_chip>` — `%Masked{}`-safe. |
| `Samen.Web.Router.samen_chat_routes/3` | the host mount macro (ADR-009 Router style). |
| `samen_ui.css` | `.chat-*` styles (append only). |

---

## The chat mount API (how a host mounts chat)

```elixir
import Samen.Web.Router

# TENANT plane — the org's own chat console (bodies + identities in the clear).
samen_chat_routes :chat, Driftwood.Chat, repo: Driftwood.Repo

# SaaS-DESK plane — the operator drills into a tenant's cross-plane threads (masked),
# reaching them through the impersonation bridge carrying the tenant org_id (ADR-012 §2.3).
samen_chat_routes :chat, Driftwood.Chat,
  repo: Driftwood.Repo,
  plane: :operator,
  path: "/operator/desk-chat",
  labels: %{pubsub: Driftwood.PubSub, object_cards: %{"freight.driver" => DriftwoodWeb.Chat.DriverCard}}
```

One-time host supervision-tree add (documented on the macro's `@doc`):

```elixir
{Phoenix.PubSub, name: Driftwood.PubSub},                     # a Phoenix app already has this
{Samen.Web.Chat.Presence, pubsub_server: Driftwood.PubSub}    # who's-online / typing
```

**A tenant chat and a SaaS-desk chat are the SAME LiveViews on different planes** — the
two-plane thesis, extended to chat. The `:object_cards` label registers a vertical override card
(data, not code); every other catalogued resource unfurls via the framework default/first-class
cards with zero cards written.

---

## The realtime path (masking BY CONSTRUCTION, ADR-012 §3)

`post_message/4`: parse refs on the PLAINTEXT (before vaulting) → persist via Ash (vault +
org-scope) → broadcast an **id-only** envelope (`%{thread_id, message_id, sender_party,
participant_id, refs}` — NEVER the body). Each subscriber's `handle_info` re-reads the message
through `Reads.get_message/3` with ITS OWN scope, so the body resolves per the RECEIVING viewer's
plane; the stored refs re-resolve through `ObjectRef.resolve_string/3` per viewer. A plaintext
body never transits PubSub — a masked operator session cannot obtain plaintext even by listening
on the topic.

---

## The 3-state identity model (ADR-012 §5)

`Samen.Web.Chat.Identity.disclosed?/3` is the ONE precedence function; disclosure is a PLANE
CHOICE per subject (resolve the participant's `full_name` on the tenant-plane actor = clear, or
the operator-plane actor = `••••`), never a bespoke masking branch. All three paths go through
`PiiResolution`:

- **State 1 — masked floor** (`:masked`, `identity_shared: false`) → operator sees the safe
  handle + `••••`.
- **State 2 — initiator opt-in** (`:initiator_opt_in`, that participant `identity_shared: true`)
  → operator sees the INITIATOR's real name; every other tenant participant stays `••••`.
- **State 3 — tenant-wide** (`:tenant_wide`, snapshotted from `ChatDisclosureSetting` at thread
  create) → operator sees ALL tenant participants' real names. Message BODIES stay masked
  (identity disclosure ≠ content disclosure).

---

## `samen_core` impact — abbrev-registry appends ONLY (the sole sanctioned change)

Appended to `samen_core/priv/abbrev_registry.json` (data file; no kernel code changed):
`wct/wcp/wcm/wcd` (the samen_web test host `Samen.WebTest.Chat.*`) and `dct/dcp/dcm/dcd`
(driftwood `Driftwood.Chat.*`). The framework-default abbrevs `cth/chp/cmg/cds` (ADR-012 §11) are
the blueprint defaults; each host passes its own prefixed set.

---

## Test results (the load-bearing gates — all pass)

Command: `mix test` in `samen_web` → **154 passed** (was 129; **+25 new chat tests**),
`mix compile --warnings-as-errors` clean.

- **`chat_realtime_test.exs` (2)** — REALTIME DELIVERY. Two subscriber processes on a real
  `Phoenix.PubSub` topic; a `broadcast` reaches the second (operator) subscriber's re-read, which
  resolves the SAME message body `••••` while the tenant subscriber's re-read is CLEAR — from the
  SAME broadcast. The envelope is asserted id-only (no `:body` key). (Red path 3.)
- **`chat_message_unfurl_test.exs` (4)** — THE CROWN JEWEL, in the chat context. A message's
  `samen:crm.person:<id>` ref renders a CLEAR card to the tenant and a `••••` card to the operator
  (same object id, plaintext absent, no `vt_`/`pii_` token); a cross-org ref renders a "not
  available" chip (no leak). (Red paths 1 + 2.)
- **`chat_identity_states_test.exs` (7)** — the 3-STATE identity model: state 1 masked, state 2
  initiator-only (non-opted-in participant stays `••••`), state 3 tenant-wide (all clear), the
  create-time snapshot, and the anti-tautology controls (tenant always clear; operator never sees
  bodies clear even under tenant-wide). (Red path 5.)
- **`chat_crossplane_scope_test.exs` (3)** — a tenant-owned thread is visible to BOTH a tenant
  actor and an impersonating operator (same `org_id`, no new policy); a mismatched-target operator
  sees zero rows. (§2.3 + red path 6.)
- **`chat_live_render_test.exs` (6)** — the ThreadsLive inbox + ThreadLive room render on both
  planes (tenant clear / operator `••••`, no token leak); `handle_event "send"` persists+appends;
  `handle_info {:chat_message,…}` re-reads a broadcast per plane; a foreign-thread broadcast is
  ignored.
- **`chat_scope_test.exs` (4)** — the blueprint gate: the four resources are catalogued Ash
  resources; message body + participant `full_name` are vault-routed (masked on operator, clear on
  tenant); `OrgScope` narrows chat reads to the actor's org.

---

## Suite status (green before AND after)

- `samen_core`: **842 passed** — UNTOUCHED (abbrev-registry data append only, no code change).
- `samen_web`: **154 passed** (129 baseline + 25 new), `--warnings-as-errors` clean.
- `driftwood`: **89 passed** (chat scope mounted + migrated + seeded; router + supervision-tree
  wired).
- `demo`: **403 passed**.
- `pawchart`: **35 passed**.

## Browser / live self-verify (per the mandate)

Driftwood booted on `PORT=4035`; `/healthz` → 200; seeded via `mix driftwood.seed` (one
cross-plane thread whose message pastes a `samen:crm.person:<id>` AND a `samen:freight.driver:<id>`
ref). The SAME thread + SAME message rendered on both planes:

- **Tenant** (`/chat/:id`): the CONTACT card shows "Dana Whitfield" + real email/phone; the DRIVER
  override card ("Dana Compliant", CDL-OK-963, TX, samsara, "available"); the roster shows the
  clear name; **0 masks**. Screenshot `/tmp/chat_tenant.png`.
- **Operator desk** (`/operator/desk-chat/:id`): the SAME cards render with title/email/phone/CDL
  `••••` (non-PII fields — CDL state TX, ELD samsara, the "available"/"lead" pills — still show);
  the real name/email are ABSENT; **no `vt_`/`pii_` token**; the safe handle
  `blueridge-dispatch` renders; the roster identity is `••••`. Screenshot `/tmp/chat_operator.png`.

This is the crown jewel proven end-to-end in the LIVE vertical: per-viewer masking on the exact
same objects, by construction (OrgScope + PiiResolution), across the operator↔tenant plane
boundary — a FRAMEWORK capability any vertical inherits, not a chat trick.

## Seams for the rest of ADR-012 / future work

- **New resource → free unfurl in chat** (the `DefaultCard`, zero cards written).
- **Bespoke card** — a `:object_cards` mount label (driftwood proves `freight.driver`).
- **Alternate pubsub/presence** — `:pubsub`/`:presence` mount labels.
- **New disclosure policy** — a new clause in `Chat.Identity.disclosed?/3` + a stored field.
- **Presence who's-online/typing** — the framework `Samen.Web.Chat.Presence` is wired into
  driftwood's supervision tree; the roster renders through the identity model (handle-only meta,
  no name in presence, red path 4).
