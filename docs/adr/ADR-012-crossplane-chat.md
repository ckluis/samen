# ADR-012 — Cross-plane realtime chat, catalog-driven object unfurl, and the participant identity model

- **Status:** Accepted (design; Build phase follows this contract, staged minimal-viable)
- **Date:** 2026-07-08
- **Task:** Framework-layer DESIGN of the FLAGSHIP feature — realtime chat that spans the
  operator↔tenant plane boundary, with a catalog-driven **object unfurl** (paste any Samen
  object id → a live card that is **masking-aware per viewer**), and a 3-state **participant
  identity model**. Framework-level in `samen_web`; verticals inherit it for free.
- **Deciders:** opus (framework layer), grounded in the owner's flagship mandate ("stupid
  rich / world-class; a framework people NEED to use; every proof feature must LEVEL UP the
  core framework") and the vision doc (`docs/samen-foundry.txt` — one substrate, catalogued
  objects, PII vault by construction).
- **Builds on:**
  - **ADR-009** (`samen_web`, the two-plane pattern, `Samen.Web.{Mount,Plane,Router,Live}`,
    the framework CRM/Billing/Support LiveViews + reads).
  - **ADR-010** (the operator plane; the **identity line** = `OrgScope` by `org_id` +
    `PiiResolution` by `plane`; the impersonation bridge `Samen.Web.Plane.operator/3`).
  - **ADR-004** (library-authored scope blueprints; the Support scope's
    `Ticket · Conversation · Message🔒 · Agent🔒`).
  - The kernel's `Samen.Api.PiiResolution` (`plane_of/1` + `impersonated?/1`),
    `Samen.Catalog` (`table/1`, `fields/1`), `Samen.Masked`, `Samen.Policy.OrgScope`.
  - `Phoenix.PubSub` (`Driftwood.PubSub` already running) + `Phoenix.Presence`.
- **Supersedes / touches:** nothing. **`samen_core` is UNTOUCHED** (~842 green; the only
  sanctioned append is abbrev-registry rows for the new chat resources, §11). All new code is
  framework-level in `samen_web`; the driftwood vertical only PROVES it.

---

## 1 · Context — why this is only possible on Samen, and why it must be a FRAMEWORK capability

The owner's thesis, stated exactly: because the SaaS company and every tenant live on **one
substrate** with **shared catalogued objects** + PubSub, realtime chat that **spans the
operator↔tenant boundary is near-free**, and the crown jewel — pasting **any** Samen object id
into a message renders a **live card preview that is masking-aware per viewer** — is a
*framework* capability, not a chat trick.

Three facts from ADR-009/010 make the flagship fall out of the kernel rather than being bolted
on:

1. **The plane line already IS the masking line.** `PiiResolution.resolve/4` masks off exactly
   one thing: `plane_of(actor) = actor.plane` (`pii_resolution.ex:158`). A tenant actor
   (`plane: :tenant`) reads its own PII clear; an operator/impersonation actor
   (`plane: :operator` + `:impersonation`) reads the SAME record and gets `%Masked{}` → `••••`.
   So the SAME loaded object, resolved for two different viewers' planes, renders a clear card
   and a masked card **with zero per-viewer masking code**. The unfurl card is *just* a
   record run through `PiiResolution` for the viewer's plane.

2. **The org line already IS the authorization line.** `Samen.Policy.OrgScope` narrows every
   read to `actor.org_id`. A pasted ref the viewer isn't org-authorized for returns **zero
   rows** — the unfurl resolver inherits refusal-by-construction, no new leak check.

3. **The catalog already names every resource + field.** `Samen.Catalog.fields/1` yields
   `{table, column, logical_name, type}` for any resource, and the `pii do` declaration marks
   which fields are vaulted. A **default card** can be rendered for ANY catalogued resource by
   walking `Ash.Resource.Info.public_attributes/1` and letting `%Masked{}` values render `••••`
   via `Phoenix.HTML.Safe` (`Samen.Masked` already implements it). The registry is a thin
   override seam over a catalog-driven default — so a NEW vertical's NEW resource unfurls the
   day it is catalogued, with no card written.

The load-bearing sections are **§4 (unfurl — the crown jewel)** and **§5 (identity model)**.
Everything else (the chat model §2, realtime §3, the framework surface §6) exists to make §4
and §5 real and testable.

### 1.1 The single most important design constraint

> The unfurl card MUST render each field through `PiiResolution` for the VIEWER'S plane, never
> a bypass. A pasted ref the viewer isn't org-authorized for must NOT leak. Masking is BY
> CONSTRUCTION.

This ADR is disciplined about it: the resolver (§4.3) loads via the **host's own resource
through Ash with the viewer's scope** (so `OrgScope` filters), then runs the loaded record
through **`PiiResolution.resolve/4` with the viewer's actor** (so vaulted fields mask per
plane). There is no code path in the unfurl that reads a column directly, unwraps a `%Masked{}`,
or bypasses `Ash.read`. The card component receives an already-resolved record and renders it —
a `%Masked{}` in any field renders `••••` verbatim through `Phoenix.HTML.Safe`. This is the
ADR-008 invariant ("masking is the field type's normal value") generalized to the flagship.

---

## 2 · The chat model — conversations + messages that span two planes

### 2.1 Decision: a **chat-specific model**, NOT a reuse of `Support.Conversation/Message`

**Decision: introduce two NEW framework-materialized resources — `ChatThread` and
`ChatMessage` — via a new library-authored blueprint `Samen.Scopes.Chat`, rather than reusing
the Support scope's `Conversation`/`Message`.**

Rationale (the reuse tension, decided honestly):

| Force | Reuse `Support.{Conversation,Message}` | New `Chat.{Thread,Message}` |
|---|---|---|
| `Conversation.ticket_id` is `allow_nil?: false` | ✗ every chat would need a synthetic ticket | ✓ no ticket coupling |
| Cross-plane participant grant (a SaaS participant in a tenant-owned thread) | ✗ Support has no participant concept; membership is implicit via org | ✓ first-class `ChatParticipant` |
| The 3-state identity model (§5) needs per-conversation + per-participant metadata | ✗ nowhere to put it | ✓ `ChatThread.disclosure_mode` + `ChatParticipant.identity_shared` |
| Message body is 🔒 free-text | ✓ Support already vaults `body` | ✓ we vault `body` the SAME way (copy the proven pii declaration) |
| Support conversations are ticket-scoped support threads; chat is a peer↔peer realtime channel | different domain object | clean separation |

The clinching reason is the **cross-plane participant grant** (§2.3). Support's model has no
seam for "a SaaS-staff actor is a member of a tenant-owned conversation." Bolting that onto
`Support.Conversation` would distort the support desk. A dedicated `Chat` scope keeps both
clean and lets chat inherit the SAME vault/pii/org-scope machinery by construction.

**Reuse where it's free:** `ChatMessage.body` copies `Support.Message`'s exact pii declaration
(`pii_attribute :body, :string, vault: :pii_body` + `reveal :reveal_message`), so the free-text
vault routing, the `pii_reads`/`no_plaintext_pii` verifiers, and the resolver behavior are
inherited verbatim — not reinvented. The chat scope is a THIN new blueprint, not a fork.

### 2.2 The three resources (`Samen.Scopes.Chat` blueprint)

Materialized in the host namespace exactly like every other scope (ADR-004), each a normal
`use Samen.Resource` with the host's `otp_app`/`repo`/`domain` and a permanent abbrev:

**`ChatThread`** (abbrev `cth`) — a conversation that may span two planes. **No PII.**
- `org_id` (implicit via OrgScope; the OWNER org — see §2.3)
- `subject :string` — non-PII thread label ("Rate confirmation for load #4471")
- `kind :atom` — `:tenant_internal | :cross_plane` (a cross-plane thread has a SaaS participant)
- `status :atom` — `:open | :closed`, default `:open`
- `disclosure_mode :atom` — the tenant-wide identity setting snapshot at thread create
  (`:masked | :tenant_wide | :initiator_opt_in`), default `:masked` (§5)
- `context_ref :string | nil` — an OPTIONAL Samen object ref this thread is "about" (e.g.
  `samen:crm.person:<id>`) so a thread can be pinned to an object. Rendered via the SAME
  unfurl resolver (§4). Not PII (an opaque ref).

**`ChatParticipant`** (abbrev `chp`) — membership, the cross-plane grant carrier. **No subject
PII** (identity is a reference + a display handle; real name lives on `Identity.User`, masked
by plane).
- `thread_id` → `ChatThread` (belongs_to, `allow_nil?: false`)
- `party :atom` — `:tenant | :operator` — WHICH plane this participant acts from. This is the
  cross-plane seam (§2.3).
- `principal_kind :atom` — `:user | :agent | :operator_staff`
- `principal_id :string` — the referenced identity id (an `Identity.User` id on the tenant
  side, an operator-staff id on the SaaS side). Opaque; not PII.
- `handle :string` — a non-PII display handle (mirrors `Identity.User.handle` /
  `Support.Agent.handle`) — safe to render on either plane. See §5.4 (the label the unmasked
  card never leaks a real name through).
- `identity_shared :boolean`, default `false` — the per-conversation initiator opt-in (§5 state 2).
- `role :atom` — `:member | :owner`, default `:member`.

**`ChatMessage`** (abbrev `cmg`) — a single message. **🔒 body.**
- `thread_id` → `ChatThread` (belongs_to, `allow_nil?: false`)
- `participant_id` → `ChatParticipant` (belongs_to, `allow_nil?: false`) — the sender.
- `sender_party :atom` — `:tenant | :operator` (denormalized for cheap rendering / broadcast).
- `body` — 🔒 `pii_attribute :body, :string, vault: :pii_body`, `reveal :reveal_message`
  (copied verbatim from `Support.Message`). Free-text; a chat body may contain PII, so it is
  vaulted by construction — clear to the tenant, `••••` to the operator, same as everything else.
- `refs {:array, :string}` — the parsed object refs found in `body` at send time (§4.2), stored
  so unfurl does not re-parse ciphertext. Opaque refs; not PII.
- `kind :atom` — `:message | :system | :join | :leave`, default `:message`.

All three carry the standard org-scope policies (`authorize_if Samen.Policy.OrgScope` on read;
`OrgScope` + `RoleAtLeast :member` on write), same-org FK changes on the belongs_to relations
(`Samen.Policy.SameOrgFk`), and the standard reveal action on `ChatMessage`. **This is the
proven Support shape, minus the ticket coupling, plus participants.**

### 2.3 Cross-plane visibility — how ONE thread is visible to BOTH a tenant and a SaaS actor without breaking `OrgScope`

This is the crux. `OrgScope` narrows every read to `actor.org_id`. A tenant actor has
`org_id = <tenant_org>`; a SaaS-staff actor drilling in has `org_id = <target_tenant_org>` via
the **impersonation plane** (`Samen.Web.Plane.operator/3` → actor `%{org_id: target, plane:
:operator, impersonation: %{...}}`). So:

**Decision: a cross-plane `ChatThread` is OWNED BY THE TENANT ORG. The SaaS participant reaches
it through the EXISTING impersonation bridge — the SAME mechanism ADR-010's "Open account" drill
uses — carrying `org_id = <tenant_org>`. `OrgScope` is satisfied for BOTH parties because the
row's `org_id` is the tenant org, and both actors present that org_id.**

This is the mirror-of-impersonation the task names, and it requires NO change to `OrgScope`:

- **Tenant participant** — a real tenant member; `org_id = <tenant_org>`, `plane: :tenant`.
  `OrgScope` passes (own org). PII clear.
- **SaaS participant** — an operator who opened this tenant via impersonation;
  `org_id = <tenant_org>` (the TARGET), `plane: :operator`, `impersonation: %{...}`. `OrgScope`
  passes (the impersonation scope carries the target org_id as its boundary — see
  `Samen.Impersonation.Scope`'s moduledoc: "the TARGET org is the tenant boundary"). PII masked.

The `ChatParticipant.party` field records which plane each participant acts from, so the UI and
the identity model (§5) know a SaaS-staff row from a tenant row **without trusting the live
actor** — the grant is data, checked against the actor at render.

**Why not an operator-owned thread with a tenant grant?** Because then the TENANT actor
(`org_id = <tenant_org>`) could not see an `org_id = <operator_org>` row without impersonating
UP into the operator org — which tenants must never do. Tenant-owned + operator-reaches-via-
impersonation is the only assignment where both actors are satisfied by `OrgScope` with no new
policy and no upward escalation. **The tenant owns the conversation about its own world; the
SaaS visits.**

**Anti-tautology / red path (§7):** an operator whose impersonation session is for a DIFFERENT
target org (or is expired) presents a different/absent `org_id` → `OrgScope` returns the thread
as zero rows. Cross-plane visibility is a *grant that expires*, not a backdoor.

---

## 3 · Realtime — PubSub topic per thread + Presence for who's-online/typing

### 3.1 Topic + broadcast

- **Topic per thread:** `"samen:chat:" <> thread_id`. Framework-owned helper
  `Samen.Web.Chat.PubSub.topic/1`. The pubsub server is read from the host (see §3.4) —
  default `Driftwood.PubSub` in driftwood; a `:pubsub` label on the mount overrides.
- **On send** (a participant posts a message): the LiveView persists the `ChatMessage` via Ash
  (vault + org-scope apply), then broadcasts a **plane-neutral envelope** — deliberately NOT
  the resolved body:

  ```
  Phoenix.PubSub.broadcast(pubsub, topic, {:chat_message, %{
    thread_id: thread_id,
    message_id: msg.id,          # the id — NOT the plaintext body
    sender_party: :tenant,       # who sent, which plane
    participant_id: msg.participant_id,
    refs: msg.refs               # parsed refs (opaque)
  }})
  ```

  The broadcast carries the message **id**, never a resolved/plaintext body. Each subscriber's
  `handle_info` **re-reads** the message through the reads layer **with ITS OWN scope**, so the
  body and any unfurl cards resolve per the receiving viewer's plane. **A plaintext body never
  transits PubSub**, so a masked operator session cannot receive plaintext even by listening on
  the topic — masking survives the realtime path by construction (§7 red path).

### 3.2 `handle_info` flow (the test-level realtime assertion)

```
def handle_info({:chat_message, %{thread_id: tid, message_id: mid}}, socket) do
  scope = Samen.Web.Chat.scope(socket.assigns.samen_mount, org_id)   # this viewer's plane
  msg   = Samen.Web.Chat.Reads.get_message(mount, scope, mid)         # PII-resolved for THIS viewer
  {:noreply, stream_insert(socket, :messages, msg)}
end
```

The required realtime test (§8) asserts exactly this seam at the unit level: two subscriber
processes on the same topic; a `broadcast` delivers `{:chat_message, ...}` to the second
subscriber's `handle_info`, and the re-read resolves the body for that subscriber's plane
(tenant subscriber → clear; operator subscriber → `••••`). The two-session browser drive
(§9) is the belt-and-suspenders proof, but the gating assertion is the `handle_info` unit test.

### 3.3 Presence — who's-online + typing

- `Samen.Web.Chat.Presence` — `use Phoenix.Presence, otp_app:, pubsub_server:`. Tracked key is
  the topic; the presence meta is **non-PII by construction**: `%{party: :tenant|:operator,
  handle: participant.handle, typing: bool, online_at: ...}`. **No real name in presence meta**
  — the handle is the safe display label (§5.4), so the presence list on the operator side shows
  a tenant participant's HANDLE, never the vaulted name. Typing is a `Presence.update` toggling
  `typing`, debounced client-side; who's-online is `Presence.list(topic)`.
- The presence roster is rendered through the SAME identity model (§5): a masked-by-default
  cross-plane thread shows the tenant participant as `handle` (e.g. `blueridge-owner`) with an
  `Identity ••••` chip on the operator side until disclosed.

### 3.4 Host wiring seam (staged)

Presence + the pubsub server name are host facts. The framework reads them from the mount:
`Mount.label(mount, :pubsub, default)` and a `:presence` label (default the framework
`Samen.Web.Chat.Presence`, which the host adds to its supervision tree). The `samen_chat_routes`
macro (§6.3) documents the one-time host supervision-tree add. This mirrors how ADR-009 threads
`repo` — a host fact carried on the mount, never hardcoded.

---

## 4 · Object unfurl — the crown jewel (catalog-driven, masking-aware per viewer)

### 4.1 The ref format

**`samen:<resource-key>:<id>`** where `<resource-key>` is the **catalog resource key** — the
resource-qualified id the catalog already assigns (a lowercased, dotted key derived from the
resource module, e.g. `crm.person`, `support.ticket`, `billing.invoice`, `freight.driver`).
Examples:

- `samen:crm.person:0f00…aa`
- `samen:support.ticket:0f00…bb`
- `samen:freight.driver:0f00…cc`

The key is resource-qualified (task requirement) and stable, and — crucially — it is **NOT a
raw module name** in user-facing text (a paste shouldn't leak `Driftwood.Crm.Person`). A
framework map `Samen.Web.ObjectRef.Catalog` translates `resource-key ↔ resource module` **for a
given mount** (the mount's namespace + `scope_kind` disambiguate `crm.person` →
`Driftwood.Crm.Person` in driftwood, `PawChart.Crm.Person` in pawchart — the ADR-009
derive-from-namespace rule again). A bare pasted object id with no `samen:` prefix is NOT
unfurled (avoids false positives on arbitrary UUIDs); the `samen:` scheme is the explicit
opt-in, and the composer offers a "copy ref" affordance on every catalogued object (§6.2).

### 4.2 Parsing — at send time, stored on the message

`Samen.Web.ObjectRef.parse/1` scans a message body for the `samen:<key>:<id>` pattern (a
bounded regex; ids are UUID-shaped) and returns a list of `%ObjectRef{key, id}`. Parsing runs
**once, at send time, on the plaintext body in the composer** (before the body is vaulted), and
the resulting refs are stored on `ChatMessage.refs` (opaque strings). This means:

- Unfurl never re-parses ciphertext (the vaulted body is `%Masked{}` on read for the operator —
  you cannot scan it, and you must not).
- The set of refs is fixed and auditable per message.
- A ref is just a pointer; storing it leaks nothing (the RESOLUTION is what masks, §4.3).

### 4.3 The resolver — `Samen.Web.ObjectRef.resolve/3` (masking BY CONSTRUCTION)

The single framework function that turns a ref into a render-ready, per-viewer card. Signature:

```
Samen.Web.ObjectRef.resolve(mount, scope, %ObjectRef{key: key, id: id})
  :: {:ok, %Card{}} | {:error, :not_found | :unknown_key | :forbidden}
```

Steps — each a construction guarantee, no bypass:

1. **Resolve the resource module** — `Catalog.resource_for(mount, key)`. Uses the mount's
   namespace (`Mount.resource/2` derive rule). Unknown key → `{:error, :unknown_key}` (a
   pasted `samen:bogus.thing:…` renders an inert "unknown object" chip, never an error leak).

2. **Load via the host's resource through Ash WITH THE VIEWER'S SCOPE** —
   `resource |> Ash.Query.filter(id == ^id) |> Ash.read!(scope: scope)`. This is the
   org-scope authorization gate: `OrgScope` narrows to `scope.actor.org_id`. **A ref the
   viewer isn't org-authorized for returns `[]` → `{:error, :not_found}`** — indistinguishable
   from a non-existent id (no existence oracle across orgs). This is the "org-scope the resolve"
   requirement, satisfied by reusing the kernel policy, not a new check.

3. **Resolve PII for the viewer's plane** —
   `PiiResolution.resolve([record], resource, scope.actor, repo: mount.repo)`. This is the
   masking gate. The SAME record resolves to a clear card for a `plane: :tenant` viewer and a
   `••••` card for a `plane: :operator` viewer — **this is the per-viewer unfurl-masking
   property, and it is literally the ADR-010 resolver, reused.**

4. **Build the card** — `Registry.card_for(mount, key, resolved_record)` (§4.4). The card is a
   struct of `{title, subtitle, fields: [{label, value}], badges, href}` where each `value` is
   the ALREADY-RESOLVED field (a plaintext string on the tenant plane, a `%Masked{}` on the
   operator plane). The card component renders `%Masked{}` as `••••` via `Phoenix.HTML.Safe`.

There is **no step that reads a column directly, unwraps a `%Masked{}`, calls
`Samen.Vault.reveal/3`, or bypasses `Ash.read`**. The resolver is a composition of two kernel
gates (`OrgScope` + `PiiResolution`) over the host's own resource — the same discipline as
`Samen.Web.CRM.Reads` (§ "MASKING INVARIANT" in that module). A resolver failure fails safe:
`{:error, _}` renders an inert chip, never plaintext, never a raise to the user.

### 4.4 The card registry — catalog-driven default + per-resource override

**Decision: a catalog-driven DEFAULT card renders ANY catalogued resource; the registry is a
thin override seam for resources that deserve a bespoke card. A new vertical inherits unfurl for
every catalogued resource with ZERO cards written.**

- **Default card (`Samen.Web.ObjectRef.DefaultCard`)** — given a resolved record + its resource,
  it introspects `Ash.Resource.Info.public_attributes/1` and renders:
  - **title** — the resource's display attribute by convention (`:name` / `:display_name` /
    `:subject` / `:handle` / `:full_name`, first present) — and because `full_name` is a
    `%Masked{}` on the operator plane, the title itself masks to `••••` correctly.
  - **fields** — the public attributes (skipping ids/timestamps), each rendered through
    `Phoenix.HTML.Safe` so a vaulted field is `••••`. The `pii do` declaration is honored
    transitively: the field was already resolved in step 3.
  - **badges** — bounded enum attributes (`status`, `priority`, `stage`, `lifecycle_stage`)
    rendered as `<.pill>` from the ADR-008 UI kit.
  - **subtitle** — the catalog resource key + a masked-aware "who can see" note.

  The default card is **field-metadata-driven from the catalog** (`Samen.Catalog.fields/1` for
  the type/label; `Ash.Resource.Info` for public? + enum constraints), so it is correct for a
  resource nobody has ever seen — the framework promise.

- **Override registry (`Samen.Web.ObjectRef.Registry`)** — a map `resource-key → card module`.
  A card module implements `card/2` (`(mount, resolved_record) -> %Card{}`). The framework
  ships a small set of first-class overrides for the inherited scopes:
  - `crm.person` → name/company/lifecycle pill + email/phone (masked per plane).
  - `crm.company` → name/industry/size.
  - `support.ticket` → subject/status/priority/SLA pill.
  - `billing.invoice` → number/amount/status.
  A host registers a vertical override (e.g. `freight.driver` → a driver card) via a
  `:object_cards` label on the mount (data, not code) — the same host-supplies-data pattern as
  `aggregate_loader:` in ADR-009. Registration is a plain map; if a key has no override, the
  default card renders. **The registry never changes masking** — it only chooses layout; every
  field it renders is the resolver's already-resolved value.

### 4.5 Why this LEVELS UP the framework (not a chat trick)

`Samen.Web.ObjectRef` is a standalone framework module usable ANYWHERE — a CRM detail page can
embed an unfurl of a related object, an audit log can unfurl the subject of an event, a
notification can unfurl its target. Chat is the first CONSUMER, not the owner. The card registry
+ catalog-driven default is a reusable "render any catalogued object, masked-per-viewer"
capability — a genuine framework primitive. **Every vertical's chat (and every vertical's detail
pages) inherits object unfurl for every catalogued resource, for free.**

---

## 5 · The participant identity model — the 3 states

A SaaS employee chatting with a tenant sees the tenant participant's identity **masked by
default** (`••••`, reveal-gated), UNLESS one of two disclosures applies. The three states,
where each is stored, and how each is enforced **through `PiiResolution` / participant
metadata** — never a bespoke masking branch:

### State 1 — MASKED BY DEFAULT (the floor)

- **Stored:** `ChatThread.disclosure_mode = :masked` (the default) AND
  `ChatParticipant.identity_shared = false`.
- **Enforced:** the participant's real identity lives on `Identity.User` (`full_name`/`emails`,
  vaulted). When the operator (`plane: :operator`) renders the participant card / presence row,
  the identity is loaded through `PiiResolution` for the operator plane → `%Masked{}` → `••••`.
  The only thing the operator sees is the non-PII `handle` (e.g. `blueridge-owner`). **This is
  the plane resolver doing its normal job** — no chat-specific masking.
- **Reveal-gated:** a second-party reveal grant (the EXISTING `Samen.Reveal` seam, the same one
  the operator impersonation UI uses) can lift the mask for a specific subject — identical to how
  a vaulted CRM contact is revealed. No new reveal path.

### State 2 — INITIATOR OPT-IN PER CONVERSATION

- **Stored:** `disclosure_mode = :initiator_opt_in` (thread-level) AND the initiator's
  `ChatParticipant.identity_shared = true` (participant-level, set by the initiator when they
  START the conversation and choose "share my identity for this chat").
- **Enforced:** disclosure is **scoped to the participant who opted in, for this thread only**.
  Mechanism (masking by construction, not a plaintext branch): when `identity_shared = true`,
  the reads layer resolves that participant's identity on the **tenant plane** actor for the
  disclosure (the tenant owns its own PII, so a tenant-plane resolve is clear) and renders the
  result into the card — i.e. disclosure is modeled as **"resolve this ONE participant's
  identity on the tenant plane instead of the operator plane."** It is NOT a reveal grant and NOT
  a `Vault.reveal` bypass; it is choosing which plane's actor resolves that one subject, and the
  tenant-plane resolve is the tenant disclosing its OWN identity (which it is entitled to do).
  Every OTHER tenant participant in the thread (who did not opt in) stays `••••` on the operator
  plane. The opt-in is per-participant + per-thread, so it never bleeds to other conversations.

### State 3 — TENANT-WIDE DISCLOSURE SETTING

- **Stored:** a tenant-org setting `expose_identity_to_support` (a Tier-0 config row —
  `ChatDisclosureSetting`, abbrev `cds`, one row per org, admin-gated). When ON, a cross-plane
  thread created for that org is stamped `disclosure_mode = :tenant_wide` at create time
  (snapshot, so flipping the setting later doesn't retroactively expose old threads).
- **Enforced:** `disclosure_mode = :tenant_wide` means EVERY tenant participant's identity in
  the thread is resolved on the **tenant plane** for the operator's card render (same mechanism
  as state 2, but org-wide rather than initiator-only). The operator sees tenant participants'
  real names because the tenant org has organizationally consented to expose participant identity
  to SaaS support. Message BODIES remain masked unless separately revealed — this setting
  discloses **participant identity**, not conversation content (the two are orthogonal:
  `disclosure_mode` governs the participant card; the body's vault governs the message text).

### 5.1 Precedence + the resolution function

`Samen.Web.Chat.Identity.disclosed?(thread, participant, viewer_party)`:

```
viewer_party == :tenant                      -> true   # tenant sees tenant, own-plane clear
thread.disclosure_mode == :tenant_wide       -> true   # state 3 (org consent)
participant.identity_shared == true          -> true   # state 2 (initiator opt-in)
true                                          -> false  # state 1 (masked floor)
```

If `disclosed?` is true, the participant's identity is resolved on the **tenant-plane actor**
(clear, own-org); if false, on the **operator-plane actor** (`%Masked{}` → `••••`). Both paths
go through `PiiResolution.resolve/4` — the ONLY difference is which plane's actor is passed. This
is the whole identity model: **a plane choice for one subject, driven by stored consent, never a
masking branch.** Fail-safe: an unknown/absent `disclosure_mode` resolves to the masked floor.

### 5.2 The 3-state test (required, §8)

One seeded cross-plane thread, rendered from the OPERATOR viewer under each stored state:
- state 1 (`:masked`, `identity_shared: false`) → operator sees `handle` + `••••`, NOT the name.
- state 2 (`:initiator_opt_in`, initiator `identity_shared: true`) → operator sees the
  INITIATOR's real name, but a second (non-opted-in) tenant participant stays `••••`.
- state 3 (`:tenant_wide`) → operator sees ALL tenant participants' real names.
Anti-tautology control: the tenant viewer always sees clear (own plane) in every state, and the
operator NEVER sees message bodies clear in any state (identity disclosure ≠ content disclosure).

---

## 6 · The framework surface — `Samen.Web.Chat.*` + how a host mounts chat

### 6.1 Modules (all in `samen_web`, framework-level)

| Module | Role |
|---|---|
| `Samen.Scopes.Chat` (+ `.Blueprint`) | the library-authored blueprint materializing `ChatThread`/`ChatParticipant`/`ChatMessage`/`ChatDisclosureSetting` in the host namespace (ADR-004). |
| `Samen.Web.Chat.Reads` | the read layer: `threads/2`, `get_thread/3`, `messages/3`, `get_message/3`, `participants/3` — every PII field resolved through `PiiResolution` for the scope's plane (the CRM/Support reads pattern; NEVER unwraps a `%Masked{}`). |
| `Samen.Web.Chat` | context: `scope(mount, org_id)` (delegates to `Plane.scope`), `disclosure` helpers, `post_message/…` (persist + broadcast). |
| `Samen.Web.Chat.Identity` | `disclosed?/3` + the per-participant plane-choice resolve (§5.1). |
| `Samen.Web.Chat.PubSub` | `topic/1`, `broadcast_message/3`, `subscribe/2`. |
| `Samen.Web.Chat.Presence` | `use Phoenix.Presence`; non-PII meta (§3.3). |
| `Samen.Web.ObjectRef` | `parse/1`, `resolve/3` — the framework unfurl resolver (§4). |
| `Samen.Web.ObjectRef.{Catalog,Registry,DefaultCard}` | ref↔resource, override map, catalog-driven default card. |
| `Samen.Web.Chat.ThreadsLive` | the inbox: list threads for the mount's plane (`/chat`). |
| `Samen.Web.Chat.ThreadLive` | the room: messages stream + composer + presence roster + inline unfurl cards (`/chat/:id`). Subscribes on mount; `handle_info` re-reads per plane (§3.2). |
| `Samen.Web.Chat.Components` | `<.chat_message>`, `<.object_card>`, `<.presence_roster>`, `<.identity_chip>` — UI-kit-styled (ADR-008), `%Masked{}`-safe. |

### 6.2 The room LiveView flow (staged)

`mount/3`: `assign_mount` → derive `scope` for the plane → `subscribe` to the thread topic →
`Presence.track` self (party + handle) → load messages (PII-resolved) + participants + presence
→ pre-resolve each message's `refs` into cards (§4.3) for the FIRST render. `handle_event
"send"`: parse refs on the plaintext (§4.2) → persist `ChatMessage` via Ash (vault + org-scope)
→ `broadcast_message` (id-only envelope, §3.1). `handle_info {:chat_message,…}`: re-read the
message for THIS viewer's scope → `stream_insert`. The composer offers a "insert object ref"
picker over catalogued resources (emits `samen:<key>:<id>`), so unfurl is discoverable.

### 6.3 The host mount — `samen_chat_routes` (ADR-009 Router style)

One macro, mirroring `samen_module_routes` (`Samen.Web.Router`):

```elixir
import Samen.Web.Router

# TENANT plane chat (the org's own chat console)
samen_chat_routes :chat, Driftwood.Chat, repo: Driftwood.Repo

# SaaS-DESK plane chat (operator drills into a tenant's cross-plane threads, masked)
samen_chat_routes :chat, Driftwood.Chat,
  repo: Driftwood.Repo,
  plane: :operator,
  target_org_id: tenant_org_id,      # the impersonation bridge (§2.3)
  path: "/operator/desk-chat"
```

The macro builds a `Samen.Web.Mount` (`scope_kind: :chat`) exactly as ADR-009 does — three host
facts (namespace + repo), plane defaults `:tenant`, the operator variant carries
`target_org_id` and threads the impersonation plane. It threads the mount through a
`live_session` (session-safe per ADR-009) and declares `/chat` + `/chat/:id`. The one-time host
supervision-tree add (`Samen.Web.Chat.Presence`) is documented in the macro's `@doc`. **A tenant
chat and a SaaS-desk chat are the SAME LiveViews on different planes — the two-plane thesis,
extended to chat.**

### 6.4 What driftwood adds to PROVE it (vertical, not framework)

- `samen_chat_routes` in the router (tenant + operator-desk variants).
- `Samen.Web.Chat.Presence` in the supervision tree (one line).
- A `:object_cards` label registering a `freight.driver` card override (proves the vertical
  override seam) — driftwood-local, freight-shaped.
- Seeds: one cross-plane thread (a tenant admin ↔ a SaaS agent) with a message that pastes a
  `samen:crm.person:<id>` ref, plus the three disclosure states across seeded threads.

---

## 7 · Red paths (masking-by-construction, enforced by tests §8)

1. **Unfurl never leaks across the plane.** The SAME `samen:crm.person:<id>` in the SAME message
   renders a CLEAR card to the tenant viewer and a `••••` card to the operator viewer. Asserted
   by the per-viewer unfurl-masking test (§8) — the crown-jewel gate.
2. **Unfurl never leaks across orgs.** A `samen:crm.person:<id>` for a DIFFERENT org's row →
   `Ash.read` under `OrgScope` returns `[]` → `{:error, :not_found}` → inert "not found" chip.
   No existence oracle, no PII. Asserted with a cross-org ref.
3. **PubSub never carries plaintext.** The broadcast envelope is id-only; a subscriber on the
   operator plane re-reads and gets `••••`. Asserted at the `handle_info` level (a body clear
   in a tenant subscriber's insert, `••••` in the operator subscriber's insert, from the SAME
   broadcast).
4. **Presence never carries a real name.** Presence meta is `{party, handle, typing}` — no
   vaulted field. Asserted by scanning presence meta for the seeded name.
5. **Identity disclosure ≠ content disclosure.** Even under `:tenant_wide`, message BODIES stay
   masked on the operator plane unless separately revealed. Asserted in the 3-state test.
6. **Expired/mismatched impersonation loses cross-plane visibility.** An operator whose
   impersonation session targets a different org sees the thread as zero rows (`OrgScope`).
   Cross-plane access is a grant that expires, not a backdoor. Asserted with a mismatched target.
7. **No token / no `pii_` column string ever renders.** Every render asserts `refute html =~
   "vt_"` and `refute html =~ "pii_"` (the ADR-009/010 red-path convention).

---

## 8 · Test plan (framework-level, in `samen_web`; gates the flagship)

Built on the existing `Samen.WebTest.DataCase` harness (`render_live/3`, `build_mount/2`, the
plane-masking assertion pattern) + a small chat seed. The GATING tests:

1. **`chat_realtime_test.exs`** — the realtime delivery seam. Two subscriber processes on
   `samen:chat:<tid>`; assert a `broadcast` delivers `{:chat_message, …}` to the second
   subscriber's `handle_info`, and the re-read resolves the body per plane (tenant clear /
   operator `••••`) from the SAME broadcast (red path 3).
2. **`chat_unfurl_masking_test.exs`** — THE CROWN-JEWEL gate. One seeded object; ONE message
   with `samen:crm.person:<id>`. Render the SAME message from a tenant mount and an operator
   mount; assert the tenant card shows the real name/email and the operator card shows `••••`
   with the plaintext absent and no `vt_`/`pii_` (red path 1). Plus the cross-org ref →
   not-found chip (red path 2).
3. **`chat_identity_states_test.exs`** — the 3-state identity model (§5.2), operator viewer under
   `:masked` / `:initiator_opt_in` / `:tenant_wide`, with the anti-tautology controls (tenant
   always clear; bodies never clear to operator).
4. **`chat_crossplane_scope_test.exs`** — §2.3: a tenant-owned thread is visible to both a
   tenant actor and an impersonating operator actor (same `org_id`); a mismatched-target operator
   sees zero rows (red path 6).
5. **`object_ref_test.exs`** — `parse/1` (ref grammar; UUID-shaped ids; ignores bare ids),
   `Catalog.resource_for/2` (derive-from-namespace), `DefaultCard` renders a never-before-seen
   catalogued resource masked-correctly (the framework promise: a resource with a `pii` field it
   has no override for still masks on the operator plane via the default card).

All suites `--warnings-as-errors` clean. `ci.sh` (samen_web gate + driftwood 20-step + demo +
pawchart) green before and after. `samen_core` untouched (§11).

### 8.1 Self-verify (browser, per the mandate)

`BIN="$HOME/.claude/skills/gstack/browse/dist/browse"`; boot driftwood on `PORT=4035`
(`MIX_ENV=dev elixir --erl "-detached" -S mix phx.server`), wait `/healthz`, seed via
`mix driftwood.seed`. Drive TWO sessions to the same thread (`/chat/:id` as a tenant;
`/operator/desk-chat/:id` as the operator): send a message with a `samen:` ref from the tenant;
assert the operator session receives it realtime, the body/identity render `••••`, and the SAME
unfurl card renders clear for the tenant and masked for the operator. Screenshot both.

---

## 9 · Staging (minimal-viable → rich; each stage independently green)

- **Stage A (kernel of the flagship, gates first):** `Samen.Scopes.Chat` blueprint
  (Thread/Participant/Message, body vaulted) + abbrev-registry append (§11) + `Samen.Web.Chat.
  Reads` + `Samen.Web.ObjectRef.{parse,resolve}` + `DefaultCard` + `chat_unfurl_masking_test`.
  This alone proves the crown jewel (per-viewer unfurl masking) — the highest-value seam.
- **Stage B (realtime):** `Chat.PubSub` + `ThreadLive` subscribe/broadcast/`handle_info` +
  `chat_realtime_test`. Presence (who's-online/typing) with non-PII meta.
- **Stage C (identity model):** `ChatDisclosureSetting` + `Chat.Identity.disclosed?/3` + the
  3-state test. `disclosure_mode` snapshot at thread create.
- **Stage D (registry + host surface):** override `Registry` + first-class cards (crm/support/
  billing) + `samen_chat_routes` macro + driftwood wiring (tenant + operator-desk) + the
  `freight.driver` vertical override + browser self-verify.

Each stage leaves all suites green; a stage can ship without the next.

---

## 10 · Seams (where a vertical / future work plugs in, without touching the framework)

- **New resource → free unfurl.** Catalog a new resource (any vertical); `samen:<key>:<id>`
  unfurls it via `DefaultCard`, masked-per-viewer, with zero cards written.
- **Bespoke card.** Register `key → card module` on the mount's `:object_cards` label (data).
- **Alternate pubsub/presence.** `:pubsub` / `:presence` labels on the mount.
- **New disclosure policy.** `Chat.Identity.disclosed?/3` is the ONE precedence function; a new
  state is a new clause + a stored field, not a new masking path.
- **Cross-plane for a new plane pair.** The impersonation bridge (`Plane.operator/3`) is the
  seam; any new plane that carries a target `org_id` inherits cross-plane visibility.

---

## 11 · `samen_core` impact — abbrev-registry appends ONLY (the sole sanctioned change)

`samen_core` code is UNTOUCHED. The chat scope's four resources need permanent, registry-checked
abbrevs (the ONLY sanctioned `samen_core` change per the hard rules), appended to
`samen_core/priv/abbrev_registry.json` under each HOST module name at build time:

| Resource | Abbrev |
|---|---|
| `<Host>.Chat.ChatThread` | `cth` |
| `<Host>.Chat.ChatParticipant` | `chp` |
| `<Host>.Chat.ChatMessage` | `cmg` |
| `<Host>.Chat.ChatDisclosureSetting` | `cds` |

(Collision-checked against `samen_core/priv/abbrev_registry.json`: `cth`/`chp`/`cmg`/`cds` are
free; `cpt` is already owned by `Demo.CmsScope.Post`, so the participant abbrev is `chp`.)

No kernel logic changes: chat reuses `Samen.Resource`, `Samen.Policy.{OrgScope,SameOrgFk,
RoleAtLeast}`, `Samen.Api.PiiResolution`, `Samen.Catalog`, `Samen.Masked`, `Samen.Reveal`, and
`Samen.Web.{Mount,Plane,Router,Live}` verbatim. The flagship is a COMPOSITION of existing kernel
primitives — which is exactly why it is "only possible here."

---

## 12 · Decision summary

1. **Chat-specific model** (`Samen.Scopes.Chat`: Thread/Participant/Message/DisclosureSetting),
   NOT a reuse of Support — because cross-plane participants + the 3-state identity model need
   first-class seams. Reuse the PROVEN body-vault + org-scope shape.
2. **Cross-plane visibility** = tenant-owned thread + operator-reaches-via-impersonation (mirror
   of ADR-010's "Open account"), so `OrgScope` is satisfied for both parties with NO new policy.
3. **Realtime** = PubSub topic per thread with an **id-only** envelope (plaintext never transits
   PubSub); each subscriber re-reads per its own plane. Presence meta is non-PII (handle only).
4. **Object unfurl** = `Samen.Web.ObjectRef` — parse-at-send, resolve via host resource under
   `OrgScope` (authorization) + `PiiResolution` (masking per viewer's plane) + a catalog-driven
   default card with a thin override registry. **Masking BY CONSTRUCTION; a framework primitive,
   not a chat trick.**
5. **Identity model** = a `disclosed?/3` precedence over stored consent (`disclosure_mode` +
   `identity_shared`) that chooses WHICH PLANE'S ACTOR resolves a participant's identity — clear
   (tenant plane) when consented, `••••` (operator plane) otherwise. Three states, all through
   `PiiResolution`, no bespoke masking branch.
6. **Host surface** = `samen_chat_routes` (ADR-009 Router style) — a tenant chat and a SaaS-desk
   chat are the SAME LiveViews on different planes.
7. **`samen_core`** = abbrev-registry appends only. Everything else is framework-level in
   `samen_web`; the driftwood vertical only proves it.
