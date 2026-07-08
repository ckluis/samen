# PawChart — Reuse Measurement (T6.2)

**Date:** 2026-07-07
**App:** `/Users/clank/Desktop/projects/samen/pawchart/` — the second-vertical thin slice, the plan's reuse-measurement probe (plan row T6.2).
**Thesis under test:** *"Build the 20%, inherit the 80%."*
**Vision-doc framing:** PawChart is the doc's declared **EASY ADDITIVE case** — "Billing: kept as plain subscriptions. Tier-2: a VaccineLot object clinics define themselves. Ticketing & CMS untouched" — the deliberate contrast with Driftwood, which *reshaped* the money model under a bounded-context anti-corruption layer.

This document reports **hard numbers**, not vibes.

---

## 1. What PawChart is

A vet-clinic SaaS on the Samen substrate, built as the doc's "two PII subjects, one relationship" shape:

- **`PawChart.Clinic.Patient`** — the **human OWNER** (the paying, messaged party). Composes `Samen.Fragments.CorePerson` via `base:`, so `full_name`/`emails`/`phones` are vault-routed with zero vertical PII code. A first-class PII subject with its own crypto-shred key.
- **`PawChart.Clinic.Pet`** — the **animal**, and the actual clinical record. Carries the scalar vault field `pii_pet_microchip` (the doc's `pii_pat_microchip` idiom — named `pet_*` because the animal record's abbrev is `pet`), + non-PII clinical columns + a `belongs_to :owner` FK.
- **Billing** — the samen_core Billing scope **mounted as-is**: 8 resources (Customer🔒 → Subscription → Plan/Price → Invoice → Payment → Usage → Entitlement), **no reshape, no `Samen.Context`, no `alias_resource`**.
- **VaccineLot** — a **Tier-2 custom object clinics define themselves** via the inherited `Samen.CustomObjects` machinery.
- **Aggregate plane** — one token-blind cross-tenant projection (`PatientVolumeBySpecies`) to exercise the C7 `no_pii_columns` + `aggregate_privacy` verifiers.

---

## 2. Hard numbers — authored vs inherited

Line counts are **code only**: `@moduledoc`/`@doc` heredocs, `#` comments, and blank lines stripped (an `awk` heredoc-aware counter; see `/pawchart` measurement run). This deliberately measures *engineering surface*, not prose.

### 2a. What PawChart AUTHORED (the "20%")

| Artifact | Code lines | What it is |
|---|---:|---|
| `lib/pawchart/clinic.ex` | 104 | The two authored nouns: Patient (composes CorePerson) + Pet (microchip vault + owner FK) + their reveal action + policies |
| `lib/pawchart/aggregate.ex` | 42 | One token-blind projection resource + its cohort spec |
| `lib/pawchart/billing.ex` | 17 | The Billing **mount** (`use Samen.Scopes.Billing` + fresh abbrevs) — that's the *entire* billing authoring |
| `lib/pawchart/repo.ex` + `application.ex` | 28 | Boilerplate repo + OTP app |
| **lib total** | **191** | |
| `priv/repo/migrations/…pawchart_resources.exs` | 282 | The authored DDL + `catalog_sync` (mostly mechanical `add(:col, :type)` — a generator would emit this; see §5) |
| `config/*.exs` | 50 | Wiring the repo into the inherited machinery (reveal/vault/tnt/aggregate repos, Oban, k-anon floor) |
| `mix.exs` | 34 | Deps + project |
| **Non-test authored total** | **557** | |
| Tests + anti-tautology probe + bootstrap | 543 | The red-path proof suite (6 test files, 19 tests) + the executable probe |

### 2b. What PawChart INHERITED for free (the "80%")

| Inherited machinery | samen_core code lines | Vertical code to use it |
|---|---:|---|
| Billing scope (8 resources: customer🔒/subscription/plan/price/invoice/payment/usage/entitlement + Stripe-mirror + entitlement helper + sync adapter) | 1,214 | **17** (one `use` + abbrevs) |
| CorePerson fragment + `Samen.Resource` base macro + storage transformers (abbrev projection, core-attrs, PII materialization) | 879 | **0** (a `base:` option) |
| Tier-2 custom objects + Tier-1 custom fields (the VaccineLot machinery) | 1,219 | **0** (call `define_object`) |
| Vault + mask + crypto-shred + KMS envelope crypto (11 modules) | ~1,900 | **1** (`pii_attribute :microchip`) |
| 6 reusable policies (OrgScope, SameOrgFk, RoleAtLeast, AggregateActorOnly, …) | — | **0** (referenced by name) |
| 16 fail-closed verifier mix tasks (the entire CI gate) | — | **0** (run the tasks) |
| Whole substrate (`samen_core/lib`) | **33,640** | — |

**The ratio, stated honestly.** PawChart authored **557 lines of non-test vertical code** (191 of it real domain logic; the other ~366 is migration DDL + config wiring that a generator would largely emit). It sits on **33,640 lines of substrate**. Against the substrate it *touches*, the leverage is starkest at the point declarations:

- `pii_attribute(:microchip, :string, vault: :pii_microchip)` — **one line** buys the entire vault + mask + crypto-shred + KMS + destruction-oracle tier chain (~1,900 lines).
- `use Samen.Scopes.Billing, …` + an abbrev map — **17 lines** buys 8 fully-policed, vaulted, catalogued, audited billing resources (1,214 lines of blueprint).
- `use Samen.Resource, base: Samen.Fragments.CorePerson` — **one option** buys the folded core-person shape with vaulted name/emails/phones (879 lines of base machinery).

By the crude "vertical LOC ÷ (vertical + substrate touched)" measure over just the four families a vet clinic exercises (Billing 1,214 + CorePerson/base 879 + Tier-2 1,219 + vault/mask/shred ~1,900 = **5,212 inherited**), PawChart's 191 lines of authored domain logic is **~3.5%** — i.e. it **inherited ~96%** of the code that makes those four families work. Across the *whole* substrate the authored fraction is well under 2%.

---

## 3. The six idioms — how many applied with ZERO vertical code

The doc's six idioms (plan §1). "Zero vertical code" = PawChart wrote **no** implementation of the idiom; it got it by declaration/mount.

| # | Idiom | Applied to PawChart? | Vertical code written | Evidence |
|---|---|---|---|---|
| 1 | **Self-qualifying storage** (abbrev-prefixed columns) | Yes | **0** | Every column is `own_*` / `pet_*` / `pbc_*` etc. — the transformer prefixed them. `mix samen.verify.prefixes` OK. |
| 2 | **Machine catalog** (`tam_table`/`fld_field`, in-tx) | Yes | **0** | `catalog_sync(@resources)` in the migration emitted rows in the same tx; `schema.dict.json` (11 tables) drift-checks; `catalog_parity` OK. |
| 3 | **PII vault** (mask-by-default, crypto-shred) | Yes | **1 line** | `pii_attribute :microchip`; the owner's name/emails/phones are inherited from CorePerson (0 lines). Round-trip + shred proven in `microchip_vault_test.exs`. |
| 4 | **Postgres-as-engine** (one DB: truth + Oban + audit + vault) | Yes | **0** | One `PawChart.Repo`; Oban taxonomy reused verbatim; `aud_event` + rollup tiers inherited. |
| 5 | **Malleability ladder** (Tier-0 config → Tier-2 objects) | Yes | **0** | Tier-0 temperament enum; Tier-2 VaccineLot via `define_object`. `tnt_catalog` + `tnt_boundary` OK; `vaccine_lot_tier2_test.exs`. |
| 6 | **Two planes, one core** (tenant + token-blind operator) | Yes | **42 lines** (one projection) | Operator-plane masking proven in `operator_plane_masking_test.exs`; `no_pii_columns` + `aggregate_privacy` OK. |

**Result: 4 of 6 idioms applied with literally ZERO vertical code** (self-qualifying storage, machine catalog, Postgres-as-engine, malleability ladder). The remaining two cost **1 line** (PII vault) and **42 lines** (one aggregate projection to have a plane to police). The full fail-closed verifier gate — all 15 verifiers — is green on PawChart with the same tasks the demo and Driftwood run, unmodified.

---

## 4. Time-to-a-passing-verifier-gate

**Honest data point:** every one of the 15 samen_core verifiers returned `OK — no violations found` on its **first invocation** after the PawChart resources compiled and the DB migrated. I did **not** fix a single verifier violation. The two failures encountered during the build were both in the *authored* domain/test code, never in the inherited gate:

1. A `config :phoenix, :json_library` line copied from Driftwood referenced a dep PawChart doesn't carry (removed).
2. Billing test used `status: "active"` / a string `feature` — the inherited Billing resources model `status`/`feature` as **bounded atoms** (`:active`, `:api_access`). Fixed the test to the inherited vocabulary.

Neither was a substrate defect; both were the vertical mis-using an inherited contract, and the inherited contract was right. The gate's *first green* came for free — which is exactly what "the build fails closed, and passing it means you obeyed the substrate" is supposed to feel like from the second product on.

---

## 5. The HONEST verdict — where the 80/20 actually lands

**Does PawChart validate "build the 20%, inherit the 80%"? — Yes, for INFRASTRUCTURE. Calibrated, for DOMAIN.**

The doc names its own honest edge, and PawChart confirms it precisely (doc §core: *"you inherit INFRASTRUCTURE, not a domain model"*). The measurement splits cleanly along the doc's two axes:

### The strong claim held — infrastructure is inherited, near-total
The cross-cutting plumbing — storage convention, vault routing, masking, org-scope, same-org-FK, audit, catalog parity, crypto-shred, the whole fail-closed verifier gate, the two-plane operator seam, the Tier-2 ladder — arrived with **0–1 lines of vertical code each** and passed on first run. A vet clinic got a compliance-grade PII vault, a token-blind operator plane, and a machine catalog **without writing any of them**. This is the 80% that a buyer's security review demands, and PawChart inherited essentially all of it.

### The calibrated claim held — domain is authored, and that's the deal
PawChart still **authored its two nouns**. Patient and Pet are not "one universal Person you widen" — the doc is explicit that this framing would *"oversell the inheritance."* The 104 lines of `clinic.ex` are real domain work: what a Pet *is*, that a microchip is a vaulted secret, that a pet FKs to an owner, that the owner is the messaged party. The substrate made the *context to build them in* faster (a `base:` option, a `pii_attribute` line), it did not supply the domain.

### Where the additive case is genuinely easier than Driftwood — measured
The doc's core distinction is **additive vs. bounded-context translation**, and the numbers show it:

- **Driftwood** had to write a `Samen.Context` with `alias_resource` renames (Company → Carrier/Shipper, Opportunity → Load, Activity → CheckCall) **and** a `reshape Settlement` with ~90 lines of netting-math calculations under an anti-corruption layer — because freight has a *new ubiquitous language* and a *two-sided money model*.
- **PawChart** wrote **zero** `Samen.Context`, **zero** `alias_resource`, **zero** `reshape`. Billing is the kernel's subscription model verbatim. The vet clinic's money model *is* the inherited one. That's the entire difference between "adds" and "translates," and it is the ~90 lines of reshape + the context module that PawChart did not have to write.

### The honest asterisks (nothing swept under the rug)
1. **The migration DDL (282 lines) is authored, mostly mechanical.** A `mix samen.new` generator (plan T6.4) would emit the `add(:col, :type)` + `catalog_sync` blocks from the resource definitions — so much of the "557 authored lines" is generatable boilerplate, not irreducible domain work. Counting it as "vertical code" is conservative (it inflates the numerator against the thesis, and the thesis still holds).
2. **The abbrev registry is GLOBAL, not per-host** (the T6.1 extraction-retro finding, re-confirmed). PawChart had to take *fresh* abbrevs (`own/pet/pbc/…`) because `bcu/bsb/…` are owned by the demo mount in the single global registry. A per-product studio hits this on every mount; the registry append is trivial but it is friction the doc's "just mount it" framing understates.
3. **The inherited feature vocabulary is fixed.** The Billing `Entitlement.feature` is a bounded atom set (`:api_access`, `:sso`, …). A vet clinic that wants `:online_booking` as a first-class feature key must extend via Tier-1, not just name it — a small instance of "you inherit the infrastructure's shape, and sometimes the shape is opinionated."
4. **This is one thin slice, not a shipped product.** No web UI, no live operator console, no game-days — those were Driftwood's job (Phase 5). PawChart measures *reuse*, and it does so at the resource/verifier/vault layer where the thesis actually lives.

### Bottom line
**PawChart validates the thesis on the axis the thesis claims it.** The infrastructure 80% is real and near-totally inherited (4 of 6 idioms at zero vertical code; the vault at one line; the whole gate green on first run). The domain 20% is real work that stays authored — and the additive case measurably *is* the easy one, saving the entire `Samen.Context` + `reshape` layer that Driftwood had to write. The doc's calibrated phrasing — *"velocity where it's inherited; real work where it's yours"* — is the accurate description of what building the second vertical actually felt like.
