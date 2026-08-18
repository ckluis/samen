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

## Recipe 7 — Scaffold CRUD screens with `--live`

**Mechanism:** the `--live` switch on `mix samen.gen.resource`
(`samen_core/lib/mix/tasks/samen.gen.resource.ex`), which emits index / show / form
LiveViews on the `Samen.UI` kit + a mount-smoke test
(`samen_core/lib/samen/gen/post_templates.ex`) and wires the `live/3` routes into the
generated app's router (`samen_core/lib/samen/gen/post.ex`).
**Verified against:** the permanent post-app generator probe
(`samen_core/priv/gen_post_probe.exs`, a root `ci.sh` step), which now runs `--live`,
asserts the three LiveViews + smoke test are emitted, that the generated app STILL
compiles and its full gate stays green with the surfaces present, and that the
index/show/form modules mount + render off a disconnected socket.

By default `mix samen.gen.resource` lands a **headless** data layer — the resource,
migration and the four G26 red-path tests, but no screens. Add `--live` and a builder
gets **visible CRUD** instead: a list, a detail view and a create/edit form, all on the
inherited kit (no bespoke markup, no per-vertical UI library). Requires a `--web` app
(the surfaces mount on samen_web's `Samen.UI`).

```bash
mix samen.gen.resource --scope Crm --resource Widget --abbrev wdg --live
```

This emits, alongside the headless output, three LiveViews under the app's
`lib/<app>_web/<scope>/` tree plus a smoke test under `test/`:

* `widget_index_live.ex` — a kit `data_table` list with a `modal`/`simple_form` create
  and a per-row `delete_confirm`;
* `widget_show_live.ex` — a detail card;
* `widget_form_live.ex` — one `simple_form` serving both create and edit;
* `crm_widget_live_smoke_test.exs` — the mount-lifecycle smoke;

and wires four routes into the router the same alias-relative way the generated app
already mounts its browser surfaces:

```elixir
scope "/", HarborWeb do
  pipe_through(:browser)

  live("/crm/widget", Crm.WidgetIndexLive, :index)
  live("/crm/widget/new", Crm.WidgetFormLive, :new)
  live("/crm/widget/:id/edit", Crm.WidgetFormLive, :edit)
  live("/crm/widget/:id", Crm.WidgetShowLive, :show)
end
```

**Masking by construction.** Each screen reads through Ash under a `%Samen.Scope{}`
carrying `plane: :tenant`, so the resource's read preparation
(`prepare(Samen.Api.PiiResolution)`) resolves the 🔒 vault field per plane before the
LiveView ever sees it. The surface renders the ALREADY-RESOLVED value — clear on the
tenant plane, `••••` on the operator plane — so it **never hand-masks** and a `vt_*`
token never reaches the DOM. On the form, the kit's `form_field/1` renders a vaulted
value on the operator plane as a read-only `••••` with no `name` (it can never
round-trip plaintext). This is the same `Samen.Api.PiiResolution` seam Recipe 5's tests
pin, exercised end to end in the emitted mount-smoke test.

---

## Recipe 8 — Run a crypto-shred

**Mechanism:** `Samen.Erasure.shred/2` (`samen_core/lib/samen/erasure.ex`) — the ONE entry
point that erases a subject. It is a key-destruction job, not a copy-chasing job: destroying
the subject's KMS key makes every one of their vaulted values undecryptable, across live,
replica, backup/PITR, CDC mirror, rollup and audit tiers, at once.
**Verified against:** `samen_core/test/erasure_test.exs` (the green/red-path suite),
`driftwood/priv/gameday/crypto_shred_gameday.exs` (the real game-day script that runs `shred/2`
against seeded subjects end-to-end), and `samen_core/lib/mix/tasks/samen.verify.no_plaintext_pii.ex`
(the T2.9 post-shred destruction oracle).

Trigger a shred for a subject — any resource's `id` that owns vaulted fields (a `User`, a CRM
`Person`, a driver row) is a valid subject id:

```elixir
{:ok, %{attestation: attestation, report: report}} =
  Samen.Erasure.shred(subject_id, repo: Harbor.Repo, actor_id: "operator:dpo")

attestation.state       # :shredded — the KMS tombstone is positive
report.outcome          # "shredded" (first call) | "already_shredded" (idempotent re-run)
report.vault_rows_sealed
```

Under the hood (module doc, `erasure.ex:13`): the key is destroyed FIRST and outside the DB
transaction (the key store is external — [ADR-001](../adr/ADR-001-key-hierarchy.md)); then, in
ONE `Ecto.Multi`, every `pii_vault` row for the subject is stamped `state: "shredded"`,
registered `non_pii!` plaintext columns are redacted, every registered rollup is rebuilt
subject-free or has its derived row suppressed, and an `"erased"` audit row lands on the
hash-chained lifecycle log. A second `shred/2` for the same subject is safe — it's idempotent
by construction (see the moduledoc's "Idempotence" section).

**Test it worked** two ways. Cheaply, in-process:

```elixir
Samen.Erasure.erased?(subject_id, repo: Harbor.Repo)   # => true
```

`erased?/2` requires ALL of: a positive `:shredded` KMS tombstone, the wrapped key material
actually gone (not just tombstoned — defence in depth), and zero `"active"` vault rows for the
subject. The stronger, tier-by-tier proof is the destruction oracle in post-shred mode — it
scans domain rows, vault, `aud_event`, rollups, and the KMS store as a separate OS process and
asserts none of them holds recoverable plaintext:

```bash
mix samen.verify.no_plaintext_pii --subject 3f2a9c10-0000-0000-0000-000000000000 --tiers all
```

`--tiers all` is the only value the task accepts (any other value is refused, fail-closed —
see the task's moduledoc). Run it against a real shredded subject id from your app; the
driftwood game-day script is the reference for wiring it into a repeatable drill.

---

## Recipe 9 — Write a sabotage patch

**Mechanism:** the `scripts/sabotage.sh` discipline — a committed `.patch` per guarantee,
applied → the named tests MUST fail → reverted with a SHA-256 byte-exact restore. This is how
the repo proves a red-path test can actually fail (a test that cannot fail is treated as a
bug) without re-deriving the sabotage by hand on every gate.
**Verified against:** `scripts/sabotage.sh` (the harness itself) and
`scripts/sabotages/16-f1-csv-formula-injection.patch` (a worked example — the CSV
formula-injection neutralization sabotage).

A sabotage patch lives at `scripts/sabotages/NN-<slug>.patch`, numbered sequentially. Find the
next free number, make the breaking change directly in the tree, and capture it as a patch —
these are manual authoring steps (crafting the adversarial change is a judgment call, not a
scripted CI step), run locally as you write a new sabotage:

```bash operator-todo
ls scripts/sabotages/ | sort | tail -1
git diff samen_web/lib/samen/web/csv.ex > scripts/sabotages/25-my-new-sabotage.patch
```

The patch is a normal `git diff` with three required `# KEY: value` header lines BEFORE the
first `diff --git` (the harness's `meta()` helper reads them; `git apply` itself ignores
everything before the diff, so the headers are metadata-only):

```
# SABOTAGE: one sentence — which guarantee this breaks and why the named tests must flip.
# APP: samen_web
# TEST_FILES: test/samen/web/csv_test.exs
# MUST_FAIL: neutralizes every formula-injection lead char on export
diff --git a/samen_web/lib/samen/web/csv.ex b/samen_web/lib/samen/web/csv.ex
index 849fbe4..3bbef8c 100644
--- a/samen_web/lib/samen/web/csv.ex
+++ b/samen_web/lib/samen/web/csv.ex
@@ -326,10 +326,10 @@ defmodule Samen.Web.Csv do
 ...
```

- **`APP`** — the app dir the harness `cd`s into before running tests (`samen_core` |
  `samen_web` | …).
- **`TEST_FILES`** — space-separated test files, relative to `APP`, that hold the tests your
  sabotage must flip.
- **`MUST_FAIL`** — one or more substrings of a test's full name (repeatable). Every one MUST
  appear among the suite's failure headers when the patch is applied — not just "something
  broke," the SPECIFIC guarantee's test.

Hand-prepend the `# SABOTAGE:` / `# APP:` / `# TEST_FILES:` / `# MUST_FAIL:` header lines
above the `diff --git` line in the captured patch, and revert your working-tree change (the
patch IS the change now; the tree should go back to green). Prove it flips before committing
it — `scripts/sabotage.sh` does all five steps for every committed patch: SHA-256 the touched
files, apply, run `TEST_FILES` and assert the `MUST_FAIL` names are among the failures, revert,
and re-SHA to confirm a byte-exact restore. Run it locally against your new patch, then run the
whole committed suite (24 patches as of this writing) — both are opt-in (they deliberately
break the tree and re-run DB-backed suites), so they're run explicitly, not by the default
`bash ci.sh`:

```bash operator-todo
./scripts/sabotage.sh
SAMEN_SABOTAGE=1 ./ci.sh
```

---

## Recipe 10 — Mount surfaces in a fresh vertical (the ≈0-LOC pattern)

**Mechanism:** the router-macro mount pattern — one line per surface, over a mount the app
already authors. No per-vertical LiveView/engine code; the framework surface renders through
`Samen.Web.Mount` + `Samen.Api.PiiResolution` exactly as CRM/Billing/Support do.
**Verified against:** the "Surface → router macro → mount it needs" table in
[`docs/guides/generators.md`](generators.md#mountable-surfaces--the---modules-menu)
and the two shipped mounts that prove it: `driftwood/lib/driftwood_web/router.ex` and
`pawchart/lib/pawchart_web/router.ex`.

Scaffold a base app the normal way (Recipe-1-adjacent — the flagship 3-flag shape):

```bash
mix samen.gen.app --module Harbor --prefix hb --abbrev hrb
```

`mix samen.gen.app` also accepts a `--modules files,search,csv,settings` flag that mounts
these same surfaces AND wires them into a navigation menu automatically (see generators.md);
this recipe shows the underlying macro calls directly, for mounting a surface over a HAND-ROLLED
router or a vertical the generator didn't scaffold this way.

Each end-user surface needs a mount it can render over — Files/Search need a Primitives mount
(materializes `File`/`SearchIndex`), CSV needs any domain with servable resources, Settings
needs an Identity namespace. Once that mount exists, adding the surface is one macro call. This
is PawChart's actual router (`pawchart/lib/pawchart_web/router.ex`) — the SECOND vertical's
proof that these surfaces inherit framework-first, zero PawChart LiveView code:

```elixir
import Samen.Web.Router

scope "/", PawChartWeb do
  pipe_through(:browser)

  # Files (ADR-026) — upload + preview + plane-gated byte-serve, over the Primitives mount.
  samen_files_routes(:files, PawChart.Primitives,
    repo: PawChart.Repo,
    labels: %{title: "Happy Paws Clinic", glyph: "V", crumb_root: "PawChart"}
  )

  # CSV (ADR-028) — per-plane-masked export + governed import, over the CRM domain.
  samen_csv_routes(:csv, PawChart.Crm,
    repo: PawChart.Repo,
    labels: %{title: "Happy Paws Clinic", glyph: "V", crumb_root: "PawChart"}
  )

  # Search (ADR-027) — the ⌘K / per-list search engine, over the Primitives mount.
  samen_search_routes(:search, PawChart.Primitives,
    repo: PawChart.Repo,
    labels: %{title: "Happy Paws Clinic", glyph: "V", crumb_root: "PawChart"}
  )
end
```

Driftwood additionally mounts `samen_settings_routes` (over its `Driftwood.Operator` Identity
namespace) and `samen_chat_routes` (over a materialized `Driftwood.Chat` scope plus a running
`Samen.Web.Chat.Presence` in its supervision tree — the one surface that needs more than a
mount, per generators.md's "why chat is not auto-mounted" note). Both routers cite the exact
ADR each surface implements in a comment above the macro call — copy that convention: it's
what lets a reader trace "why is this line here" back to the design record without asking.

**Masking by construction, again.** None of these macros authors a masking branch. Files
preview, CSV export cells, and search result projections all resolve through
`Samen.Api.PiiResolution` exactly like the CRM/Billing/Support LiveViews (see
[Two-plane + masking concepts](../concepts/two-plane-masking.md)) — mounting a surface never
means re-deriving its masking guarantee.

---

*Every recipe above cites shipped code. If a cited task or macro disappears from the tree,
`doc_recipes_test.exs` fails; if a fenced command stops being executed by CI,
`doc_commands_test.exs` fails. That is the point.*
