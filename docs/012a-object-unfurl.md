# Task 012a — Object-Unfurl framework capability (ADR-012 Stage A, the crown jewel)

- **Status:** Shipped, all suites green. `samen_core` UNTOUCHED (842 tests pass).
- **Scope:** the STANDALONE `Samen.Web.ObjectRef` framework service (ADR-012 §4) — parse a
  `samen:<key>:<id>` ref out of any text, ORG-SCOPE-authorize the viewer, resolve via the
  Mount-derived resource + catalog, and render a **masking-aware-per-viewer** card through a
  catalog-driven default + a per-resource override registry. This does NOT depend on chat
  (chat is Stage B); it is reusable anywhere a catalogued object needs a live preview.

---

## What shipped (framework-level in `samen_web`)

| Module | Role |
|---|---|
| `Samen.Web.ObjectRef` | `parse/1`, `resolve/3`, `resolve_string/3`, `to_string/2`, `ref_for/2`, `from_string/1`. The resolver = compose OrgScope (load) + PiiResolution (mask) over the host's own resource. |
| `Samen.Web.ObjectRef.Catalog` | ref-key ↔ resource module (derive-from-namespace). `key_for/1`, `resource_for/2`. |
| `Samen.Web.ObjectRef.Card` | the render-ready, plane-neutral card struct (values are already-resolved). |
| `Samen.Web.ObjectRef.FieldValue` | the ONE masking-safe field formatter (a `%Masked{}` passes through untouched). |
| `Samen.Web.ObjectRef.DefaultCard` | catalog-driven default — renders ANY catalogued resource, masked-per-viewer, ZERO cards written. |
| `Samen.Web.ObjectRef.Registry` | override map (`key → card module`); host `:object_cards` label wins over the framework set; falls back to the default card. |
| `Samen.Web.ObjectRef.Cards.{Person,Company,Ticket,Invoice}` | first-class overrides for the inherited scopes. |
| `Samen.UI.object_card/1` | the `<.object_card>` component (renders a `%Card{}` or an `{:error, reason}` "not available" chip). |
| `samen_ui.css` | `.obj-card*` styles (append only). |

Files: `samen_web/lib/samen/web/object_ref.ex` (+ `object_ref/` dir),
`samen_web/lib/samen/ui.ex` (object_card component), `samen_web/priv/static/assets/samen_ui.css`.

---

## The ObjectRef API

```elixir
# Parse refs out of plaintext (ONCE, at send time, before the body is vaulted).
Samen.Web.ObjectRef.parse("look at samen:crm.person:<uuid>") ::
  [%Samen.Web.ObjectRef{key: "crm.person", id: "<uuid>", raw: "samen:crm.person:<uuid>"}]
# A bare UUID with no `samen:` prefix is IGNORED (no false positives).

# Resolve a ref into a render-ready, per-viewer card. `mount` carries namespace+repo+plane;
# `scope` carries the viewer's actor (org_id + plane).
Samen.Web.ObjectRef.resolve(mount, scope, %ObjectRef{key: key, id: id}) ::
  {:ok, %Card{}}                       # every field ALREADY resolved through PiiResolution
  | {:error, :unknown_key}             # key maps to no catalogued resource for this mount
  | {:error, :not_found}               # no row under the viewer's org-scope (== cross-org)
  | {:error, :forbidden}               # a load raised (fail-safe)

# Convenience: build/parse ref strings + resolve a stored ref string directly.
Samen.Web.ObjectRef.to_string(key, id) :: "samen:<key>:<id>"
Samen.Web.ObjectRef.ref_for(resource_module, id) :: "samen:<key>:<id>"
Samen.Web.ObjectRef.resolve_string(mount, scope, "samen:crm.person:<uuid>") :: {:ok, %Card{}} | {:error, _}
```

**Masking by construction (no bypass anywhere):** `resolve/3` is exactly two kernel gates over
the host's own resource: (1) `Ash.read!(scope: scope)` → `Samen.Policy.OrgScope` narrows to
`scope.actor.org_id`; (2) `Samen.Api.PiiResolution.resolve/4` rewrites vaulted fields per plane.
There is NO path that reads a column directly, unwraps a `%Masked{}`, reveals through the vault,
or bypasses `Ash.read`. A resolver failure fails SAFE (inert chip, never plaintext, never a raise
to the user). The `<.object_card>` component renders each value verbatim, so a `%Masked{}` renders
`••••` through `Phoenix.HTML.Safe`.

**Ref-key convention:** `<scope>.<resource>` = the last two module segments lowercased+dotted
(`Driftwood.Crm.Person → "crm.person"`). Host-agnostic and stable; the mount's namespace supplies
the host root, so a ref never embeds a host module name. Resolution is cross-scope (a `:crm` mount
resolves `support.ticket`) because the host root is shared.

---

## Test results (the load-bearing gates)

### `chat_unfurl_masking_test.exs` — THE CROWN JEWEL (per-viewer + org-scope), all pass
- **TENANT viewer** resolves `samen:crm.person:<id>` → card title `"Aurelia Sentinelson"`
  (clear), rendered HTML shows the real name + email.
- **OPERATOR viewer** resolves the SAME ref → card title `%Masked{}` (`••••`); rendered HTML has
  the mask sentinel and the tenant plaintext name/email/phone are ABSENT; no `vt_` / `pii_` token.
- **Same-object invariant:** the SAME ref resolves to the SAME `id` on both planes; the ONLY
  difference is masking (clear binary title vs `%Masked{}` title).
- **Cross-org (red path 2):** a `samen:crm.person:<id>` for a DIFFERENT org's row →
  `{:error, :not_found}` for BOTH a tenant and an impersonating operator viewer; the "not
  available" chip carries no plaintext from the foreign row. Indistinguishable from a nonexistent
  id (no existence oracle).
- **Unknown key:** `{:error, :unknown_key}` (inert chip, never a raise).

### `object_ref_test.exs` — grammar, catalog, default card, registry, all pass
- `parse/1`: extracts/orders/de-dupes refs; ignores bare UUIDs and non-UUID ids; nil/empty safe;
  `to_string → parse → from_string` round-trips.
- `Catalog`: `key_for/1` = last-two-segments; `resource_for/2` derives the host resource and
  resolves cross-scope; `:unknown_key` for nonexistent/malformed keys.
- `DefaultCard` FRAMEWORK PROMISE: a person resolved on the operator plane, rendered by the
  catalog-driven default card with NO override, has a `%Masked{}` title and `%Masked{}` vaulted
  fields (emails/phones) — the `pii do` declaration honored transitively, ZERO cards written.
- First-class `Cards.Person` override surfaces NO clear identity on the operator plane.
- `Registry`: framework cards registered for the inherited scopes; a host `:object_cards` label
  WINS over the framework set (the vertical seam).

Command: `mix test test/samen/web/object_ref_test.exs test/samen/web/chat_unfurl_masking_test.exs`
→ **22 passed**.

### Honest note (a real property, not a bug)
The CRM `Person.display_name` is a NON-vaulted kernel attribute (the kernel does not classify it
as PII), so the catalog-driven DEFAULT card renders it clear on BOTH planes. That is by-
construction correct per the kernel's own classification. The first-class `Cards.Person` override
is deliberately tighter — it titles with the vaulted `full_name` and omits `display_name`, so an
operator's person card carries no clear identity at all. Both behaviors are asserted.

---

## Suite status (green before AND after)
- `samen_web`: **129 passed** (`mix test`), `mix compile --warnings-as-errors` clean.
- `driftwood`: **89 passed** (1 property, 88 tests).
- `demo`: **403 passed** (17 properties, 386 tests).
- `pawchart`: **35 passed**.
- `samen_core`: **842 passed** — UNTOUCHED (no code change, no abbrev append; the chat
  resources that need abbrevs are Stage B, not this task).

## Browser / live self-verify
- Driftwood booted on `PORT=4035`; `/healthz` → 200; `/crm/contacts` renders 200 with the updated
  `Samen.UI` kit (which now includes `object_card`).
- **End-to-end resolution proof in the LIVE driftwood vertical** (real seeded data, real Ash +
  PiiResolution): the SAME `samen:crm.person:f5026b9d-…` ref resolved to `"Dana Whitfield"` on the
  tenant plane and `#Masked<••••>` on the operator plane, same object id, cross-org →
  `{:error, :not_found}`, unknown key → `{:error, :unknown_key}`.

## Seams for the rest of ADR-012 (unblocked)
- Chat (Stage B) consumes `ObjectRef.parse/1` at send time (store on `ChatMessage.refs`) and
  `ObjectRef.resolve_string/3` per subscriber's plane in `handle_info` — the id-only broadcast
  re-reads per viewer, so unfurl cards mask per plane on the realtime path for free.
- Any vertical registers a bespoke card via the mount's `:object_cards` label (data), e.g.
  `freight.driver` in driftwood; a NEW catalogued resource unfurls via the default card with zero
  cards written.
