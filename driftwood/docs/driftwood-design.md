# Driftwood — Domain Design (T5.1)

**Task:** T5.1 — DESIGN the Driftwood reference vertical: context map, settlement
billing reshape, FMCSA compliance gate, PII inventory, and malleability-rung
placement. This is the **spec the build (T5.2) follows**. No app code is written
here.

**Status:** design complete. Judge-panel synthesis of three settlement-model
approaches (§3.6). Every load-bearing choice is called out as a DECISION; every
gap the build must close is an OPEN RISK (§8).

**Environment note (locked):** Driftwood is a **new top-level app** at
`/Users/clank/Desktop/projects/samen/driftwood/`, matching the repo's convention
(`samen_core/`, `demo/`, `spikes/` are siblings — this repo is **not** an `apps/`
umbrella; see plan OD-1). It mounts `samen_core` scopes exactly as `demo/` does
(`use Samen.Scopes.Crm, otp_app: :driftwood, repo: Driftwood.Repo, namespace: …`)
plus `Samen.Context`. It runs **locally** (Phoenix on localhost, local Postgres
role `clank`). Fly deploy + Neon PITR + AWS KMS/S3 are **operator TODOs**; game-days
(T5.4/T5.5) run as **local simulations** reusing the T2.5 machinery.

---

## 0 · Substrate facts this design is built on (verified against the code)

Everything below was read from the built substrate, not assumed. Citations are to
real files so the build can trust them.

| Fact | Source (read) |
|---|---|
| Scopes mount via `use Samen.Scopes.Crm/Billing/…` blueprint macros that expand into **host-owned** resources in the host namespace, each a normal `use Samen.Resource` with the host `otp_app`/`repo`/`domain`. | `demo/lib/demo/crm_scope.ex`, `demo/lib/demo/billing_scope.ex`; `samen_core/lib/samen/scopes/crm.ex` |
| The CRM/Billing blueprint macros accept an **`abbrevs:` compile-time map literal** override, merged over defaults. So Driftwood can (and must) assign its own abbrevs. | `Samen.Scopes.Crm.__using__/1` `resolve_abbrevs/2` |
| Kernel **Company** attrs: `name, domain, industry, size, website, notes, custom`. No PII. Admin/member-gated writes, `OrgScope` read. | `crm/blueprint.ex` `define_company/5` |
| Kernel **Person** composes `Samen.Fragments.CorePerson` (`full_name→:pii_name`, `emails→:pii_email`, `phones→:pii_phone`, all composite/no `pii_` prefix; `job_title`, `custom`); adds `display_name`; declares `reveal :reveal_person`; `belongs_to :company`; `SameOrgFk` on `[:company]`. | `crm/blueprint.ex` `define_person/6`; `fragments/core_person.ex` |
| Kernel **Opportunity** attrs: `name, value_cents, currency, probability, status(one_of open/won/lost/on_hold), close_date, notes, custom`; `belongs_to :company, :pipeline`; `SameOrgFk`. | `crm/blueprint.ex` `define_opportunity/7` |
| Kernel **Activity** attrs: `type(call/email/meeting/note/task), subject, body, status(pending/completed/cancelled), due_at, completed_at, custom`; FKs `company/person/opportunity`; `SameOrgFk`. | `crm/blueprint.ex` `define_activity/8` |
| Kernel **Invoice** attrs: `provider_invoice_ref, status, amount_due_cents, amount_paid_cents, currency, period_start/end, due_date, paid_at, line_items ({:array,:map}), custom`; `belongs_to :customer, :subscription`. **Money is integer cents.** | `billing/blueprint.ex` `define_invoice/7` |
| **`Samen.Context`** provides exactly two entities: `alias_resource Kernel, as: Name` (a **name-only** mapping — no second resource, so kernel policies/vault/audit can't be widened) and `reshape Kernel do calculate name, type, expr(...) end` (Ash **expression calculations** loaded ad-hoc; **NO storage**, no column, no attribute). `:money` is sugar → `:decimal`. `NoStorage` transformer fails closed if a reshape touches storage. | `samen_core/lib/samen/context/{dsl,entities,info}.ex`, `context.ex`, `context/transformers/no_storage.ex` |
| **Reveal**: `pii do reveal(:action) end` + `Samen.Reveal.Context`/`grant_checker().granted?/1`; the reveal action returns plaintext only under a grant; `RevealRequest` needs distinct-party approval; DB `CHECK (granted_by <> requestor_id)`; `expires_at`; Oban auto-revoke enqueued same-tx. | `crm/blueprint.ex` `define_person` reveal action; `samen_core/lib/samen/reveal/*` |
| **Scalar `pii_` field**: `pii_attribute :dob, :date, vault: :pii_dob` inside `pii do` → stored `pii_<abbrev>_dob`. Composite types carry no `pii_` prefix; scalars do. | `demo/lib/demo/crm.ex` Contact; `fragments/core_person.ex` |
| **Same-org FK** guard = `change {Samen.Policy.SameOrgFk, relationships: [...]}` (a `before_action` change reading target `org_id` via bare repo). **Org scope** = `Samen.Policy.OrgScope` FilterCheck. **Role gate** = `{Samen.Policy.RoleAtLeast, role: :admin|:member}`. | `samen_core/lib/samen/policy/*` |
| Abbrevs are **permanent, per-host, registry-checked** in `<app>/priv/abbrev_registry.json`. Demo takes `org,mbr,cnt,ido,usr,mbs,iro,key,inv` in its own registry; scope defaults `cmp,per,pip,opp,act,att` / billing set. Driftwood gets a **fresh registry** — no cross-app collision, but each abbrev is one-resource-forever. | `demo/priv/abbrev_registry.json`; `samen_core/lib/samen/abbrev_registry.ex` |
| The **full verifier gate** Driftwood's own `ci.sh` must replicate (§runs "runs" section) is exactly the 17-step gate in `demo/ci.sh`: compile `--warnings-as-errors`, schema.dict drift, `catalog_parity, prefixes, pii_reads, pii_classify, no_plaintext_pii, migrations, sink_schema, metric_labels, vault_declared_parity, tnt_catalog, tnt_boundary, api_contract --version v1, same_org_fk, no_pii_columns, aggregate_privacy`, and `mix test --only adversarial`. | `demo/ci.sh` |

**The one hard constraint that shapes the whole billing reshape (§3):** a
`reshape` **cannot add storage**. It can only `calculate … expr(...)` over columns
that **already exist** on the kernel resource. The kernel Invoice has
`amount_due_cents`, `amount_paid_cents`, `line_items`, `custom` — but **no**
`linehaul`, `advances`, `factoring_rate` columns. So the settlement inputs must
either (a) live in `custom`/`line_items` (jsonb, Tier-1, expr-addressable but
weakly typed), or (b) live on a **new vertical resource** (`Settlement`) authored
in Driftwood's own bounded context via `use Samen.Resource`. The design uses
**both**, deliberately, and §3 says exactly which number goes where and why.

---

## 1 · The context map (T5.1a) — every kernel noun mapped or declared unused

Driftwood mounts the CRM, Billing, Identity, Support, and Primitives scopes (plan
OD-10: Identity/CRM/Billing/Support/Primitives are the deep scopes the dogfood
exercises; Marketing/CMS are shallow and out of Driftwood's critical path). It then
lays a `Driftwood.Context` (`use Samen.Context`) over the kernel nouns and authors a
small set of **vertical resources** (`use Samen.Resource`) for concepts with no
kernel analogue.

### 1.1 Mounted scopes and the abbrev allocation

Driftwood's own `priv/abbrev_registry.json` (permanent, per-app). Proposed abbrevs
(3-letter, never recycled):

| Host resource | Abbrev | Kernel origin |
|---|---|---|
| `Driftwood.Crm.Company` | `cmp` | CRM scope default |
| `Driftwood.Crm.Person` | `per` | CRM scope default (composes CorePerson) |
| `Driftwood.Crm.Pipeline` | `pip` | CRM scope default |
| `Driftwood.Crm.Opportunity` | `opp` | CRM scope default |
| `Driftwood.Crm.Activity` | `act` | CRM scope default |
| `Driftwood.Crm.Attachment` | `att` | CRM scope default |
| `Driftwood.Billing.{Customer,Subscription,Plan,Price,Invoice,Payment,Usage,Entitlement}` | Billing defaults | Billing scope |
| `Driftwood.Freight.Driver` | `drv` | **vertical** — composes CorePerson |
| `Driftwood.Freight.Settlement` | `stl` | **vertical** — new resource (see §3 DECISION S) |
| `Driftwood.Freight.DispatchEvent` | `dsp` | **vertical** — see §1.4 DECISION A |

**DECISION AB (abbrev reuse):** Driftwood keeps the CRM/Billing **scope-default
abbrevs** (`cmp`, `per`, `opp`, …). The registry is per-app, so there is no
collision with demo; keeping defaults means the shipped blueprints are mounted
verbatim (least surprise, maximal reuse). The vertical-authored resources take
fresh abbrevs `drv/stl/dsp`.

### 1.2 The full kernel-noun map (nothing unmapped by accident)

Legend: **alias** = `alias_resource` rename in `Driftwood.Context`; **reshape** =
kernel resource + reshape calcs; **compose** = a new `use Samen.Resource, base:`
resource; **as-is** = mounted and used under its kernel name; **unused** = mounted
by the scope but not exercised by Driftwood (declared, not silently dropped).

| Kernel noun (scope) | Driftwood treatment | Mechanism | Rung |
|---|---|---|---|
| **Company** (CRM) | **Carrier** AND **Shipper** — two roles over ONE kernel resource | `alias_resource Company, as: Carrier` **and** `as: Shipper` + a **role discriminator** attribute (DECISION C) | Context (Tier-3) + Tier-0 config |
| **Person** (CRM) | Broker-side contacts (dispatchers, AP clerks at carriers/shippers) — as-is | mounted as-is (vaulted PII rides underneath) | inherited |
| **Person / CorePerson** (fragment) | **Driver** = `compose CorePerson` + CDL/medical PII | `use Samen.Resource, base: Samen.Fragments.CorePerson` (own table `drv_*`) | code composition (Tier-3) |
| **Opportunity** (CRM) | **Load** — a freight load/shipment being brokered | `alias_resource Opportunity, as: Load` + reshape for rate fields **and** a role-mapping of `value_cents`→shipper rate (DECISION L) | Context (Tier-3) |
| **Pipeline** (CRM) | **Load lifecycle** stages (Quoted→Booked→Dispatched→In-Transit→Delivered→Invoiced) | Tier-0 config rows on the kernel Pipeline | Tier-0 |
| **Activity** (CRM) | **Dispatch event / check-call** — see DECISION A | `alias_resource Activity, as: CheckCall` (name) **plus** a thin vertical `DispatchEvent` resource for the FMCSA-gated dispatch action (DECISION A) | Context + code composition |
| **Attachment** (CRM) | Rate confirmations, BOLs, PODs (file refs) | mounted as-is | inherited |
| **Customer** (Billing) | The **Shipper as bill-to** (broker's AR side) — as-is 🔒 | mounted as-is (billing_name/billing_email vaulted) | inherited |
| **Invoice** (Billing) | **Two roles:** (1) *customer invoice* (shipper owes broker) as-is; (2) *carrier settlement* is a **reshape** over a vertical `Settlement` resource, NOT over this Invoice — see §3 DECISION S | as-is (AR) + reshape on `Settlement` | Context (Tier-3) |
| **Payment** (Billing) | Shipper payments in; carrier settlement payouts out (two directions) | mounted as-is; direction is a config enum on `Settlement` | inherited + Tier-0 |
| **Subscription/Plan/Price/Usage/Entitlement** (Billing) | **Broker's own SaaS plan** (Driftwood-the-product billing the freight broker) — mounted as-is; NOT reshaped | as-is | inherited |
| **Customer/Subscription** (broker-plane) | operator-plane billing rollups (unchanged) | inherited | inherited |
| **User/Org/Membership/Role/ApiKey/Invitation** (Identity) | Broker org + broker staff — as-is (org = the freight brokerage tenant) | mounted as-is | inherited |
| **Ticket/Conversation/Message/Agent/Sla/Macro/Csat** (Support) | Carrier/shipper support tickets — as-is (Message🔒, Agent🔒 vaulted) | mounted as-is | inherited |
| **Notification/File/Search/Audit/Webhook/FeatureFlag** (Primitives) | as-is (load-status webhooks, driver-doc files) | mounted as-is | inherited |
| **Marketing scope** (Campaign/Segment/Subscriber/…) | **declared UNUSED** by Driftwood (freight brokers don't run marketing campaigns in the dogfood). Mounted only if a later carrier-recruiting feature needs it. | not mounted | — |
| **CMS scope** (Page/Post/…) | **declared UNUSED** (no content-marketing surface in the dogfood). | not mounted | — |

**Every kernel noun is now either mapped or explicitly declared unused.** Marketing
and CMS are the only two declared-unused scopes, with a stated reason (freight
brokerage has no campaign/content surface in the reference dogfood; deepen in P6 if
a carrier-recruiting funnel is added).

### 1.3 DECISION C — Company → Carrier AND Shipper: **one resource + role discriminator** (not two composed resources)

This is the sharpest design fork. Two candidate mechanisms:

- **Option C1 — two composed resources.** `Driftwood.Freight.Carrier` and
  `Driftwood.Freight.Shipper`, each `use Samen.Resource` cloning the Company shape,
  own tables `car_*`/`shp_*`.
- **Option C2 (CHOSEN) — one kernel Company + a role discriminator + two aliases.**
  Mount the CRM `Company` once. Add a **Tier-0 role enum** column
  `company_role :atom, one_of: [:carrier, :shipper, :both]` via the blueprint's
  natural extension point (the vertical adds it — see below). In `Driftwood.Context`,
  declare **both** `alias_resource Company, as: Carrier` and
  `alias_resource Company, as: Shipper`. Queries under the alias filter by role.

**Why C2 wins (the justification the task demands):**

1. **The substrate's own model.** `alias_resource` is *explicitly a name-only
   mapping* (`Samen.Context.Alias` carries no second resource, by design "so the
   kernel's policies/vault/audit cannot be widened or bypassed by the rename").
   Two aliases over one resource is exactly the shape the DSL supports; two separate
   composed resources is a heavier, redundant duplication of the whole Company
   surface (attrs, policies, catalog rows, verifiers) for what is fundamentally
   **one entity type with two roles**.
2. **Real freight domain truth.** A single legal company is frequently **both** a
   carrier and a shipper (an asset-based carrier that also tenders freight; a 3PL).
   Two disjoint tables force a duplicate row and split the relationship graph;
   `:both` on one row models reality directly. This is the decisive domain argument.
3. **FK integrity.** A Load references *a shipper* and a Driver references *a
   carrier*. With one Company table, both FKs target `cmp_company` and the
   `SameOrgFk` guard already shipped covers them. With two tables, `Load.shipper_id`
   → `shp_*` and `Driver.carrier_id` → `car_*` are two FK targets, doubling the
   same-org-FK surface for no domain gain.
4. **Catalog / LLM grounding.** One `cmp_company` table with a `company_role` field
   is one coherent catalog entry the LLM grounds on; two near-identical tables
   invite the model to confuse them.

**The mechanism, precisely.** The CRM blueprint's `define_company` does not itself
carry a role column, and blueprints are library-owned (Driftwood must not edit
`samen_core`). Two build-time paths (T5.2 picks one; **preferred = path (i)**):

- **(i) PREFERRED — role as a Tier-0 config attribute added by a Driftwood
  post-mount.** Driftwood mounts CRM with defaults, then **does not** try to inject
  a column into the library resource. Instead the role lives as a **Tier-1 custom
  field** `company_role` in the Company `custom` jsonb bag, registered as a
  `tnt_field` (Tier-1 metadata, validated-at-write, catalogued). Aliased queries
  filter `expr(fragment("? ->> 'company_role'", custom) == "carrier")`. Zero
  `samen_core` change; role is a config value; passes `tnt_catalog`.
  **Cost:** jsonb-typed, so no DB enum constraint (validated at write by the Tier-1
  metadata, not the DB). Acceptable for a role that is org-configurable anyway.
- **(ii) ALTERNATE — a thin vertical join resource** `CompanyRole` (`use
  Samen.Resource`, abbrev `cro`) carrying `company_id + role(enum)`. Stronger
  typing and a DB `one_of` constraint; one extra table + FK. Use this if the build
  finds the jsonb-filter ergonomics on `Carrier`/`Shipper` aliased reads too weak.

**DECISION C is C2 with mechanism (i) as the default; (ii) is the documented
fallback if (i)'s query ergonomics fail in T5.2.** Either way the *renames*
(`Carrier`, `Shipper`) are `alias_resource` entries — pure ubiquitous-language, no
policy widening. This is OPEN RISK OR-1 (the build must confirm (i) is ergonomic or
fall back to (ii)).

### 1.4 DECISION A — Activity → dispatch event: **alias for the name + a thin vertical `DispatchEvent` resource for the gated action**

The vision doc leaves Activity's Driftwood mapping open ("Activity → (dispatch
event? decide)"). Analysis:

- The kernel **Activity** (call/email/meeting/note/task, subject/body, due/completed)
  is a perfect fit for **check-calls** and load-status touchpoints — the routine
  "where's my truck" activity stream. So: `alias_resource Activity, as: CheckCall`
  (name-only), and freight check-calls are ordinary kernel Activities under that
  name. **Rung: Context.**
- But **dispatch itself** — assigning a *driver* to a *load* — is the FMCSA-gated
  action (§4). It needs (a) FKs to `Driver` and `Load`, (b) a `before_action`
  validation that refuses when the driver's CDL/medical card is expired, and (c) an
  auditable dispatch record. A kernel Activity has none of the driver/load FKs and
  `alias_resource` **cannot add** attributes, relationships, or a validation (it is
  name-only; a reshape adds only derived calcs, no storage). So dispatch cannot be
  expressed as an alias or a reshape.

**DECISION A:** `Activity → CheckCall` via `alias_resource` (the routine event
stream), **and** a small **vertical resource** `Driftwood.Freight.DispatchEvent`
(`use Samen.Resource`, abbrev `dsp`) that carries `belongs_to :driver, :load`, a
`status` enum, `dispatched_at`, and the **FMCSA gate** as a `before_action` change
(§4). This is the honest split: the *name* Activity→dispatch-event is an alias; the
*gated behavior* is authored domain code (Tier-3 composition) because the substrate
correctly refuses to let an anti-corruption rename smuggle in a new authorization
rule. Documenting this refusal is itself a proof the anti-corruption layer works.

### 1.5 DECISION D — Driver composes CorePerson

`Driftwood.Freight.Driver` = `use Samen.Resource, base: Samen.Fragments.CorePerson,
abbrev: "drv"` — one physical table `drv_driver` folding the nine core person
columns (`full_name/emails/phones` vaulted, `job_title`, `custom`, id/org_id/ts)
plus Driftwood's driver-specific fields:

```
# Composition sketch (SPEC — built in T5.2, not here)
defmodule Driftwood.Freight.Driver do
  use Samen.Resource,
    otp_app: :driftwood, domain: Driftwood.Freight,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "drv",
    base: Samen.Fragments.CorePerson          # → drv_full_name (vault :pii_name), etc.

  postgres do table("drv_driver"); repo(Driftwood.Repo) end

  attributes do
    attribute :cdl_state, :string, public?: true            # drv_cdl_state — core, non-PII
    attribute :medical_card_expiry, :date, public?: true    # drv_medical_card_expiry — core, non-PII
    attribute :cdl_expiry, :date, public?: true             # drv_cdl_expiry — core, non-PII (gate input)
    attribute :eld_provider, :atom, public?: true,          # drv_eld_provider — Tier-0 config enum
      constraints: [one_of: [:samsara, :motive, :geotab, :other]]
    attribute :status, :atom, public?: true, default: :available,
      constraints: [one_of: [:available, :on_load, :out_of_service, :terminated]]
  end

  pii do
    reveal :reveal_driver                                    # the reveal chokepoint
    vault :pii_cdl
    pii_attribute :cdl_number, :string, vault: :pii_cdl      # → pii_drv_cdl_number (scalar → pii_ prefix)
  end

  relationships do
    belongs_to :carrier, Driftwood.Crm.Company do            # FK → cmp_company (the composed table)
      public? true; attribute_type :uuid; allow_nil? true
    end
  end

  changes do
    change {Samen.Policy.SameOrgFk, relationships: [:carrier]}   # same-org FK guard (inherited pattern)
  end
  # OrgScope + RoleAtLeast policies copied from the scope-authoring template.
end
```

Notes matching the vision doc's driver row (`pii_drv_cdl_number`, `drv_cdl_state`,
`drv_medical_card_expiry`, `drv_carrier_id` FK → company, `drv_eld_provider` Tier-0):
- `pii_drv_cdl_number` is the **scalar `pii_` field** (`pii_attribute :cdl_number,
  :string, vault: :pii_cdl` → stored `pii_drv_cdl_number`, masked `••••` by default,
  plaintext only via `:reveal_driver` under a grant). Matches the doc's `pii_drv_cdl_number text → vault`.
- `cdl_state`, `medical_card_expiry`, `cdl_expiry` are **core (non-PII)** columns —
  a state abbreviation and expiry dates are not subject-identifying alone. `cdl_expiry`
  is added beyond the doc row because the gate (§4) checks CDL expiry as well as the
  medical card; the doc row lists medical_card_expiry explicitly and CDL is the
  vaulted number, so CDL *validity* needs its own expiry column (a date, non-PII).
- `eld_provider` is the **Tier-0 config enum** (doc's `drv_eld_provider enum → Tier-0`).
- `carrier` FK → `cmp_company` (the composed Company table; per the fragment FK rule
  a `belongs_to` **must** target the composed resource, never the fragment). Matches
  `drv_carrier_id uuid → FK company tbl`.

`c4 pii_classify` cross-check (§6): `cdl_number` lives inside `pii do` so it is
declared PII (no flag). But the **column name `cdl_*`** is on `pii_classify`'s
likely-PII token list (`ssn·dob·mrn·cdl·tax_id·email`). `cdl_state`/`cdl_expiry` are
new plain-typed columns whose *names contain `cdl`* → **`pii_classify` will flag
them** and fail the build until they are either declared `pii_attribute` OR cleared
by a **review-gated `non_pii!`**. DECISION: `cdl_state` and `cdl_expiry` are cleared
via `non_pii!` with a second-reviewer sign-off recorded in the catalog (a US state
code and an expiry date are not PII; but the override must be *reviewed*, not
self-served — this is the substrate working as designed). This is OPEN RISK OR-2 —
the build must land the reviewed `non_pii!` registration, not just assert it.

---

## 2 · (moved) — see §3 for the settlement billing reshape

---

## 3 · The settlement billing reshape (T5.1b) — carrier settlement = linehaul − advances − factoring

### 3.1 The two-sided money model

Freight brokerage has **two independent money flows**, and the whole point of the
Driftwood reshape is that the substrate models both without a new billing engine:

```
   SHIPPER  ──(shipper rate / linehaul billed)──►  BROKER  ──(settlement payout)──►  CARRIER
   the shipper owes the broker (AR)                 (margin)      the broker owes the carrier (AP)
```

- **AR side (shipper → broker):** the **kernel Billing `Invoice`**, used **as-is**.
  `amount_due_cents` = the shipper rate for the load. This is a normal customer
  invoice; no reshape needed. The `Customer` is the shipper (bill-to), PII vaulted.
- **AP side (broker → carrier):** the **carrier settlement**. This is the reshaped
  side: `net_payable = linehaul − advances − factoring_fee (− accessorial/claim
  deductions)`. This is what the broker actually pays the carrier.
- **Broker margin** = shipper rate − carrier linehaul (before the carrier-side
  advances/factoring, which are the carrier's costs, not the broker's).

### 3.2 DECISION S — the settlement lives on a **vertical `Settlement` resource**, and the reshape adds the **derived netting calcs** over it (NOT over kernel Invoice)

This is the load-bearing billing decision, and it is forced by the substrate:

- A `reshape` **cannot add storage** (`NoStorage` transformer, verified). It can only
  `calculate … expr(...)` over **existing** columns.
- The kernel Invoice has `amount_due_cents/amount_paid_cents/line_items/custom` — it
  has **no** `linehaul_cents`, `advances_cents`, `factoring_rate_bps` columns. Those
  are the settlement's *inputs*, and they must be **stored** (they are facts about a
  specific carrier settlement, not derivable from the shipper invoice).
- Storing them in the kernel Invoice `custom` jsonb bag is *possible* (Tier-1) and
  expr-addressable via `fragment("? ->> 'linehaul_cents'", custom)`, but: (a) they'd
  be weakly typed jsonb, (b) they conflate the AR invoice with the AP settlement on
  one row, and (c) the netting math on jsonb-cast text is fragile. **Rejected.**

**DECISION S:** Driftwood authors a **vertical `Settlement` resource**
(`Driftwood.Freight.Settlement`, `use Samen.Resource`, abbrev `stl`) that **stores**
the settlement inputs as typed integer-cents columns, and `Driftwood.Context`
declares a `reshape Settlement do … end` that adds the **derived netting fields**
(`gross`, `factoring_fee`, `net_payable`, `carryover`) as `calculate … expr(...)`
computed at query time. The *inputs* are stored (authored domain, Tier-3); the
*netting math* is a **reshape** (Context) — this is exactly the doc's calibration:
"you inherit the plumbing… you still author the domain," and the money reshape lives
in the vertical's bounded context.

**Why this is still faithful to "kernel Invoice reshaped to a carrier settlement":**
the reshape *is* over a Billing-family resource in the vertical's bounded context; we
reuse the kernel Billing **fields/idioms** (integer-cents money, `currency`, `status`
enum, `paid_at`, `belongs_to :customer`-shaped FK to the carrier, the `Payment`
resource for the actual payout) and add only the netting **calculations**. What we
do **not** do is corrupt the kernel `Invoice` table with freight-specific columns —
that would violate the anti-corruption boundary the whole design is proving.

### 3.3 Which kernel Billing fields are REUSED vs which are VERTICAL calculations

| Concept | Where it lives | Reused vs vertical |
|---|---|---|
| shipper rate / customer AR | kernel `Invoice.amount_due_cents` | **REUSED** kernel field, as-is |
| shipper payment in | kernel `Payment` (direction: inbound) | **REUSED** kernel resource |
| `currency` | `Settlement.currency` (mirrors kernel `Invoice.currency`) | **REUSED** kernel idiom (same shape) |
| settlement `status` enum | `Settlement.status` (draft/approved/paid) | **REUSED** kernel Invoice status idiom |
| carrier payout | kernel `Payment` (direction: outbound) + FK to `Settlement` | **REUSED** kernel resource |
| `linehaul_cents` | `Settlement.linehaul_cents` (stored) | **VERTICAL** stored input |
| `advances_cents` | `Settlement.advances_cents` (stored — fuel advance / quick-pay) | **VERTICAL** stored input |
| `factoring_rate_bps` | `Settlement.factoring_rate_bps` (stored — basis points) | **VERTICAL** stored input |
| `fuel_surcharge_cents`, `accessorial_cents`, `claim_deduction_cents` | `Settlement.*_cents` (stored) | **VERTICAL** stored inputs |
| `gross` | reshape `calculate` | **VERTICAL** derived calc |
| `factoring_fee` | reshape `calculate` | **VERTICAL** derived calc |
| `net_payable` | reshape `calculate` | **VERTICAL** derived calc |
| `carryover` | reshape `calculate` | **VERTICAL** derived calc |
| broker margin | reshape `calculate` over `Settlement` joined to `Load`/`Invoice` | **VERTICAL** derived calc (see OR-3) |

### 3.4 The reshape spec (exact `Samen.Context` shape)

`Settlement` stored columns (integer cents to match the kernel Billing money
convention; `factoring_rate_bps` is basis points, an integer 0–10000):

```
attribute :linehaul_cents, :integer, default: 0
attribute :advances_cents, :integer, default: 0
attribute :fuel_surcharge_cents, :integer, default: 0
attribute :accessorial_cents, :integer, default: 0
attribute :claim_deduction_cents, :integer, default: 0
attribute :factoring_rate_bps, :integer, default: 0        # e.g. 300 = 3.00%
attribute :currency, :string, default: "USD"
attribute :status, :atom, one_of: [:draft, :approved, :paid], default: :draft
belongs_to :load, Driftwood.Crm.Opportunity      # the load being settled
belongs_to :carrier, Driftwood.Crm.Company       # the carrier being paid
```

The reshape (in `Driftwood.Context`), using the substrate's `calculate name, :money,
expr(...)` — note `:money` → `:decimal`, and the cents columns are integers so the
calc yields decimal cents (the UI divides by 100 for display; keeping cents integer
avoids float money):

```
reshape Driftwood.Freight.Settlement do
  # gross = linehaul + fuel surcharge + accessorials  (all cents)
  calculate :gross_cents, :integer,
    expr(linehaul_cents + fuel_surcharge_cents + accessorial_cents)

  # factoring fee = gross * rate_bps / 10000  (integer cents, truncated)
  calculate :factoring_fee_cents, :integer,
    expr((linehaul_cents + fuel_surcharge_cents + accessorial_cents) * factoring_rate_bps / 10000)

  # net_raw = gross - advances - factoring_fee - claim deductions  (may be negative)
  calculate :net_raw_cents, :integer,
    expr((linehaul_cents + fuel_surcharge_cents + accessorial_cents)
         - advances_cents
         - ((linehaul_cents + fuel_surcharge_cents + accessorial_cents) * factoring_rate_bps / 10000)
         - claim_deduction_cents)

  # net_payable = max(net_raw, 0)  — a carrier is never paid a negative settlement
  calculate :net_payable_cents, :integer,
    expr(if((...net_raw...) > 0, ...net_raw..., 0))

  # carryover = max(-net_raw, 0) — the negative rolls forward as a debt against the next load
  calculate :carryover_cents, :integer,
    expr(if((...net_raw...) < 0, -(...net_raw...), 0))
end
```

(The `...net_raw...` placeholder is the inlined net-raw expression; the build
factors this into an intermediate calc if Ash allows calc-referencing-calc, else
inlines it. This is OPEN RISK OR-4 — Ash expression calcs cannot always reference
sibling calcs; the build confirms and inlines if needed. The **arithmetic is
canonical** and verified in §3.5 regardless of how it's factored.)

**Integer division note:** `factoring_fee_cents` uses integer truncation
(`gross_cents * bps / 10000`). Verified against the decimal reference in §3.5: for
gross=215000c and bps=300, `215000*300/10000 = 6450c` exactly (=$64.50). The build
must ensure Postgres integer division truncates toward zero and that the property
test (T5.2) pins the truncation direction. OPEN RISK OR-5.

### 3.5 Worked numeric examples (≥3, incl. factoring + advance-exceeds-linehaul)

All figures verified by a decimal reference computation. Cents shown as dollars for
readability; the stored/derived values are integer cents.

**Example 1 — plain settlement, no factoring (the base case).**
Linehaul $2,000.00; advances $500.00 (fuel advance); no factoring; no surcharge.
```
gross          = 2000.00
factoring_fee  = 0.00
net_raw        = 2000.00 − 500.00 − 0.00 = 1500.00
net_payable    = 1500.00
carryover      = 0.00
```
Broker pays the carrier **$1,500.00**. (Stored: linehaul_cents 200000, advances_cents
50000, factoring_rate_bps 0 → derived net_payable_cents 150000.)

**Example 2 — factoring case (carrier uses a factoring company, 3% of gross).**
Linehaul $2,000.00; fuel surcharge $150.00; no advance; factoring rate 300 bps (3%).
```
gross          = 2000.00 + 150.00 = 2150.00
factoring_fee  = 2150.00 × 0.03 = 64.50
net_raw        = 2150.00 − 0.00 − 64.50 = 2085.50
net_payable    = 2085.50
carryover      = 0.00
```
Broker pays **$2,085.50** (the factoring company takes its $64.50 cut of the $2,150
gross). Stored: linehaul 200000c, fuel_surcharge 15000c, factoring_rate_bps 300 →
factoring_fee 6450c, net_payable 208550c.

**Example 3 — advance exceeds linehaul (the negative-settlement edge).**
Linehaul $1,200.00; advances $1,500.00 (a large fuel advance on a cheap load);
factoring 200 bps (2%).
```
gross          = 1200.00
factoring_fee  = 1200.00 × 0.02 = 24.00
net_raw        = 1200.00 − 1500.00 − 24.00 = −324.00   ◄ NEGATIVE
net_payable    = max(−324.00, 0) = 0.00                ◄ carrier is not paid a negative amount
carryover      = max(324.00, 0) = 324.00               ◄ $324 debt rolls to the next settlement
```
Broker pays **$0.00** this settlement; the carrier **owes the broker $324.00**,
tracked as `carryover_cents 32400`. This is the critical edge the vision doc calls
out ("advance-exceeds-linehaul edge"): the settlement clamps at zero and books a
carryover rather than paying a negative amount. **DECISION N (negative handling):**
never pay negative; clamp `net_payable` at 0 and surface the shortfall as
`carryover` (a receivable the broker nets against the carrier's next load). The
carryover is a *derived* value here; whether it is also *persisted forward* onto the
next settlement is OPEN RISK OR-6 (the design specifies the derivation; the build
decides if carryover chaining across settlements is in-scope for the dogfood or a
documented single-settlement simplification).

**Example 4 — full stack (surcharge + accessorial + factoring + advance + claim).**
Linehaul $1,800.00; fuel surcharge $220.00; accessorial (detention) $75.00;
factoring 300 bps; advance $600.00; claim deduction (cargo damage) $50.00.
```
gross          = 1800.00 + 220.00 + 75.00 = 2095.00
factoring_fee  = 2095.00 × 0.03 = 62.85
net_raw        = 2095.00 − 600.00 − 62.85 − 50.00 = 1382.15
net_payable    = 1382.15
carryover      = 0.00
```
Broker pays **$1,382.15**. Exercises every input at once.

**Two-sided-money worked check (broker margin).** Shipper is billed $2,500.00
(kernel `Invoice.amount_due_cents = 250000`); carrier linehaul is $2,000.00
(Example 1). Broker **gross margin = 2500.00 − 2000.00 = $500.00** — a *reshape calc*
over `Settlement` joined to the load's customer Invoice (OR-3). The carrier-side
advances/factoring are the carrier's costs and do **not** reduce the broker's margin;
they only move money between the broker's AP payout and the factoring company. This
is the "two-sided money" the doc means: two independent nettings (AR invoice, AP
settlement) with the margin as the derived spread.

### 3.6 Judge-panel synthesis — three settlement-model approaches scored

The task flags T5.1 as judge-panel-worthy. Three approaches were explored:

| Approach | Where inputs live | Where math lives | Score | Verdict |
|---|---|---|---|---|
| **A: reshape kernel Invoice directly** (inputs in Invoice `custom` jsonb, calcs read `fragment(custom->>…)`) | kernel Invoice `custom` | reshape on kernel Invoice | 4/10 | **Rejected.** Weakly-typed jsonb money; conflates AR invoice with AP settlement on one row; fragile netting on text-cast values; corrupts kernel Invoice semantics. |
| **B: fully vertical Settlement resource + vertical calcs as Ash `calculate` on the resource** (no `Samen.Context` at all) | vertical `Settlement` typed columns | Ash `calculate` in the resource | 6/10 | Works, but **skips the anti-corruption layer** — the reshape is the *point* of the Driftwood proof (that money reshaping lives in `Samen.Context`, not ad-hoc). Loses the catalog `catalog_context_map` derived-field grounding. |
| **C (CHOSEN): vertical Settlement stores typed inputs; `Samen.Context` `reshape` adds the derived netting calcs** | vertical `Settlement` typed columns | `reshape Settlement do calculate … end` in `Driftwood.Context` | 9/10 | **Chosen.** Typed integer-cents inputs (correct money); netting math is a first-class reshape in the bounded context (the doc's exact idiom); derived fields appear in `catalog_context_map` with `physical?: false` for LLM grounding; kernel Invoice stays uncorrupted (used as-is for the AR side). |

**Synthesis (why C, not B):** B and C store inputs identically; the difference is
*where the money math lives*. The vision doc's whole Driftwood claim is that the
**billing reshape** is a bounded-context translation expressed through the
anti-corruption layer — "reshape money (settlement-netting)" is named as the
Context's job. Putting the netting in `Samen.Context.reshape` (C) makes that claim
literally true and gives the catalog a derived-field surface; putting it in a plain
Ash `calculate` (B) makes it just another resource and forfeits the proof. C wins on
the exact dimension T5 exists to demonstrate.

---

## 4 · The FMCSA compliance gate (T5.1c)

**The rule (exact):** *A driver MUST NOT be dispatched to a load if, at the moment
of dispatch, any of the following holds:*
1. `medical_card_expiry` is null OR `medical_card_expiry < today` (medical card
   missing or expired), OR
2. `cdl_expiry` is null OR `cdl_expiry < today` (CDL missing or expired), OR
3. the `cdl_number` vault token is absent/`SHREDDED` (no valid CDL on file), OR
4. `driver.status == :out_of_service` OR `:terminated`.

Dispatch is the `create` (or a named `:dispatch`) action on
`Driftwood.Freight.DispatchEvent` (§1.4). **"today"** is `Date.utc_today()` evaluated
at dispatch time — the gate is a *point-in-time* check at the dispatch action, so a
grant/row lingering past expiry cannot dispatch (mirrors the reveal-grant
"deny-on-expiry-even-if-row-lingers" idiom).

**Mechanism DECISION F — a `before_action` change (validation), not (only) a
policy.** Two candidates:

- **F-policy:** an `Ash.Policy.SimpleCheck` on the dispatch action. *Rejected as the
  sole mechanism* because a policy failure is an authorization error (a 403-shaped
  "Forbidden"), which leaks less-useful information and is awkward to attach a
  domain-specific "medical card expired on 2026-05-01" diagnostic to. Policies are
  the right tool for *who may dispatch*, not *is this driver legal to dispatch*.
- **F-change (CHOSEN):** a reusable `Ash.Resource.Change`,
  `Driftwood.Policy.FmcsaDispatchGate`, run in `before_action` on the dispatch
  action — exactly the shape of the shipped `Samen.Policy.SameOrgFk` change (reads a
  related row's fields via a bounded query, adds an error, refuses the write). It
  loads **only** the driver's `medical_card_expiry`, `cdl_expiry`, `status`, and the
  presence of the CDL vault token (a bounded read — **never the plaintext CDL
  number**; the gate checks token presence + expiry dates, all non-PII), compares
  against `Date.utc_today()`, and on any failing condition adds a changeset error
  with a precise reason (`{:medical_card_expired, expiry}` / `{:cdl_expired, expiry}`
  / `:cdl_missing` / `{:driver_out_of_service, status}`) and refuses. **Plus** the
  ordinary `OrgScope` + `RoleAtLeast` **policies** gate *who* may dispatch and
  same-org. So: **policy = authorization (who/same-org); change = the FMCSA legality
  gate (is this driver dispatchable).** Both fire; the change is the load-bearing
  compliance rule.

**Why the change reads dates, not the vaulted CDL:** the gate must not decrypt the
CDL number (that would need a reveal grant and would route PII into a dispatch code
path — a `pii_reads` violation). It checks (a) that the **vault token exists and is
not the `SHREDDED` sentinel** (proving a CDL is on file) and (b) the **expiry dates**
(plain, non-PII columns). This keeps the gate entirely on non-PII data — a deliberate
design choice so the compliance check never touches plaintext PII. This is also why
`cdl_expiry` is a separate non-PII column (§1.5): the gate needs CDL *validity*
without CDL *plaintext*.

**Red-path tests the gate ships (HARD RULE 2):**
- **Must-fail path:** dispatch a driver whose `medical_card_expiry` = yesterday →
  the create is refused with `{:medical_card_expired, ~D[…]}`; assert no
  `DispatchEvent` row was written. Same for `cdl_expiry` = yesterday, for
  `cdl_number` shredded, and for `status: :out_of_service`.
- **Must-pass control:** a fully-compliant driver (both expiries in the future,
  CDL present, status `:available`) dispatches successfully — proving the gate is
  non-vacuous (it doesn't just block everything).
- **Anti-tautology probe (in a project-local scratch dir):** temporarily invert the
  gate's comparison (`<` → `>`), confirm the must-fail test flips to passing (an
  expired driver dispatches), then revert; state the result in the T5.2 report. This
  proves the test actually exercises the gate, not a constant.

**Rung:** the FMCSA gate is **code composition (Tier-3)** — it is authored domain
logic on a vertical resource. It is *not* Tier-0 config: a compliance rule that a
tenant could toggle off in config would defeat its purpose (a broker cannot
self-serve "let me dispatch expired drivers"). The `eld_provider` *enum* is Tier-0;
the *gate* is Tier-3.

---

## 5 · PII inventory (T5.1d) — every Driftwood PII field, its vault, its plane visibility

Driftwood **inherits** all kernel-scope PII unchanged (the vaults, masking, reveal,
crypto-shred all ride underneath). The table lists inherited PII (for completeness)
and the **one new vertical PII field** Driftwood adds.

| Field (logical) | Resource | Stored column | Type | Vault | Reveal action | Tenant plane | Operator plane (no grant) | Aggregate plane |
|---|---|---|---|---|---|---|---|---|
| `cdl_number` **(NEW)** | `Freight.Driver` | `pii_drv_cdl_number` | scalar string | `:pii_cdl` | `:reveal_driver` | own-org sees plaintext per own RBAC (own-key, no grant) | `••••` (masked) unless a distinct-party reveal grant | **absent** (no `pii_` col in the aggregate projection; C7) |
| `full_name` | `Freight.Driver` (via CorePerson) | `drv_full_name` | composite FullName | `:pii_name` | `:reveal_driver` | own-org plaintext | `••••` | absent |
| `emails` | `Freight.Driver` (via CorePerson) | `drv_emails` | composite Emails | `:pii_email` | `:reveal_driver` | own-org plaintext | `••••` | absent |
| `phones` | `Freight.Driver` (via CorePerson) | `drv_phones` | composite Phones | `:pii_phone` | `:reveal_driver` | own-org plaintext | `••••` | absent |
| `full_name/emails/phones` | `Crm.Person` (broker contacts) | `per_*` | composite | `:pii_name/:pii_email/:pii_phone` | `:reveal_person` | own-org plaintext | `••••` | absent |
| `billing_name/billing_email` | `Billing.Customer` (shipper bill-to) | `bcu_*` | composite/scalar | `:pii_name/:pii_email` | inherited | own-org plaintext | `••••` | absent |
| `message body / agent identity` | `Support.Message🔒 / Agent🔒` | inherited | — | inherited vaults | inherited | own-org plaintext | `••••` | absent |

**Non-PII columns explicitly cleared (the `pii_classify` interactions, §1.5):**
`cdl_state`, `cdl_expiry`, `medical_card_expiry` — plain columns whose names trip the
`cdl`/expiry heuristic (`cdl_*`) or are date-shaped. `cdl_state`/`cdl_expiry` require
a **review-gated `non_pii!`** (name contains `cdl`); `medical_card_expiry` is a plain
date whose name does not hit the token list but is confirmed non-PII in the catalog.
All three are on the **destruction-oracle tier list** as registered `non_pii!` where
applicable (erased by row-level deletion on a driver-erasure request, since a
plaintext-at-rest column is not key-shredded).

**Plane-visibility invariants Driftwood inherits (asserted, not re-implemented):**
- **Masked-by-default:** `%Masked{}` is the normal value; `pii_drv_cdl_number`
  renders `••••` in LiveView, JSON API, CSV, webhook payloads, and logs by omission.
- **Reveal seam:** the operator plane crosses PII only via a distinct-party reveal
  grant (DB `CHECK (granted_by <> requestor_id)`, `expires_at`, Oban auto-revoke
  same-tx). A tenant reading its own org's driver PII needs **no** grant (two-key
  rule).
- **Aggregate plane:** the token-blind aggregate actor reads a projection where
  `pii_` columns **physically do not exist** (C7 `no_pii_columns` asserts this
  against the live DB). Driver MRR-style rollups (e.g. loads-per-carrier) carry no
  driver identity.
- **Crypto-shred:** destroying a driver subject's external-KMS key makes
  `pii_drv_cdl_number` (and name/emails/phones) undecryptable across
  live·replica·PITR·CDC·rollup·audit at once; the `non_pii!` `cdl_state`/`cdl_expiry`
  are erased by row-level deletion. T5.4 runs the oracle against a real erased driver.

---

## 6 · Malleability-rung placement (T5.1e) — which rung each customization lands on

| Customization | Rung | Justification |
|---|---|---|
| Load lifecycle stages (Quoted→…→Delivered) | **Tier-0 config** | Pipeline config rows per org; brokers reorder/rename stages without a fork. |
| `eld_provider` enum, settlement `status`, `company_role` (if via jsonb) | **Tier-0 / Tier-1** | Bounded enums = Tier-0 constraint; `company_role` in the Company `custom` bag = Tier-1 (validated-at-write `tnt_field`). |
| Per-org custom fields on Company/Load/Driver (`custom` jsonb bag) | **Tier-1** | The inherited `xxx_custom jsonb` + `tnt_field` runtime metadata; validated-at-write, catalogued. |
| A tenant-defined object a broker adds (e.g. "LaneRate" a broker tracks itself) | **Tier-2 custom object** | `tnt_record` + `tnt_object`/`tnt_field` (one-way boundary). Not needed by the core dogfood; available. |
| **Company → Carrier/Shipper aliases** | **Tier-3 (Context)** | `alias_resource` — ubiquitous-language rename in `Samen.Context`; the top rung is a context boundary. |
| **Opportunity → Load alias** | **Tier-3 (Context)** | `alias_resource` rename. |
| **Activity → CheckCall alias** | **Tier-3 (Context)** | `alias_resource` rename (the routine event stream). |
| **Settlement netting calcs** (gross/factoring_fee/net_payable/carryover) | **Tier-3 (Context reshape)** | `reshape … calculate … expr(...)` — derived money in the bounded context; the doc's exact idiom. |
| **Driver = compose CorePerson** (+ CDL/medical PII) | **Tier-3 (code composition)** | `use Samen.Resource, base:` — single-table fragment composition; new PII rides the same vault. |
| **Settlement resource** (typed cents inputs) + **DispatchEvent resource** | **Tier-3 (code composition)** | Authored vertical resources with no kernel analogue (the substrate correctly refuses to let an alias/reshape mint storage or a validation). |
| **FMCSA dispatch gate** | **Tier-3 (code composition)** | A `before_action` change on DispatchEvent — a hard compliance rule, deliberately NOT tenant-configurable. |

**The rung story in one line:** Driftwood's *renames and money reshape* land on the
top rung (Context, Tier-3) exactly as the doc promises; its *new nouns* (Driver,
Settlement, DispatchEvent) are Tier-3 code composition; its *tunable knobs* (stages,
ELD provider, custom fields) are Tier-0/1 — proving the full ladder in one vertical.

---

## 7 · Driftwood's own `ci.sh` (the §runs "runs" gate)

Driftwood ships `driftwood/ci.sh` running the **full verifier gate exactly as
`demo/ci.sh`** does (the §runs section's gate), against Driftwood's resources:

```
mix compile --warnings-as-errors
schema.dict.json drift check
mix samen.verify.catalog_parity
mix samen.verify.prefixes
mix samen.verify.pii_reads
mix samen.verify.pii_classify --baseline schema.dict.json
mix samen.verify.no_plaintext_pii
mix samen.verify.migrations
mix samen.verify.sink_schema
mix samen.verify.metric_labels
mix samen.verify.vault_declared_parity
mix samen.verify.tnt_catalog
mix samen.verify.tnt_boundary
mix samen.verify.api_contract --version v1
mix samen.verify.same_org_fk
mix samen.verify.no_pii_columns
mix samen.verify.aggregate_privacy
mix test --only adversarial
```

The **root `ci.sh`** gains a Driftwood arm (mirroring the demo arm) so the whole
repo gate covers spikes + samen_core + demo + Driftwood. Every Driftwood guarantee
ships a red-path test + an anti-tautology probe (HARD RULE 2), most notably: the
FMCSA gate must-fail tests (§4), a settlement property test asserting the netting
math matches the §3.5 worked examples (incl. the negative/carryover edge), a masked
`pii_drv_cdl_number` egress test, and the crypto-shred oracle against an erased
driver (T5.4).

---

## 8 · Decisions (load-bearing) and Open Risks (T5.2 must resolve)

### Decisions (§ where argued)
- **DECISION C (§1.3):** Company→Carrier/Shipper = **one kernel Company + role
  discriminator + two `alias_resource` aliases** (C2), default mechanism = role as a
  **Tier-1 jsonb `company_role`** field (i); fallback = a thin `CompanyRole` join
  resource (ii). Not two composed resources.
- **DECISION A (§1.4):** Activity→dispatch = **`alias_resource Activity, as:
  CheckCall`** for the routine stream **plus** a vertical **`DispatchEvent`**
  resource for the FMCSA-gated dispatch action (an alias/reshape cannot add
  FKs/validation).
- **DECISION D (§1.5):** **Driver composes CorePerson**; `pii_drv_cdl_number` is the
  scalar vault field; `cdl_state`/`cdl_expiry` non-PII (reviewed `non_pii!`).
- **DECISION S (§3.2):** carrier settlement inputs live on a **vertical typed
  `Settlement` resource**; the **netting math is a `Samen.Context` reshape** over it
  (approach C in the judge panel). Kernel `Invoice` stays as-is for the shipper AR
  side.
- **DECISION N (§3.5):** negative settlement clamps `net_payable` at 0 and books a
  `carryover`; never pay negative.
- **DECISION F (§4):** FMCSA gate = a **`before_action` change** (validation) reading
  only expiry dates + CDL token presence (never plaintext CDL), plus ordinary
  OrgScope/RoleAtLeast policies for *who* may dispatch. Tier-3, not tenant-toggleable.
- **DECISION AB (§1.1):** keep CRM/Billing scope-default abbrevs; vertical resources
  take `drv/stl/dsp` in Driftwood's own permanent registry.
- **Scopes (§1):** mount Identity/CRM/Billing/Support/Primitives deep; **declare
  Marketing + CMS unused** (freight brokerage has no campaign/content surface in the
  dogfood).

### Open Risks (the build follows the spec; these it must close)
- **OR-1 (§1.3):** confirm the Tier-1 jsonb `company_role` filter ergonomics on the
  `Carrier`/`Shipper` aliased reads are acceptable; fall back to the `CompanyRole`
  join resource if not. (Which mechanism (i)/(ii) — a real fork the build resolves.)
- **OR-2 (§1.5):** land the **reviewed `non_pii!`** registration for `cdl_state` and
  `cdl_expiry` (second-reviewer sign-off recorded in the catalog) — `pii_classify`
  will fail the build until this exists.
- **OR-3 (§3.5):** the **broker-margin** calc spans two resources (`Settlement` and
  the load's customer `Invoice`); confirm a `Samen.Context` reshape can express a
  cross-resource margin, or compute margin in an aggregate/rollup instead.
- **OR-4 (§3.4):** confirm whether Ash expression calcs can **reference sibling
  calcs** (`net_payable` referencing `net_raw`); if not, inline the net-raw
  expression (arithmetic unchanged; §3.5 canonical).
- **OR-5 (§3.4):** pin **integer-division truncation** direction for
  `factoring_fee_cents` in Postgres and in the property test (verified correct on the
  §3.5 numbers; must be locked so a rounding drift can't slip in).
- **OR-6 (§3.5):** decide whether **carryover chains forward** onto the next
  settlement (a persisted receivable) or is a single-settlement derived value in the
  dogfood; document the choice honestly (never fake a pass).
- **OR-7 (§4):** the FMCSA gate reads the CDL **vault-token presence** — confirm the
  substrate exposes a token-present/`SHREDDED`-sentinel check that does **not**
  decrypt (so the gate stays off the `pii_reads` path); if not, gate on
  `cdl_expiry` + a non-PII `cdl_on_file :boolean` flag instead.
- **OR-8 (§7):** Driftwood's `api_contract.v1.json` + `schema.dict.json` baselines
  must be generated and committed at build time so the gate has a real diff/parity
  baseline (as demo does).
- **OR-9 (game-days):** T5.4/T5.5 run as **local simulations** (no Fly/Neon/AWS
  here). Every simulated seam (KMS destruction attestation, Neon PITR branch) must be
  documented as an operator TODO with the exact real command the operator will run —
  simulate faithfully, never fake a pass.

---

## 9 · What this design does NOT do (scope honesty)

- No app code is written (T5.1 is spec-only; T5.2 builds it).
- No `samen_core` change is proposed — Driftwood mounts the shipped scopes and
  `Samen.Context` verbatim, authoring only vertical resources (Driver, Settlement,
  DispatchEvent) and the `Driftwood.Context`. If the build discovers a genuine core
  gap (e.g. OR-7 token-presence check), that is a **finding for the extraction retro
  (T6.1)**, recorded as an ADR — not a silent core edit inside T5.2.
- Fly/Neon/AWS are operator TODOs; the running app and game-days are local.
