# The Samen Cookbook

Top recipes for a generated Samen app (WS-D D9 / AC-G10-3). Every recipe cites the exact
generator command or framework macro **and the shipped file it is verified against** — this
doc is claim-evidence-parity checked by `samen_core/test/doc_recipes_test.exs` (each cited
task/macro must exist in the tree, or the suite fails) and every fenced `bash` command runs
through the D9a doc-command extractor (`samen_core/test/doc_commands_test.exs`): a command
not in CI's executed set fails the build.

Prerequisite: an app scaffolded by `mix samen.gen.app` (see
[getting-started](getting-started.md)). Recipes below use the tutorial's `Harbor` app; swap
in your module/abbrevs.

---

## Recipe 1 — Add a scope (and its first resource)

**Mechanism:** `mix samen.gen.scope` + `mix samen.gen.resource`
(`samen_core/lib/mix/tasks/samen.gen.scope.ex`,
`samen_core/lib/mix/tasks/samen.gen.resource.ex`).
**Verified against:** the permanent post-app generator probe
(`samen_core/priv/gen_post_probe.exs`, a root `ci.sh` step) which runs exactly these
commands against a fresh app and re-runs the app's full 18-step gate.

A *scope* is an `Ash.Domain` namespace you own. The scope generator emits the domain module
and registers it in **both** `:ash_domains` config lists (the app's own + `:samen_core`) so
the verifier gate scans everything mounted there — no hand-edit of config. The resource
generator then lands a Tier-0 resource into it: the resource module (`use Samen.Resource`),
a `Samen.Migration` with abbrev-prefixed columns + `catalog_sync`, the append-only abbrev
reservation, the domain wiring, the four G26 red-path test files and a per-resource
anti-tautology probe.

```bash
mix samen.gen.scope --scope Crm
mix samen.gen.resource --scope Crm --resource Widget --abbrev wdg
mix ecto.migrate
mix samen.catalog.dump --output schema.dict.json
MIX_ENV=test bash ci.sh
```

The `--abbrev` must be a fresh 3-letter lowercase abbrev (permanently reserved in
`samen_core/priv/abbrev_registry.json`; a collision fails the command fail-closed). The
catalog re-dump re-baselines `schema.dict.json` so the gate's drift step stays green.
Correct-by-construction: after `mix ecto.migrate`, the four emitted tests pass and the whole
gate stays green with zero hand-edits (proven by `gen_post_probe.exs` on every root CI run).

---

## Recipe 2 — Bend billing the Driftwood way (Tier-0 config rows)

**Mechanism:** `use Samen.Scopes.Billing` with the `abbrevs:` override — one macro, eight
host-owned resources.
**Verified against:** `driftwood/lib/driftwood/billing.ex` (the shipped freight vertical's
mount) and the Tier-0 convention in `docs/guides/scope-authoring.md` §7.

You never fork the Billing scope to change billing behavior. The mount gives you
`Plan` and `Price` as **Tier-0 config rows** — org-scoped reads, admin-gated writes — and
the tenant *bends* behavior by editing rows, never by forking the product. The Driftwood
idiom (fresh `f`-prefixed abbrevs, because the scope defaults are already owned by the demo
mount in the global registry):

```elixir
# lib/harbor/billing.ex — mirrors driftwood/lib/driftwood/billing.ex
defmodule Harbor.Billing do
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Billing,
    otp_app: :harbor,
    repo: Harbor.Repo,
    namespace: Harbor.Billing,
    abbrevs: %{
      customer: "hbc", subscription: "hbs", plan: "hbp",
      price: "hbr", invoice: "hbi", payment: "hby",
      usage: "hbu", entitlement: "hbe", subscription_event: "hbv"
    }
end
```

Then bend: seed/edit `Harbor.Billing.Plan` and `Harbor.Billing.Price` rows per org (bounded
enums, admin-gated `RoleAtLeast` writes). `mix samen.gen.app` already emits this mount for
you — this recipe is for adding it to a hand-rolled host or re-abbreviating a second mount.
No samen_core code changes; only the data-file registry gains your reserved rows
(append-only).

---

## Recipe 3 — Add a feature flag + ramp it

**Mechanism:** `Samen.FeatureFlags.evaluate/3` over `Primitives.FeatureFlag` Tier-0 config
rows (`rollout_pct`).
**Verified against:** `samen_core/lib/samen/feature_flags.ex` (the ADR-020 engine),
`define_feature_flag` in `samen_core/lib/samen/scopes/primitives/blueprint.ex` (the flag
resource: `enabled` · `rollout_pct` · `target_rules` · `variants`), and the inherited flag
admin `Samen.Web.Operator.FlagAdminLive` mounted at `/operator/flags` by
`samen_operator_routes` (`samen_web/lib/samen/web/router.ex`).

Create the flag as a config row (generated apps have the Primitives mount; the flag admin UI
does this too), then gate your code path:

```elixir
# 1. The flag row (Tier-0 config; admin-gated writes; NonPiiTargeting enforced at write)
Samen.Factory.create!(Harbor.Primitives.FeatureFlag, %{
  org_id: org_id,
  name: "billing.invoice_pdf",
  enabled: true,
  rollout_pct: 10          # start the ramp at 10%
}, authorize?: false)

# 2. The gate — fail-SAFE: OFF on any error, kill switch short-circuits everything
case Samen.FeatureFlags.evaluate("billing.invoice_pdf", %{org_id: org_id, plan: "pro"}) do
  %Samen.FeatureFlags.Decision{on: true} -> render_pdf()
  _ -> :off
end
```

**The ramp:** raise `rollout_pct` (10 → 50 → 100). Bucketing is deterministic
`:erlang.phash2({flag_name, subject_key}, 10_000)` — the same `(flag, org)` buckets
identically forever, so raising the percentage only ever **adds** orgs (off→on), never
reshuffles (the RP-F1 monotonic-ramp property, red-path tested in samen_core).
`enabled: false` is the kill switch — it beats every rule and rollout. Targeting rules key
ONLY off governed non-PII attributes; a rule keyed on a PII-classified attribute is refused
at write by `Samen.FeatureFlags.NonPiiTargeting`. Operators drive all of this from the
inherited `/operator/flags` admin (wire `flags_namespace:` in the cockpit labels — see
Recipe 4).

---

## Recipe 4 — Mount the operator cockpit

**Mechanism:** the `samen_operator_routes` router macro
(`samen_web/lib/samen/web/router.ex`).
**Verified against:** `driftwood/lib/driftwood_web/router.ex` (the shipped Driftwood mount)
— and every generated app's router, which `mix samen.gen.app` emits with this mount already
in place (HTTP-asserted by the flagship probe).

One macro call mounts Accounts (+ the per-account health drill-down), Platform billing,
Revenue, the platform Flag admin, Analytics and the Desk — zero authored LiveView modules:

```elixir
# lib/harbor_web/router.ex — mirrors driftwood/lib/driftwood_web/router.ex
import Samen.Web.Router

scope "/" do
  pipe_through(:browser)

  samen_operator_routes(Harbor.Operator,
    repo: Harbor.Repo,
    operator_org_id: "<your operator org uuid>",
    include_aggregate: false,
    labels: %{
      operator_workspace: "Harbor Ops",
      operator_glyph: "H",
      tenant_landing: "/billing",              # where clear act-as lands
      impersonate_path: "/operator/impersonate",
      flags_namespace: Harbor.Primitives       # activates /operator/flags (Recipe 3)
    }
  )
end
```

Plane semantics are load-bearing: the operator seat reads the operator org's OWN book of
business on the **tenant plane** (clear); crossing into a tenant's world is the explicit
impersonation link, where vaulted PII renders masked (`••••`) by construction. The
`include_aggregate: true` variant adds the token-blind `/operator/aggregate` surface.

---

## Recipe 5 — Add a vaulted PII field + its masking test

**Mechanism:** the `pii do` resource block (`vault` / `pii_attribute` / `reveal`) + the
`Samen.RedPath` test macros `vault_routing` and `policy_matrix`.
**Verified against:** `pawchart/lib/pawchart/clinic.ex` (the shipped 🔒 `microchip` field),
`docs/guides/scope-authoring.md` §5, and the test shapes `mix samen.gen.resource` emits
(`samen_core/lib/samen/gen/post_templates.ex`) — which the post-app probe proves green.

Declare the field on the resource (scalar fields get the `pii_` column prefix):

```elixir
# In your resource — mirrors pawchart/lib/pawchart/clinic.ex ("microchip")
pii do
  vault(:pii_microchip)
  pii_attribute(:microchip, :string, vault: :pii_microchip)  # column pii_<abbrev>_microchip
  reveal(:reveal_pet)                                        # plaintext ONLY via this action, under a grant
end
```

Add the `pii_<abbrev>_<name>` column (type `:text`) in a `Samen.Migration` ending in
`catalog_sync`, run `mix ecto.migrate`, re-dump `schema.dict.json`. The domain row now holds
an opaque `vt_*` token; reads present `%Samen.Masked{}` by construction; the
`no_plaintext_pii`, `pii_reads`, `pii_classify` and `vault_declared_parity` verifiers
enforce the consequences.

**The masking test** — do not hand-roll it; use the emitted `Samen.RedPath` shapes:

```elixir
use Samen.RedPath, repo: Harbor.Repo

# 1. vt_* at rest, plaintext NOWHERE, last-line VaultField guard refuses a raw write
vault_routing(
  resource: Resource, org: Org,
  fields: [:microchip],
  plaintexts: ["VAULT-PLAINTEXT-hunt"],
  attrs: fn org_id -> %{org_id: org_id, name: "row", status: :active,
                        microchip: "VAULT-PLAINTEXT-hunt"} end
)

# 2. masked-by-default on a tenant-plane read (part of the policy matrix)
policy_matrix(resource: Resource, org: Org, role: :admin, pii: [:microchip], ...)
```

These are the exact file-1 and file-3 shapes `mix samen.gen.resource` emits — asserting
`%Samen.Masked{}` on default reads and hunting the named plaintext across row, token column
and vault ciphertext.

---

## Recipe 6 — Expose a field on the API

**Mechanism:** the `show_fields` allowlist in the resource's `json_api` block + the
`mix samen.verify.api_contract` snapshot update.
**Verified against:** the emitted resource template
(`samen_core/lib/samen/gen/templates.ex`, `json_api` block) and the gate's step 16
(`api_contract`), sabotage-proven by the flagship probe.

The API is **deny-by-default serialized**: a field NOT named in `show_fields` is absent from
every payload — even via `?fields=` (AshJsonApi's `show_field?` requires membership), and
`derive_filter?` is off so the filter surface matches the serialization surface (no hit/miss
side channel). To expose `segment` → `status`:

```elixir
json_api do
  type("record")
  show_fields([:id, :name, :segment, :status])  # names are CATALOG names, never storage names
  derive_filter?(false)
end
```

Then version the contract **consciously** — the committed `api_contract.v1.json` pins routes
+ fields, and the gate fails on un-versioned structural breaks:

```bash
mix samen.verify.api_contract --version v1 --update
MIX_ENV=test bash ci.sh
```

Adding a field is additive (the verifier only fails on drops/narrowings), but the snapshot
update keeps the committed contract the reviewable source of truth. A vaulted field enters
the payload only by this same conscious opt-in — it then serializes per plane via
`Samen.Api.PiiResolution` (tenant clear, operator masked/absent), and `org_id` stays
deliberately un-allowlisted (the tenant boundary is internal routing).

---

*Every recipe above cites shipped code. If a cited task or macro disappears from the tree,
`doc_recipes_test.exs` fails; if a fenced command stops being executed by CI,
`doc_commands_test.exs` fails. That is the point.*
