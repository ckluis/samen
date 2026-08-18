# Scope-authoring guide — the fan-out template

**Audience:** whoever authors a universal scope (CRM, Billing, Marketing, CMS, Support,
Primitives — tasks T3.2–T3.7) or a new vertical scope. This is the pattern the
**Identity** scope (T3.1) established and every other scope copies verbatim. Read
[ADR-004](../adr/ADR-004-scope-packaging.md) first for *why* scopes are packaged this way;
this guide is *how*.

Reference implementation (copy from these):

- `samen_core/lib/samen/scopes/identity.ex` — the mount macro
- `samen_core/lib/samen/scopes/identity/blueprint.ex` — the per-resource definitions
- `samen_core/lib/samen/scopes/identity/audit.ex` — the audit writers (rides `aud_event`)
- `samen_core/lib/samen/policy/{org_scope,org_is_self,role_at_least,manage_role}.ex` — the policy library
- `samen_core/lib/samen/scope{.ex,/role.ex,/api_key.ex}` — the actor/RBAC/api-key model
- `demo/lib/demo/identity.ex` + `demo/priv/repo/migrations/20260705130000_add_identity_scope.exs` — the host mount
- `demo/test/identity_*_test.exs` — the test conventions (policy matrix + red paths)

---

## 0 · The shape of a scope (what you ship)

A scope is **three files in `samen_core` + one migration template**, plus a mount + tests
in the host:

| File | Role |
|---|---|
| `lib/samen/scopes/<scope>.ex` | the mount macro (`use MyScope, otp_app:, repo:, namespace:`) |
| `lib/samen/scopes/<scope>/blueprint.ex` | the per-resource `define_*` macros (attributes, PII, policies) |
| `lib/samen/scopes/<scope>/audit.ex` | audit writers over `aud_event` (only if the scope emits audit events) |
| `priv/scopes/<scope>/migration reference` (mirrored in this guide) | the copied `Samen.Migration` template the host runs |

The **host** adds: a domain module that `use`s the scope, a copied migration, two config
lines, and the policy-matrix + red-path tests.

Do **not** ship a scope as pre-compiled resources with `otp_app: :samen_core` — see
ADR-004 §2 (Option A rejected): the host must own `otp_app`/`repo`/`domain` or the
resources won't be in the host's catalog and the verifiers won't see them.

---

## 1 · The mount macro (`Samen.Scopes.<Scope>`)

Copy `identity.ex`. The macro:

1. reads `otp_app`, `repo`, `namespace` from the caller and `Macro.expand`s the alias args;
2. resolves the per-resource **abbrevs** to literal strings **at expansion time** (the base
   macro validates abbrevs caller-side and needs a compile-time literal — do NOT pass an
   `abbrevs.foo` AST expression into the blueprint);
3. emits a `resources do … end` block registering every scope resource in the host domain;
4. calls each `Blueprint.define_*` with the host's `otp_app`/`domain`/`repo` + the literal abbrev.

```elixir
defmacro __using__(opts) do
  otp_app   = Keyword.fetch!(opts, :otp_app)   |> Macro.expand(__CALLER__)
  repo      = Keyword.fetch!(opts, :repo)      |> Macro.expand(__CALLER__)
  namespace = Keyword.fetch!(opts, :namespace) |> Macro.expand(__CALLER__)
  domain    = __CALLER__.module
  abbrevs   = resolve_abbrevs(Keyword.get(opts, :abbrevs), __CALLER__)   # → %{atom => literal string}
  # ... Module.concat(namespace, Resource) for each ...
  quote do
    require MyScope.Blueprint
    resources do resource(unquote(res_mod)) ... end
    MyScope.Blueprint.define_thing(unquote(res_mod), unquote(otp_app), unquote(domain),
                                   unquote(repo), unquote(abbrevs.thing))
    ...
  end
end
```

**Gotchas (learned in T3.1):**
- `require MyScope.Blueprint` inside the emitted quote, or the `define_*` macros are undefined.
- Pass `unquote(domain)` (the caller module), never `__MODULE__` inside `bind_quoted`.
- An inline `expr(field == …)` inside a blueprint `quote` is **hygiene-captured** — use a named
  `FilterCheck` module instead (see §3, `Samen.Policy.OrgIsSelf`).

---

## 2 · Ash.Scope: actor + org_id from membership

Every tenant-plane request carries a `%Samen.Scope{}` — a struct with a PII-free `actor` map
`%{id, org_id, role, membership_id}` that implements `Ash.Scope.ToOpts`. Build it from the
actor's Identity membership:

```elixir
scope = Samen.Scope.for_membership(membership)   # or Samen.Scope.new(%{id:, org_id:, role:})
Ash.read(MyScope.Thing, actor: scope.actor, authorize?: true)
```

`Samen.Scope.new/1` **refuses a scope with no `org_id`** (a cross-org hazard → fail closed).
The actor is bounded IDs + an enum role — never a name/email — so it is safe to log/label and
consistent with the `metric_labels` / `no_plaintext_pii` posture. Every scope reuses this — do
not invent a per-scope actor shape.

---

## 3 · The org-scope policy (every tenant-plane read/write filtered by org)

**This is the single most-copied block.** Every tenant-plane resource wires the Ash policy
authorizer and the org-scope `FilterCheck`:

```elixir
use Samen.Resource, ..., authorizers: [Ash.Policy.Authorizer], abbrev: "abc"

policies do
  policy action_type([:read, :create, :update, :destroy]) do
    authorize_if Samen.Policy.OrgScope
  end
end
```

`Samen.Policy.OrgScope` is a `FilterCheck`: on a read it narrows to `org_id == actor.org_id`
(foreign-org rows are **invisible**, not merely forbidden — the correct multi-tenant semantic);
on a write it authorizes only same-org rows. An org-less actor matches **no rows** (fail closed).

- The **org anchor itself** (a resource that IS the tenant, e.g. `Identity.Org`) is org-LESS —
  it has no foreign `org_id`. Use `Samen.Policy.OrgIsSelf` (filters `id == actor.org_id`) instead,
  and declare `org_id` nullable so `CoreAttributes` doesn't inject a NOT-NULL `org_id` the anchor
  can never satisfy (blueprint `define_org`).
- Fields aren't auto-selected: in tests, `Ash.Query.select([:id, :org_id, …])` to assert on the
  tenant boundary or on masked PII (vault fields load on demand).
- **Same-org FK on every `belongs_to` (F3.2).** `OrgScope` guards a row's OWN `org_id` (reads +
  writes to a foreign row), but it does NOT validate that a `belongs_to` FK on an otherwise-same-org
  row points at a same-org target. A missing same-org-FK check let an org-A actor write a same-org
  row whose FK referenced an org-B row — a dangling cross-tenant FK, and (in Marketing) a
  suppression-list bypass. So **every tenant-plane resource with a `belongs_to` FK must add**:

      changes do
        change {Samen.Policy.SameOrgFk, relationships: [:parent_a, :parent_b]}
      end

  `Samen.Policy.SameOrgFk` loads only the target's `org_id` (bounded UUID, no PII) directly from the
  target table — NOT via `Ash.read` (which `OrgScope` would filter, hiding the foreign target and
  passing vacuously) — and refuses the write on a mismatch. Omit `relationships:` to check all
  `belongs_to`. The red-path test: an org-A row referencing an org-B FK must be refused (see
  `marketing_scope_policy_matrix_test.exs` + `crm_scope_policy_matrix_test.exs`).

---

## 4 · RBAC role checks

Roles are a **closed, ranked** set (`Samen.Scope.Role`: `owner`>`admin`>`member`>`viewer`).
Two reusable checks:

- `{Samen.Policy.RoleAtLeast, role: :admin}` — gates *who* may act (rank floor).
- `Samen.Policy.ManageRole` — gates *what role they may set* (no escalation): the actor must be
  `admin`+ AND strictly out-rank the role the changeset sets. A `member` cannot mint an `admin`;
  an `admin` cannot mint an `owner`.

Combine them with `forbid_unless` (deny if either fails):

```elixir
policy action_type([:create, :update, :destroy]) do
  forbid_unless Samen.Policy.OrgScope                     # same org
  forbid_unless {Samen.Policy.RoleAtLeast, role: :admin}  # admin+
  forbid_unless Samen.Policy.ManageRole                   # no escalation
  authorize_if always()
end
```

Store the role as a **bounded `:atom` attribute** with `constraints: [one_of: Samen.Scope.Role.all()]`
— never free text (bounded label cardinality; no `String.to_atom/1` on untrusted input).

---

## 5 · PII routing (🔒 fields)

For every 🔒 field in the scope table, route it through the vault with `pii_attribute`:

```elixir
pii do
  vault :pii_email
  pii_attribute :email, Samen.Type.Emails, vault: :pii_email   # composite → no pii_ prefix
  # scalar example: pii_attribute :ssn, :string, vault: :pii_ssn  → column pii_<abbrev>_ssn
  reveal :reveal_thing                                          # the declared reveal action
end
```

- Composite types (`FullName`/`Emails`/`Phones`) route **by vault name** (column carries the
  resource abbrev, no `pii_` prefix); scalar `pii_attribute`s carry the `pii_` prefix. Both are
  equally vault-routed — the verifiers key on the `pii do` declaration, not the column name.
- The domain column holds an opaque `vt_*` token; reads present `%Masked{}` by construction
  (the `Samen.Type.VaultField` type); plaintext only via the declared `reveal` action **under a
  grant**. The reveal action's `run/2` calls `Samen.Reveal.grant_checker().granted?(ctx)` (default
  deny) — do **not** call a bare `Samen.Reveal.granted?/1` (it does not exist).
- Once you declare the `pii do` block + run the migration, the `no_plaintext_pii`, `pii_reads`,
  `pii_classify`, `vault_declared`, and `vault_declared_parity` verifiers enforce the
  *consequences* of that declaration (masked reads, no plaintext to sinks, no plain-typed column,
  a declared route for every declared vault).
- **Know precisely which check is authoritative for a forgotten free-text 🔒 field.** The gate
  enforces vault *consequences*, not the *presence* of a `pii do` declaration in general. For a
  🔒 field whose logical name IS in the C4 `pii_classify` heuristic token-list
  (`email`/`ssn`/`dob`/`phone`/name-ish/…), forgetting to vault it *is* caught by `pii_classify`
  (it flags the resulting plain-typed column). But for a **free-text 🔒 field whose logical name is
  NOT in that token-list** (`body`, `rendered_body`, `signing_secret`), `pii_classify` does not
  flag it, and the other resource-introspection verifiers key on the `pii do` block that no longer
  exists — so a *de-vault* (dropping the route while the `pii_<abbrev>_<name>` column stays in the
  DB) is caught by exactly two things: (1) the `vault_declared_parity` verifier (C6, review fix
  F3.1), which reads the **DB truth** — every `^pii_[a-z]{3}_` column must have a matching declared
  route, failing closed on the leftover column — and (2) the scope's hand-written
  `*_vault_routing_test.exs` (the authoritative red path: it asserts each 🔒 field writes a `vt_*`
  token and the plaintext appears nowhere). Ship both; do not assume a name-heuristic verifier
  guards a free-text 🔒 field.

---

## 6 · Audit rides `aud_event` — never a new table

The scope table lists `audit` under Identity and Primitives. **A scope never defines its own audit
table.** Audit-worthy actions call `Samen.AuditEvent.insert/2` (the T2.2 append-only, partitioned,
REVOKE+trigger-guarded tier). Ship a thin `<Scope>.Audit` module of writers (copy
`identity/audit.ex`) that insert **token-only** rows (bounded IDs + operator tokens, never subject
PII — the `AudEvent` `no_plaintext_pii` tier enforces this). Do **not** add an `aud_*` table to your
migration.

---

## 7 · Tier-0 config-row convention

The bottom rung of the malleability ladder is **config rows**: a scope ships resources whose rows
are per-org configuration (e.g. `Identity.Role` = the per-org role catalog; a bounded `plan` on the
org; `Billing.Plan`/`Price`). These are normal org-scoped resources with bounded-enum attributes and
admin-gated writes — the tenant *bends* behavior by editing rows, never by forking the product.
Author them exactly like any other scope resource (org-scope + `RoleAtLeast` on writes). Higher rungs
(Tier-1 custom fields T3.8, Tier-2 custom objects T3.9) are separate mechanisms — a scope does not
build them.

**Content-edit vs Tier-0-transition divergence (documented exception).** The default write pattern is
"all writes require a role floor" (`create/update/destroy` gated at `RoleAtLeast`). One deliberate
exception exists and MUST be documented in the scope's moduledoc when used: **CMS `Page`/`Post`**
authorize the default `:update` (a member editing draft content) at `OrgScope` only, while gating the
*lifecycle transitions* `:publish`/`:archive` at admin+. This is the correct editorial RBAC (editors
edit, admins publish), not drift — but because it diverges from the floor-on-all-writes norm, it is an
**explicit choice recorded in `Samen.Scopes.Cms.Blueprint`'s moduledoc (F3.4)**. If your scope needs a
similar member-level-edit / admin-level-transition split, document it the same way; otherwise keep the
standard admin-gated split-read/split-write idiom (`policy action_type(:read)` then
`policy action_type([:create, :update, :destroy])` — NOT a first policy that also lists the write
action_types, which is redundant since Ash ANDs all matching policies).

---

## 8 · Catalog registration (the migration)

Copy the migration template (`demo/priv/repo/migrations/*_add_identity_scope.exs`). Rules:

- `use Samen.Migration` (NOT plain `Ecto.Migration`) so `catalog_sync/1` is available.
- Create every table with **abbrev-prefixed columns** matching what the resource produces
  (introspect with `mix run` + `Samen.Catalog.fields/1` to get the exact column list — do not guess).
- End `up/0` with `catalog_sync(@resources)` — this writes `tam_table`/`fld_field` rows **in the same
  transaction** as the DDL. `down/0` starts with `catalog_sync_down(@resources)`.
- Never `@disable_ddl_transaction true` in a migration that calls `catalog_sync` (it would run the
  catalog INSERT outside a transaction — fail-open; `catalog_sync` refuses at runtime).
- Register the host domain in **both** `config :<host>, :ash_domains` and
  `config :samen_core, :ash_domains` so the verifiers discover the resources.
- Reserve each resource's abbrev in `samen_core/priv/abbrev_registry.json` under the **host** module
  name (permanent, 3-letter, collision-free). A missing/colliding abbrev fails compile.

**The catalog-parity red path:** a mounted table with no `catalog_sync` row is a *ghost table* /
*uncatalogued column* — `catalog_parity` fails closed (proven in
`demo/test/identity_catalog_parity_red_path_test.exs`).

---

## 9 · Test conventions (policy matrix + red paths)

Every scope ships, in the host, the same three test files (copy `demo/test/identity_*_test.exs`):

1. **Policy matrix** (`<scope>_policy_matrix_test.exs`) — through the REAL authorizer against REAL
   Postgres:
   - a **property test**: for many org pairs, an actor scoped to org A reads **zero** of org B's rows
     (cross-org read denied);
   - cross-org write denied; org-less actor sees zero rows (fail closed);
   - positive controls (an actor sees + writes its OWN org's rows) so the checks aren't vacuously
     restrictive;
   - PII masked-by-default on the tenant-plane read (`%Samen.Masked{}`).
2. **RBAC red paths** (`<scope>_rbac_red_path_test.exs`) — escalation denied (member→admin,
   admin→owner) through the authorizer + the pure `Samen.Scope.Role`/`ApiKey` decision functions;
   positive controls.
3. **Vault routing** (`<scope>_vault_routing_test.exs`) — each 🔒 field writes a `vt_*` token; the
   plaintext appears nowhere in the domain row; the `VaultField` last-line guard refuses a raw write.
4. **Catalog-parity red path** (`<scope>_catalog_parity_red_path_test.exs`) — green when catalogued;
   deleting a catalog row makes the verifier fail (anti-tautology probe).

**Anti-tautology discipline (hard rule):** every guarantee ships a red-path test AND a sabotage
probe. Before signing off, temporarily break the check (e.g. make `OrgScope.filter` return
`expr(true)`, or `Role.may_manage?` return `true`) in a **project-local scratch backup**, confirm the
red-path test **flips to failing**, then revert and confirm green. State the probe result in the task
report. (T3.1 did exactly this for `OrgScope` and `may_manage?`.)

Also run `mix compile --warnings-as-errors` and the full `mix test --warnings-as-errors` in both
`samen_core/` and `demo/`, and `bash ci.sh` at the root, before and after.

---

## 10 · Checklist (copy into your scope's task)

- [ ] `lib/samen/scopes/<scope>.ex` mount macro (copy identity.ex; expand aliases; resolve abbrevs to literals)
- [ ] `lib/samen/scopes/<scope>/blueprint.ex` — one `define_*` per resource: `authorizers: [Ash.Policy.Authorizer]`, org-scope policy, RBAC where relevant, `pii do` for 🔒 fields
- [ ] `change {Samen.Policy.SameOrgFk, relationships: […]}` on every resource with a `belongs_to` FK (F3.2 same-org FK guard) + an org-A→org-B FK red-path test
- [ ] `mix samen.verify.vault_declared_parity` green — the DB-truth backstop for a de-vaulted free-text 🔒 field (F3.1); the authoritative removal red path is the scope's `*_vault_routing_test.exs`
- [ ] `lib/samen/scopes/<scope>/audit.ex` (only if the scope audits) — writers over `aud_event`, never a new table
- [ ] abbrevs reserved in `priv/abbrev_registry.json` (permanent, collision-free)
- [ ] host domain module `use`s the scope; registered in both `:ash_domains` configs
- [ ] copied `Samen.Migration` with abbrev-prefixed columns + `catalog_sync(@resources)`
- [ ] `schema.dict.json` regenerated (`mix samen.catalog.dump`) and committed
- [ ] four test files (policy matrix property + RBAC red path + vault routing + catalog-parity red path)
- [ ] anti-tautology sabotage probe run + result stated
- [ ] `mix test --warnings-as-errors` green in samen_core + demo; `bash ci.sh` green
</content>
