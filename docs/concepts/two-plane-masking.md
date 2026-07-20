# Concepts — the two-plane model and PII masking

**Read this before the ADRs.** [ADR-009](../adr/009-samen-web.md) and
[ADR-010](../adr/010-operator-plane.md) are the load-bearing specs — precise, but written as
decision records with rejected alternatives and staging notes. This page pulls the mental
model out of both and states it plainly, the way you'd want it explained before you build your
first Samen surface. It does not replace the ADRs; it's the on-ramp to them.

## The one-sentence version

Every Samen app renders on one of two **planes** — `:tenant` (an org looking at its own data)
or `:operator` (the SaaS company looking at a tenant's data) — and the plane, not the LiveView,
decides whether a PII field renders in the clear or as `••••`. No component ever has a masking
branch; masking is a property of *who is asking*, resolved once, at one chokepoint, before any
UI code runs.

## Why two planes at all

A SaaS product has two audiences that need to see overlapping data through opposite lenses:

- **The tenant** — an org using the product, reading its own customers/records. It owns that
  PII; there is no reason to hide it from itself.
- **The operator** — the SaaS company's own staff, running support/success/billing across
  *every* tenant. They need to see enough to do their job (open a ticket, check a subscription)
  without a standing ability to read any tenant's customer data in the clear.

Naively, "operator support tooling" gets bolted on as a separate admin app with its own queries,
its own accidental plaintext leaks, and its own rules that drift from the tenant app's. Samen's
answer is structural instead: **one framework, one masking resolver, two actor shapes.** The
same `Samen.Web.CRM.ContactsLive` — the literal same module — renders a tenant's contacts in the
clear when the actor is that tenant, and renders the identical page `••••` when the actor is an
operator impersonating that tenant. The plane is data on the actor, not a fork in the code.

## The two planes, concretely

### `:tenant` — an org over its own data

The ordinary case: a logged-in user of org `Blue Ridge` reads Blue Ridge's own CRM contacts,
invoices, tickets. The actor looks like:

```elixir
%{id: "user:...", org_id: blue_ridge_org_id, role: :member, plane: :tenant}
```

`Samen.Policy.OrgScope` narrows every read to rows where `org_id == blue_ridge_org_id`.
`plane: :tenant` tells the masking resolver (below) that this actor owns the rows it's reading
— so vaulted PII resolves in the clear, with **no reveal grant required**. This is the "a tenant
never needs permission to see its own data" rule.

### `:operator` — the SaaS company, either over its own book of business or impersonating a tenant

This is the subtler half, and [ADR-010](../adr/010-operator-plane.md) is entirely about getting
it right. There are actually two different operator situations, and conflating them is the
mistake ADR-010 exists to prevent:

1. **The operator reading its OWN book of business.** The SaaS company is itself an
   `Identity.Org` — the **operator org** — running the same scopes as any tenant, except its
   rows describe *its* customers (which are the tenant orgs), *its* platform billing (tenants'
   subscriptions to the SaaS), and *its* own help desk (tickets tenants file with the SaaS).
   Reading this data is, structurally, **the operator org acting on the `:tenant` plane over its
   own rows** — the actor is `%{org_id: operator_org_id, plane: :tenant}`. Yes, `:tenant` — the
   word "operator" here names the *workspace*, not the masking plane. The tenant-admin contact
   the operator signed up (their name, their email) is the SaaS's own vendor-relationship data,
   so it renders clear, by the exact same rule that lets Blue Ridge see its own contacts clear.

2. **The operator crossing into ONE tenant's downstream world (impersonation).** This is the
   support-agent case: an operator opens Blue Ridge's account to help with a ticket, and now
   reads Blue Ridge's *own* customers — the freight drivers, the CRM contacts Blue Ridge owns.
   This is genuinely someone else's data, so the actor flips to
   `%{org_id: blue_ridge_org_id, plane: :operator, impersonation: %{session_id: ...}}`. PII
   renders `••••` by default; a live, second-party-approved reveal grant is required to see
   plaintext, and every reveal is written to the tenant-readable hash-chained audit log
   ([ADR-002](../adr/002-worm-anchor.md)).

The line between (1) and (2) — which PII is "the SaaS's own" versus "the tenant's own" — is
called **the identity line** in ADR-010, and it is drawn by a mount boundary (operator-namespace
rows vs. vertical-namespace rows) *and* a plane boundary (`:tenant` vs `:operator`) at once, so
one misconfiguration can't leak both barriers at the same time.

## The masking mechanism — `Samen.Api.PiiResolution`

Every 🔒 vault-routed field, wherever it's read, resolves through exactly one function:
`Samen.Api.PiiResolution.resolve/4` (`samen_core/lib/samen/api/pii_resolution.ex`). It is the
single chokepoint every read surface — LiveView reads, JSON:API serialization, CSV export,
search result projection — runs through. No surface hand-masks; they all hand a loaded record
to this resolver and render whatever comes back.

The resolver looks at the field's current value (a `%Samen.Masked{}` — see below) and the
actor's `:plane`:

| Actor shape | `plane_of/1` | What a 🔒 field resolves to |
|---|---|---|
| `%{org_id: same_org, plane: :tenant}` | `:tenant` | **Plaintext**, no grant needed — the org owns this row. |
| `%{plane: :operator, impersonation: %{session_id: _}}` | `:operator` (impersonated) | `%Masked{}` → `••••`, **present but masked**, unless a live reveal grant covers the subject (then plaintext). |
| `%{plane: :operator}` with no impersonation marker (an operator API key) | `:operator` (not impersonated) | `%Ash.ForbiddenField{}` — the field is **absent** from the payload entirely, not just masked. |
| no `:plane` key at all | unrecognised | `%Masked{}` → `••••` — the fail-safe default. |

Three things are worth noticing about this table, because they're the load-bearing design
choices:

- **Impersonation masks-present; an API key masks-absent.** A human operator looking at a UI
  needs to see the *shape* of the data (a field that exists but reads `••••`) to do their job;
  a machine client with no grant gets the field omitted, so `?fields=email` can't be used to
  probe for existence. Both are "no plaintext without a grant," expressed two different ways
  for two different consumers.
- **An unrecognised actor is masked, never plaintext.** There is no "trusted by default" branch.
  Absence of a `:plane` key fails toward `••••`, not toward clear.
- **A failed decrypt (e.g. a shredded key) keeps the value masked, never raises and never
  leaks.** `reveal_plaintext/2` returns `nil` on any decrypt failure and the resolver falls back
  to the `%Masked{}` it already had. This is also what makes crypto-shred (below) safe to run
  against live traffic: a post-shred read of a shredded field degrades to `••••`, not a crash.

## `%Samen.Masked{}`, the vault token, and why `••••` is the *normal* value

A vault-routed field's normal, at-rest, in-memory value is `%Samen.Masked{token: vt_token,
label: :field_name}` — **never** the plaintext. The struct carries an opaque `vt_*` vault token
(a foreign key into the encrypted vault row) and nothing else. This is why masking-by-omission
is structurally hard to get wrong: there is no plaintext sitting in the struct waiting to leak
through a forgotten serializer.

`Samen.Masked` implements every protocol a value can be coerced through, and all of them render
the mask:

- `String.Chars` (`to_string/1`, string interpolation) → `"••••"`
- `Inspect` (`inspect/1`, logger `~p`) → `#Masked<••••>`
- `Jason.Encoder` (JSON API / webhook payloads) → `"••••"`
- `Phoenix.HTML.Safe` (a bare `<%= @person.email %>` in HEEx) → `"••••"`
- `to_iodata/1` (CSV encoders that build iodata) → `"••••"`

So even a careless `Jason.encode!(record)` or a raw `<%= field %>` in a template renders the
mask — there is no serialization path that can produce plaintext from a `%Masked{}`, because the
struct never holds plaintext to begin with. The **only** function in the entire codebase that
returns plaintext for a subject is `Samen.Vault.reveal/3`, and it only runs behind the
`Samen.Reveal` grant seam. Plaintext exists, at most, transiently inside that one call.

## Why every PII surface ships per-plane masking tests

Because masking is a property of the actor, not the component, the thing worth proving for
every *new* surface that renders a 🔒 field isn't "does this field ever show `••••`" — it's "does
this specific surface actually run through the resolver, on both planes, correctly." A test
that only checks the green path (tenant sees plaintext) can't catch a surface that
accidentally bypasses `PiiResolution` and hand-renders a raw column. That's why the house rule
(`CLAUDE.md`, "Per-plane masking tests") requires **three** proofs per surface, not one:

1. **Green** — the tenant plane (and an operator-with-grant) resolves the field to plaintext.
2. **Red** — an operator-without-grant plane resolves to `%Masked{}`: renders `••••`, never the
   plaintext, never a raw `vt_*` token in the DOM/CSV/API payload.
3. **Sabotage twin (anti-tautology)** — the red assertion is proven *refutable*: the same record
   flipped to the tenant plane goes clear (proving the resolver is doing real work, not a
   blanket string replace), and a deliberately-reintroduced plaintext leak IS caught by the same
   scan. A red-path test that can never fail is treated as a bug, not a proof.

`Samen.MaskingCase` (`samen_core/lib/samen/masking_case.ex`) is the shared helper that encodes
this three-part shape so every new surface writes the same non-vacuous proof instead of
re-deriving it:

```elixir
use Samen.MaskingCase

resolved = resolve_on_plane(record, MyApp.Notification, :operator, repo: MyApp.Repo, grant: DenyAllGrant)
assert_plane_masked!(resolved.rendered_body, @secret_plaintext)   # red half
```

`resolve_on_plane/4` runs the exact `Samen.Api.PiiResolution.resolve/4` chokepoint every real
read surface runs through — not a hand-rolled stand-in — so the test proves the real resolver
behaves correctly, not a mock of it. The reference consumers are
`samen_web/test/samen/web/file_preview_masking_test.exs` (the first adopter) and
`samen_web/test/samen/web/notifications_masking_test.exs`; read either before writing a new one.

## Crypto-shred: what erasure means on top of this model

Masking answers "who sees plaintext, right now." Erasure ([`Samen.Erasure`](../../samen_core/lib/samen/erasure.ex),
see also the [cookbook's crypto-shred recipe](../guides/cookbook.md)) answers "can *anyone*,
ever again." A `%Masked{token: vt_token}` only resolves to plaintext because the vault can still
decrypt the ciphertext behind that token with the subject's key. Destroy the key — one call,
`Samen.Erasure.shred/2` — and every vault row for that subject, on every tier (live, replica,
backup/PITR, CDC mirror, rollups, the audit log), becomes permanently undecryptable at once.
The `%Masked{}` struct itself doesn't change; what changes is that `reveal_plaintext/2` now
always fails, so *even a tenant reading its own row* sees `••••` forever after — masking's
fail-closed behavior on a failed decrypt (above) is exactly what makes post-shred reads safe
rather than an unhandled crash.

## Cross-links

- [ADR-009](../adr/009-samen-web.md) — the `samen_web` framework lib, the `Samen.Web.Mount`
  parameterization struct, and the full `Samen.Web.Plane` two-plane specification.
- [ADR-010](../adr/010-operator-plane.md) — the operator/SaaS-company plane, the identity line,
  and why the operator's own workspace is `plane: :tenant` while impersonation is
  `plane: :operator` (§7.2 of that ADR is the exact vocabulary note this page's "two operator
  situations" section is built from).
- [`Samen.Api.PiiResolution`](../../samen_core/lib/samen/api/pii_resolution.ex) — the resolver
  source, including the fail-safe branches this page describes.
- [`Samen.Masked`](../../samen_core/lib/samen/masked.ex) — the struct and its protocol impls.
- [`Samen.MaskingCase`](../../samen_core/lib/samen/masking_case.ex) — the shared three-part
  masking-test helper.
- [Cookbook Recipe 5](../guides/cookbook.md#recipe-5--add-a-vaulted-pii-field--its-masking-test) —
  adding a new vaulted field and its masking test, hands-on.
