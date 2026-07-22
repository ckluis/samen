# ADR-036 — Rich property types: the H1–H7 `Ash.Type` contracts, AshMoney-backed `Money`, and the destructive cents→composite migration

- **Status:** Accepted (design; WS-H. Implementing tasks: T12 executes the Money migration, T15 the custom-field + gen.resource menu work; the type modules land in `samen_core` under the tasks that consume them).
- **Date:** 2026-07-21
- **Task:** T11 — fix the WS-H type contracts (spec H1–H7) before implementation: the `Ash.Type` design for Money/Percent/Score/Duration/Priority/URL/EmailAddress/PhoneNumber/Address; catalog + CSV + masked-render integration rules; the new vault classes `pii_address`/`pii_dob`; and the H1 migration plan for CRM Opportunity + Billing Price.
- **Deciders:** fable (T11 orchestrator), grounded in the **binding** verdicts of `docs/adr/ADR-037-ash-ecosystem-adoption.md` (§5.2 AshMoney **ADOPT**, §5.11 AshCsv **REJECT**), the classification keystone `Samen.Pii.Classification` + its reviewer-gate ADR-034, the CSV masking surface ADR-028, the four existing `Ash.Type` modules (`samen_core/lib/samen/type/*.ex`), the vault-routing DSL `Samen.Pii` (`samen_core/lib/samen/pii.ex`), the catalog (`samen_core/lib/samen/catalog.ex`), the custom-field engine (`samen_core/lib/samen/custom_fields.ex`), and the two money-bearing blueprints (`samen_core/lib/samen/scopes/crm/blueprint.ex`, `.../billing/blueprint.ex`).
- **Consumes (binding inputs):** ADR-037 §5.2 & §5.11; spec `spec/full-saas-readiness.md` §WS-H (H1–H7) + INV-1..INV-6; `_orch/directive.md`; `_orch/plan/spec-questions.md` rulings **M6** (Money strategy settled by ADR-037), **c15** (Priority ordering), **c17** (H4 Address vs F5 Location split).

---

## 1 · Context

Today the foundry expresses money as a **paired convention** — an `_cents :integer` column beside a `currency :string` column — and expresses percent/score/duration/priority/url/email/phone as bare `:string`/`:integer`/`:atom` columns with ad-hoc validation (or none). WS-H closes the Properties column by promoting these conventions to **first-class `Ash.Type`s** so the four downstream consumers — the **catalog** (`Catalog.fields/1`), the **generators** (`mix samen.gen.resource`), the **forms** (`Samen.UI.Form`), and the **CSV** round-trip (`Samen.Web.Csv`) — all understand each type uniformly, at substrate level (INV-5), inherited by every generated app.

Three facts shape every decision below:

1. **The classification keystone is mask-unknown-by-default.** `Samen.Pii.Classification.classify/1` (`samen_core/lib/samen/pii/classification.ex`) returns `:pii` for **any type it cannot prove non-PII**. The only plaintext-by-default set is `@non_pii_scalars` (the bare Ash primitives: `Boolean, Integer, Float, Decimal, UUID, UUIDv7, Atom, UtcDatetime, UtcDatetimeUsec, NaiveDatetime, Time, DurationName`). **A new custom `Ash.Type` is not in that set** — so unless it self-classifies, it is masked/vaulted by default. Every new type in this ADR must therefore make a *deliberate, reviewed* classification choice; a silently-plain money column is exactly the leak-by-omission this keystone forbids.

2. **`:non_pii` self-classification is reviewer-gated (ADR-034).** A type exporting `def samen_pii_class, do: :non_pii` is honored **only** behind a valid two-distinct-party clearance in `Samen.NonPii.TypeClearance` (a pure config allowlist; `cleared_by ≠ reviewed_by`, non-blank `reason`); ungoverned it falls through to the PII default (fail-closed). Opting a whole type out of masking is exactly as hard as opting one column out (`Samen.NonPii.register/1`). This ADR uses that governed opt-out as the foundry-level mechanism for its genuinely-non-PII types.

3. **The Money & CSV verdicts are already settled by ADR-037 — this ADR does not re-open them.** §5.2 **ADOPTs** `ash_money 0.2.6` (+ `ex_money ~> 6.0`, `ex_money_sql ~> 2.0`) and mandates that `Samen.Type.Money` be *a thin samen-owned wrapper over `AshMoney.Types.Money`* (samen name in the catalog/type-menu, package semantics underneath), and settles the H1 migration as a **pre-1.0 destructive single data-copy migration per resource** (M6). §5.11 **REJECTs** `ash_csv` (a CSV *data layer*, a category error against samen's masked CSV surface): H7's round-trip work **extends the existing `Samen.Web.Csv`** (ADR-028), it does not adopt a data layer. There is **no in-repo precedent** for a non-PII scalar `Ash.Type` with `constraints/0` — the four existing types (`FullName/Emails/Phones/VaultField`) are all PII/vault-oriented. This ADR establishes the first non-PII type family.

---

## 2 · Decision

**Seven load-bearing decisions.**

### D1 — `Samen.Type.Money` is a thin wrapper over `AshMoney.Types.Money`, self-classifying `:non_pii` behind a foundry `TypeClearance`.

Per ADR-037 §5.2 (binding): `Samen.Type.Money` **wraps** `AshMoney.Types.Money` — samen owns the *name* (so the catalog dumps `"Samen.Type.Money"`, not `"AshMoney.Types.Money"` — see D5), the package owns currency arithmetic/rounding/SQL-aggregation. Its Ash `storage_type` is the Postgres composite `money_with_currency(char(3), numeric)`, installed via `AshMoney.AshPostgresExtension` in each host's `installed_extensions`. Its value is an `ex_money` `%Money{amount: Decimal.t(), currency: atom()}`. Money is **not PII** → it exports `def samen_pii_class, do: :non_pii`, and **samen_core ships the two-party `TypeClearance` entry** (see D5's clearance manifest) so the classification oracle honors it. Without that clearance a Money column would mask-by-default — correct fail-closed behavior, deliberately cleared by review.

### D2 — The non-PII scalar type family (Percent, Score, Duration, Priority, URL) — self-classify `:non_pii` behind foundry `TypeClearance`, with `constraints/0` for bounds.

Each is a first-class `Ash.Type` (skeleton modeled on the existing `use Ash.Type` modules) that (a) exports `def samen_pii_class, do: :non_pii` and is cleared in the samen_core `TypeClearance` manifest (D5); (b) implements `constraints/0` for its bounded discipline; (c) format/range-validates in `cast_input/2`, failing `:error` on violation. Storage shapes:

| Type | `storage_type` | Canonical value | Constraints |
|---|---|---|---|
| `Samen.Type.Percent` | `:decimal` | `Decimal` in `0..100` (percent points, not a fraction) | `min` (default 0), `max` (default 100), `decimals` (default 2) |
| `Samen.Type.Score` | `:decimal` | `Decimal`, default range `0..100` | `min` (default 0), `max` (default 100), `decimals` (default 0) |
| `Samen.Type.Duration` | `:integer` | seconds (non-negative integer) | `min`, `max` (both optional) |
| `Samen.Type.Priority` | `:integer` (**rank**) | atom `:low\|:normal\|:high\|:urgent` cast to rank `10\|20\|30\|40` | fixed ordered enum |
| `Samen.Type.URL` | `:string` | normalized absolute URL string | `schemes` (default `["http","https"]`), `max_length` |

**Priority stores an integer rank, not the atom** (c15: "ordered enum `low<normal<high<urgent`, sortable in Reads"). A `:atom` column sorts alphabetically (`high<low<normal<urgent` — wrong). Storing the rank makes the ordering **native and sortable in `Reads`** with no computed column; the type's input/read face is the atom, its storage face is the rank. This is the one type whose storage differs from its logical shape, and the reason is the sortability requirement.

### D3 — `EmailAddress` and `PhoneNumber` are format-validating but **PII-by-default**: no blanket type-level clearance. Personal use routes to the vault; org-contact plaintext needs a per-column clearance. (The H3 rule made structural.)

Spec H3 is explicit: these scalars are "for org-level, non-personal contact points — PII classification still defaults personal uses to vault." Email and phone are classic PII shapes. So, unlike D2, **`Samen.Type.EmailAddress` and `Samen.Type.PhoneNumber` do NOT self-classify `:non_pii`** and are **not** in the foundry `TypeClearance` manifest. They are format-validating types (`storage_type :string`, RFC-ish email / E.164-ish phone validation in `cast_input`) usable two ways:

- **Personal (the default, safe path):** as the *logical* type inside a vaulted attribute — `pii_attribute :email, Samen.Type.EmailAddress, vault: :pii_email`. The `VaultField` storage guard applies; the value is validated on input, tokenized at rest, `%Masked{}` on read. (Contrast with the existing multi-value composites `Samen.Type.Emails`/`Phones`, which stay the vehicle for a person's *list* of contacts; the H3 scalars are the single-value validating face.)
- **Org-level, non-personal (e.g. a company's `support@`, a billing contact):** as a **plaintext** `attribute :billing_email, Samen.Type.EmailAddress` — which, being unclassified, **masks-by-default** until that *specific column* is cleared through the two-distinct-party `Samen.NonPii.register/1`. The reviewer clearance is the record that "this column is a genuine org contact point, not a person."

This makes "personal uses default to vault" a **structural** property, not a documentation convention: an email/phone column is masked unless a named human review says otherwise (INV-1, done-criterion 3). URL differs (D2 gives it a type-level clearance) because a website URL is categorically non-PII.

### D4 — `Samen.Type.Address` (H4) is a PII composite; the new vault classes `pii_address`/`pii_dob` (H5) are zero-migration declarations.

`Samen.Type.Address` is a composite `Ash.Type` modeled on `Samen.Type.FullName` — `storage_type :map`, `defstruct [:line1, :line2, :city, :region, :postal_code, :country]`, `dump_to_native` to a string-keyed map, and **`def samen_pii_class, do: :pii`** (always honored, no gate). It routes by vault name with **no `pii_` column prefix** (the composite convention: column `<abbrev>_address`), declared `pii_attribute :address, Samen.Type.Address, vault: :pii_address`. Per **c17**, this ADR/H4 delivers the *composite type + `pii_address`*; the optional Location *resource* (F5/T47) is a separate deliverable that *uses* it (and per ADR-037 §5.10, Location carries no PostGIS geometry column — ash_geo REJECT).

**Vault classes are per-resource `vault :x` declarations, not a central registry.** All vault rows share one physical table (`Samen.Vault.VaultRow` / `"pii_vault"`, keyed by `(subject_id, vault_name, field_name)`, `vault_name` stored as the class-atom string). Therefore **`pii_address` and `pii_dob` require no schema/table change** — a new class is a new declared `vault :pii_address` + a `pii_attribute` routing to it; the closed-world `Samen.Pii.Verifiers.VaultDeclared` fails compile on a route to an undeclared vault. `:pii_dob` already appears as the canonical scalar example in `samen_core/lib/samen/pii.ex` (`pii_attribute :dob, :date, vault: :pii_dob`; scalar column `pii_<abbrev>_dob`); H5 formalizes it. **Extension recipe for `pii_ssn`-grade fields** (H5): a vertical declares `vault :pii_ssn` + `pii_attribute :ssn, :string, vault: :pii_ssn` in its resource/fragment — nothing else; it inherits the entire vault/mask/reveal/crypto-shred path by construction. Documented in the H5 contract row.

### D5 — Catalog / CSV / form integration rules (H7 round-trip), and the foundry `TypeClearance` manifest.

- **Catalog dump (H7).** `Catalog.fields/1` derives a field's type string via `type_string/1` = `inspect(type) |> String.trim_leading("Ash.Type.")`. A samen-named type therefore dumps its **own** module name (`"Samen.Type.Money"`, `"Samen.Type.Percent"`, …). This is *why* Money must be the wrapper, not a direct alias — the catalog is the type-name surface every generator and API contract reads. No separate type registry exists or is added; the module name **is** the catalog identity. `catalog_parity` (C1) checks column⇄row parity **by name only** and does not inspect the composite Postgres type — so the single `money_with_currency` column is one `fld_field` row and stays parity-clean; the separate `samen.verify.migrations` down-check gains the composite-type DDL as a fixture (an addition, not a weakening).
- **CSV round-trip (H7), extending `Samen.Web.Csv` — NOT adopting a data layer (ADR-037 §5.11).** Export already resolves every cell through `Samen.Api.PiiResolution` on the actor's plane *before* serialization (ADR-028); the H3/H4 PII types inherit that unchanged (`%Masked{}`→`"••••"`, `%Ash.ForbiddenField{}`→empty cell, never a `vt_*` token). What H7 adds is the **canonical cell string** for the new *non-PII* types, so export/import round-trips losslessly. `Samen.Web.Csv.cell/1` gains explicit clauses (rather than falling to `to_string/1` or the map-JSON branch):

  | Type | CSV cell (export) | Import parse (`decode_cell` → the action's `cast_input`) |
  |---|---|---|
  | Money | `"USD 12.34"` (ISO-4217 space amount) | same string; `cast_input` parses currency+amount |
  | Percent | `"42.5"` | decimal string |
  | Score | `"87"` | decimal string |
  | Duration | ISO-8601 `"PT1H30M"` | ISO-8601 or bare seconds |
  | Priority | `"high"` (the atom name, never the rank) | atom name → rank |
  | URL | the URL string | string |
  | EmailAddress / PhoneNumber | the string (or `"••••"`/empty when vaulted, per plane) | string |
  | Address | JSON object (or `"••••"`/empty when vaulted, per plane) | JSON object → struct |

- **Form input (H7).** `Samen.UI.Form.form_field/1` dispatches on a `:type` string against a whitelist (`~w(text email tel url password number date time datetime-local search hidden textarea select)`). The mapping: URL→`url`, EmailAddress→`email`, PhoneNumber→`tel`, Percent/Score/Duration→`number`, Priority→`select` (options = the ordered enum), Money→`number` (a first-class currency+amount composite input is an optional kit enhancement, not required by the contract), Address→a grouped set of inputs (composite; an optional kit component). The existing `%Samen.Masked{}` clause (disabled, `name`-less `••••` input — un-submittable) already covers the masked render of the H3/H4 PII types; **no masking-render code is added or weakened** (INV-1).
- **The `TypeClearance` manifest samen_core ships** (config `:samen_core, :non_pii_type_clearances`): one two-distinct-party entry per D1/D2 type — `Samen.Type.{Money, Percent, Score, Duration, Priority, URL}` — each with `cleared_by`, a distinct `reviewed_by`, and a `reason` ("categorically non-PII financial/measurement/enum/link scalar; PII-shaped uses route to the vault per ADR-036 D3"). `EmailAddress`/`PhoneNumber`/`Address` are deliberately **absent** (D3/D4).

### D6 — Custom-field Tier-1 types (H6) gain `money`, `url`, `phone`, `email`, `address`, reusing the same types and the bounded-constraint discipline.

`Samen.CustomFields.@field_types` (`samen_core/lib/samen/custom_fields.ex`, currently `[:string, :integer, :number, :boolean, :date, :enum]`) gains the five H6 types. Each addition touches the same three closed-world seams the existing types use: `field_types/0`'s list (define-time closed-world), a `type_ok?/2` value predicate, and a `constraint_violations/3` bounded-constraint clause — reusing the value/validation logic of the corresponding `Samen.Type.*` (Money reuses `Samen.Type.Money`, per ADR-037 §5.2). The Tier-1 PII guard is unchanged and decisive: `classify_containment/2` already rejects a PII-shaped value on a non-`pii_declared` field, so a custom `email`/`phone`/`address` field can **never** become a vault bypass — a personal-use custom contact field must be `pii_declared: true` (fail-closed). Storage stays the single `:map` bag (`<abbrev>_custom`); the new types serialize into it with the same canonical forms as D5's CSV column.

### D7 — The H1 Money migration: a pre-1.0 **destructive** single migration per resource (implementing ADR-037 §5.2 / M6 **AshMoney ADOPT**).

The paired columns are replaced by one `money_with_currency` composite column, **old columns dropped in the same migration, no deprecation window, CHANGELOG mandatory** — exactly the shape AshMoney adoption implies (keeping both readable would mean double-writing a composite and a pair for zero consumers of the public repo's pre-1.0 schema). Full sequence in §4. This migration is **T12's** to execute; this ADR fixes its shape.

---

## 3 · Per-type contract (H1–H7)

Each row gives the done-criterion-1 fields: **spec id · storage shape · cast/dump rules · catalog dump · CSV round-trip · form input · PII posture**.

### H1 · `Samen.Type.Money`
- **Storage shape.** Postgres composite `money_with_currency(char(3), numeric)` (via `AshMoney.AshPostgresExtension` in `installed_extensions`); one physical column. Ash value: ex_money `%Money{amount: Decimal, currency: atom}`.
- **Cast / dump.** Wraps `AshMoney.Types.Money`. `cast_input` accepts `%Money{}`, `{amount, currency}`, `"USD 12.34"`, or `%{"amount" =>, "currency" =>}`; dumps to the composite. Arithmetic/rounding/`sum|min|max|avg` SQL delegated to ex_money/ash_money.
- **Catalog dump.** `"Samen.Type.Money"` (via the samen wrapper — the reason for the wrapper).
- **CSV round-trip.** Export `"USD 12.34"`; import parses the same. New `cell/1` clause.
- **Form input.** `number` (amount) + currency select; optional first-class composite money input.
- **PII posture.** **Non-PII.** `samen_pii_class => :non_pii` + shipped `TypeClearance`. No vault interaction (ADR-037 §5.2: "Money is not PII").

### H2 · `Samen.Type.Percent`, `Score`, `Duration`, `Priority`
- **Percent** — storage `:decimal` (0..100 pts); `constraints [min:0, max:100, decimals:2]`; range-validating `cast`; catalog `"Samen.Type.Percent"`; CSV `"42.5"`; form `number`; **non-PII** (clearance).
- **Score** — storage `:decimal` (default 0..100); `constraints [min:0, max:100, decimals:0]`; catalog `"Samen.Type.Score"`; CSV `"87"`; form `number`; **non-PII** (clearance).
- **Duration** — storage `:integer` seconds (≥0); `constraints [min:, max:]`; `cast` accepts seconds / ISO-8601 / `%Duration{}`; catalog `"Samen.Type.Duration"`; CSV ISO-8601 `"PT1H30M"`; form `number`; **non-PII** (clearance).
- **Priority** — storage `:integer` **rank** (`low=10, normal=20, high=30, urgent=40`), atom input/read face (c15: ordered, sortable in Reads via native rank sort); fixed enum, `cast` rejects out-of-enum; catalog `"Samen.Type.Priority"`; CSV `"high"` (atom name); form `select`; **non-PII** (clearance).

### H3 · `Samen.Type.URL`, `EmailAddress`, `PhoneNumber`
- **URL** — storage `:string` (normalized absolute URL); `constraints [schemes: ["http","https"], max_length:]`; `cast` validates scheme+host; catalog `"Samen.Type.URL"`; CSV the URL string; form `url`; **non-PII by default** (type-level clearance — a website/link is categorically non-PII). **Personal-profile caveat (mirrors D3):** a URL that *identifies a natural person* (a personal social/profile link) is PII and must **not** live in a bare plaintext `attribute :x, Samen.Type.URL` column — route it through a vaulted `pii_attribute :x, Samen.Type.URL, vault: :pii_x` (the explicit vault opt-in survives the type's non-PII classification, exactly as it does for email/phone). The type-level clearance means "URL columns are non-PII by default," not "every URL is always safe to leave plaintext."
- **EmailAddress** — storage `:string` (format-validated); catalog `"Samen.Type.EmailAddress"`; CSV the string or `"••••"`/empty per plane when vaulted; form `email`; **PII-by-default (D3):** personal → `pii_attribute … vault: :pii_email`; org-contact plaintext → per-column `Samen.NonPii.register/1`. **No type-level clearance.**
- **PhoneNumber** — storage `:string` (E.164-ish); catalog `"Samen.Type.PhoneNumber"`; CSV string or masked per plane; form `tel`; **PII-by-default (D3):** personal → `pii_attribute … vault: :pii_phone`; org-contact plaintext → per-column clearance. **No type-level clearance.**

### H4 · `Samen.Type.Address` (+ vault class `pii_address`)
- **Storage shape.** `:map` composite; `defstruct [:line1,:line2,:city,:region,:postal_code,:country]`; column `<abbrev>_address` (composite convention, no `pii_` prefix).
- **Cast / dump.** Modeled on `FullName`: `cast_input` from `%Address{}`/map, `dump_to_native` to a string-keyed map.
- **Catalog dump.** `"Samen.Type.Address"`.
- **CSV round-trip.** JSON object; `"••••"`/empty per plane when vaulted (inherits ADR-028 resolution).
- **Form input.** Grouped inputs (composite kit component; optional).
- **PII posture.** **PII composite.** `samen_pii_class => :pii` (always honored). Declared `vault :pii_address` + `pii_attribute :address, Samen.Type.Address, vault: :pii_address`. Per c17, F5/Location merely *uses* this; no geometry column (ADR-037 §5.10).

### H5 · New vault classes `pii_address`, `pii_dob`; `pii_ssn` extension recipe
- **Contract.** Vault classes are per-resource `vault :x` declarations; all rows share `"pii_vault"` keyed by `vault_name`. **Zero schema/table change** to add `pii_address`/`pii_dob`. `pii_dob` (scalar, routes `:date`, column `pii_<abbrev>_dob`) already exists as the canonical example; `pii_address` (composite, D4). **Recipe (H5):** a vertical needing `pii_ssn`-grade fields declares `vault :pii_ssn` + `pii_attribute :ssn, :string, vault: :pii_ssn` — inheriting vault/mask/reveal/crypto-shred wholesale; the closed-world `VaultDeclared` verifier fails compile on any undeclared route.

### H6 · Custom-field Tier-1 types: `money`, `url`, `phone`, `email`, `address`
- **Contract.** Add to `Samen.CustomFields.@field_types`; each gets a `type_ok?/2` predicate + a `constraint_violations/3` bounded-constraint clause, reusing the matching `Samen.Type.*` validation. Storage stays the `:map` bag; canonical serialized forms = D5's CSV forms. **PII guard unchanged:** `classify_containment/2` forces a personal `email`/`phone`/`address` custom field to be `pii_declared: true` or be rejected — a Tier-1 field can never be a vault bypass.

### H7 · `mix samen.gen.resource` menu + catalog/masked-render/CSV honor every type
- **Contract.** The generator's emitted-resource template (`Samen.Gen.Post` / `samen_core/lib/samen/gen/post_templates.ex`) is extended to offer the full type menu (T15). Because the catalog identity of a type is simply its module name (D5), and CSV/forms dispatch on the catalog/value shape, **catalog dump, masked render (per plane, unchanged), and CSV import/export honor every new type by construction** once the D5 clauses land. No new type registry; the module name is the single identity across catalog, generator, forms, and CSV.

---

## 4 · The H1 Money migration plan (done-criterion 2)

**Verdict implemented:** ADR-037 §5.2 — **AshMoney ADOPT** (M6). Strategy: **pre-1.0 destructive single data-copy migration per resource**; old paired columns dropped in the **same** migration; **no deprecation window**; **CHANGELOG entry mandatory**.

### 4.1 · Blueprint change (single source, in `samen_core`)
Two blueprint macros hold the paired columns; both change identically — drop the `_cents :integer` + `currency :string` pair, add one Money attribute:

- `Samen.Scopes.Crm.Blueprint.define_opportunity/7` — remove `attribute :value_cents, :integer` + `attribute :currency, :string`; add `attribute :value, Samen.Type.Money`.
- `Samen.Scopes.Billing.Blueprint.define_price/6` — remove `attribute :unit_amount_cents, :integer` + `attribute :currency, :string`; add `attribute :unit_amount, Samen.Type.Money`.

Every host inherits the change; each host **generates its own** data-copy migration (real DDL lives per host: `demo/priv/repo/migrations/`, `driftwood/priv/repo/migrations/`, `pawchart/priv/repo/migrations/`). `installed_extensions` gains `AshMoney.AshPostgresExtension` (adds the `money_with_currency` composite type + `+`/`sum`/`min`/`max`/`avg` SQL operators).

### 4.2 · Every table/column touched
Physical names are `<abbrev>_<name>`; abbrevs differ per host mount (`AbbrevStorage`). All CRM + Billing mounts (demo, driftwood, pawchart) are affected:

| Resource | Host (mount) | Abbrev | Table | Columns dropped | Column added |
|---|---|---|---|---|---|
| CRM Opportunity | demo | `opp` | `opp_opportunity` | `opp_value_cents`, `opp_currency` | `opp_value` (`money_with_currency`) |
| CRM Opportunity | driftwood | `fop` | `fop_opportunity` | `fop_value_cents`, `fop_currency` | `fop_value` |
| CRM Opportunity | pawchart | `vcd` | `vcd_opportunity` | `vcd_value_cents`, `vcd_currency` | `vcd_value` |
| Billing Price | demo | `bpr` | `bpr_price` | `bpr_unit_amount_cents`, `bpr_currency` | `bpr_unit_amount` |
| Billing Price | driftwood (tenant billing) | `fbr` | `fbr_price` | `fbr_unit_amount_cents`, `fbr_currency` | `fbr_unit_amount` |
| Billing Price | driftwood (operator billing) | `dpr` | `dpr_price` | `dpr_unit_amount_cents`, `dpr_currency` | `dpr_unit_amount` |
| Billing Price | pawchart | `ppc` | `ppc_price` | `ppc_unit_amount_cents`, `ppc_currency` | `ppc_unit_amount` |

**Generator deliverables (INV-5 — enumerated, not asserted).** The generator TEMPLATES today emit the paired integer columns and MUST be rewritten by T12, or the gen-app flagship probe and the `templates_golden` test fail:

- `samen_core/priv/templates/m_app_resources.eex:56` — `add(:<%= bp %>_unit_amount_cents, :integer, null: false)` + `:57` `add(:<%= bp %>_currency, …)` → emit a single composite column `add(:<%= bp %>_unit_amount, :money_with_currency, null: false)` (the AshMoney/ex_money_sql column shape) and drop the paired `add`s.
- `samen_core/priv/templates/m_mount_operator_scopes.eex:181` — `add(:<%= o_price %>_unit_amount_cents, :integer, null: false)` + `:182` `add(:<%= o_price %>_currency, …)` → same composite emission.
- Each template's migration must also emit `AshMoney.AshPostgresExtension` in the app's `installed_extensions` so the `money_with_currency` type exists.
- **Regenerate the golden fixtures** that pin template output: `samen_core/test/fixtures/templates_golden/{web,web_api,web_api_deploy,web_api_modules}/priv/repo/migrations/20260709100000_app_resources.exs.golden` and `…/20260714210000_mount_operator_scopes.exs.golden` (the `headless` variant has only `app_resources`; all five `app_resources` goldens encode `apr_unit_amount_cents` and must be regenerated). The `templates_golden` test byte-compares emitted output to these fixtures — regeneration is mandatory, not optional.

Every **generated app** (`mix samen.gen.app` output + the three gen-app probe apps in `ci.sh`) that mounts CRM/Billing then inherits the same per-abbrev composite migration, keeping the flagship probe green (INV-3). Note: `Customer`/`Invoice`/`Payment` `_currency` columns the templates also emit (`m_app_resources.eex:29,119,157`, `m_mount_operator_scopes.eex:154,244,282`) are **not** touched — they pair with amount columns outside the H1 scope (§4.4).

### 4.3 · Exact migration sequence (per resource, per host)
One migration, **contract phase** (net-destructive: it drops columns with no deprecation window — precisely samen's contract-phase category, PITR-covered rather than `down/0`-down-tested; this is why `samen.verify.migrations`, which round-trip-tests only `:expand` migrations, does not require a reversible `down/0` here):

1. `CREATE TYPE money_with_currency` if absent (idempotent; supplied by `AshMoney.AshPostgresExtension` in `installed_extensions`).
2. `ALTER TABLE <t> ADD COLUMN <abbrev>_<newcol> money_with_currency`.
3. **Backfill** — `UPDATE <t> SET <abbrev>_<newcol> = ROW(<abbrev>_currency, <abbrev>_<name>_cents::numeric / 100)::money_with_currency` (existing integer-cents ÷ 100 → numeric amount; `currency` string → the composite's `char(3)`). Lossless for the current integer-cents data.
4. `ALTER TABLE <t> DROP COLUMN <abbrev>_<name>_cents`, `DROP COLUMN <abbrev>_currency` — **same migration**, no deprecation window.
5. Catalog reconciliation: the dropped columns' `fld_field` rows are removed and the new composite column's `fld_field` row added (one column → one row), keeping `catalog_parity` clean (name-only parity; the composite type is invisible to that verifier). The `samen.verify.migrations` fixture set gains the composite-type DDL.

**Documented reversal recipe** (for operators; not a down-tested `down/0` since this is a contract migration): re-add the pair, `UPDATE … SET _cents = round(amount*100), currency = code` from the composite, drop the composite column. The forward transform is a bijection over the existing integer-cents data, so the recipe is exact.

### 4.4 · Scope boundary (what H1 does and does NOT migrate)
ADR-037 §5.2 names exactly **CRM Opportunity** and **Billing Price** — user-authored money a person enters (a deal value, a price a tenant sets). **Deliberately not migrated this run:** the Stripe-mirror amount columns (`Invoice.amount_due_cents`/`amount_paid_cents` + line-item jsonb, `Payment.amount_cents`) — provider-authoritative numbers (INV-4 boundary), not user-authored money. **Revisit trigger:** if any of those becomes a user-editable, currency-bearing surface, migrate it to `Samen.Type.Money` then (do not hand-roll a second money convention). A `Customer.currency` default-currency column is a plain code, not an amount — untouched.

**RETRACTION (P1, verifier finding).** A prior draft of this section claimed the subscription-movement ledger and "the SQL aggregates" are untouched by H1. **That is false and is retracted.** The `mov` ledger's *own physical columns* (`mrr_delta_cents`/`mrr_before_cents`/`mrr_after_cents`, ADR-017) do stay integer-cents — but the ledger and the revenue rollups are not self-contained: they **read the migrated `Price.unit_amount_cents` and `Opportunity.value_cents` columns as their source**. Dropping those columns without repointing their readers breaks gate-tested revenue surfaces (`revenue_reconciliation_test`, `subscription_movement_ledger_test`, `operator_revenue_plan_floor_test`, the aggregate rebuilds, the broker rollup — ADR-010/ADR-017). H1 therefore has a **mandatory consumer sweep (§4.5)** that T12 executes *in the same change set* as the DDL. Done-criterion 2's "every table/column touched" is schema-complete above; §4.5 completes it at the code-reader level so T12 does not inherit the landmine the T98 ADR chain exists to prevent.

### 4.5 · Consumer sweep (P1 — mandatory; T12 executes alongside the DDL)
Every reader/writer of the four migrated logical columns (`Opportunity.value_cents`, `Opportunity.currency`, `Price.unit_amount_cents`, `Price.currency`) and their physical forms (`*_value_cents`, `*_unit_amount_cents`). Enumerated by grep, not estimate. Each entry: file:line — what it does now — what T12 changes it to.

**(1) Kernel MRR source — Ash reads of `Price.unit_amount_cents`:**
- `samen_core/lib/samen/billing/subscription_movement.ex:166` `ensure_selected([:plan_id, :unit_amount_cents, …])` and `:170` `Map.new(&{&1.plan_id, &1.unit_amount_cents})` → select `:unit_amount` (the Money attr) and extract minor units via ex_money (`Money.to_integer_exp/1` / a `Samen.Type.Money.cents/1` helper) so the downstream `mrr_delta_cents` math is unchanged.
- `samen_core/lib/samen/billing/movement_backfill.ex:146` + `:150` — identical shape, identical fix.

**(2) Raw-SQL revenue rollups — read the *physical* migrated columns (must sum the composite):**
- `demo/lib/demo/aggregate/rebuild.ex:72` `COALESCE(SUM(pr.bpr_unit_amount_cents),0)::int AS amr_mrr_cents` → sum the composite's minor units, e.g. `SUM((pr.bpr_unit_amount).amount * 100)::int` (or ash_money's SQL `sum` operator); update the column-list doc at `:11`.
- `driftwood/lib/driftwood/aggregate/rebuild.ex:44` `COALESCE(SUM(l.fop_value_cents),0)::int AS dag_gross_cents` → `SUM((l.fop_value).amount * 100)::int`; update the doc at `:10`.
- `driftwood/lib/driftwood/broker_rollup.ex:50` `COALESCE(SUM(l.fop_value_cents),0)::int AS dbs_gross_cents` → same composite sum.

**(3) `samen_web` read/UI consumers (repoint to the Money value + a `dollars/format` helper on it):**
- `samen_web/lib/samen/web/billing/reads.ex:211` `ensure_selected([…:unit_amount_cents,:currency…])`, `:212` `sort(unit_amount_cents: :asc)`, `:585` `ensure_selected([…:unit_amount_cents…])`, `:595` `acc + subs*(price.unit_amount_cents||0)` → select `:unit_amount`; sort on the composite (ash_money adds the SQL ordering operators); sum via the Money value's minor units.
- `samen_web/lib/samen/web/operator/reads.ex:557` `ensure_selected([…:unit_amount_cents…])` + `:561` `Map.new(&{&1.plan_id,&1.unit_amount_cents})` → select `:unit_amount`, extract minor units.
- `samen_web/lib/samen/web/billing/plans_live.ex:466` `dollars(price.unit_amount_cents)` → `dollars(price.unit_amount)` (Money-aware helper).
- `samen_web/lib/samen/web/crm/reads.ex:206` + `:323` `ensure_selected([…:value_cents…])`, `:369` `sum_resource(open_opps_query, :value_cents, scope)` → select `:value`; sum the Money composite.
- `samen_web/lib/samen/web/crm/pipeline_live.ex:37,45,48,59,104,142,168` — the `total_value_cents`/`stage_value` accumulators (`opp.value_cents || 0`) and `dollars(...)` render → accumulate over the Money value's minor units; render via the Money helper.
- `samen_web/lib/samen/web/crm/company_live.ex:334` and `contact_live.ex:373` `dollars(opp.value_cents)` → `dollars(opp.value)`.
- `samen_web/lib/samen/web/crm/companies_live.ex:200` `dollars(@metrics.pipeline_value_cents || 0)` → the metric now carries a Money total; render via the helper.
- The shared `dollars/1` kit helper is repointed once from `(cents_integer)` to a Money-aware formatter (currency-carrying); all the above call sites then pass the Money value.

**(4) Vertical UI + query (driftwood; pawchart CRM has no money render today):**
- `driftwood/lib/driftwood/reads.ex:95` `ensure_selected([…:value_cents,:currency…])` → `:value`.
- `driftwood/lib/driftwood_web/broker_live.ex:292` and `driftwood/lib/driftwood_web/operator_impersonation_live.ex:285` `dollars(l.value_cents)` → `dollars(l.value)`.

**(5) Seeds / test-support writers (write the old keys — must write the Money value):**
- `driftwood/lib/driftwood/seeds.ex`, `driftwood/lib/driftwood/operator_seeds.ex`, `driftwood/lib/driftwood/dogfood_scenario.ex:175,180` (`value_cents:`), `driftwood/lib/driftwood/crypto_shred_gameday.ex:265,269` (`value_cents:`), `pawchart/lib/pawchart/seeds.ex`, `samen_web/test/support/seeds.ex:288` (`value_cents: 250_000`) + `:340` (`unit_amount_cents: 29_900`), `samen_web/test/support/operator_seeds.ex:219` (`unit_amount_cents: 49_900`) → construct the Money value (e.g. `Money.new(:USD, "2500.00")` / `{amount, :USD}`) instead of the integer-cents + currency pair.

**Not edited:** the historical migrations that *created* the paired columns (`driftwood/priv/repo/migrations/20260708110000_…`, `pawchart/priv/repo/migrations/20260708200000_…`, `samen_web/priv/repo/migrations/20260708130000_…`) — migration history is append-only; the new §4.3 data-copy migration performs the transition. Each gate-tested revenue surface listed in the §4.4 retraction must be green after the sweep (INV-3); T12 owns the per-plane/revenue proofs.

---

## 5 · PII posture summary (INV-1 · done-criterion 3)

| Type | Classification | Routes to vault by default? | Mechanism |
|---|---|---|---|
| Money | non-PII | no | `samen_pii_class :non_pii` + foundry `TypeClearance` |
| Percent | non-PII | no | `:non_pii` + `TypeClearance` |
| Score | non-PII | no | `:non_pii` + `TypeClearance` |
| Duration | non-PII | no | `:non_pii` + `TypeClearance` |
| Priority | non-PII | no | `:non_pii` + `TypeClearance` |
| URL | non-PII by default | no (but a **personal-profile** URL must be vaulted per-column) | `:non_pii` + `TypeClearance`; personal-identifying URL → `pii_attribute … vault: :pii_x` (D2/H3 caveat) |
| EmailAddress | **PII-by-default** | **yes (personal use)** | no type clearance; personal → `pii_attribute vault: :pii_email`; org-contact → per-column `NonPii.register/1` |
| PhoneNumber | **PII-by-default** | **yes (personal use)** | no type clearance; personal → `pii_attribute vault: :pii_phone`; org-contact → per-column `NonPii.register/1` |
| Address | **PII** | **yes** | `samen_pii_class :pii` (always) + `vault :pii_address` |

The keystone is preserved and extended: no new type opens a plaintext-PII path; the two PII-shaped scalars (email/phone) mask-by-default and only a named two-party review makes a specific org-contact column plaintext (H3 "personal uses default to vault" made structural). `no_plaintext_pii` / `pii_reads` stay green (INV-1); the C4 `pii_classify` verifier consults the same oracle, now with the foundry clearance manifest for the six cleared types.

---

## 6 · Rationale

- **Wrapper over adopter (Money).** ADR-037 §5.2 already weighed hand-build vs adopt and chose AshMoney; the only samen-side decision left is *naming* — and the catalog's `type_string/1` makes the module name the type's public identity, so the wrapper is what keeps "Samen.Type.Money" in the catalog/generator/API surface while ex_money owns the arithmetic. Cheapest correct option.
- **Reviewed non-PII, not a new plaintext primitive.** Adding the new types to `@non_pii_scalars` would be a *single-party* widening of the plaintext set — exactly the asymmetry ADR-034 closed. Routing them through `samen_pii_class :non_pii` + `TypeClearance` reuses the existing two-party governed opt-out: the safe default (mask) holds until a reviewed clearance ships, and the clearance is auditable config.
- **PII-shaped scalars stay masked-by-default.** Email and phone are PII; a blanket type-level clearance would let a careless personal-use column inherit plaintext. Per-column `NonPii.register` for the genuine org-contact case is the narrower, honest lever — and it makes the spec's "personal uses default to vault" a property of the type system, not a comment.
- **Priority stores a rank because the spec demands ordering + sortability** (c15); a stored atom cannot sort correctly. One type's storage≠logical shape, for a stated reason.
- **CSV extends, never adopts a data layer** (ADR-037 §5.11): the masked CSV chokepoint stays sole; H7 only teaches `cell/1`/`decode_cell/1` the new canonical strings, inheriting the per-plane resolution ADR-028 already proves.
- **Destructive money migration is the pre-1.0 honest choice** (M6): a public repo with no pre-1.0 schema consumers gains nothing from a deprecation window; a single data-copy migration + CHANGELOG is the cheapest truthful path, and the integer-cents→composite transform is a lossless bijection.

## 7 · Rejected alternatives

- **Hand-build `Samen.Type.Money`.** Rejected — reimplements currency arithmetic/rounding/SQL-aggregation ex_money proves; ADR-037 §5.2 binds ADOPT.
- **Adopt `ash_csv` for H7 round-trip.** Rejected — it is a CSV *data layer* (storage = a file), a category error against the masked `Samen.Web.Csv` surface; would bypass Postgres/vault/policies (ADR-037 §5.11).
- **Add the new types to `@non_pii_scalars`.** Rejected — single-party widening of the plaintext default; the `TypeClearance` two-party gate is the governed equivalent (ADR-034 symmetry).
- **Give `EmailAddress`/`PhoneNumber` a type-level non-PII clearance.** Rejected — they are PII shapes; a blanket clearance risks a personal-use column silently going plaintext. Per-column clearance is the correct granularity (D3).
- **Store Priority as a constrained `:atom`.** Rejected — sorts alphabetically, violating c15's ordering/sortability. Integer rank sorts natively.
- **Deprecation-window (dual-column) Money migration.** Rejected — double-writes a composite and a pair for zero pre-1.0 consumers of the public repo (M6; ADR-037 §5.2).
- **Migrate all `_cents` columns now.** Rejected — Invoice/Payment are Stripe-mirrors (INV-4) and the `mov` ledger deltas are SQL-summed aggregates; ADR-037 §5.2 scopes H1 to the two user-authored money surfaces. Revisit trigger recorded (§4.4).

## 8 · Consequences

- **Positive.** WS-H closed at substrate level (INV-5): one uniform type identity across catalog, generators, forms, CSV; money arithmetic delegated to a mature dep; the classification keystone extended with an auditable clearance manifest rather than widened by fiat; PII posture explicit and mostly structural.
- **Negative / accepted.** A pre-1.0 destructive schema break for Opportunity + Price (CHANGELOG-recorded; PITR-covered). Six shipped `TypeClearance` entries are a real, deliberate review artifact the foundry maintains. Org-contact email/phone columns each cost a two-party per-column clearance (intended friction). First-class composite Money/Address form inputs are optional kit enhancements, not delivered by this contract.
- **Neutral / affected tasks.** **T12** executes §4 in one change set: the per-host data-copy migration (§4.3), `installed_extensions` + the generator-template rewrite and golden-fixture regeneration (§4.2), the **mandatory consumer sweep** repointing the kernel MRR source, the raw-SQL revenue rollups, the ~15 `samen_web` read/UI consumers, the vertical UI, and the seeds/test-support writers (§4.5), and the CHANGELOG entry. The §4.4 retraction means the sweep is not optional cleanup — dropping the columns without it breaks gate-tested revenue surfaces. **T15** implements the H6 custom-field types + the H7 gen.resource menu; the H1–H4 type modules land in `samen_core/lib/samen/type/` under the tasks that consume them. **Verifier/sabotage duties (house rules, INV-3):** the `samen.verify.migrations` fixture gains the composite DDL; `catalog_parity` stays clean by name; a red test asserts a Money/Percent/etc. column classifies `:non_pii` **only** with its clearance present (drop the clearance → it flips to PII/masked — the ADR-034 sabotage twin), and a red test asserts an `EmailAddress`/`PhoneNumber` column with **no** clearance masks-by-default. `no_plaintext_pii`/`pii_reads` remain green; no masking tier is removed, coverage is added.

## 9 · References

- **Binding:** `docs/adr/ADR-037-ash-ecosystem-adoption.md` §5.2 (AshMoney ADOPT + Money migration shape), §5.11 (AshCsv REJECT), §5.10 (ash_geo REJECT — Location/F5).
- `docs/adr/034-nonpii-type-selfclassify-reviewer-gate.md` (the `:non_pii` two-party `TypeClearance` gate); `docs/adr/028-csv-import-export-mask-by-omission.md` (the masked CSV surface H7 extends).
- Spec: `spec/full-saas-readiness.md` §WS-H (H1–H7), INV-1..INV-6. Rulings: `_orch/plan/spec-questions.md` M6, c15, c17.
- Code seams: `samen_core/lib/samen/pii/classification.ex` (the oracle); `samen_core/lib/samen/pii.ex` (`vault`/`pii_attribute` DSL, `VaultDeclared`); `samen_core/lib/samen/vault/schema.ex` (`pii_vault`); `samen_core/lib/samen/type/{full_name,emails,phones,vault_field}.ex` (the `use Ash.Type` skeleton); `samen_core/lib/samen/catalog.ex` (`type_string/1`); `samen_web/lib/samen/web/csv.ex` (`cell/1`/`decode_cell/1`); `samen_web/lib/samen/ui/form.ex` (`form_field/1`); `samen_core/lib/samen/custom_fields.ex` (`@field_types`); `samen_core/lib/samen/scopes/crm/blueprint.ex` (`define_opportunity/7`), `samen_core/lib/samen/scopes/billing/blueprint.ex` (`define_price/6`); `samen_core/lib/samen/transformers/abbrev_storage.ex` (`<abbrev>_<name>`); `CHANGELOG.md`.

## 10 · Addendum — D3 conformance: the vaulted write path validates on input (T99)

**Status:** accepted (T99, 2026-07). Scope: the two vault-kernel files (`samen_core/lib/samen/vault/change.ex`, and the behavior documented against `samen_core/lib/samen/transformers/materialize_pii.ex`) + tests. This is a conformance note on D3, **not** a new ADR.

**The gap D3 promised closed but the substrate left open.** D3 (and the H3 contract rows for `EmailAddress`/`PhoneNumber`) state that on the personal vaulted path "the value is **validated on input**, tokenized at rest, `%Masked{}` on read." That was not true. `Samen.Transformers.MaterializePii` materializes every `pii_attribute` as a `Samen.Type.VaultField` column regardless of its **declared logical type** (`EmailAddress`, `PhoneNumber`, `URL`, `Emails`, `:date`, …), and `Samen.Type.VaultField.cast_input/2` is an identity pass-through (it must accept any plaintext shape, because encryption — a side-effecting, subject-keyed operation — happens in `Samen.Vault.Change`, not a pure type callback). `Samen.Vault.Change` then only stringified the plaintext before encryption. **Net effect:** the declared type's `cast_input` — where all H2/H3 validation and normalization lives — NEVER ran on the vaulted write path. A garbage email (`"this is not an email at all !!!"`) vaulted successfully and revealed byte-for-byte; a phone number vaulted un-normalized (reveal returned `"+1-555-010-0100"`, not `"+15550100100"`). Independently confirmed by the T13 verifier's live probe (`_orch/verify/T13-verdict.json` → `probe`, `caveat_rulings["2"]`).

**Decision — where the cast belongs: `Samen.Vault.Change`, immediately before the plaintext is dumped to the vault.** Considered and rejected:

- *A `MaterializePii`-injected validation change* — more machinery, and it would have to re-derive the plaintext/masked/token/nil discrimination `Samen.Vault.Change` already performs. Redundant.
- *`Samen.Pii.WriteGuard`* — wrong seam: the write guard is a plane-authorization gate (refuse operator-plane plaintext writes); it is deliberately a no-op on the tenant/nil plane, which is exactly the legitimate write surface that must be validated. Format validation is orthogonal to who is writing.
- *Delegate at read/reveal time* — explicitly forbidden by the task and by the invariant: validate/normalize ONCE at write; tokens at rest must be unchanged.

`Samen.Vault.Change` already (a) resolves the subject, (b) collects exactly the `(field, plaintext)` pairs a caller genuinely set to a non-token/non-`%Masked{}`/non-nil value — the set it is about to encrypt, and (c) has the **declared logical type** in hand as `field.type` (via `Samen.Pii.Info.fields/1`, which reads the un-materialized `%Samen.Pii.Attribute{}` DSL entity, NOT the `VaultField` the column was materialized to). So the cast runs there, on precisely the values headed for the vault, with the declared type already available — the most surgical seam.

**How it runs.** For each plaintext to vault, `Samen.Vault.Change` calls `Ash.Type.cast_input(field.type, plaintext)` — the **same** entry point Ash uses to cast an ordinary (org-plaintext) attribute of that type (it inits the type's constraints and applies its `cast_input`). This guarantees **parity**: a value vaulted through `pii_attribute :phone, Samen.Type.PhoneNumber` and a value written to a bare `attribute :support_phone, Samen.Type.PhoneNumber` normalize to the identical canonical form. The value **stored in the vault is the cast-normalized value** (so `Samen.Vault.reveal/3` returns the normalized value, not the raw input). A value the declared type **rejects** surfaces as a normal Ash changeset error on the offending attribute (the write is refused inside the action's transaction — DB unchanged); the rejected value is **never** echoed into the error (it is, or may be, PII). A value the type normalizes to `nil` (e.g. an empty string) clears the column rather than vaulting an empty row.

**Scope — SCALAR validating types only; composites deliberately untouched.** The cast gate runs for the **scalar** validating types this ADR added (`EmailAddress`/`PhoneNumber`/`URL`, and any scalar logical type such as `:date`): the value is refused if the type rejects it, and stored **normalized** (phone `"+1-555-010-0100"` → `"+15550100100"`, reveal-parity with the org-plaintext path). That is the confirmed gap (the T13 probe).

**Composite** PII types (`FullName`/`Emails`/`Phones`) are left **exactly as before** — no cast gate, the original value is stored byte-for-byte. Two reasons this is out of scope for a *surgical* D3 fix:

1. **Reshape breaks readers.** Casting a map/list to the type's struct changes the stored JSON (an `Emails` list `[{…}]` → `{"entries":[{…}]}`); the masking/reveal/render/CDC/blind-index consumers that parse the stored composite (CRM contact render, identity email lookup, chat unfurl, marketing lists) depend on that shape not changing.
2. **Gating rejects shipped loose-shape writes.** Shipped resources write composites in shapes their *own* `cast_input` refuses — e.g. `Invitation.email` is a `Samen.Type.Emails` field written as a bare-string list `["invitee@example.test"]` (the type's contract is `[%{address: …}]`), which stores fine today but a cast gate would reject. Enforcing composite validation therefore requires **first** cleaning up those loose writers — a cross-cutting change beyond the two vault-kernel files.

Composite validation-on-write (what T14's `Samen.Type.Address` ultimately wants) is a **follow-up**: the seam now exists in `Samen.Vault.Change` (`cast_declared_types/1`), so once the loose composite writers are made canonical, flipping composites into the gate is a one-line change. T14 should either write `Address` in canonical shape + carry its own validation, or land that writer-cleanup task first.

**INV-1 preserved; nothing weakened.** `Samen.Type.VaultField`'s last-line dump refusal (raw plaintext to the domain column ⇒ `:error`) is untouched; the domain column still only ever receives a `vt_*` token. Masking, reveal, erasure/crypto-shred, and the operator-plane write guard are unchanged; the full masking suite, `no_plaintext_pii`/`pii_reads` verifiers, and every sabotage twin stay green.

**Test-assertion correction (non-silent, per the T99 done-criteria).** `samen_core/test/type/phone_number_test.exs` previously asserted the *pre-fix* behavior — reveal returning the **un-normalized** `"+1-555-010-0100"` (its own moduledoc flagged this as the documented gap). That assertion encoded the bug D3 promises against; with the fix, reveal returns the normalized `"+15550100100"`. The assertion is updated to the corrected (and D3-conformant) value — a strengthening, not a weakening. The permanent probe + positive controls live in `samen_core/test/vault/vault_cast_validation_test.exs`.

**Forward note (T14).** `Samen.Type.Address` (H4, the `pii_address` composite) does **not** automatically get validation-on-write from this fix — composites are outside the scalar gate (see Scope above). The seam is ready (`cast_declared_types/1`), but T14 must either (a) land a small writer-cleanup task that makes the shipped loose composite writers canonical, then flip composites into the gate, or (b) validate `Address` at its own boundary. This is called out so T14 does not assume the behavior is already wired.

## 11 · Addendum — T14: `Address` validated at its own boundary (H4/H5, post-T99)

**Status:** accepted (T14, 2026-07). Binding ruling from the prime orchestrator (post-T99): option (b) from the section 10 forward note above — validate `Address` at its own input boundary, NOT option (a) (the composite-writer cleanup), because T05 was concurrently working the Invitation/Emails surface that (a) would touch.

**Implementation.** `Samen.Vault.Change`'s `cast_declared_types/1` (section 10) gained a narrow, TYPE-SPECIFIC carve-out — by module identity, not a blanket `field.composite?` flip: a value routed to a `Samen.Type.Address`-typed `pii_attribute` now re-runs `Ash.Type.cast_input/2` (Address's own `cast_input/2`, which validates every field's shape and normalizes `country` to a strict ISO-3166-1 alpha-2 code) before it reaches the vault, exactly like the H3 scalars. `FullName`/`Emails`/`Phones` are completely untouched — the carve-out is safe specifically because `Address` is brand-new (T14) with zero shipped loose-shape writers to break, unlike `Emails` (`Invitation.email`'s bare-string-list write, the reason section 10 scoped the original fix to scalars).

**Proof.** The garbage-Address red test + positive control (the Address analogue of T99's garbage-email probe) lives permanently in `samen_core/test/vault/vault_cast_validation_test.exs` (alongside T99's scalar probes) and is repeated, alongside the full `Ash.Type` contract and the `Samen.MaskingCase` 3-proof, in `samen_core/test/type/address_test.exs`.

**H5 formalization + the extension recipe.** `pii_dob` (already live in `SamenCore.Support.Clinical.Patient`) and the new `pii_address` are both declared in `SamenCore.Support.RichTypes.PersonalFixture`'s `pii do` block — no central registry exists or was added (D4); a vault class IS the `vault :name` declaration. The general recipe (a `pii_ssn`-grade scalar field gets full vault/mask/reveal/write-validation behavior from two file touches — the `pii do` declaration and a migration — with NO extra code; a new PII composite additionally needs a type module and, only if it has a real format rule and no legacy writers, the same narrow `cast_declared_types/1` carve-out `Address` uses) is documented in `docs/guides/vault-class-extension.md`.
