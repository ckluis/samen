# ADR-004 — Scope packaging: how a universal scope ships and how a host mounts it

- **Status:** Accepted
- **Date:** 2026-07-05
- **Task:** T3.1 (Identity scope + canonical policy patterns + scope-authoring guide)
- **Deciders:** opus (T3.1), reviewed against `docs/plan.md` §7 Phase 3 and the vision doc
  (`docs/samen-foundry.txt`) — "The inherited 80%" scope table (:309), "The proof — one base,
  many shapes" (:357), "The external surface" (:693).
- **Supersedes:** nothing. First ADR to stake the packaging seam every scope (T3.2–T3.7) copies.

---

## 1 · Context — the real open decision

Samen's thesis is that every product **inherits** seven universal scopes as Ash resources "in the
same idioms — catalogued, PII-safe, malleable" (doc :311). Phase 3 must make that inheritance real:
Identity first (org · user🔒 · membership · role · api_key · invitation🔒 · audit), then a six-scope
fan-out (CRM/Billing/Marketing/CMS/Support/Primitives).

The packaging question is genuinely open and load-bearing, because a Samen resource is **not**
context-free. `use Samen.Resource` requires four things that only the *host* can supply:

1. `otp_app:` — the application whose config the verifiers read
   (`Application.get_env(otp_app, :ash_domains | :ecto_repos | :catalog_parity_allow_list)`).
   Every verifier (`catalog_parity`, `prefixes`, `pii_reads`, `pii_classify`, `no_plaintext_pii`)
   resolves `otp_app = Mix.Project.config()[:app]` — the **host's** app, not `:samen_core`.
2. `repo:` (in the `postgres do … end` block) — the host owns the one Postgres. Identity rows and
   PII vault rows must live in the **host's** repo so crypto-shred, the destruction oracle, and the
   operator plane all see one database (doc: "one Postgres per product").
3. `domain:` — the host's Ash domain, so `Ash.Domain.Info.resources/1` (which the catalog and the
   ghost-table check enumerate) returns Identity resources.
4. the **catalog rows** — `tam_table`/`fld_field` must be written into the *host's* catalog tables,
   in the *host's* migration transaction (`Samen.Migration.catalog_sync/1`), or `catalog_parity`
   fails closed with a "ghost table" violation.

So the naive framing "ship Identity as library-defined Ash resources in `lib/samen/scopes/identity/`
that a host app mounts" cannot be literal. A resource module compiled *inside* `samen_core` with
`otp_app: :samen_core, repo: Samen.SomeRepo` would be:

- **invisible to the host's catalog** — the host's `catalog_sync` enumerates the host's domains, which
  do not contain `Samen.Scopes.Identity.Org`;
- **invisible to the host's verifiers** — they read the host's `otp_app` config, so a
  `Samen.`-namespaced resource in a foreign otp_app is either not scanned (silent gap) or, if forced
  into the host's `:ash_domains`, flagged as a ghost table because its repo/table live elsewhere;
- **wrong for tenancy** — its rows would land in a `samen_core`-owned repo, splitting PII across two
  databases and breaking the single-Postgres crypto-shred guarantee.

The two framings the task named ("library-defined resources the host mounts" vs "generated into the
host") therefore collapse to one real axis: **who owns the compiled resource module — and how does the
library-authored definition acquire the host's `otp_app`/`repo`/`domain` without a copy-paste fork per
host?**

---

## 2 · Options considered

### Option A — Pure library resources (`Samen.Scopes.Identity.Org` compiled in samen_core)

Ship fully-formed resource modules in `samen_core/lib/samen/scopes/identity/`, each with
`otp_app: :samen_core` and a `repo` the library picks. The host adds the library's *domain* to its
`:ash_domains`.

**Rejected.** Fails all four host-ownership requirements above. The host's catalog never gets rows for
`samen_core`-owned tables; `catalog_parity` (which enumerates the host's domains and diffs the host's
`tam_table`) either ignores them (a real hole — an uncatalogued scope) or, if the host force-adds the
library domain, reports ghost tables because the physical tables were created against a foreign repo.
The verifiers would need per-scope special-casing — exactly the "verifiers working unchanged"
requirement the task forbids breaking. And PII would live in `samen_core`'s repo, not the host's — a
tenancy and crypto-shred split.

### Option B — Copy generation (mix task stamps `.ex` files into the host)

A `mix samen.gen.scope identity` copies template `.ex` files into `lib/host/identity/`, rewriting the
module namespace/otp_app/repo. The host then owns real source files.

**Rejected as the *primary* mechanism, kept as an escape hatch.** It satisfies host-ownership, but:

- the scope's *definition* is then forked into every host — a bug fix or a new field in the canonical
  Identity scope must be re-generated and re-diffed into N hosts (the exact drift the Rule-of-Three
  buyer is trying to escape; doc :959 "inherited infrastructure, not a domain model");
- the fan-out gate (T3.14) has to police "did every host's generated copy stay consistent" instead of
  "is the single definition correct" — it moves the consistency burden from compile time to review
  time;
- generated `.ex` files are heavy to keep warning-clean under `--warnings-as-errors` across host
  upgrades.

Generation is the right tool for the **top rung of the malleability ladder** (a vertical that wants to
*fork* a scope and diverge — Phase 3.10 `Samen.Context` / Phase 5), not for the inherited 80% that
should stay singly-defined.

### Option C (CHOSEN) — Library-authored *blueprint macro*, host-materialized resources

`samen_core` ships the Identity scope as a **blueprint**: a single macro per resource
(`Samen.Scopes.Identity.Org`, `…User`, `…Membership`, …) that expands into a real `use Samen.Resource`
resource **in the host's module namespace, with the host's `otp_app`/`repo`/`domain`**. The host mounts
the whole scope with one call:

```elixir
defmodule Demo.Identity do
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Identity,
    otp_app: :demo,
    repo: Demo.Repo,
    namespace: Demo.Identity   # host owns the module names: Demo.Identity.Org, …
end
```

The macro defines `Demo.Identity.Org`, `Demo.Identity.User`, `Demo.Identity.Membership`,
`Demo.Identity.Role`, `Demo.Identity.ApiKey`, `Demo.Identity.Invitation` — each a normal Samen resource
whose `otp_app`/`repo`/`domain` are the host's, whose columns therefore appear in the **host's** catalog,
and whose PII routes into the **host's** vault. The scope's *shape* (attributes, PII declarations,
policies, RBAC) is authored once in `samen_core`; the *identity* (namespace, tenancy, catalog) is the
host's. Audit is **not** duplicated — Identity's audit surface is the existing T2.2 `aud_event` tier,
written via `Samen.AuditEvent.insert/2` (see §5).

**Chosen** because it is the only option that keeps all four host-ownership invariants **and** a single
canonical definition:

| Requirement | A (pure lib) | B (copy-gen) | **C (blueprint)** |
|---|---|---|---|
| Resources in the HOST's catalog | ✗ | ✓ | **✓** |
| Verifiers unchanged (read host's otp_app) | ✗ | ✓ | **✓** |
| PII in the host's single Postgres | ✗ | ✓ | **✓** |
| One canonical definition (no per-host fork) | ✓ | ✗ | **✓** |
| Demo mounts Identity end-to-end | ✗ | ✓ | **✓** |
| New field ships to all hosts by upgrade | ✓ | ✗ | **✓** |

---

## 3 · The decision

**Universal scopes ship as library-authored blueprint macros in `samen_core`
(`lib/samen/scopes/<scope>/`). A host mounts a scope by `use`-ing the scope macro inside its own Ash
domain, passing `otp_app`, `repo`, and a `namespace`. The macro expands into real `use Samen.Resource`
resources owned by the host — catalogued in the host's catalog, scanned by the host's unchanged
verifiers, with PII in the host's one Postgres. Migrations ship as a documented, host-run
`Samen.Migration` template (copied into the host's `priv/repo/migrations/`, one per scope), because
DDL + `catalog_sync` must execute in the host's repo's migration transaction. Audit rides the T2.2
`aud_event` tier and is never duplicated.**

### Why the macro can safely define host-owned resources

- `use Samen.Resource` already takes `otp_app`, `domain`, `data_layer`, and `abbrev` as options and
  `repo` inside `postgres do … end`. The blueprint macro simply threads the host's values into those
  slots. Nothing about `Samen.Resource` assumes a fixed otp_app.
- Module names are the host's (`namespace: Demo.Identity` → `Demo.Identity.Org`). The abbrev registry
  (`priv/abbrev_registry.json` in `:samen_core`) records the **host** module string as the owner —
  consistent with how the demo's `Demo.Crm.*` are already registered there. Abbrevs stay permanent and
  collision-checked across all hosts sharing the registry.
- FKs target host-owned composed resources (Membership → User, Membership → Org), never a fragment —
  the same "belongs_to points at a real queryable resource" rule the doc states (:365).

### Migrations: why a copied template, not a mix task (for now)

The catalog-in-migration-transaction guarantee (`Samen.Migration`, ADR-lineage from S0.4) requires the
DDL and the `catalog_sync` INSERTs to run in **one** transaction in the **host's** repo. Ash's codegen
cannot interleave the catalog data rows (see `Samen.Migration` moduledoc). We therefore ship the
Identity migration as a **documented `Samen.Migration` template** the host copies into
`priv/repo/migrations/` and runs with its own `Demo.Repo`. This is the same pattern the demo already
uses for `CrmResources`. A `mix samen.gen.migration.scope` task that stamps the template with the host's
namespace/table names is a **registered follow-up** (low-risk, mechanical) — deferred so T3.1 ships the
load-bearing seam (the blueprint + a working host mount) rather than a generator. The template is
authored once in `samen_core/priv/scopes/identity/migration.exs.eex`-style reference and mirrored in the
scope-authoring guide; the demo's copied migration is the executable proof.

### What "unchanged verifiers" means concretely

`bash demo/ci.sh` runs the five verifiers + the Phase-2 additions against the demo's `otp_app: :demo`.
After mounting Identity, `Demo.Identity` is added to `:demo, :ash_domains`, its tables get catalog rows
from the copied migration, and **every verifier passes with zero code changes to the verifier tasks**.
The T3.1 red path `unregistered scope resource fails catalog_parity` proves the converse: a mounted
resource whose migration forgot `catalog_sync` is caught as a ghost table.

---

## 4 · Consequences

**Positive**

- One canonical Identity definition; T3.2–T3.7 copy the *blueprint pattern*, not the resources.
- Host owns tenancy, catalog, and PII — single Postgres, single crypto-shred surface, single catalog.
- Verifiers, oracle, and operator plane need zero per-scope special-casing.
- A scope upgrade (new field) reaches every host by bumping the `samen_core` dep + running one
  additive `Samen.Migration` (`catalog_sync(only: […])`).

**Negative / accepted costs**

- The blueprint macro is metaprogramming-heavy: a resource is defined inside a `quote` block. Mitigated
  by keeping each resource's body a plain `use Samen.Resource` (no conditional DSL), and by the demo
  mount being the compile-time proof that the expansion is well-formed.
- Migrations are copied templates, not fully generated — a documented seam (the `mix samen.gen` task is
  a follow-up). The host must run the migration; the guide states this explicitly.
- The abbrev registry is global to `:samen_core`, so two hosts in the same repo cannot both claim
  abbrev `usr` for their own `User`. Accepted: the demo is the single reference host; multi-host abbrev
  namespacing is a Phase-6 generalization concern, noted here as a seam.

**Neutral**

- Policies ship *in the blueprint* (authored once), so RBAC/org-scope are inherited, not re-authored —
  this is the point of §4 of the scope-authoring guide.

---

## 5 · Audit — rides T2.2, never duplicated

The scope table lists `audit` under Identity (and again under Primitives). This is **not** a new table.
Identity actions that must leave an audit trail (role change, api_key mint/revoke, invitation accept,
membership grant) call `Samen.AuditEvent.insert/2` — the existing append-only, partitioned, REVOKE +
trigger-guarded `aud_event` tier (T2.2). The `aud_subject_id`/`aud_actor_id`/`aud_detail` columns carry
only opaque IDs and operator tokens (the token-only invariant the `no_plaintext_pii` `AudEvent` tier
enforces). Identity therefore contributes *writers* to the audit tier, not a schema. The
scope-authoring guide (§6) states this as a hard rule: **a scope never defines its own audit table.**

---

## 6 · Red paths this ADR commits to (proven in T3.1)

1. **Unregistered scope resource fails `catalog_parity`** — a mounted Identity table with no
   `catalog_sync` row is a ghost table (fail closed). Proven by a scratch-sabotage probe.
2. **Cross-org read denied** — Identity's org-scope policy filters every tenant-plane read by
   `org_id` from the actor's membership; a foreign-org read returns `[]`/forbidden (policy matrix
   property test).
3. **Role escalation denied** — a non-admin actor cannot mint/alter a role above their own; the RBAC
   check denies.
4. **api_key cannot out-reach its actor** — a key's effective scope is `∩` its minting membership's
   role; a key cannot read what its actor cannot.
5. **Invitation PII vault-routed** — invitation email routes through the vault (`%Masked{}` default);
   the `pii_reads`/`no_plaintext_pii`/`vault_declared` verifiers pass, and a red-path proves an
   un-vaulted invitation email would fail them.
</content>
