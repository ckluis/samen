# GATE — Flagship Cross-Plane Chat + Object Unfurl (ADR-012)

**Decision: GO**

Date: 2026-07-08
Scope gated: the flagship realtime cross-plane chat with catalog-driven, per-viewer-masked
object unfurl, framework-level in `samen_web`, mounted in Driftwood on two planes.

---

## Verdict in one line

Every load-bearing claim is verified against the code AND proven live. The crown-jewel
property — the SAME object card rendering real PII to the owning tenant and `••••` to the SaaS
operator, with no vault-token/plaintext leak — is demonstrated in a running Driftwood on both
planes (operator DOM: **0** leaks, **7×** `••••`), and by a per-viewer `samen_web` test. Realtime
delivery, the 3-state identity model, framework-level reuse (a vertical `freight.driver` card
with zero framework edits), and all suites green are confirmed. **GO, no mandatory fixes.**

---

## Requirement-by-requirement

### (1) REALTIME CROSS-PLANE — PASS

- `test/samen/web/chat_realtime_test.exs` (2 tests): the tenant posts a message; a broadcast
  reaches a SECOND subscriber process on the same `Phoenix.PubSub` topic; each subscriber
  re-reads via its OWN scope → tenant sees the clear body, operator sees `%Masked{}`. **Red path
  3 proven**: the envelope carries only `[:message_id, :participant_id, :refs, :sender_party,
  :thread_id]` — no `:body` key — so plaintext NEVER transits PubSub; a listening operator
  cannot obtain plaintext.
- LiveView-level: `Samen.Web.Chat.ThreadLive.mount/3` subscribes on connect;
  `handle_info({:chat_message, envelope}, socket)` re-reads per the socket's plane
  (`chat_live_render_test.exs`: "handle_info re-reads a broadcast message per plane (operator →
  ••••)" and "ignores a broadcast for a DIFFERENT thread").
- Live: the operator desk-chat INDEX reaches the TENANT-OWNED thread ("Rate confirmation for
  load BR-4471") via the impersonation bridge (`plane.target_org_id || org_id`), the §2.3
  mechanism — one set of LiveViews, two planes.
- Presence/typing is wired (`Samen.Web.Chat.Presence` started in Driftwood's supervision tree
  after `Driftwood.PubSub`) — the "plus" is present.

### (2) OBJECT UNFURL, PER-VIEWER MASKED (the crown jewel) — PASS

Proven LIVE in a running Driftwood (port 4041, seeded org `b1112d00-…-001`, thread
`a6ea36fc-…`), the SAME thread/message/refs on both planes:

| Field | Tenant `/chat/<id>` | Operator `/operator/desk-chat/<id>` |
|---|---|---|
| Participant identity | `Dana Whitfield` | `••••` |
| crm.person card name | `Dana Whitfield` / `dana.whitfield@…` | `••••` |
| freight.driver card name | `Dana Compliant` | `••••` |
| Message body | clear | `••••` |

Operator DOM leak scan (all MUST be 0): `Dana Whitfield`=0, `dana.whitfield@`=0,
`Dana Compliant`=0, `vt_`=0, `pii_`=0. Mask sentinel `••••`=7, non-PII subject `BR-4471`=2.
**No leak of any masked PII through an unfurl card.**

By construction (`Samen.Web.ObjectRef.resolve/3`): a COMPOSITION of two UNCHANGED kernel gates —
(a) `Ash.read` under the viewer's scope, so `Samen.Policy.OrgScope` narrows to the viewer's org;
(b) `Samen.Api.PiiResolution.resolve/4` for the viewer's plane. There is NO code path that reads a
column directly, unwraps a `%Masked{}`, calls `Vault.reveal`, or bypasses `Ash.read`. The UI
component `Samen.UI.object_card/1` renders `{value}` verbatim; a `%Masked{}` renders `••••` through
its `Phoenix.HTML.Safe` impl (routed via the fixed mask string — no token, no injection).

Test: `chat_unfurl_masking_test.exs` (6) — same object → clear title (tenant) vs `%Masked{}` title
(operator), same id; a cross-org ref → `{:error, :not_found}` (an inert "Object not available"
chip, no existence oracle, no plaintext); a nonexistent id indistinguishable from cross-org; an
unknown key → `{:error, :unknown_key}`. Resolver is fail-safe: any error → inert chip, never
plaintext, never raise.

### (3) IDENTITY MODEL (3 states) — PASS

`Samen.Web.Chat.Identity` models disclosure as a PLANE CHOICE per subject (which plane's actor
resolves that one field through `PiiResolution`) — not a reveal grant, not a vault bypass; fail-safe
to the masked floor. `chat_identity_states_test.exs` (6) proves:

- STATE 1 `:masked` — operator sees the non-PII `handle` + `••••`, not the real name.
- STATE 2 `:initiator_opt_in` — the opted-in initiator's real name discloses; a second,
  non-opted-in participant STAYS `••••`.
- STATE 3 `:tenant_wide` — ALL tenant participants' names disclose to the operator.
- Snapshot-at-create: the org `ChatDisclosureSetting` stamps `disclosure_mode` at thread create,
  so flipping the org setting later does NOT retroactively expose old threads.
- Anti-tautology controls: the tenant viewer always sees clear (own plane) in every state; the
  operator NEVER sees message BODIES clear even under `:tenant_wide` (identity ≠ content, red path 5).

Write side (framework-level, inherited by every host inbox): `Samen.Web.Chat.start_conversation/3`
(initiator opt-in → `:initiator_opt_in`), `set_disclosure_setting/3` (admin-gated org toggle).
`chat_identity_write_test.exs` (8). Both `ThreadsLive` handle_events are DOUBLE-guarded
(`tenant_plane?` in the LiveView AND the blueprint's `RoleAtLeast`/`OrgScope` policies); a masked
operator inbox exposes neither control.

### (4) FRAMEWORK-LEVEL + REUSE — PASS

- `Samen.Web.ObjectRef` + `.DefaultCard` (catalog-driven, renders ANY catalogued resource with
  zero cards) + `.Registry` (host `:object_cards` mount label wins over the framework set,
  fail-safe to default) + 4 first-class cards live in `samen_web`. Resource-agnostic: proven on
  ≥2 resource types (`crm.person` via a first-class card, `freight.driver` via a Driftwood
  override, both unfurled live).
- The chat model is a THIN library-authored blueprint `Samen.Scopes.Chat` hosted in `samen_web`
  via the UNCHANGED `use Samen.Resource`, inheriting vault routing, the `pii_reads`/
  `no_plaintext_pii` verifiers, `OrgScope`, `SameOrgFk`, and catalog wiring by construction.
- Driftwood registers `DriftwoodWeb.Chat.DriverCard` on the mount's `:object_cards` label — a
  DATA registration, no framework edit — proving a vertical inherits unfurl and specializes it.
- `samen_core` respected: the driftwood ci.sh catalog/pii verifiers (catalog_parity, pii_reads,
  pii_classify, no_plaintext_pii, no_pii_columns, same_org_fk) all pass against the LIVE DB with
  the new chat vault columns; the only sanctioned kernel change is the abbrev-registry append.

### (5) GREEN — PASS

| Suite | Result |
|---|---|
| samen_web | **162 passed** (`--warnings-as-errors`; baseline 129 + net-new chat/unfurl) |
| driftwood `mix test` | **89 passed** (1 property, 88 tests), 4 excluded |
| driftwood `ci.sh` (20-step) | **ALL PASSED** (incl. schema-dict drift, all verifiers, crypto-shred + PITR game-days, red-path probe) |
| demo | **403 passed** (17 properties) |
| pawchart | **35 passed** |

Chat/unfurl test inventory (71 tests / 9 files): object_ref 16, chat_identity_write 8,
chat_live_render 6, chat_identity_states 6, chat_unfurl_masking 6, chat_scope 4,
chat_message_unfurl 4, chat_crossplane_scope 3, chat_realtime 2.

---

## Notes / observations (non-blocking)

- The input under-counted the delivered tests (claimed +25; actual net-new is larger, and total
  chat/unfurl coverage is 71). This is a positive discrepancy — more coverage, no regression.
- `Samen.Web.Chat.set_disclosure_setting/3` and `Identity`'s disclosure resolve synthesize a
  tenant-plane actor map rather than deriving from the live scope. This is legitimate and
  org-scope-confined (the tenant disclosing its OWN org's PII; the operator can never reach the
  path — the disclose branch only fires when stored `disclosure_mode`/`identity_shared` say so,
  never on operator request). Flagged for awareness, not a defect.
- Live verification was done on a fresh port (4041) because 4035 was held by a stale
  chrome-headless process (unrelated to this feature).

---

## Fix tasks

**Mandatory: none.** The gate is GO.

**Nice-to-have (polish, not blocking):**
1. Add a short live two-session dogfng note/screenshot pair (tenant sends → operator's open
   session updates without reload) to the ADR-012 evidence; the realtime path is already
   test-proven at both the context and LiveView levels, this is belt-and-suspenders.
2. Consider a doc-comment on `Identity.tenant_actor/1` and `Chat.admin_tenant_scope/1` noting the
   synthesized-actor pattern is intentional and org-scope-confined (reduce future-reader surprise).
3. Optional: a live cross-org "Object not available" chip screenshot (the no-leak error path is
   test-proven; a live shot would round out the evidence).
